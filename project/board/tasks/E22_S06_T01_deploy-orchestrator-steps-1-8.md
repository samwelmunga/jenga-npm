---
id: E22_S06_T01
story_id: E22_S06
epic_id: E22
title: publish_deploy.sh — full end-to-end deploy orchestrator (steps 1–8)
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: publish_deploy.sh — full end-to-end deploy orchestrator (steps 1–8)

## Description
Create `skills/publish/scripts/publish_deploy.sh` — the single orchestration script that sequences the full `/publish deploy` pipeline. This task covers steps 1–8 of the AC flow.

**Invocation contract:**
```
publish_deploy.sh [--target <name>] [--config <path>] [--yes] [--dry-run]
                  [--minor | --major] [--release-notes <path>]
```

**Steps 1–8 implementation:**

1. **Target selection** — if `--target` not given (and not `--yes`): list targets from `publish.json`; prompt user to pick one. If `publish.json` is missing, exit 4.
2. **Config completeness check** — call `check_target_config.sh <target> <config>`. On exit 4 in interactive mode: auto-trigger setup wizard. On exit 4 with `--yes`: exit 4 with field listing, no wizard.
3. **Env var validation** — call `validate_ios_env.sh <config>` (or the appropriate per-adapter validator). On failure: exit 4 listing missing vars.
4. **Board summary** — read closed tasks/stories since last publish tag; print as informational block (missing board data → skip silently).
5. **Pre-deploy gates** — call `run_gates.sh pre <target> <config> [--non-interactive]`. On exit 2: halt and surface error.
6. **Release note draft** — call `generate_release_notes.sh [--from-tag <last_tag>] [--output <tmp>]`; open draft in `$EDITOR` or `less` for review (if `--yes`: skip review).
7. **Semver bump** — call `suggest_semver_bump.sh`; prompt for confirmation (if `--yes` or `--minor`/`--major` flag: auto-accept).
8. **Final confirmation** — print: `Deploy v<x.y.z> to <target>? [y/N]`. On `N`: exit 1. (If `--yes`: skip prompt.)

After step 8 confirmation: invoke the adapter pipeline (`ios_pipeline.sh` for `mobile-ios`) and exit on adapter failure with code 3.

## Prerequisites
All of S01–S05 merged to main. ✅

## Acceptance Criteria
- [ ] `skills/publish/scripts/publish_deploy.sh` exists and is executable
- [ ] All 8 steps execute in sequence with correct failure exits
- [ ] Target selection prompts if `--target` not given (interactive mode)
- [ ] Auto-trigger wizard on incomplete config (interactive); exit 4 (non-interactive)
- [ ] Pre-deploy gates called with `--non-interactive` when `--yes` is set
- [ ] Release note review shown unless `--yes`
- [ ] Semver bump confirmed interactively or auto-accepted with flags
- [ ] Final `[y/N]` prompt shown unless `--yes`
