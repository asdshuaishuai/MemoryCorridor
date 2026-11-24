#!/usr/bin/env python3
"""Conversation thread contract end-to-end (续五十五).

User turns now enter the engine: a thread starts from a delivered proactive
reply, the host appends user/agent turns, and the daemon/agent driver speak with
the thread as context. Pins the state machine (open/append/close/limit/replay),
the delivered-parent gate, and the full daemon loop (speech -> thread -> user
message -> user turn).
"""
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
DAEMON = ROOT / "scripts/evo_daemon.py"


def at(seconds: int) -> str:
    base = datetime(2026, 11, 17, 2, 0, 0, tzinfo=timezone.utc)
    return (base + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-evo-thread-") as work:
        vault = Path(work)

        def call(op, error=None, **fields):
            run = subprocess.run([str(EXE)],
                                 input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                 text=True, capture_output=True, check=True, timeout=120)
            response = json.loads(run.stdout)
            if error:
                assert not response["ok"] and error in response["error"], response
                return response
            assert response["ok"], response
            return response["result"]

        call("init", purpose="对话线程契约端到端")
        call("evo-policy", enabled=True, at=at(0))
        call("evo-init", seed=7, at=at(1))
        step = 0
        due = None
        for _ in range(160):
            step += 1
            call("evo-observe", step=step, kind="social", salience=1.0, valence=1.0,
                 subject="user", body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                 at=at(10 + step))
            if call("evo-proactive-due", at=at(1900 + step))["due"]:
                due = True
                break
        assert due, "affect never reached the gate"
        parent = call("evo-proactive-open", driver="driver-a",
                      lease_until=at(200000), at=at(3000))
        call("evo-proactive-complete", id=parent["id"], driver="driver-a",
             at=at(3001), result={"text": "主动问候", "model": "mock"})
        call("evo-proactive-ack", id=parent["id"], at=at(3002))

        # 1. open / replay / already-open / delivered-parent gate.
        opened = call("evo-thread-open", proactive=parent["id"], text="主动问候",
                      driver="driver-a", at=at(3010))
        assert opened["status"] == "open" and opened["turns"] == 1, opened
        assert call("evo-thread-open", proactive=parent["id"], text="主动问候",
                    driver="driver-a", at=at(3010))["replayed"] is True
        call("evo-thread-open", proactive=parent["id"], text="另一句",
             driver="driver-a", at=at(3010), error="evo_thread_already_open")
        for _ in range(8):
            step += 1
            call("evo-observe", step=step, kind="social", salience=1.0, valence=1.0,
                 subject="user", body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                 at=at(10 + step))
        claimed = call("evo-proactive-open", driver="driver-b",
                       lease_until=at(300001), at=at(3020))
        call("evo-thread-open", proactive=claimed["id"], text="未投递",
             driver="driver-b", at=at(3021), error="evo_thread_parent_not_done")
        call("evo-proactive-complete", id=claimed["id"], driver="driver-b",
             at=at(3022), result={"text": "未投递", "model": "mock"})
        call("evo-thread-open", proactive=claimed["id"], text="已完成未送达",
             driver="driver-b", at=at(3023), error="evo_thread_parent_not_delivered")

        # 2. append / replay / role+text validation / turn limit.
        assert call("evo-thread-append", id=opened["id"], role="user",
                    text="你为什么这么说？", at=at(3020))["turns"] == 2
        assert call("evo-thread-append", id=opened["id"], role="user",
                    text="你为什么这么说？", at=at(3020))["replayed"] is True
        call("evo-thread-append", id=opened["id"], role="boss", text="x",
             at=at(3021), error="evo_thread_role_invalid")
        call("evo-thread-append", id=opened["id"], role="user", text="",
             at=at(3022), error="evo_thread_text_invalid")
        call("evo-thread-append", id="d" * 64, role="user", text="x",
             at=at(3023), error="evo_thread_not_found")
        for index in range(3, 17):
            call("evo-thread-append", id=opened["id"], role="user" if index % 2 else "agent",
                 text=f"第{index}轮", at=at(3000 + index))
        assert call("evo-thread-list")["counts"]["open"] == 1
        call("evo-thread-append", id=opened["id"], role="user", text="overflow",
             at=at(3100), error="evo_thread_turn_limit")

        # 3. close terminal state and read-only list.
        closed = call("evo-thread-close", id=opened["id"], at=at(3200))
        assert closed["status"] == "closed", closed
        call("evo-thread-append", id=opened["id"], role="user", text="late",
             at=at(3201), error="evo_thread_closed")
        assert call("evo-thread-close", id=opened["id"], at=at(3200))["replayed"] is True
        call("evo-thread-close", id=opened["id"], at=at(3201),
             error="evo_thread_terminal")
        listed = call("evo-thread-list")
        assert listed["counts"] == {"open": 0, "closed": 1}, listed
        assert len(listed["threads"][0]["turns"]) == 16, listed["threads"][0]
        assert call("evo-thread-list") == listed

    # 4. daemon loop: speech opens the thread, a user message appends her turn.
    with tempfile.TemporaryDirectory(prefix="corridor-evo-thread-daemon-") as work:
        vault = Path(work)

        def call(op, **fields):
            run = subprocess.run([str(EXE)],
                                 input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                 text=True, capture_output=True, check=True, timeout=120)
            response = json.loads(run.stdout)
            assert response["ok"], response
            return response["result"]

        call("init", purpose="daemon 线程契约")
        call("evo-policy", enabled=True, at=at(0))
        call("evo-init", seed=7, at=at(1))
        step = 0
        for _ in range(160):
            step += 1
            call("evo-observe", step=step, kind="social", salience=1.0, valence=1.0,
                 subject="user", body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                 at=at(10 + step))
            if call("evo-proactive-due", at=at(1900 + step))["due"]:
                break
        messages = vault / "messages.txt"
        messages.write_text("", encoding="utf-8")

        ticks = [0]

        def daemon():
            # Simulated clock, advanced per tick: a real host's clock moves
            # forward, and a thread-append's event identity binds (role, at),
            # so replaying one instant across ticks would collide events.
            minute = ticks[0]
            ticks[0] += 1
            now = (datetime(2026, 11, 17, 10, 0, 0, tzinfo=timezone.utc) +
                   timedelta(minutes=minute)).strftime("%Y-%m-%dT%H:%M:%SZ")
            run = subprocess.run([sys.executable, str(DAEMON), "--vault", str(vault),
                                  "--cli", str(EXE), "--once", "--mock",
                                  "--driver", "thread-daemon", "--now", now,
                                  "--tick-seconds", "60",
                                  "--message-file", str(messages),
                                  "--reflect-every", "0", "--consolidate-every", "0"],
                                 capture_output=True, text=True, timeout=300)
            assert run.returncode == 0, (run.stdout, run.stderr)
            return json.loads(run.stdout.strip().splitlines()[-1])

        first = daemon()
        assert first["speech"] and first["speech"]["acked"] is True, first
        thread = call("evo-thread-list")
        assert thread["counts"]["open"] == 1, thread
        assert thread["threads"][0]["turns"][0]["role"] == "agent", thread
        thread_row_id = thread["threads"][0]["id"]

        messages.write_text("我有点担心这个项目。\n", encoding="utf-8")
        second = daemon()
        assert second["messages"] and second["messages"][0]["valence"] < 0, second
        # The daemon answers on the follow-up chain (续六十四): the reply is a
        # delivered follow-up of the speech that opened the thread.
        reply = second["reply"]
        assert reply and reply["acked"] is True and reply["turn"] == 1, reply
        assert "mock 跟进·第1轮" in reply["text"], reply
        thread = call("evo-thread-list")
        turns = thread["threads"][0]["turns"]
        assert len(turns) == 3 and turns[1]["role"] == "user", turns
        assert turns[1]["text"] == "我有点担心这个项目。", turns
        assert turns[2]["role"] == "agent" and "mock 跟进" in turns[2]["text"], turns
        assert call("evo-proactive-list")["counts"]["delivered"] == 2

        # Two fresh messages in one tick ride a single evo-observe-batch (续六十一);
        # both are sensed with consecutive steps; the reply answers the LAST
        # message (one follow-up per tick) as chain turn 2.
        messages.write_text("第二句话，仍然有些不安。\n还有第三句，想多了解一点。\n",
                            encoding="utf-8")
        third = daemon()
        sensed = third["messages"]
        assert len(sensed) == 2 and all("error" not in row for row in sensed), sensed
        assert sensed[0]["step"] + 1 == sensed[1]["step"], sensed
        assert third["reply"]["turn"] == 2, third["reply"]
        assert "还有第三句" in third["reply"]["text"], third["reply"]
        turns = call("evo-thread-list")["threads"][0]["turns"]
        assert len(turns) == 5 and turns[4]["role"] == "agent", turns

        # A full thread rolls over: the daemon closes it instead of appending.
        for index in range(11):
            role = "user" if index % 2 == 0 else "agent"
            call("evo-thread-append", id=thread_row_id, role=role,
                 text=f"填充第{index}轮", at=at(5000 + index))
        full = call("evo-thread-list")["threads"][0]
        assert full["status"] == "open" and len(full["turns"]) == 16, full
        messages.write_text("第四句，线程该滚动了吧。\n", encoding="utf-8")
        fourth = daemon()
        assert fourth["messages"] and not fourth["reply"], fourth
        rolled = fourth["messages"][0]["thread_turn"]
        assert rolled and rolled["reason"] == "thread_full", rolled
        counts = call("evo-thread-list")["counts"]
        assert counts == {"open": 0, "closed": 1}, counts

    print("evo thread e2e: open/replay/limit/close contract, delivered-parent gate, "
          "daemon speech opens thread and user message appends her turn passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())