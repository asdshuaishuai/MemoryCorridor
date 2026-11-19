#!/usr/bin/env python3
"""Apply a staged RSI proposal through the ordinary commit order flow (续六十).

Manual host tool: a human picks a staged draft (staging/dream-work/<task>.md,
written by the driver's --propose) and the raw source that legitimizes the
page, and this script walks the EXISTING engine order flow — scan → context →
analysis-submit → render → commit. It invents no new write path: every page
byte goes through the ordinary commit transaction, so source revocation still
invalidates the published page. The driver never calls this; applying is a
human decision.

Refusals (exit 1, reason on stderr): missing staged draft, empty body,
missing source file, target page already active, ambiguous open order (pass
--order), and any engine fault from the flow itself.

Lifecycle (续六十四): a successful apply writes `<stem>.applied.json` beside
the draft, so a proposal is applied-once and auditable. `--list` reports every
staged draft as applied / pending / stale. A stale page (its source was
revoked) comes back through the SAME flow once the source changes again:
scan then yields an order — or the open order for that source is reused —
and the commit revives the page with the new bytes.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

DEFAULT_CLI = Path(__file__).resolve().parents[1] / "_build/native/debug/build/cli/cli.exe"


def fail(message: str) -> int:
    print(f"rsi-apply: {message}", file=sys.stderr)
    return 1


def call(cli: str, vault: str, op: str, **fields):
    payload = json.dumps(dict(fields, op=op, vault=vault))
    run = subprocess.run([cli], input=payload + "\n", text=True,
                         capture_output=True, check=True, timeout=120)
    response = json.loads(run.stdout)
    if not response["ok"]:
        raise RuntimeError(response["error"])
    return response["result"]


def parse_staged(text: str):
    """Split the staged draft into (meta, body); both driver-written and
    hand-written drafts carry the same minimal frontmatter."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise ValueError("staged draft has no frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError:
        raise ValueError("staged draft frontmatter is unterminated") from None
    meta = {}
    for line in lines[1:end]:
        key, sep, value = line.partition(":")
        if not sep:
            continue
        meta[key.strip()] = value.strip().strip('"')
    body = "\n".join(lines[end + 1:]).strip()
    return meta, body


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply a staged RSI proposal via the ordinary commit flow")
    parser.add_argument("--vault", required=True)
    parser.add_argument("--cli", default=str(DEFAULT_CLI))
    parser.add_argument("--proposal", default=None,
                        help="staged draft path, e.g. staging/dream-work/<task-id>.md")
    parser.add_argument("--source", default=None,
                        help="raw source (vault-relative) that legitimizes the page")
    parser.add_argument("--page-id", default=None,
                        help="target page id; default dream-work/<task-stem>")
    parser.add_argument("--order", default=None,
                        help="open analysis order id; required when scan yields more than one")
    parser.add_argument("--at", default=None)
    parser.add_argument("--list", action="store_true",
                        help="report every staged proposal's lifecycle state and exit")
    args = parser.parse_args()

    vault = Path(args.vault)

    def marker_path(proposal: Path) -> Path:
        return proposal.parent / (proposal.stem + ".applied.json")

    def page_state(page_id: str):
        """'missing' | 'active' | 'stale' for a would-be page id."""
        probe = subprocess.run([args.cli], input=json.dumps(
            {"op": "read-page", "id": page_id, "vault": args.vault}) + "\n",
            text=True, capture_output=True, check=True, timeout=120)
        response = json.loads(probe.stdout)
        if not response["ok"]:
            return "missing"
        return "stale" if response["result"].get("stale") else "active"

    missing = [flag for flag, value in
               [("--proposal", args.proposal), ("--source", args.source),
                ("--at", args.at)] if not value]
    if missing and not args.list:
        return fail("missing required arguments: " + ", ".join(missing))

    if args.list:
        staged_dir = vault / "staging" / "dream-work"
        rows = []
        for draft in sorted(staged_dir.glob("*.md")) if staged_dir.is_dir() else []:
            stem = draft.stem
            # The page's actual state decides: active means applied, stale is
            # a revive candidate, missing means still pending. The marker is
            # an audit trail, not the source of truth.
            state = {"active": "applied", "stale": "stale",
                     "missing": "pending"}[page_state(f"dream-work/{stem[:24]}")]
            rows.append({"proposal": draft.relative_to(vault).as_posix(),
                         "page": f"dream-work/{stem[:24]}", "state": state})
        print(json.dumps({"proposals": rows}, ensure_ascii=False))
        return 0

    staged = vault / args.proposal
    if not staged.is_file():
        return fail(f"staged proposal not found: {args.proposal}")
    try:
        meta, body = parse_staged(staged.read_text(encoding="utf-8"))
    except ValueError as err:
        return fail(str(err))
    if not body:
        return fail("staged proposal has an empty body")
    source_file = vault / args.source
    if not source_file.is_file():
        return fail(f"source file not found: {args.source}")
    title = meta.get("title") or staged.stem
    page_type = meta.get("type") or "concept"
    stem = staged.stem[:24]
    page_id = args.page_id or f"dream-work/{stem}"
    page_path = f"wiki/{page_id}.md"



    try:
        # Idempotence guard: an active page must not be silently re-published.
        try:
            existing = call(args.cli, args.vault, "read-page", id=page_id)
            if not existing.get("stale"):
                return fail(f"page already active: {page_id}")
        except RuntimeError as err:
            # entry_not_found: id free; not_a_page: id occupied by a non-page.
            if "entry_not_found" not in str(err) and "not_a_page" not in str(err):
                raise

        orders = call(args.cli, args.vault, "scan")["orders"]
        order = args.order
        if order is None:
            if len(orders) == 1:
                order = orders[0]
            else:
                # A republish finds no fresh scan change: reuse the open
                # order already bound to this source, if exactly one exists.
                open_rows = [row["id"] for row in call(args.cli, args.vault, "status")["orders"]
                             if row["phase"] in ("pending", "context-ready", "analysis-done")
                             and row["source"] == args.source]
                if len(open_rows) == 1:
                    order = open_rows[0]
                elif len(orders) == 0:
                    return fail("no open order for %s; the source has not changed since "
                                "its last commit" % args.source)
                else:
                    return fail("ambiguous open orders (%d); pass --order" % len(orders))

        call(args.cli, args.vault, "context", order=order)
        call(args.cli, args.vault, "analysis-submit", order=order, analysis={
            "entities": [], "concepts": [title[:64]], "conflicts": [],
            "summary": title[:128],
        })
        render_dir = vault / "staging" / order
        render_dir.mkdir(parents=True, exist_ok=True)
        rendered = render_dir / "rsi-page.md"
        rendered.write_text(
            "---\n"
            f"type: {page_type}\n"
            f'title: "{title.replace(chr(34), chr(39))}"\n'
            f'sources: ["{args.source}"]\n'
            "---\n" + body + "\n", encoding="utf-8")
        call(args.cli, args.vault, "commit", order=order, at=args.at,
             pages=[{"id": page_id, "path": page_path,
                     "staged": f"staging/{order}/rsi-page.md"}])
    except RuntimeError as err:
        return fail(f"engine refused: {err}")

    marker = {"applied": True, "page": page_id, "mode": "commit",
              "order": order, "source": args.source, "at": args.at}
    marker_path(staged).write_text(json.dumps(marker, ensure_ascii=False),
                                   encoding="utf-8")
    print(json.dumps({"applied": True, "page": page_id, "path": page_path,
                      "order": order, "source": args.source, "title": title},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
