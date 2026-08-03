# Summary: E03_S02 — Auto-Implementation via /jenga Skill

## What Was Changed

### `skills/dooo/SKILL.md` (and `.agents` mirror)
- Restored to pure interactive behaviour — presents a numbered list of eligible tasks to the user at each iteration.
- Removed the `*` wildcard invocation row, the auto-select note in Step 3, and the Auto-Select Mode section.
- Retained the story-derived task eligibility improvement: tasks from `project/board/tasks/` whose parent story is in `project/todo.md` are included as eligible candidates in the interactive list.

### `skills/jenga/SKILL.md` (new, and `.agents` mirror)
- New skill that owns the fully automated implementation loop (previously the `/dooo *` auto-select mode).
- Reads the board, finds all eligible tasks, and repeatedly invokes `/do` without any user prompts until no tasks remain.
- Eligibility criteria: `Pending` status, resolved dependencies, directly listed in `project/todo.md` or derived from a queued story.

### `project/board/stories/E03_S02_dooo-wildcard-auto-select.md`
- Progressed `status` from `Pending` → `In Progress` → `Passed`.
- Set `date_started` and `date_completed` to `2026-04-29`.
- Checked all acceptance criteria and tasks.

## Auto-Implementation Behaviour (Plain Language)
When a user types `/jenga`, the skill skips every interactive prompt. It reads the board, finds all tasks that are Pending and ready to run (dependencies met, in todo.md or derived from a queued story), sorts them by ID, picks the first one, and starts it with `/do`. This repeats in a tight loop with no human input until the eligible list is empty, at which point the skill prints a completion message and exits.

## `/dooo` Behaviour (Plain Language)
`/dooo` remains purely interactive. After each `/do` invocation it reads the board and presents a numbered list of eligible parallel tasks to the user via `ask_user`. The user chooses the next task to start (or selects "Done" to exit).

## Edge Cases Considered
- **No eligible tasks at start** — `/jenga` exits immediately with the completion message rather than hanging on an empty list.
- **Task not in todo.md** — even if Pending and unblocked, a story/task not in `todo.md` (or derived from one that is) is excluded from both `/dooo` and `/jenga`.
- **Story-derived tasks** — if `todo.md` contains a story (e.g., `E01_S06`) that gets broken down into individual tasks, those tasks are included in the eligible scope for both skills. Each task is evaluated independently.
- **`/do` failure** — treated as a skip so the remaining tasks can still be attempted.
