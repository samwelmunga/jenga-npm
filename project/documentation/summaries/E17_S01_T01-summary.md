# Execution Summary: AC/DoD Enforcement in Agent Workflow (E17_S01 — All Tasks)

**Task ID:** E17_S01_T01, E17_S01_T02, E17_S01_T03, E17_S01_T04, E17_S01_T05
**Story ID:** E17_S01
**Epic ID:** E17
**Date Completed:** 2026-06-06 (UTC)
**Agent:** developer
**Session ID:** d69351b2-bbf0-4d75-b745-33a3433faae1

---

## What Was Implemented

All 5 tasks under E17_S01 are complete. The story adds systematic AC/DoD format enforcement across the agent workflow:

- **Schema documentation** for the required AC and DoD format rules
- **Validation script** that agents and humans can run to check story files
- **Scrum Master gate** that blocks writing any malformed story file to the board
- **Tester verification step** that reads AC coverage and ticks DoD checkboxes before writing any Passed status
- **Reconcile gap detection** that surfaces completed stories with unchecked DoD boxes in the reconcile report

---

## Files Changed

| File | Summary of Changes |
|------|--------------------|
| `templates/SCRUM_BOARD_SCHEMA.md` | Added "Story Format Standards" section; updated Story DoD example from plain bullets to `- [ ]` checkboxes |
| `scripts/validate-story-format.sh` | New executable script; validates file readable (exit 1), AC present (exit 2), DoD present (exit 3), DoD has `- [ ]` checkboxes (exit 4); exits 0 on pass |
| `agents/scrum-master.md` | Added "Story Format Validation" gate to Finalizing Items → before writing any story file, runs `validate-story-format.sh`, fixes format if it fails, logs correction |
| `agents/tester.md` | Inserted Step 6 "AC/DoD Verification" into test execution flow; runs `validate-story-format.sh`, reads AC for coverage, ticks DoD checkboxes, writes Failed + rapport if any DoD item unverifiable |
| `skills/reconcile/SKILL.md` | Added DoD gap detection sub-step to Phase 4; scans completed stories for unchecked `- [ ]`; report-only, no status changes |
| `skills/reconcile/assets/report_format.md` | Added "DOD GAPS" section to report template; added section rule to omit when no gaps found |

---

## Commits

| SHA | Message |
|-----|---------|
| `6a4e1b8` | feat(E17_S01): add story format standards and validation script |
| `40c409b` | feat(E17_S01): add AC/DoD enforcement gates to scrum-master and tester agents |
| `95f1a94` | feat(E17_S01): add DoD gap detection to reconcile skill |

---

## Acceptance Criteria Coverage

| Criterion | Status | Notes |
|-----------|--------|-------|
| `SCRUM_BOARD_SCHEMA.md` has "Story Format Standards" section documenting AC and DoD rules | ✅ Done | Section added with ownership info |
| Story file format example shows `- [ ]` in DoD section | ✅ Done | Template updated |
| `scripts/validate-story-format.sh` exists, is executable, exits non-zero with clear messages on failure | ✅ Done | All 4 exit codes tested |
| `agents/scrum-master.md` includes format validation step referencing `scripts/validate-story-format.sh` | ✅ Done | Gate added to Finalizing Items |
| `agents/tester.md` has AC/DoD verification step between execute-tests and evaluate-results | ✅ Done | Inserted as Step 6 with all 4 sub-steps |
| `skills/reconcile/SKILL.md` Phase 4 has DoD gap detection, `assets/report_format.md` has DoD Gaps section | ✅ Done | Both files updated |

---

## Edge Cases & Known Concerns

- **validate-story-format.sh**: Uses `awk` + `grep` to extract the DoD section. Works correctly when DoD is followed by another `##` heading or is at EOF. Tested against all 4 failure modes.
- **Scrum Master gate**: The instruction uses a temp file approach for validation. If the agent is purely text-based (no shell), it should validate the DoD format inline (look for `^- \[ \]` lines) before persisting.
- **Tester DoD tick-back**: The tester must use the file-locking protocol when rewriting the story file with ticked checkboxes.
- **Reconcile gap detection**: Correctly skips stories where the DoD section is absent (no error), and correctly skips stories where all boxes are ticked (no gap).

---

## Notes for Tester

- **T02 (script)**: Run the script against the 5 test cases in the plan:
  1. A valid story with AC + DoD checkboxes → should exit 0
  2. A story missing `## Acceptance Criteria` → should exit 2
  3. A story missing `## Definition of Done` → should exit 3
  4. A story with DoD as plain bullets only → should exit 4
  5. A non-existent file → should exit 1
- **T01/T03/T04/T05**: These are documentation changes — verify the sections are present, unambiguous, and match the acceptance criteria exactly.
- The story file for E17_S01 (`project/board/stories/E17_S01_ac-dod-enforcement.md`) is currently untracked in the main branch. It has a valid AC section and DoD with checkboxes, so it should pass `validate-story-format.sh`.
