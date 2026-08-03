# Execution Plan: AC/DoD Enforcement in Agent Workflow (E17_S01 — All Tasks)

**Task ID:** E17_S01_T01, E17_S01_T02, E17_S01_T03, E17_S01_T04, E17_S01_T05
**Story ID:** E17_S01
**Epic ID:** E17
**Date:** 2026-06-06 (UTC)
**Agent:** developer
**Session ID:** d69351b2-bbf0-4d75-b745-33a3433faae1

---

## Task Summary

Add systematic AC/DoD format enforcement across the agent workflow. This involves: documenting format standards in the schema, creating a validation script, and updating three agent/skill definitions to enforce and report on the standards at write time, test time, and reconciliation time.

---

## Implementation Approach

1. **T01** — Add a "Story Format Standards" section to `templates/SCRUM_BOARD_SCHEMA.md` documenting AC (format-agnostic) and DoD (must use `- [ ]` checkboxes) rules. Update the Story file format example to use checkboxes in the DoD section.

2. **T02** — Create `scripts/validate-story-format.sh`. The script accepts a path to a story file and runs 4 ordered checks: file readable (exit 1), AC section present (exit 2), DoD section present (exit 3), DoD has at least one `- [ ]` checkbox (exit 4). Exit 0 on success.

3. **T03** — Update `agents/scrum-master.md` to add a "Story Format Validation" gate in the "Finalizing Items" section. The gate must run (or simulate) `scripts/validate-story-format.sh` before writing any story file, and fix the format before persisting if validation fails.

4. **T04** — Update `agents/tester.md` to insert an AC/DoD verification step between the current Step 5 (execute tests) and Step 6 (evaluate results). The new step runs `validate-story-format.sh`, reads AC for coverage confirmation, and ticks each `- [ ]` to `- [x]` in the story file before writing any Passed status.

5. **T05** — Update `skills/reconcile/SKILL.md` Phase 4 to scan completed stories for unchecked DoD checkboxes and report them in a "DoD Gaps" section. Update `skills/reconcile/assets/report_format.md` with the new section template. Gap detection is report-only — no automatic status changes.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `templates/SCRUM_BOARD_SCHEMA.md` | Add Story Format Standards section; update Story DoD example to use `- [ ]` |
| `scripts/validate-story-format.sh` | Create new executable validation script |
| `agents/scrum-master.md` | Add format validation gate to story-writing flow |
| `agents/tester.md` | Insert AC/DoD verification step in test execution flow |
| `skills/reconcile/SKILL.md` | Add DoD gap detection sub-step to Phase 4 |
| `skills/reconcile/assets/report_format.md` | Add "DoD Gaps" section to report template |

---

## Dependencies & Risks

- T02 must exist before T03 and T04 reference it by path — implement T02 first.
- All changes are to documentation/instructions files and a shell script; no code dependencies.
- The validation script uses standard POSIX tools (`grep`, `awk`) — no external dependencies.

---

## Notes

- All 5 tasks are pure text/script changes; no build or install steps required.
- The worktree is `E17_S01-ac-dod-enforcement`.
