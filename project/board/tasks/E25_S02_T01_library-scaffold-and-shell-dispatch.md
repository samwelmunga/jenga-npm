---
id: E25_S02_T01
story_id: E25_S02
epic_id: E25
title: Library scaffold & shell dispatch entry point
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-23
dates_previously_completed:
reopened_on:
reopened_reason:
---

# Task: Library scaffold & shell dispatch entry point

## Description

Create the library directory structure and the shell-dispatchable entry point. The library should live at `.claude/skills/index/scripts/` (or `skills/index/scripts/` in the root if that fits the project convention — confirm by checking `skills/` directory structure).

Specifically:
- Create `skills/index/scripts/board_index.py` — the main Python module (Python 3, no third-party deps beyond stdlib)
- Create `skills/index/scripts/board-index` — a thin bash shim that invokes `board_index.py "$@"` so callers can run `board-index graph::nodes` without knowing Python
- The entry point must parse subcommands: `graph::nodes [--type=<type>] [--format json]` and `graph::edges [--type=<type>] [--format json]`
- Output JSON array to stdout; errors/warnings to stderr
- `--help` on any subcommand prints usage and exits 0
- Exit code 0 on success, nonzero on fatal errors

Do **not** implement extraction logic in this task — stub `graph::nodes` and `graph::edges` to return `[]` so the scaffold is testable. Extraction comes in T02–T04.

## Acceptance Criteria
- [ ] `board-index graph::nodes` runs and returns `[]` (stub)
- [ ] `board-index graph::edges` runs and returns `[]` (stub)
- [ ] `board-index graph::nodes --type Epic` runs and returns `[]` (stub with type passthrough)
- [ ] `board-index --help` exits 0 with usage text
- [ ] Shim is executable (`chmod +x board-index`)
- [ ] Directory structure created: `skills/index/scripts/`
- [ ] No third-party Python deps (stdlib only)

## Definition of Done
- [ ] Scaffold exists with working stub endpoints
- [ ] Shim is executable and routes to Python module
- [ ] `--type` and `--format` flags are wired up (even if ignored at stub stage)
