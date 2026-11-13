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
        return {"cycles": 0, "last_tick": "", "last_reflect": "",
                "last_consolidate": "", "deferred": 0}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return {"cycles": int(value.get("cycles", 0)),
                "last_tick": value.get("last_tick", ""),
                "last_reflect": value.get("last_reflect", ""),
                "last_consolidate": value.get("last_consolidate", ""),
                "deferred": int(value.get("deferred", 0))}
    except (json.JSONDecodeError, OSError, ValueError):
        return {"cycles": 0, "last_tick": "", "last_reflect": "",
                "last_consolidate": "", "deferred": 0}


def save_state(vault: str, state: dict) -> None:
    path = state_path(vault)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, ensure_ascii=False, sort_keys=True), encoding="utf-8")


class Clock:
    """Real or simulated wall clock; tests pass --now and --tick-seconds."""

    def __init__(self, start=None, tick_seconds=0):
        if start:
            self.current = datetime.strptime(start, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc)
        else:
            self.current = None
        self.tick_seconds = tick_seconds

    def stamp(self):
        if self.current is None:
            return now()
        return self.current.strftime("%Y-%m-%dT%H:%M:%SZ")

    def stamp_in(self, seconds):
        if self.current is None:
            return iso_in(seconds)
        return (self.current + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def advance(self):
        if self.current is not None:
            self.current = self.current + timedelta(seconds=self.tick_seconds)

    def hour(self):
        current = self.current or datetime.now(timezone.utc)
        return current.hour

    def seconds_since(self, text):
        if not text:
            return None
        try:
            value = datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc)
        except ValueError:
            return None
        current = self.current or datetime.now(timezone.utc)
        return (current - value).total_seconds()


class Daemon:
    def __init__(self, cli, vault, name, mock, ack, with_rsi, expression, limit,
                 clock, reflect_every, consolidate_every, quiet_start, quiet_end):
        self.cli = cli
        self.vault = vault
        self.name = name
        self.mock = mock
        self.ack = ack
        self.with_rsi = with_rsi
        self.expression = expression
        self.limit = limit
        self.clock = clock
        self.reflect_every = reflect_every
        self.consolidate_every = consolidate_every
        self.quiet_start = quiet_start
        self.quiet_end = quiet_end
        self.state = load_state(vault)

    def is_quiet(self):
        if self.quiet_start < 0:
            return False
        hour = self.clock.hour()
        if self.quiet_start < self.quiet_end:
            return self.quiet_start <= hour < self.quiet_end
        return hour >= self.quiet_start or hour < self.quiet_end

    def schedule_due(self, key, every):
        if every <= 0:
            return False
        elapsed = self.clock.seconds_since(self.state.get(key, ""))
        return elapsed is None or elapsed >= every

    def speak(self):
        try:
            due = driver.call(self.cli, self.vault, "evo-proactive-due", at=self.clock.stamp())
        except RuntimeError as error:
            if "evo_paused_human_gate" in str(error):
                return {"paused": str(error)}
            raise
        if not due["due"]:
            return None
        opened = driver.call(self.cli, self.vault, "evo-proactive-open",
                             driver=self.name, lease_until=self.clock.stamp_in(300), at=self.clock.stamp())
        try:
            if self.mock:
                text = f"（mock 主动应答）第 {opened['context']['step']} 步，我想说句话。"
                model = "mock"
            else:
                text, model = driver.llm(driver.build_prompt(opened))
            driver.call(self.cli, self.vault, "evo-proactive-complete",
                        id=opened["id"], driver=self.name, at=self.clock.stamp(),
                        result={"text": text, "model": model})
            print(text)
            acked = False
            if self.ack:
                driver.call(self.cli, self.vault, "evo-proactive-ack",
                            id=opened["id"], at=self.clock.stamp())
                acked = True
            return {"id": opened["id"], "text": text, "model": model,
                    "acked": acked, "reclaimed": opened.get("reclaimed", False)}
        except Exception as error:  # noqa: BLE001 - record and keep the loop alive
            try:
                driver.call(self.cli, self.vault, "evo-proactive-fail",
                            id=opened["id"], driver=self.name,
                            reason=str(error)[:1000], at=self.clock.stamp())
            except RuntimeError:
                pass
            return {"id": opened["id"], "error": str(error)}

    def rsi_pass(self):
        if not self.with_rsi:
            return None
        if not self.schedule_due("last_consolidate", self.consolidate_every):
            return None
        self.state["last_consolidate"] = self.clock.stamp()
        due = driver.call(self.cli, self.vault, "dream-due", at=self.clock.stamp())
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

    def reflect(self):
        """Read the cross-round ledger and feed it back as an inner-life event."""
        retro = driver.call(self.cli, self.vault, "dream-retro")
        status = driver.call(self.cli, self.vault, "evo-status")
        step = int(status["window"]["steps"]) + 1
        salience = min(1.0, 0.2 + retro["work"]["total"] / 20.0)
        valence = max(-1.0, min(1.0, retro["retention_rate"] * 2.0 - 1.0))
        driver.call(self.cli, self.vault, "evo-observe", step=step, kind="task",
                    salience=salience, valence=valence, subject="reflection",
                    body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                    at=self.clock.stamp())
        return {"step": step, "retention_rate": retro["retention_rate"],
                "rounds": retro["rounds"], "work": retro["work"]}

    def tick(self):
        at = self.clock.stamp()
        try:
            status = driver.call(self.cli, self.vault, "evo-status")
        except RuntimeError as error:
            if "evo_disabled" in str(error):
                return {"stopped": "evo_disabled", "at": at}
            raise
        if not status.get("initialized"):
            return {"stopped": "evo_not_initialized", "at": at}
        driver.sweep_stale(self.cli, self.vault, self.name, stamp=at)
        # Speak from the state the soul already has, then absorb the new
        # perception. A fresh negative observation must not swallow a gate that
        # was already open.
        if self.is_quiet():
            try:
                due = driver.call(self.cli, self.vault, "evo-proactive-due",
                                  at=self.clock.stamp())
            except RuntimeError as error:
                if "evo_paused_human_gate" in str(error):
                    return {"at": at, "paused": str(error)}
                raise
            if due["due"]:
                self.state["deferred"] = self.state.get("deferred", 0) + 1
                self.state["last_deferred_at"] = at
                speech = {"quiet": True, "deferred": True,
                          "reason": due["reason"]}
            else:
                speech = {"quiet": True, "deferred": False}
        else:
            deferred_before = self.state.get("deferred", 0)
            speech = self.speak()
            if isinstance(speech, dict) and "paused" in speech:
                return {"at": at, "paused": speech["paused"]}
            if deferred_before > 0:
                if speech is not None:
                    speech["woke_from_night"] = True
                self.state["deferred"] = 0
        try:
            sense = bridge.run_pass(self.cli, self.vault, self.limit, True,
                                    stamp=self.clock.stamp())
        except RuntimeError as error:
            if "evo_paused_human_gate" in str(error):
                return {"at": at, "paused": str(error)}
            raise
        reflection = None
        if self.schedule_due("last_reflect", self.reflect_every):
            try:
                reflection = self.reflect()
            except RuntimeError as error:
                if "evo_paused_human_gate" not in str(error):
                    raise
                reflection = {"paused": str(error)}
            self.state["last_reflect"] = at
        expression = None
        if self.expression:
            expression = driver.call(self.cli, self.vault, "evo-expression",
                                     at=self.clock.stamp())
        rsi = self.rsi_pass()
        self.state["cycles"] += 1
        self.state["last_tick"] = at
        save_state(self.vault, self.state)
        self.clock.advance()
        return {"at": at, "cycle": self.state["cycles"], "sense": sense,
                "speech": speech, "reflection": reflection,
                "expression": expression, "rsi": rsi}


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
    parser.add_argument("--reflect-every", type=int, default=600,
                        help="seconds between reflection passes (0 disables)")
    parser.add_argument("--consolidate-every", type=int, default=1800,
                        help="seconds between RSI consolidation passes (0 disables)")
    parser.add_argument("--quiet-start", type=int, default=22,
                        help="quiet-hours start hour (0..23; -1 disables)")
    parser.add_argument("--quiet-end", type=int, default=7,
                        help="quiet-hours end hour (0..23)")
    parser.add_argument("--now", default=None,
                        help="simulated start time YYYY-MM-DDTHH:MM:SSZ (tests)")
    parser.add_argument("--tick-seconds", type=int, default=0,
                        help="simulated seconds advanced per tick (tests; default=interval)")
    parser.add_argument("--ticks", type=int, default=0,
                        help="run this many ticks then exit (0 = until stopped)")
    args = parser.parse_args()
    if not 1 <= args.limit <= 50:
        parser.error("--limit must be in 1..50")
    clock = Clock(args.now, args.tick_seconds or int(args.interval))
    daemon = Daemon(args.cli, args.vault, args.driver, args.mock, not args.no_ack,
                    args.with_rsi, not args.no_expression, args.limit, clock,
                    args.reflect_every, args.consolidate_every,
                    args.quiet_start, args.quiet_end)
    target = args.ticks or (1 if args.once else 0)
    try:
        while True:
            try:
                summary = daemon.tick()
                print(json.dumps(summary, ensure_ascii=False))
                if summary.get("stopped"):
                    return 0
            except Exception as error:  # noqa: BLE001 - a daemon must not die mid-tick
                print(f"daemon: tick failed: {error}", file=sys.stderr)
                if args.once or args.ticks:
                    return 1
            if target and daemon.state["cycles"] >= target:
                return 0
            if args.once:
                return 0
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())