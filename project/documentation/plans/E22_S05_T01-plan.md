# Execution Plan: Release notes, publish ledger, and history reconciliation

**Task ID:** E22_S05_T01, E22_S05_T02, E22_S05_T03
**Story ID:** E22_S05
**Epic ID:** E22
**Date:** 2026-07-11 (UTC)
**Agent:** developer
**Session ID:** 88d3f412-a3db-4356-aa58-96c6d8860c37

---

## Task Summary

Implement the release-note draft generator, canonical publish-ledger helpers, semver bump suggestion, history display, and tag↔ledger reconciliation utilities for the `/publish` workflow. The work must keep `project/logs/publish-history.json` append-only, resolve the last publish from semver tags that are actually represented in the ledger, and update `/publish` documentation to describe the history and reconciliation behavior.

---

## Implementation Approach

1. **T01 — release note generation**
   - Add a shared publish helper for repo-root, ledger resolution, semver/tag lookup, and lock handling.
   - Implement `skills/publish/scripts/generate_release_notes.sh` so it can resolve the last published semver tag from git + ledger, group commits into Features / Bug Fixes / Other, and best-effort enrich the draft with completed scrum-board tasks.
   - Support `--from-tag`, `--to-ref`, `--output`, and optional config-path resolution while gracefully falling back to full history when no prior ledger-backed publish exists.

2. **T02 — version suggestion, ledger writes, and tagging**
   - Implement `skills/publish/scripts/suggest_semver_bump.sh` to inspect git history since the last publish and suggest a major/minor/patch bump.
   - Implement `skills/publish/scripts/write_ledger_entry.sh` to confirm or auto-accept the version, append a canonical ledger entry under file lock, and create the matching annotated git tag (warning only if it already exists).
   - Keep ledger writes append-only and include extra metadata (`commit_sha`, optional note) only as additive fields.

3. **T03 — history display and reconciliation**
   - Implement `skills/publish/scripts/show_history.sh` with table, filtering, limit, and JSON output.
   - Implement `skills/publish/scripts/reconcile_tags.sh` so unmatched git tags create `partial` ledger rows and unmatched ledger rows create retroactive tags, with `--dry-run` support.
   - Update `skills/publish/SKILL.md` and mirrored help copies to reference the new commands and document the append-only reconciliation policy.

4. **Handoff**
   - Commit at meaningful milestones after the release-note engine and after the ledger/history tooling.
   - Write `project/documentation/summaries/E22_S05_T01-summary.md` covering all three tasks.
   - Prepare tester handoff with the worktree path and all commit SHAs.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `project/documentation/plans/E22_S05_T01-plan.md` | Add the combined execution plan for T01–T03 |
| `skills/publish/scripts/publish_common.sh` | New shared helper for repo paths, history lookup, semver math, and file locking |
| `skills/publish/scripts/generate_release_notes.sh` | New release-note generator with git-first logic and board enrichment |
| `skills/publish/scripts/suggest_semver_bump.sh` | New semver bump suggestion helper with interactive confirmation / `--yes` |
| `skills/publish/scripts/write_ledger_entry.sh` | New append-only ledger writer and git-tagging helper |
| `skills/publish/scripts/show_history.sh` | New human-readable / JSON ledger viewer |
| `skills/publish/scripts/reconcile_tags.sh` | New git-tag ↔ ledger reconciliation utility |
| `skills/publish/SKILL.md` | Document history command, release-notes command, and ledger/tagging policy |
| `.agents/skills/publish/SKILL.md` | Sync publish skill documentation for MCP/help discovery |
| `.claude/skills/publish/SKILL.md` | Sync local mirrored publish skill documentation |
| `project/documentation/summaries/E22_S05_T01-summary.md` | Add combined implementation summary for tester handoff |
| `project/queue/.session_handoff.json` | Write required developer handoff payload |

---

## Dependencies & Risks

- Depends on the current git history and any existing `project/logs/publish-history.json`; scripts must tolerate the file being absent.
- Uses `jq` and `git` directly, so error handling must surface missing tool or invalid JSON issues clearly.
- Board enrichment is explicitly best-effort and must never fail release-note generation if board files are missing or partially populated.
- Existing publish-history content may include older non-canonical rows, so display and reconciliation logic must be defensive and filter gracefully.

---

## Notes

This story intentionally implements standalone scripts and documentation. Full end-to-end orchestration that wires the scripts into a single `/publish deploy` command remains the responsibility of later publish-story work.
