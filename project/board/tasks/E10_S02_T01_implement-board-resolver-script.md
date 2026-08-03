---
id: E10_S02_T01
story_id: E10_S02
epic_id: E10
title: Implement scripts/board_resolver.sh
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Implement scripts/board_resolver.sh

## Description
Create `scripts/board_resolver.sh` — a self-contained shell script that resolves the board path from `project/configs/workflow.json` using `jq` (or a portable grep fallback). It must output a single normalised path line (trailing `/` always present, never doubled), fall back to `project/board/` when the config is missing or the key is absent, and exit non-zero on malformed JSON.

## Prerequisites
None

## Acceptance Criteria
- [ ] File exists at `scripts/board_resolver.sh` and is executable
- [ ] Reads board path from `project/configs/workflow.json`; falls back to `project/board/` if file or key absent
- [ ] Output always ends with exactly one `/`
- [ ] Exits 0 on success; exits non-zero + stderr on malformed JSON
- [ ] Self-contained — no dependency on other E10 scripts
