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
import nlp_adapter  # noqa: E402

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
                "last_consolidate": "", "deferred": 0, "message_offset": 0}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return {"cycles": int(value.get("cycles", 0)),
                "last_tick": value.get("last_tick", ""),
                "last_reflect": value.get("last_reflect", ""),
                "last_consolidate": value.get("last_consolidate", ""),
                "deferred": int(value.get("deferred", 0)),
                "message_offset": int(value.get("message_offset", 0))}
    except (json.JSONDecodeError, OSError, ValueError):
        return {"cycles": 0, "last_tick": "", "last_reflect": "",
                "last_consolidate": "", "deferred": 0, "message_offset": 0}


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
                 clock, reflect_every, consolidate_every, quiet_start, quiet_end,
                 message_file=None, affect_provider="lexicon", thread=True,
                 activity_file=None, workspace=None):
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
        self.message_file = message_file
        self.affect_provider = affect_provider
        self.thread = thread
        self.activity_file = activity_file
        self.workspace = workspace
        self.state = load_state(vault)
        self.sensed_texts = []

    def read_messages(self):
        """Read complete, newline-terminated lines appended since the cursor."""
        if not self.message_file:
            return []
        path = Path(self.message_file)
        if not path.exists():
            return []
        size = path.stat().st_size
        offset = int(self.state.get("message_offset", 0))
        if size < offset:
            offset = 0
        with path.open("rb") as handle:
            handle.seek(offset)
            data = handle.read()
        head, sep, tail = data.rpartition(b"\n")
        if sep:
            payload = head + b"\n"
            consumed = offset + len(payload)
        else:
            payload = b""
            consumed = offset
        lines = [line.strip() for line in payload.decode("utf-8", errors="replace").splitlines()
                 if line.strip()]
        self.state["message_offset"] = consumed
        return lines[-20:]

    def observe_row(self, step, affect, at):
        return {"step": step, "kind": "social", "salience": affect["salience"],
                "valence": affect["valence"], "subject": "user",
                "body": {"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                "at": at}

    def sense_messages(self):
        messages = self.read_messages()
        if not messages:
            self.sensed_texts = []
            return []
        self.sensed_texts = list(messages)
        status = driver.call(self.cli, self.vault, "evo-status")
        step = int(status["window"]["steps"])
        affects = []
        for text in messages:
            try:
                affects.append((text, nlp_adapter.affect(text, provider=self.affect_provider)))
            except RuntimeError as error:
                affects.append((text, {"error": str(error)[:300]}))
        good = [(text, affect) for text, affect in affects if "error" not in affect]
        stamp = self.clock.stamp()
        # One atomic batch per tick (续五十九); its bytes equal the sequential
        # singles, so the observable behaviour is unchanged. Only if the engine
        # refuses the whole batch do we fall back to per-message observes so a
        # single bad row cannot block the others.
        try:
            if good:
                driver.call(self.cli, self.vault, "evo-observe-batch",
                            rows=[self.observe_row(step + index + 1, affect, stamp)
                                  for index, (text, affect) in enumerate(good)])
        except RuntimeError:
            # Steps must be exactly state.steps+1 each, so a row that fails
            # without applying must not consume a number: count successes only.
            applied_fallback = 0
            for position, (text, affect) in enumerate(affects):
                if "error" in affect:
                    continue
                try:
                    driver.call(self.cli, self.vault, "evo-observe",
                                **self.observe_row(step + applied_fallback + 1, affect, stamp))
                    applied_fallback = applied_fallback + 1
                except RuntimeError as error:
                    affects[position] = (text, {"error": str(error)[:300]})
        observed = []
        applied = 0
        for text, affect in affects:
            if "error" in affect:
                observed.append({"error": affect["error"]})
                continue
            applied += 1
            appended = self.append_user_turn(text, offset=len(observed))
            observed.append({"step": step + applied, "valence": affect["valence"],
                             "arousal": affect["arousal"],
                             "topics": affect["topics"],
                             "provider": affect["provider"],
                             "thread_turn": appended})
        return observed

    def append_user_turn(self, text, offset=0):
        """Append a user turn to the open thread when the last turn is hers.

        `offset` spaces same-tick appends apart in time: a thread-append's
        event identity binds (role, at), so two messages in one tick must not
        share a stamp. A full thread (max_turns reached) is closed instead:
        the conversation rolls over, and the next proactive speech opens a
        fresh thread.
        """
        rows = driver.call(self.cli, self.vault, "evo-thread-list").get("threads", [])
        open_row = next((row for row in rows if row.get("status") == "open"), None)
        if open_row is None:
            return None
        turns = open_row.get("turns", [])
        if len(turns) >= open_row.get("max_turns", 16):
            # A full thread rolls over regardless of whose turn is last.
            driver.call(self.cli, self.vault, "evo-thread-close",
                        id=open_row["id"], at=self.clock.stamp_in(offset))
            return {"closed": open_row["id"], "reason": "thread_full"}
        if turns and turns[-1].get("role") != "agent":
            return None
        driver.call(self.cli, self.vault, "evo-thread-append", id=open_row["id"],
                    role="user", text=text, at=self.clock.stamp_in(offset))
        return {"id": open_row["id"], "role": "user"}

    def chain_parent(self, thread_row):
        """The latest delivered proactive reply continues the follow-up chain
        across daemon restarts; the thread's original parent is the fallback
        for a vault that never had a follow-up."""
        rows = driver.call(self.cli, self.vault, "evo-proactive-list").get("proactive", [])
        delivered = [row for row in rows
                     if row.get("status") == "done" and row.get("delivered_at")]
        if delivered:
            delivered.sort(key=lambda row: row.get("delivered_at") or "")
            return delivered[-1]["id"]
        return thread_row.get("last_proactive")

    def reply(self, user_texts):
        """Answer the last sensed user message on the open thread through the
        existing follow-up chain: open follow-up -> reply -> complete -> ack
        -> append the agent turn. A reply is a conversational response, not a
        proactive initiation, so the quiet-hours gate does not apply to it.
        One reply per tick (the chain allows a single in-flight request)."""
        if not user_texts:
            return None
        rows = driver.call(self.cli, self.vault, "evo-thread-list").get("threads", [])
        open_row = next((row for row in rows if row.get("status") == "open"), None)
        if open_row is None:
            return None
        turns = open_row.get("turns", [])
        if not turns or turns[-1].get("role") != "user":
            return None
        # The reply lands after every same-tick user append in time.
        reply_offset = len(user_texts)
        parent = self.chain_parent(open_row)
        if parent is None:
            return None
        user_text = user_texts[-1]
        try:
            opened = driver.call(self.cli, self.vault, "evo-proactive-followup",
                                 id=parent, user_text=user_text, driver=self.name,
                                 lease_until=self.clock.stamp_in(300),
                                 at=self.clock.stamp())
        except RuntimeError as error:
            code = str(error)
            if "evo_proactive_followup_depth" in code:
                # The chain has reached its depth limit: close the thread so
                # the conversation rolls over on the next proactive speech.
                driver.call(self.cli, self.vault, "evo-thread-close",
                            id=open_row["id"], at=self.clock.stamp_in(reply_offset))
                return {"closed": open_row["id"], "reason": "followup_depth"}
            if ("evo_proactive_backpressure" in code or
                    "evo_proactive_parent_not_delivered" in code):
                return {"skipped": code[:120]}
            raise
        try:
            if self.mock:
                text = (f"（mock 跟进·第{opened['turn']}轮）你说“{user_text[:40]}”，"
                        "我接着回应。")
                model = "mock"
            else:
                history = driver.parent_reply(self.cli, self.vault, parent)
                thread = driver.thread_turns(self.cli, self.vault)
                memories = driver.fetch_memory_lines(self.cli, self.vault, user_text,
                                                     self.workspace)
                text, model, _ = driver.curious_reply(driver.build_prompt(
                    opened, history, thread, now_dt=self.clock.current,
                    memories=memories))
            driver.call(self.cli, self.vault, "evo-proactive-complete",
                        id=opened["id"], driver=self.name, at=self.clock.stamp(),
                        result={"text": text, "model": model})
            acked = False
            if self.ack:
                driver.call(self.cli, self.vault, "evo-proactive-ack",
                            id=opened["id"], at=self.clock.stamp())
                acked = True
            driver.call(self.cli, self.vault, "evo-thread-append", id=open_row["id"],
                        role="agent", text=text, at=self.clock.stamp_in(reply_offset))
            return {"id": opened["id"], "text": text, "model": model,
                    "acked": acked, "turn": opened["turn"]}
        except Exception as error:  # noqa: BLE001 - record and keep the loop alive
            try:
                driver.call(self.cli, self.vault, "evo-proactive-fail",
                            id=opened["id"], driver=self.name,
                            reason=str(error)[:1000], at=self.clock.stamp())
            except RuntimeError:
                pass
            return {"id": opened["id"], "error": str(error)}

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
        history = driver.history_text(self.cli, self.vault, opened["id"])
        thread = driver.thread_turns(self.cli, self.vault)
        try:
            if self.mock:
                marker = "·续" if history else ""
                text = f"（mock 主动应答{marker}）第 {opened['context']['step']} 步，我想说句话。"
                model = "mock"
            else:
                rels = opened["context"]["relations"]
                query = rels[0]["subject"] if rels else ""
                memories = driver.fetch_memory_lines(self.cli, self.vault, query,
                                                     self.workspace)
                text, model, _ = driver.curious_reply(driver.build_prompt(
                    opened, history, thread, now_dt=self.clock.current,
                    memories=memories))
            driver.call(self.cli, self.vault, "evo-proactive-complete",
                        id=opened["id"], driver=self.name, at=self.clock.stamp(),
                        result={"text": text, "model": model})
            print(text)
            acked = False
            if self.ack:
                driver.call(self.cli, self.vault, "evo-proactive-ack",
                            id=opened["id"], at=self.clock.stamp())
                acked = True
            if self.thread:
                driver.open_thread(self.cli, self.vault, opened["id"], text,
                                   self.name, self.clock.stamp())
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

    def report_activity(self):
        """Report the main agent's presence to the engine.

        The host owns the signal (a file the agent touches while it works, or
        an explicit UTC stamp inside it). Reporting is monotonic and idempotent:
        the engine ignores older stamps, so a stale file cannot rewind the idle
        window. Without this, self-monitoring observations would look like
        activity and proactive speech could interrupt a busy agent.
        """
        if not self.activity_file:
            return None
        path = Path(self.activity_file)
        try:
            stat = path.stat()
        except OSError:
            return None
        stamp = None
        try:
            text = path.read_text(encoding="utf-8").strip()
        except (OSError, UnicodeDecodeError):
            text = ""
        if len(text) == 20 and text.endswith("Z"):
            try:
                datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
                stamp = text
            except ValueError:
                stamp = None
        if stamp is None:
            stamp = datetime.fromtimestamp(stat.st_mtime, timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ")
        if stamp == self.state.get("last_activity_report"):
            return stamp
        try:
            driver.call(self.cli, self.vault, "evo-activity", at=stamp)
        except RuntimeError as error:
            # A paused human gate blocks engine writes by design; the idle
            # window simply does not advance until it clears.
            if "evo_disabled" in str(error) or "evo_paused_human_gate" in str(error):
                return None
            raise
        self.state["last_activity_report"] = stamp
        return stamp

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
        activity = self.report_activity()
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
            messages = self.sense_messages()
        except RuntimeError as error:
            if "evo_paused_human_gate" in str(error):
                return {"at": at, "paused": str(error)}
            raise
        try:
            reply_row = self.reply(self.sensed_texts)
        except RuntimeError as error:
            if "evo_paused_human_gate" in str(error):
                return {"at": at, "paused": str(error)}
            raise
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
        return {"at": at, "cycle": self.state["cycles"], "activity": activity,
                "messages": messages,
                "reply": reply_row,
                "sense": sense, "speech": speech, "reflection": reflection,
                "expression": expression, "rsi": rsi}


def main() -> int:
    parser = argparse.ArgumentParser(description="Minimal digital-soul daemon for evo")
    parser.add_argument("--vault", required=True)
    parser.add_argument("--workspace", default=None,
                        help="registered workspace id for memory leads")
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
    parser.add_argument("--message-file", default=None,
                        help="host-owned newline-delimited user messages to sense")
    parser.add_argument("--activity-file", default=None,
                        help="host-owned presence file: an explicit UTC stamp inside it (or its mtime) "
                             "is reported as agent activity; while it moves, proactive speech stays closed")
    parser.add_argument("--no-thread", action="store_true",
                        help="do not open a conversation thread after delivery")
    parser.add_argument("--affect-provider", default="auto",
                        choices=["auto", "lexicon", "llm", "hanlp"],
                        help="NLP provider for user-message affect (auto = HanLP first, "
                             "self-written lexicon fallback)")
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
                    args.quiet_start, args.quiet_end,
                    args.message_file, args.affect_provider,
                    not args.no_thread, args.activity_file, args.workspace)
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