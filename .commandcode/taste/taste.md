# Taste

- Writes in Chinese and expects the assistant to reply in Chinese. Confidence: 0.6
- Before continuing work on a project, wants the assistant to first investigate the existing state/progress (e.g., what a prior agent or tool has already built) and then proceed. Confidence: 0.6
- Gives terse continuation instructions ("继续"、"继续推进吧"、"继续挖") and expects the assistant to choose the next work item itself from the project's spec/audit/plan documents instead of asking what to do next. Confidence: 0.75
- Expects changes to be carried through end-to-end without being asked: find the real gap, fix it, add/update tests, sync docs/specs/README and verification numbers, and run the full project verify script before reporting back. Confidence: 0.5
