---
id: E22_S06_T02
story_id: E22_S06
epic_id: E22
title: Post-deploy steps, ledger write, dry-run mode, and non-interactive path
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Post-deploy steps, ledger write, dry-run mode, and non-interactive path

## Description
Complete `publish_deploy.sh` with steps 9–11, dry-run mode, and the fully-working non-interactive path.

**Steps 9–11:**

9. **Post-deploy gates** — call `run_gates.sh post <target> <config> [--non-interactive]`. On exit 2: print warning (post-deploy failure does NOT roll back the upload; it is logged to history as `partial`).
10. **Ledger entry + git tag** — call `write_ledger_entry.sh <target> <adapter> <platform_state> <notes_path> [--yes]`. Creates the ledger entry and annotated tag.
11. **Surface manual steps** — read and print the adapter's post-deploy manual steps block (from `adapters/<type>.md`, section `## Post-deploy manual steps`).

**Dry-run mode (`--dry-run`)**:
- All steps run normally EXCEPT:
  - Adapter pipeline (`ios_pipeline.sh --dry-run`) — prints commands with `[DRY RUN]` prefix
  - Git tag creation — skipped; print: `[DRY RUN] Would create tag v<x.y.z>`
  - Ledger write — writes a `platform_state: "dry-run"` entry (so dry runs are traceable in history)
- Print banner at start: `🔍 DRY RUN — no real deployment will occur`

**Non-interactive path validation** (`--target <name> --yes`):
- No prompts at any step
- `--minor` or `--major` overrides the semver bump suggestion
- Default bump is `patch` if neither `--minor` nor `--major` is given
- All gate failures abort immediately (no retry prompts)
- Exit codes propagated correctly: 1=user abort, 2=gate failure, 3=adapter failure, 4=config/env missing

## Prerequisites
T01 (steps 1–8) must be complete.

## Acceptance Criteria
- [ ] Post-deploy gates called after adapter success; failure logged as `partial` (not a hard halt)
- [ ] `write_ledger_entry.sh` called with correct args; tag created
- [ ] Manual steps block printed from adapter template
- [ ] `--dry-run` flag: adapter runs with `--dry-run`, tag skipped, dry-run ledger entry written
- [ ] Non-interactive path (`--yes`): all prompts suppressed; semver uses `patch` by default or `--minor`/`--major`
- [ ] Exit codes 1–4 correctly propagated in all failure paths
