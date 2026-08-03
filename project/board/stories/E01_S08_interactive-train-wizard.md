---
id: E01_S08
epic_id: E01
title: Interactive Train Wizard
status: Passed
date_created: 2026-04-30
date_started: 2026-04-30
date_completed: 2026-04-30
tasks:
  - Parse --interactive flag in train new command handler
  - Implement prompt loop for critical fields (job name, type, data file path, 2-3 key model params)
  - Add --full flag that expands prompts to all configurable fields
  - Add inline field hints/descriptions to each prompt
  - Implement Ctrl+C (SIGINT) handler that asks user to keep or delete scaffolded directory
  - Ensure existing positional flow (train new <type> <name>) remains untouched and scriptable
---

# Story: Interactive Train Wizard

As a user setting up a new training job, I want to run `train new --interactive` and be guided through the critical configuration decisions — so that I don't have to manually edit `config.yaml` after scaffolding.

## Acceptance Criteria
- [x] `train new --interactive` triggers a prompt-based wizard for critical fields only (job name, type, data file path, 2–3 key model params)
- [x] `--full` flag expands the wizard to prompt for every configurable field in the relevant template
- [x] Each prompt includes an inline hint or description
- [x] Hitting Ctrl+C mid-wizard asks the user whether to delete the scaffolded directory or leave it
- [x] Existing `train new <type> <name>` positional flow is fully preserved and scriptable (no breaking changes)

## Definition of Done
- [x] `--interactive` and `--full` flags are parsed and handled in `train new`
- [x] Prompt loop covers all critical fields per job type (classifier / transformer / nlp)
- [x] SIGINT handler implemented with keep/delete prompt
- [x] No regression in existing `train new` positional invocation
- [x] Documented in the `/train` skill
