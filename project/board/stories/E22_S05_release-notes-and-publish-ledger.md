---
id: E22_S05
epic_id: E22
title: Release notes & publish ledger
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
tasks:
  - E22_S05_T01
  - E22_S05_T02
  - E22_S05_T03
---

# Story: Release notes & publish ledger

## Goal
Implement release note generation (git-first, with scrum board enrichment as best-effort)
and the canonical publish ledger. `publish-history.json` is the system of record; git
tags mirror it. Define reconciliation behavior for when tags and ledger diverge.

## Acceptance Criteria
- [ ] `/publish release-notes` sub-command generates a release note draft without deploying
- [ ] Release notes sourced from: git log since last publish tag (primary) + closed board tasks since last publish tag (enrichment, best-effort — missing board data does not fail the command)
- [ ] "Last publish tag" determined by: highest semver tag matching `v*.*.*` on the current branch that has a corresponding entry in `publish-history.json`
- [ ] If no prior publish tag exists, all git history is used and a note is added: "First release — full history included"
- [ ] User can review and edit the draft before deploying
- [ ] On successful deploy: append entry to `project/logs/publish-history.json` with fields: `version`, `target`, `timestamp`, `released_by`, `release_notes`, `platform_state` (per-adapter publish state)
- [ ] On successful deploy: create git tag `v<semver>` matching the ledger version
- [ ] Semver bump suggested automatically: patch if only bug-fix commits, minor if any feat commits, major if any breaking-change indicators — user confirms before tagging
- [ ] Reconciliation rule documented: if git tag exists but no ledger entry → ledger entry created as `partial` with note "Manually tagged without /publish"; if ledger entry exists but no git tag → tag created retroactively with warning
- [ ] `/publish history` command reads and displays `publish-history.json` in a human-readable format

## Notes
- Board task enrichment should gracefully handle: no board, no closed tasks, tasks with missing titles, tasks closed since non-tag commit
- The publish ledger is append-only; entries are never modified after writing (failed publishes get their own entry)

## Definition of Done
- [x] `skills/publish/scripts/generate_release_notes.sh` exists and correctly resolves last publish tag
- [x] Commit sections: Features, Bug Fixes, Other; board enrichment silently skipped if unavailable
- [x] `skills/publish/scripts/suggest_semver_bump.sh` exists and suggests correct bump level
- [x] `skills/publish/scripts/write_ledger_entry.sh` appends correct JSON entry with file locking
- [x] Annotated git tag created on successful deploy; skipped with warning if already exists
- [x] `skills/publish/scripts/show_history.sh` displays human-readable history table
- [x] `show_history.sh` supports `--limit`, `--target`, `--json` flags
- [x] `skills/publish/scripts/reconcile_tags.sh` creates partial ledger entries and retroactive tags
- [x] SKILL.md updated with history command reference and ledger/tagging section
