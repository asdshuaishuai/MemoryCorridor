#!/usr/bin/env python3
"""Proactive agent driver (续三十三).

When the emotion/personality subsystem is enabled, its own affect state decides
to speak: this host-side driver polls `evo-proactive-due`, opens a request,
calls an OpenAI-compatible LLM, and writes the reply back with
`evo-proactive-complete`. With `--ack`, a successful print is followed by
`evo-proactive-ack` (stdout is the delivery channel; omit it when the reply is
only logged). On restart it fails its own expired claims so a crash cannot
leave the single in-flight slot blocked forever. The MoonBit engine never calls
a model; disabling evo (`evo-policy enabled=false`) stops the loop because every
evo op returns `evo_disabled`.

Environment for real calls:
  EVO_LLM_ENDPOINT  base URL, e.g. https://api.example.com/v1
  EVO_LLM_MODEL     model id
  EVO_LLM_API_KEY   optional bearer token

Usage:
  python3 scripts/evo_agent_driver.py --vault /abs/vault --once --mock
  python3 scripts/evo_agent_driver.py --vault /abs/vault --interval 15
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
                         capture_output=True, text=True, check=True, timeout=60)
    response = json.loads(run.stdout)
    if not response["ok"]:
        raise RuntimeError(response.get("error", "engine error"))
    return response["result"]


def build_prompt(request) -> str:
    """Host-owned prompt template; the engine only supplies structured tokens."""
    context = request["context"]
    emotion = context["emotion"]
    relations = ", ".join(
        f'{row["subject"]}(trust={row["trust"]:.2f})' for row in context["relations"][:3]
    ) or "无"
    return (
        "你是它的内在声音。根据以下内部状态，主动对用户说一句简短、自然的话（不超过 80 字），"
        "不要解释你在做什么，不要提及 JSON 或系统。\n"
        f"情绪(效价/唤醒/支配)：{emotion[0]:.2f}/{emotion[1]:.2f}/{emotion[2]:.2f}\n"
        f"冲动强度：{context['impulse']:.2f}；触发原因：{request['reason']}；"
        f"紧迫度：{request['urgency']:.2f}\n"
        f"关系：{relations}\n"
        f"最近步数：{context['step']}"
    )


def llm(prompt: str):
    endpoint = os.environ.get("EVO_LLM_ENDPOINT")
    model = os.environ.get("EVO_LLM_MODEL")
    key = os.environ.get("EVO_LLM_API_KEY")
    if not endpoint or not model:
        raise RuntimeError("set EVO_LLM_ENDPOINT and EVO_LLM_MODEL (OpenAI-compatible /chat/completions)")
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 256,
    }).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    request = urllib.request.Request(endpoint.rstrip("/") + "/chat/completions",
                                     data=body, headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload["choices"][0]["message"]["content"].strip(), model


def sweep_stale(cli: str, vault: str, driver: str) -> None:
    """Fail this driver's own expired claims so a crash cannot wedge the slot."""
    rows = call(cli, vault, "evo-proactive-list")["proactive"]
    stamp = now()
    for row in rows:
        lease = row.get("lease_until")
        if (row["status"] == "claimed" and row["driver"] == driver and
                lease and lease <= stamp):
            try:
                call(cli, vault, "evo-proactive-fail", id=row["id"], driver=driver,
                     reason="driver lease expired before delivery", at=stamp)
                print(f"driver: released stale claim {row['id'][:12]}", file=sys.stderr)
            except RuntimeError as error:
                print(f"driver: stale claim release skipped: {error}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Proactive agent driver for the evo subsystem")
    parser.add_argument("--vault", required=True)
    parser.add_argument("--cli", default=str(DEFAULT_CLI))
    parser.add_argument("--driver", default="evo-agent-driver")
    parser.add_argument("--interval", type=float, default=15.0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--mock", action="store_true",
                        help="skip the network and return a deterministic mock reply (tests)")
    parser.add_argument("--ack", action="store_true",
                        help="acknowledge delivery after printing (stdout is the delivery channel)")
    args = parser.parse_args()
    while True:
        at = now()
        try:
            sweep_stale(args.cli, args.vault, args.driver)
            due = call(args.cli, args.vault, "evo-proactive-due", at=at)
        except RuntimeError as error:
            print(f"driver: skip ({error})", file=sys.stderr)
            if args.once:
                return 0
            time.sleep(args.interval)
            continue
        if not due["due"]:
            if args.once:
                print("driver: nothing due")
                return 0
            time.sleep(args.interval)
            continue
        opened = call(args.cli, args.vault, "evo-proactive-open",
                      driver=args.driver, lease_until=iso_in(300), at=at)
        try:
            if args.mock:
                text = f"（mock 主动应答）现在是第 {opened['context']['step']} 步，我想和你说句话。"
                model = "mock"
            else:
                text, model = llm(build_prompt(opened))
        except Exception as error:  # noqa: BLE001 - driver must record, not crash
            call(args.cli, args.vault, "evo-proactive-fail", id=opened["id"],
                 driver=args.driver, reason=str(error)[:1000], at=now())
            print(f"driver: llm failed: {error}", file=sys.stderr)
            if args.once:
                return 1
            time.sleep(args.interval)
            continue
        call(args.cli, args.vault, "evo-proactive-complete", id=opened["id"],
             driver=args.driver, at=now(), result={"text": text, "model": model})
        print(text)
        if args.ack:
            call(args.cli, args.vault, "evo-proactive-ack", id=opened["id"], at=now())
        if args.once:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())