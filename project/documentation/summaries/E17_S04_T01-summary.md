# Summary: E17_S04_T01 — Update /commit skill to invoke /reconcile as initial step

## What Was Done
Updated `skills/commit/SKILL.md` to invoke `/reconcile` as step 1 of the commit flow.

### Changes
- **`.agents/skills/commit/SKILL.md`** — Added new step 1: "Reconcile the board". Describes two outcomes: drift found (user is informed and must confirm before commit proceeds) and no drift (continue silently). Existing steps renumbered from 1–3 to 2–4.

## Acceptance Criteria Coverage
- ✅ `/reconcile` is now the first instruction step in `/commit`
- ✅ Both outcomes (drift / no drift) are described
- ✅ All existing commit steps preserved at steps 2–4

## Board Items Updated
- `project/board/stories/E17_S04_reconcile-on-commit.md` — tasks list updated with T01
- `project/board/epics/E17_workflow-quality-enforcement.md` — stories list updated with E17_S04
- `project/board/tasks/E17_S04_T01_update-commit-skill-invoke-reconcile.md` — created
