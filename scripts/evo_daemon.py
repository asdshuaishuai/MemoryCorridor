#!/usr/bin/env python3
"""Minimal digital-soul daemon (续四十).

One process, one loop, one schedule table. It keeps the soul continuous between
turns without putting threads, clocks or models into the MoonBit engine:

  sense knowledge tensions -> proactive speech -> expression frame -> RSI pass

The engine remains a pure library; this host daemon owns timing, the external
LLM call and delivery. If evo is disabled, the daemon stops cleanly (the soul
switch is off). Crash recovery relies on the engine's leases/ack/takeover.

Usage:
  python3 scripts/evo_daemon.py --vault /abs/vault --once --mock
  python3 scripts/evo_daemon.py --vault /abs/vault --interval 60 --with-rsi
"""
import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evo_agent_driver as driver  # noqa: E402
import evo_knowledge_bridge as bridge  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RSI_DRIVER = ROOT / "scripts/rsi_agent_driver.py"


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_in(seconds: int) -> str:
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def state_path(vault: str) -> Path:
    return Path(vault) / ".corridor" / "evo-daemon" / "state.json"


def load_state(vault: str) -> dict:
    path = state_path(vault)
    if not path.exists():
        return {"cycles": 0, "last_tick": ""}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return {"cycles": int(value.get("cycles", 0)),
                "last_tick": value.get("last_tick", "")}
    except (json.JSONDecodeError, OSError, ValueError):
        return {"cycles": 0, "last_tick": ""}


def save_state(vault: str, state: dict) -> None:
    path = state_path(vault)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, ensure_ascii=False, sort_keys=True), encoding="utf-8")


class Daemon:
    def __init__(self, cli, vault, name, mock, ack, with_rsi, expression, limit):
        self.cli = cli
        self.vault = vault
        self.name = name
        self.mock = mock
        self.ack = ack
        self.with_rsi = with_rsi
        self.expression = expression
        self.limit = limit
        self.state = load_state(vault)

    def speak(self):
        try:
            due = driver.call(self.cli, self.vault, "evo-proactive-due", at=now())
        except RuntimeError as error:
            if "evo_paused_human_gate" in str(error):
                return {"paused": str(error)}
            raise
        if not due["due"]:
            return None
        opened = driver.call(self.cli, self.vault, "evo-proactive-open",
                             driver=self.name, lease_until=iso_in(300), at=now())
        try:
            if self.mock:
                text = f"（mock 主动应答）第 {opened['context']['step']} 步，我想说句话。"
                model = "mock"
            else:
                text, model = driver.llm(driver.build_prompt(opened))
            driver.call(self.cli, self.vault, "evo-proactive-complete",
                        id=opened["id"], driver=self.name, at=now(),
                        result={"text": text, "model": model})
            print(text)
            acked = False
            if self.ack:
                driver.call(self.cli, self.vault, "evo-proactive-ack",
                            id=opened["id"], at=now())
                acked = True
            return {"id": opened["id"], "text": text, "model": model,
                    "acked": acked, "reclaimed": opened.get("reclaimed", False)}
        except Exception as error:  # noqa: BLE001 - record and keep the loop alive
            try:
                driver.call(self.cli, self.vault, "evo-proactive-fail",
                            id=opened["id"], driver=self.name,
                            reason=str(error)[:1000], at=now())
            except RuntimeError:
                pass
            return {"id": opened["id"], "error": str(error)}

    def rsi_pass(self):
        if not self.with_rsi:
            return None
        due = driver.call(self.cli, self.vault, "dream-due", at=now())
        if not due["due"]:
            return {"due": False, "reasons": due["reasons"]}
        args = [sys.executable, str(RSI_DRIVER), "--vault", self.vault,
                "--cli", self.cli, "--once", "--driver", self.name + "-rsi"]
        if self.mock:
            args.append("--mock")
        run = subprocess.run(args, capture_output=True, text=True, timeout=300)
        if run.returncode != 0:
            return {"error": run.stderr.strip()[:1000]}
        try:
            return json.loads(run.stdout.strip().splitlines()[-1])
        except (json.JSONDecodeError, IndexError):
            return {"output": run.stdout.strip()[:1000]}

    def tick(self):
        at = now()
        try:
            status = driver.call(self.cli, self.vault, "evo-status")
        except RuntimeError as error:
            if "evo_disabled" in str(error):
                return {"stopped": "evo_disabled", "at": at}
            raise
        if not status.get("initialized"):
            return {"stopped": "evo_not_initialized", "at": at}
        driver.sweep_stale(self.cli, self.vault, self.name)
        # Speak from the state the soul already has, then absorb the new
        # perception. A fresh negative observation must not swallow a gate that
        # was already open.
        speech = self.speak()
        if isinstance(speech, dict) and "paused" in speech:
            return {"at": at, "paused": speech["paused"]}
        try:
            sense = bridge.run_pass(self.cli, self.vault, self.limit, True)
        except RuntimeError as error:
            if "evo_paused_human_gate" in str(error):
                return {"at": at, "paused": str(error)}
            raise
        expression = None
        if self.expression:
            expression = driver.call(self.cli, self.vault, "evo-expression", at=now())
        rsi = self.rsi_pass()
        self.state["cycles"] += 1
        self.state["last_tick"] = at
        save_state(self.vault, self.state)
        return {"at": at, "cycle": self.state["cycles"], "sense": sense,
                "speech": speech, "expression": expression, "rsi": rsi}


def main() -> int:
    parser = argparse.ArgumentParser(description="Minimal digital-soul daemon for evo")
    parser.add_argument("--vault", required=True)
    parser.add_argument("--cli", default=str(driver.DEFAULT_CLI))
    parser.add_argument("--driver", default="evo-daemon")
    parser.add_argument("--interval", type=float, default=60.0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--mock", action="store_true",
                        help="skip the network and use deterministic replies (tests)")
    parser.add_argument("--no-ack", action="store_true",
                        help="do not acknowledge delivery after printing")
    parser.add_argument("--with-rsi", action="store_true",
                        help="run one RSI pass when dream-due says due")
    parser.add_argument("--no-expression", action="store_true",
                        help="skip the expression frame")
    parser.add_argument("--limit", type=int, default=3,
                        help="knowledge tensions per tick (1..50)")
    args = parser.parse_args()
    if not 1 <= args.limit <= 50:
        parser.error("--limit must be in 1..50")
    daemon = Daemon(args.cli, args.vault, args.driver, args.mock, not args.no_ack,
                    args.with_rsi, not args.no_expression, args.limit)
    try:
        while True:
            try:
                summary = daemon.tick()
                print(json.dumps(summary, ensure_ascii=False))
                if summary.get("stopped"):
                    return 0
            except Exception as error:  # noqa: BLE001 - a daemon must not die mid-tick
                print(f"daemon: tick failed: {error}", file=sys.stderr)
                if args.once:
                    return 1
            if args.once:
                return 0
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())