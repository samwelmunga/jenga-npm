---
id: E22_S03_T03
story_id: E22_S03
epic_id: E22
title: Configurable per-target gates, failure UX, history logging, non-interactive mode
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Configurable per-target gates, failure UX, history logging, non-interactive mode

## Description
Complete the quality gate system by implementing configurable per-target gates, the failure UX, history logging, and non-interactive behavior.

**Configurable per-target gates** (read from `publish.json` `targets[].checks.pre` and `targets[].checks.post`):
- `lint` — runs `checks.lint_command` or a conventional default
- `type-check` — runs `checks.typecheck_command` or a conventional default
- `custom-script` — runs a script path specified in config; path must match an allowlisted pattern (`^[./a-zA-Z0-9_-]+$`) — no shell expansion, no pipes, no arbitrary commands
- `smoke-test` — post-deploy gate: runs `checks.smoke_test_command`
- `ping` — post-deploy gate: HTTP GET to `checks.ping_url`, expects 2xx

**Failure UX (interactive mode)**:
- When any gate fails, print a formatted failure block with gate name, command, and full output
- Prompt the user: `[r] Retry after fixing / [a] Abort deploy` (case-insensitive)
- `r` re-runs the failed gate(s); `a` exits with code 2
- Loop up to 3 retries maximum; after 3 retries force abort

**Non-interactive mode** (`--non-interactive` flag):
- Any gate failure immediately exits with code 2 — no prompts

**History logging**:
- On any gate failure or abort, append an entry to `project/logs/publish-history.json`:
  ```json
  {
    "event": "gate_failure",
    "gate": "<gate_name>",
    "phase": "<pre|post>",
    "target": "<target_name>",
    "date": "<ISO 8601 UTC>",
    "exit_code": 2
  }
  ```
- Create `project/logs/publish-history.json` as an empty array `[]` if it does not exist

## Prerequisites
T02 (mandatory gates) should be complete.

## Acceptance Criteria
- [ ] `lint`, `type-check`, `custom-script` gates implemented and invocable via `checks.pre`
- [ ] `smoke-test`, `ping` gates implemented and invocable via `checks.post`
- [ ] `custom-script` path validated against allowlist pattern before execution
- [ ] On failure (interactive): user offered retry/abort with up to 3 retries
- [ ] On failure (non-interactive): immediate exit 2 with no prompts
- [ ] Gate failures logged to `project/logs/publish-history.json`
- [ ] `publish-history.json` initialised to `[]` if absent
