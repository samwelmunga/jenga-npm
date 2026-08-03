# Plan: E03_S02 — /jenga Auto-Implementation Skill

## Problem Statement
The `/dooo` skill requires user interaction at every loop iteration to select the next task. When a user wants to run all eligible tasks without supervision, they must repeatedly confirm each selection. Rather than adding a `*` argument to `/dooo`, the auto-implementation feature is extracted into its own dedicated skill: `/jenga`.

## Approach

### Why a Separate Skill
A dedicated `/jenga` skill keeps `/dooo` purely interactive (present a list, wait for user choice) and gives the auto-implementation feature its own clear entry point, description, and documentation.

### How /jenga Works
1. **Collect eligible tasks** — read `project/board/stories/` and `project/board/tasks/`. A task is eligible if it is Pending, has no unresolved dependencies, and is directly listed in `project/todo.md` or belongs to a story that is listed there.
2. **Pick automatically** — sort eligible items by ID ascending (lexicographic) and select index 0.
3. **Invoke `/do`** — call the `/do` skill for the selected item without any user prompt.
4. **Mark Running** — update the item's `status:` to `Running` in its board file.
5. **Loop** — repeat from step 1 with no user interaction.
6. **Exit** — when no eligible tasks remain, the skill prints `✅ Jenga complete. All eligible tasks have been started.` and exits.

### Deterministic Sort
Sort eligible task IDs lexicographically ascending and pick index 0. This ensures reproducible behaviour regardless of filesystem ordering.

## Files Changed
- `skills/jenga/SKILL.md` (and `.agents/skills/jenga/SKILL.md`) — new skill with the auto-implementation loop
- `skills/dooo/SKILL.md` (and `.agents/skills/dooo/SKILL.md`) — restored to pure interactive behaviour
- `project/board/stories/E03_S02_dooo-wildcard-auto-select.md` — status updates
- `project/documentation/plans/E03_S02-plan.md` — this file
- `project/documentation/summaries/E03_S02-summary.md` — execution summary

