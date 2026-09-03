---
name: j:todo
description: Add missions to the project todo list (project/todo.md), optionally linking them to epics and stories. Loops until the user is done, then optionally executes the list.
keywords:
  - todo
  - add task
  - queue work
  - backlog
  - add to list
examples:
  - "add this to the todo list"
  - "queue this as a task"
metadata: 
  prefered_agent: scrum-master
---

# Todo — Add Missions to the Todo List

## `--trivial` Flag

**Syntax:** `/todo --trivial <description>` — optionally combined with the same `: <Epic no.>_<Story no.>` linkage syntax normal `/todo` entries use, e.g. `/todo --trivial Fix typo in error message: E12_S03`.

When `--trivial` is present, the mission is written as a **fully-formed task board file immediately** (not just a raw `todo.md` line deferred to `/do`'s own breakdown pass) with `execution_scope: inline` forced unconditionally — no threshold computation is consulted for the scope value itself. See step 4.5 below for the mechanics.

**Human-only override.** `--trivial` is invoked by a human typing `/todo --trivial ...` — it is never applied by the scrum-master to itself during autonomous story/epic breakdown elsewhere (e.g. `/jenga`'s Phase 0.5, or `/do`'s own scrum-master decomposition step in `skills/do/SKILL.md` step 3). Those paths keep using the normal heuristic-only `execution_scope` assignment documented in `agents/scrum-master.md`'s Execution Scope Assignment section, unmodified by this flag.

**Fallback on failure is out of scope here.** If a `--trivial`-forced inline run fails the smoke-harness or shows scope creep at dispatch time, `/do`'s own `--trivial` handling (a separate task, E32_S14_T02) is responsible for falling back to the full `task` pipeline — this skill only ever writes the initial forced-inline task.

## Instructions

1. **Ensure `project/todo.md` exists** — If it doesn't exist, it will be auto-created by `todo_manager.sh` — no manual action needed.

2. **Ask the user about the mission:**
   - Where do you want to do this?
   - What would you like to do?
   - What is the goal?
   - (If `--trivial` was passed, these answers still apply — `--trivial` changes how the mission is written to the board in step 4.5, not what's asked here.)

3. **Classify the mission** — Check if it fits into:
   - An existing story
   - A new story inside an existing Epic
   - A new story inside a new Epic
   - None of the above

   **`--trivial` requires an existing (or, in this same step, newly-created) story to attach to.** It forces the scope of a single task, not a container — if the mission has no story yet, create it now via step 4 below exactly as normal, then continue to step 4.5. `--trivial` cannot be used for "None of the above."

4. **Update project documentation** — Add the mission to the appropriate files under `project/board/epics/` and `project/board/stories/` if applicable.
   - If the mission involves implementing or modifying a skill, apply the **Skill Implementation Principle — Scripts Over Inline Logic** (see `CLAUDE.md` / `AGENTS.md`): note in the story/task's acceptance criteria that deterministic, repeatable steps must be offloaded to scripts under `skills/<name>/scripts/` (or `scripts/`) rather than encoded as inline agent instructions in `SKILL.md`.
   - If the user indicates the mission is high-risk, or explicitly asks to flag it, set an elevated caution tier directly on the story or task frontmatter: `crucial_level` (one of `advisory`, `gated`, `locked` — see `templates/SCRUM_BOARD_SCHEMA.md` for valid values and their meaning), `crucial_set_by: user`, and `crucial_note` capturing the user's stated reason. This user-initiated flag is written immediately — it does not require the confirm-before-write gate, which applies only to scrum-master-*proposed* caution tiers (a separate, heuristic-driven path).

4.5. **If `--trivial` was passed, create the task now** (skip step 5 — this step writes the todo.md entry itself):

   a. **Estimate the change**, using the same judgment `agents/scrum-master.md`'s Execution Scope Assignment heuristic applies: how many files will this mission likely touch, and roughly how many lines. This is a reasoning step, not a script step — do not guess wildly, but a rough, honest estimate is sufficient.

   b. **Determine `computed_tier`** — what `execution_scope` the normal heuristic would have assigned to this estimate, purely for the audit trail (it is never written as the actual `execution_scope`, which is always forced to `inline`):
      - Read `inline_max_files`, `inline_max_lines`, and `story_max_files` from `project/configs/scope-thresholds.json` at run time — never hardcode these numbers here.
      - Apply `agents/scrum-master.md`'s `inline` / `story` / `task` heuristics (file count vs. `inline_max_files`, line estimate vs. `inline_max_lines`, contention and cross-cutting checks for `story`) to the estimate from (a). The result is `computed_tier` — one of `inline`, `task`, or `story` (never `epic` — the heuristic never autonomously computes `epic`).

   c. **Run the helper script**, which handles everything mechanical — next task-ID assignment, writing the task board file with `execution_scope: inline` forced, registering the new task ID into the parent story's `tasks:` frontmatter list, and adding the `project/todo.md` entry using the full task ID (so `/do` routes straight into its Inline Execution Path with no redundant breakdown pass):
      ```
      bash skills/todo/scripts/add_trivial_task.sh \
        --story <E##_S##> \
        --title "<mission title>" \
        --description "<mission description>" \
        --criteria "<criterion 1>|<criterion 2>|..." \
        --computed-tier <inline|task|story> \
        --est-files <N> \
        --est-lines <M> \
        [--prerequisites "<text>"]
      ```
      The script writes `scope_rationale` in the form `"forced inline via --trivial; computed scope would have been '<computed_tier>' — estimated <N> files, ~<M> lines"` and sets `jenga_assigned: false` with a matching `override_justification`, so `/do` step 4.1's existing override-validation logs the override on dispatch — no separate acknowledgement step needed here.
      On success the script prints the new task ID to stdout; on failure (e.g. the story doesn't exist yet, or `--computed-tier` is invalid) it exits non-zero with an explanatory message on stderr — surface that to the user rather than retrying blindly.
   d. Continue to step 6 (skip step 5 — the script already added the `todo.md` entry).

5. **Add to `project/todo.md`** by running (skip this step if step 4.5 already ran):
   ```
   bash scripts/todo_manager.sh add '<mission title>: <Epic no.>_<Story no.>'
   ```
   The epic and story reference is only required if the mission is assigned to one.

6. **Ask the user**: "Add another todo" or "Done"?
   - If **add another** — go back to step 2. (`--trivial` applies only to the mission it was passed with — it does not carry over to the next mission unless the user says `--trivial` again.)
   - If **done** — ask if they want to execute the todo list.
     - If **yes** — invoke the `/do` skill.
     - If **no** — exit.
