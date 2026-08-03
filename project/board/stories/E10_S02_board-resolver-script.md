---
id: E10_S02
epic_id: E10
title: "`scripts/board_resolver.sh`"
status: Done
date_created: 2026-05-08
date_started:
date_completed: 2026-05-10
tasks: []
---

# Story: `scripts/board_resolver.sh`

As a skill or script author, I want a single script that resolves the board path from `project/configs/workflow.json` so that no skill hardcodes `project/board/` or silently uses the wrong path.

## Acceptance Criteria
- [ ] Script lives at `scripts/board_resolver.sh` and is executable
- [ ] Reads the board path key from `project/configs/workflow.json` using `jq` (or a portable fallback if `jq` is unavailable)
- [ ] Falls back to `project/board/` if the config file is missing or the key is not set
- [ ] Outputs a single line — the resolved path — with a trailing `/` always present and never doubled
- [ ] Exits 0 on success; exits non-zero and prints to stderr if `workflow.json` exists but is malformed JSON
- [ ] Script is self-contained — no dependency on other scripts in this epic

## Definition of Done
- [ ] Running the script with a valid `workflow.json` outputs the configured path
- [ ] Running the script with no `workflow.json` outputs `project/board/`
- [ ] Running the script with malformed JSON exits non-zero
