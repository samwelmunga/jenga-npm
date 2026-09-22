---
name: j.todo
description: Add missions to the project todo list (project/todo.md), optionally linking them to epics and stories. Loops until the user is done, then optionally executes the list.
output_types:
  - when: argument-is-ranked-list
    type: ranked_list
  - when: argument-is-not-ranked-list
    type: id_list
input_types: id_list
keywords:
  - todo
  - add task
  - queue work
  - backlog
  - add to list
  - j-todo
examples:
  - "add this to the todo list"
  - "queue this as a task"
  - "j-todo"
metadata: 
  prefered_agent: scrum-master
---

# Todo — Add Missions to the Todo List

`skills/j-todo/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-todo/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/todo/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## `--trivial` Flag

**Syntax:** `/todo --trivial <description>` — optionally combined with the same `: <Epic no.>_<Story no.>` linkage syntax normal `/todo` entries use, e.g. `/todo --trivial Fix typo in error message: E12_S03`.

When `--trivial` is present, the mission is written as a **fully-formed task board file immediately** (not just a raw `todo.md` line deferred to `/do`'s own breakdown pass) with `execution_scope: inline` forced unconditionally — no threshold computation is consulted for the scope value itself. See step 4.5 below for the mechanics.

**Human-only override.** `--trivial` is invoked by a human typing `/todo --trivial ...` — it is never applied by the scrum-master to itself during autonomous story/epic breakdown elsewhere (e.g. `/jenga`'s Phase 0.5, or `/do`'s own scrum-master decomposition step in `skills/j-do/SKILL.md` step 3). Those paths keep using the normal heuristic-only `execution_scope` assignment documented in `agents/scrum-master.md`'s Execution Scope Assignment section, unmodified by this flag.

**Fallback on failure is out of scope here.** If a `--trivial`-forced inline run fails the smoke-harness or shows scope creep at dispatch time, `/do`'s own `--trivial` handling (a separate task, E32_S14_T02) is responsible for falling back to the full `task` pipeline — this skill only ever writes the initial forced-inline task.

## `--ranked-list` Flag

**Syntax:** `/todo --ranked-list` — takes no other arguments.

**Non-interactive, one-shot, read-only.** `--ranked-list` is a distinct mode, not a modifier on a
normal `/todo` mission-add invocation. It calls the shared `scripts/render-ranked-list.sh` (built by
`E63_S01_T01`; see that script's own header comment for the full eligibility rule and its env-var
overrides — do not re-derive or restate the scan logic here) and prints its stdout **verbatim**, then
exits — this is exactly the same script and the same eligibility scan `/dooo`'s own step 2/3 already
uses (`skills/j-dooo/SKILL.md`), so `--ranked-list`'s output is byte-for-byte identical to `/dooo`'s
list for the same board/`todo.md` state. Do not append a trailing "Done" option or any interactive
prompt — that framing belongs to `/dooo`'s own UI layer on top of the script, not to the shared
script's output, and not to `--ranked-list` either.

**No mutation.** `--ranked-list` never writes `project/todo.md`, never writes a board file, and never
dispatches a task. It is a pure read/render, matching `scripts/render-ranked-list.sh`'s own
no-mutation contract.

**Takes precedence over mission text.** If the user somehow passes `--ranked-list` together with
mission text, treat `--ranked-list` as taking precedence and ignore the mission text — it has no
mission to attach to, so it cannot combine the way `--trivial` combines with an epic/story reference.

**Short-circuits the whole flow.** See step 0 below — when `--ranked-list` is passed, none of the
normal `/todo` steps 1-6 (the "where/what/goal" questions, mission classification, board writes, the
"add another" loop) are ever reached.

## Instructions

0. **If `--ranked-list` was passed, handle it now and stop — do not proceed to step 1:**
   ```
   bash "$([ -f scripts/render-ranked-list.sh ] && echo scripts/render-ranked-list.sh || echo node_modules/@jenga-ai/agent/scripts/render-ranked-list.sh)"
   ```
   Print the script's stdout verbatim as the response (no added framing, no "Done" option, no
   follow-up question) and end the skill invocation here. Steps 1-6 below do not apply to
   `--ranked-list` at all.

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
   - If the user indicates the mission is high-risk, or explicitly asks to flag it, set an elevated caution tier directly on the story or task frontmatter: `crucial_level` (one of `advisory`, `gated`, `locked` — see `$([ -f templates/SCRUM_BOARD_SCHEMA.md ] && echo templates/SCRUM_BOARD_SCHEMA.md || echo node_modules/@jenga-ai/agent/templates/SCRUM_BOARD_SCHEMA.md)` for valid values and their meaning), `crucial_set_by: user`, and `crucial_note` capturing the user's stated reason. This user-initiated flag is written immediately — it does not require the confirm-before-write gate, which applies only to scrum-master-*proposed* caution tiers (a separate, heuristic-driven path).

4.5. **If `--trivial` was passed, create the task now** (skip step 5 — this step writes the todo.md entry itself):

   a. **Estimate the change**, using the same judgment `agents/scrum-master.md`'s Execution Scope Assignment heuristic applies: how many files will this mission likely touch, and roughly how many lines. This is a reasoning step, not a script step — do not guess wildly, but a rough, honest estimate is sufficient.

   b. **Determine `computed_tier`** — what `execution_scope` the normal heuristic would have assigned to this estimate, purely for the audit trail (it is never written as the actual `execution_scope`, which is always forced to `inline`):
      - Read `inline_max_files`, `inline_max_lines`, and `story_max_files` from `project/configs/scope-thresholds.json` at run time — never hardcode these numbers here.
      - Apply `agents/scrum-master.md`'s `inline` / `story` / `task` heuristics (file count vs. `inline_max_files`, line estimate vs. `inline_max_lines`, contention and cross-cutting checks for `story`) to the estimate from (a). The result is `computed_tier` — one of `inline`, `task`, or `story` (never `epic` — the heuristic never autonomously computes `epic`).

   c. **Run the helper script**, which handles everything mechanical — next task-ID assignment, writing the task board file with `execution_scope: inline` forced, registering the new task ID into the parent story's `tasks:` frontmatter list, and adding the `project/todo.md` entry using the full task ID (so `/do` routes straight into its Inline Execution Path with no redundant breakdown pass):
      ```
      bash skills/j-todo/scripts/add_trivial_task.sh \
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
   bash "$([ -f scripts/todo_manager.sh ] && echo scripts/todo_manager.sh || echo node_modules/@jenga-ai/agent/scripts/todo_manager.sh)" add '<mission title>: <Epic no.>_<Story no.>'
   ```
   The epic and story reference is only required if the mission is assigned to one.

6. **Ask the user**: "Add another todo" or "Done"?
   - If **add another** — go back to step 2. (`--trivial` applies only to the mission it was passed with — it does not carry over to the next mission unless the user says `--trivial` again.)
   - If **done** — ask if they want to execute the todo list.
     - If **yes** — invoke the `/do` skill.
     - If **no** — exit.
