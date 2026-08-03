# Execution Plan: Board doc provenance schema

**Task ID:** E24_S01_T01
**Story ID:** E24_S01
**Epic ID:** E24
**Date:** 2026-07-23 (UTC)
**Agent:** developer
**Session ID:** 37e3defc-b60a-4fa2-b78d-b636a7d25b8a

---

## Task Summary
Add optional `docs` frontmatter support to the scrum board schema and templates, provide a board validation helper that accepts the field while remaining backward compatible with existing board files, and update Scrum Master guidance so board items can declare documentation provenance for the `/doc` skill.

---

## Implementation Approach

1. Update `templates/SCRUM_BOARD_SCHEMA.md` so epic, story, and task examples include an optional `docs` array and explain its purpose and optionality.
2. Inspect existing validation coverage; since only story format validation exists today, add a new `scripts/validate-board.sh` helper that validates allowed board frontmatter keys, accepts optional `docs`, and preserves compatibility with existing files that omit it.
3. Update `agents/scrum-master.md` with explicit guidance on when and how to populate `docs` annotations using repo-relative documentation paths.
4. Validate the helper against representative existing board files and temporary docs-annotated copies without changing live board content.
5. Commit changes in logical milestones, then write the execution summary and session handoff for the tester.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `templates/SCRUM_BOARD_SCHEMA.md` | Add optional `docs` field to epic/story/task frontmatter examples and document provenance usage |
| `scripts/validate-board.sh` | Add board frontmatter validation helper that accepts optional `docs` arrays |
| `agents/scrum-master.md` | Add Scrum Master guidance for optional `docs` annotations |
| `project/documentation/plans/E24_S01_T01-plan.md` | Record implementation plan |
| `project/documentation/summaries/E24_S01_T01-summary.md` | Record implementation summary after work completes |
| `project/queue/.session_handoff.json` | Provide tester handoff at session end |

---

## Dependencies & Risks

- Existing board files omit `docs`, so the validation helper must treat the field as optional.
- No dedicated JSON schema file for board items was found during initial inspection; this work will extend the Markdown schema and add a shell validation helper instead.
- Validation must not mutate canonical board files during verification.

---

## Notes

Use only canonical root files inside the worktree (`agents/`, `scripts/`, `templates/`). Do not modify generated `.agents/` or `.claude/` artifacts as primary sources.
