#!/usr/bin/env python3
"""RSI host driver (续三十四).

Drives the deterministic RSI loop the engine exposes:

  dream-due -> dream-plan -> dream-open -> dream-work-open -> claim ->
  LLM judgments -> complete -> close (retained/rejected)

The MoonBit engine never calls a model: it publishes an opportunity set and a
structured work outbox; this host-side driver answers the semantic judgments
with an OpenAI-compatible endpoint (or `--mock` in tests) and records them.
It never writes knowledge pages and never bypasses the normal commit flow.

Usage:
  python3 scripts/rsi_agent_driver.py --vault /abs/vault --once --mock
  python3 scripts/rsi_agent_driver.py --vault /abs/vault --interval 300

Environment for real calls:
  RSI_LLM_ENDPOINT  base URL, e.g. https://api.example.com/v1
  RSI_LLM_MODEL     model id
  RSI_LLM_API_KEY   optional bearer token
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLI = ROOT / "_build/native/debug/build/cli/cli.exe"


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_in(seconds: int) -> str:
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def call(cli: str, vault: str, op: str, **fields):
    run = subprocess.run([cli], input=json.dumps(dict(fields, op=op, vault=vault)) + "\n",
                         capture_output=True, text=True, check=True, timeout=120)
    response = json.loads(run.stdout)
    if not response["ok"]:
        raise RuntimeError("%s: %s" % (op, response.get("error", "engine error")))
    return response["result"]


def build_prompt(task) -> str:
    """Host-owned prompt: the engine only supplies the structured task view."""
    return (
        "你在参与一次知识库的自我改进轮次。请只输出一个 JSON 对象，"
        '形如 {"judgments": {"<不超过256字节的键>": <数字/布尔/不超过1024字节的字符串>}}，'
        "不要输出解释或 markdown。\n"
        f"任务类型：{task['kind']}\n主体：{task['subject']}\n"
        f"优先级：{task['priority']}\n"
        "请给出你对这个主体的判断（例如是否值得建页、风险、下一步）。"
    )


def parse_judgments(text: str):
    """Accept one JSON object of scalar judgments; anything else is a failure."""
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as error:
        raise RuntimeError("model did not return JSON: %s" % error)
    judgments = payload.get("judgments") if isinstance(payload, dict) else None
    if not isinstance(judgments, dict):
        raise RuntimeError("model JSON lacks a judgments object")
    clean = {}
    for key, value in judgments.items():
        if not isinstance(key, str) or not key or len(key.encode()) > 256:
            raise RuntimeError("judgment key invalid")
        if isinstance(value, str) and len(value.encode()) > 1024:
            raise RuntimeError("judgment value invalid")
        if not isinstance(value, (str, int, float, bool)):
            raise RuntimeError("judgment value must be scalar")
        clean[key] = value
    if len(clean) > 32:
        raise RuntimeError("too many judgments")
    return {"judgments": clean, "proposals": []}


def llm(prompt: str):
    endpoint = os.environ.get("RSI_LLM_ENDPOINT")
    model = os.environ.get("RSI_LLM_MODEL")
    key = os.environ.get("RSI_LLM_API_KEY")
    if not endpoint or not model:
        raise RuntimeError("set RSI_LLM_ENDPOINT and RSI_LLM_MODEL (OpenAI-compatible /chat/completions)")
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 512,
    }).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    request = urllib.request.Request(endpoint.rstrip("/") + "/chat/completions",
                                     data=body, headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload["choices"][0]["message"]["content"].strip()


def process_task(cli: str, vault: str, task, driver: str, mock: bool) -> str:
    call(cli, vault, "dream-work-claim", id=task["id"], driver=driver,
         lease_until=iso_in(300), at=now())
    try:
        if mock:
            result = {"judgments": {"task": task["id"], "verdict": "mock-reviewed"},
                      "proposals": []}
        else:
            result = parse_judgments(llm(build_prompt(task)))
        call(cli, vault, "dream-work-complete", id=task["id"], driver=driver,
             at=now(), result=result)
        return "done"
    except Exception as error:  # noqa: BLE001 - record, never crash the loop
        call(cli, vault, "dream-work-fail", id=task["id"], driver=driver,
             reason=str(error)[:1000], at=now())
        print(f"driver: task {task['id'][:12]} failed: {error}", file=sys.stderr)
        return "failed"


def drain(cli: str, vault: str, round_id: str, driver: str, mock: bool, limit: int) -> dict:
    """Open and answer work until no pending task remains for this round."""
    opened = 0
    done = 0
    failed = 0
    for _ in range(16):
        created = call(cli, vault, "dream-work-open", round=round_id,
                       limit=limit, at=now())
        opened += created["created"]
        work = call(cli, vault, "dream-work-list")["work"]
        pending = [w for w in work if w["round"] == round_id and w["status"] == "pending"]
        for task in pending:
            outcome = process_task(cli, vault, task, driver, mock)
            done += outcome == "done"
            failed += outcome == "failed"
        if created["created"] == 0 and not pending:
            break
    return {"opened": opened, "done": done, "failed": failed}


def run_pass(cli: str, vault: str, driver: str, mock: bool, limit: int, space) -> dict:
    rounds = call(cli, vault, "dream-list")["dreams"]
    open_rounds = [r for r in rounds if r["status"] == "open"]
    opened = None
    if open_rounds:
        round_id = open_rounds[0]["id"]
    else:
        due = call(cli, vault, "dream-due", at=now())
        if not due["due"]:
            return {"due": False, "reasons": due["reasons"], "closed": None}
        plan = call(cli, vault, "dream-plan", limit=limit,
                    **({"space": space} if space else {}))
        fields = {"baseline": plan["fingerprint"], "at": now()}
        if space:
            fields["space"] = space
        opened = call(cli, vault, "dream-open", **fields)
        round_id = opened["id"]
    try:
        work = drain(cli, vault, round_id, driver, mock, limit)
        note = f"driver {driver}: {work['done']} done, {work['failed']} failed"
        decision = "rejected" if work["failed"] else "retained"
    except RuntimeError as error:
        # The knowledge baseline moved after the round opened (a new source or
        # page). Work cannot be opened against a stale round; reject it and
        # leave the reason in the ledger instead of retrying forever.
        if "dream_stale_baseline" not in str(error):
            raise
        work = {"opened": 0, "done": 0, "failed": 0}
        note = f"driver {driver}: knowledge drifted ({error})"
        decision = "rejected"
    try:
        closed = call(cli, vault, "dream-close", id=round_id,
                      decision=decision, at=now(), note=note)
    except RuntimeError as error:
        if "dream_compat" not in str(error):
            raise
        closed = call(cli, vault, "dream-close", id=round_id,
                      decision="rejected", at=now(),
                      note=(note + "; " + str(error))[:1024])
    return {"due": True, "opened": round_id if opened else None,
            "work": work, "closed": closed["status"], "decision": decision}


def main() -> int:
    parser = argparse.ArgumentParser(description="RSI host driver")
    parser.add_argument("--vault", required=True)
    parser.add_argument("--cli", default=str(DEFAULT_CLI))
    parser.add_argument("--driver", default="rsi-agent-driver")
    parser.add_argument("--interval", type=float, default=300.0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--mock", action="store_true",
                        help="skip the network and use deterministic judgments (tests)")
    parser.add_argument("--limit", type=int, default=5,
                        help="opportunities/tasks per batch (1..50)")
    parser.add_argument("--space", default=None,
                        help="optional vector space for missing_vector opportunities")
    args = parser.parse_args()
    if not 1 <= args.limit <= 50:
        parser.error("--limit must be in 1..50")
    while True:
        try:
            summary = run_pass(args.cli, args.vault, args.driver, args.mock,
                               args.limit, args.space)
            print(json.dumps(summary, ensure_ascii=False))
        except Exception as error:  # noqa: BLE001 - a scheduler must not die
            print(f"driver: pass failed: {error}", file=sys.stderr)
            if args.once:
                return 1
        if args.once:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())