# Plan: E03_S03 — Jenga Empty-Board Fallback to /do

## Objective
Modify `skills/jenga/SKILL.md` so that when the eligible task list is empty, `/jenga` does not immediately exit. Instead, it first invokes `/do` to surface any stories on the board that have not yet been broken down into tasks. Only when `/do` also finds no eligible work does `/jenga` output the completion message and exit.

## Approach

### 1. Update Step 6 (Exit condition)
Replace the immediate exit with a two-phase check:
- Phase 1: eligible task list is empty → invoke `/do` without a specific task ID, asking it to find stories with no tasks yet.
- Phase 2: if `/do` reports no eligible work → output completion message and exit.

### 2. Update "No eligible tasks at start" edge case
Reflect that the skill no longer exits immediately; instead it falls back to `/do`.

### 3. Add "Empty todo list" edge case
Explicitly document the scenario where `project/todo.md` is empty or has no actionable entries, and describe the `/do` fallback behaviour.

## Files Changed
- `skills/jenga/SKILL.md` — step 6, edge cases section
- `project/board/stories/E03_S03_jenga-empty-board-fallback.md` — status updates
- `project/documentation/summaries/E03_S03-summary.md` — execution summary
- `project/logs/events.json` — started/completed log entries
