---
id: E26_S01
epic_id: E26
title: Retire /distribute and .jenga_paths
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-07-31
dates_previously_completed:
reopened_on:
reopened_reason:
docs: ["README.md"]
tasks:
  - E26_S01_T01
  - E26_S01_T02
  - E26_S01_T03
  - E26_S01_T03
---

# Story: Retire /distribute and .jenga_paths

As a framework maintainer, I want to remove the `/distribute` skill and the `.jenga_paths` device-local file so that the codebase no longer contains distribution mechanisms that only work on one machine.

## Acceptance Criteria
- [ ] `skills/distribute.md` is deleted from the repository
- [ ] `.jenga_paths` is added to `.gitignore` (it is a local-only file; existing copies on disk are not deleted but the file is no longer tracked or read)
- [ ] `workflow_version` in `jenga.config.json` (and its example) is removed or annotated as deprecated with a note pointing to `package.json` version
- [ ] No file in `skills/`, `agents/`, or `scripts/` references `/distribute`, `.jenga_paths`, or `workflow_version` as an active mechanism
- [ ] The `/help` skill listing no longer includes `/distribute`
- [ ] If any `index` or `registry` file lists skills, `/distribute` is removed from that list

## Definition of Done
- [ ] `skills/distribute.md` does not exist in the repo
- [ ] `.jenga_paths` is listed in `.gitignore`
- [ ] `grep -r "distribute" skills/ agents/ scripts/` returns no active references (comments or docs referencing history are acceptable)
- [ ] `grep -r "jenga_paths" .` returns only `.gitignore` and any migration notes
- [ ] `grep -r "workflow_version" .` returns only `jenga.config.json` with a deprecation annotation (or is fully removed)
- [ ] `/help` output does not list `/distribute`
