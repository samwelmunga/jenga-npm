# Evaluation Rapport: acceptance-criteria-enforcement

## Goal
Ensure Acceptance Criteria in story files are systematically verified before stories are marked as Passed/Done — eliminating the current gap where stories can be promoted without checking whether their AC checklist items are fulfilled.

## References
- `agents/tester.md`
- `agents/scrum-master.md`
- `hooks/on_session_end.sh`
- `project/board/stories/E01_S06_training-skill-assets.md`
- `templates/SCRUM_BOARD_SCHEMA.md`

---

## Observations

### `agents/tester.md`
The Tester is the only agent permitted to update task and story statuses. Its task testing flow (Steps 1–8 in "Invoked for test implementation and/or execution") reads the task/story/epic from the board, runs tests, and sets status — but contains **no explicit step requiring the agent to read and verify each Acceptance Criteria item**. The agent is implicitly expected to derive test cases from the task context, but there is no enforcement gate that checks the story's AC section before a `Passed` status is written. A tester session can conclude with all technical tests green without any of the story-level AC items being explicitly acknowledged.

### `agents/scrum-master.md`
The Scrum Master's `story_rollup` handler is purely mechanical: if all tasks under a story are `Passed` or `Passed with remarks`, it updates the story status to `Passed`. This is correct as a rollup rule but insufficient as an AC gate — it promotes a story based solely on task completion counts, not on whether the story's AC checklist was walked through. The Scrum Master's "Backlog Item Definitions" section explicitly states that stories must include AC "written so a tester can verify them without ambiguity", but the Scrum Master's own rollup path never reads the AC back to validate it.

### `hooks/on_session_end.sh`
The hook handles rapport detection, status-review triggers, and inter-agent routing. It has no awareness of story-level content (AC, DoD). This is correct by design — the hook is a router, not a validator. Adding AC enforcement here would be architecturally wrong: the hook runs after agent sessions end and has no reasoning capability; it cannot read and evaluate a prose checklist.

### `project/board/stories/E01_S06_training-skill-assets.md`
This story has `status: Passed` in its frontmatter, yet its `## Definition of Done` section contains a checkbox list (`- [ ]`) where every item is **unchecked**. This is the concrete evidence of the gap: the story was promoted to `Passed` through the task-rollup path without any agent ever ticking off the DoD checkboxes. The `## Acceptance Criteria` section uses a numbered prose list (not checkboxes), meaning it is not mechanically trackable at all in its current form.

---

## Gaps & Issues

- **Critical — Tester has no AC verification step**: The Tester's test execution flow (Steps 1–8) does not include a step to read the story's `## Acceptance Criteria` section and confirm each item is covered by the test run. This is the primary enforcement gap.

- **Critical — DoD checkboxes are never ticked**: The `## Definition of Done` section uses `- [ ]` checkboxes, but no agent is instructed to check them. They are written at story-creation time and never updated, making them decorative rather than functional.

- **High — Scrum Master story_rollup has no AC gate**: When the Scrum Master promotes a story from task-level `Passed` statuses, it does not read the story's AC or DoD. It treats the story as complete based purely on child task counts.

- **Medium — AC format is inconsistent**: The `## Acceptance Criteria` section in E01_S06 uses a numbered prose list. The `## Definition of Done` uses checkboxes. There is no schema-level standard for AC format, making mechanical enforcement harder and creating confusion about which list a tester should verify.

- **Medium — No traceability between AC items and test cases**: Nothing in the current workflow requires a tester to map test results back to specific AC items. A story with 20 AC items and 2 passing tests could be marked `Passed` with no traceability gap flagged.

- **Low — Story template not enforced by schema**: `SCRUM_BOARD_SCHEMA.md` defines file paths and status values but does not specify a required AC checkbox format or mandate that AC items be checked before a status transition.

---

## Score
**Score**: 2/5  
**Justification**: The workflow has the right structural components (Tester as sole status authority, explicit AC sections in stories, DoD checklists) but no agent or hook is instructed to use them as a gate — they are written and then ignored during execution and rollup.

---

## Summary

The Acceptance Criteria enforcement gap is primarily a **Tester agent instruction gap**: the Tester is the right enforcement point (it owns status transitions) but its current instructions do not require AC verification before marking a story `Passed`. The fix should be applied at two points: (1) add an explicit AC/DoD verification step to the Tester's task testing flow for story-level promotions, and (2) add a lightweight AC-gate check to the Scrum Master's `story_rollup` handler so that mechanical rollup cannot override an unchecked DoD. The `on_session_end.sh` hook is the wrong place for this — it is a stateless router with no reasoning capability. A secondary improvement is standardising the AC format in `SCRUM_BOARD_SCHEMA.md` to use checkboxes, making enforcement unambiguous and mechanically verifiable.
