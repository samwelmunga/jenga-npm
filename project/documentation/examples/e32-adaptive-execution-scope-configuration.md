# E32 — Adaptive Execution Scope: How It Works & How Configuration Affects It

## 1. What it is

E32 ("Adaptive Execution Scope for `/jenga` + `/do`") is a feature that lets the
board orchestration skills — `/jenga` and `/do` — pick the *right amount of
overhead* for each task instead of treating every task identically. Every
task carries two new frontmatter fields, assigned by the scrum-master at
breakdown time:

- `execution_scope`: `inline` | `story` | `task` | `epic`
- `needs_docs`: boolean

These decide whether a task runs directly in the current session, gets
bundled with sibling tasks into one shared developer worktree, gets its own
fully isolated developer+tester cycle, or (rarely, and only with explicit
human sign-off) spans an entire epic.

## 2. Why it exists

Before this feature, every task — from a one-line config tweak to a
multi-file architectural change — went through the same heavyweight path:
spin up a developer subagent, create a git worktree, implement, commit, hand
off to the tester. That's correct for genuinely risky work, but wasteful for
trivial ones. E32 right-sizes the footprint so:

- Tiny, safe changes execute inline with no subagent/worktree/tester at all.
- Small clusters of related tasks in one story share a single worktree
  instead of spinning up one per task.
- Anything with branching logic, shared-infrastructure edits, or
  uncertainty still gets full isolation (the safe default).
- Nothing epic-sized ever gets auto-approved — a human has to opt in.

## 3. How it works

### Assignment (scrum-master, at breakdown time)

The scrum-master reads **all numeric thresholds** from
`project/configs/scope-thresholds.json` — it never hardcodes them — and
applies heuristics:

- **`inline`**: task touches exactly `inline_max_files` file, needs no new
  tests, is purely additive/config-level (no new branching logic), and the
  estimated diff is ≤ `inline_max_lines` lines. `needs_docs` is always
  `false` for inline tasks.
- **`story`**: *all* tasks in the story share a module/directory, have no
  cross-story dependencies, and the story's total file count is below
  `story_max_files`. A mandatory **contention check** first verifies no two
  tasks in the story write the same shared-infra file (`package.json`,
  `settings.json`, etc.) — if they do, *both* tasks are downgraded to
  `task` scope and the conflict is written into each one's
  `scope_rationale`.
- **`task`** (default/safe choice): used whenever there's branching logic,
  sensitive tester validation, shared-infra edits, cross-story deps, a
  failed contention check, or just uncertainty. "When in doubt, default to
  `task`."
- **`epic`**: never assigned autonomously. The scrum-master leaves the task
  at `task` scope and notes in `scope_rationale` that it may warrant epic
  scope — only a human sets `epic_scope_approval: true`.

Every scoped task must carry a `scope_rationale` string with a measurable
justification (e.g. "touches 1 file; purely additive; ~15 lines") — vague
rationales like "this is small" are rejected in favor of falling back to
`task` scope.

### Execution (`/jenga` and `/do`, at runtime)

Both skills **load `scope-thresholds.json` fresh on every invocation** (no
cached/hardcoded fallbacks) and **hard-fail** if it's missing or malformed —
the config is a required dependency, not an optional tuning knob:

```
ERROR: project/configs/scope-thresholds.json not found. Cannot proceed.
ERROR: project/configs/scope-thresholds.json is malformed (invalid JSON). Cannot proceed.
```

From there:

- **`/do` inline path** (§4.2): if a task's `execution_scope: inline`, `/do`
  implements it directly in the current session — no developer subagent,
  no worktree. It commits, runs an Intent-vs-Diff divergence check, self-
  verifies against acceptance criteria, and marks `Passed`. If the change
  turns out bigger than expected mid-implementation, it aborts and
  re-routes to the normal developer path.
- **`/jenga` bundle detection** (Phase 3.5): for each story, if *every*
  task has `execution_scope: story` (all-or-nothing — one mismatched task
  disqualifies the whole story), `/jenga` calls `/do <story_id>` once
  instead of dispatching tasks individually.
- **`/do` story-bundle mode** (§1.5): acquires an epic-level lock
  (`project/queue/epic-lock-<E##>.json`, staleness governed by
  `bundle_lock_ttl_minutes`) so two bundles in the same epic can't run
  concurrently, writes a rollback-anchor manifest (`anchor_sha` +
  `task_changed_files`), then runs all the story's tasks sequentially in
  **one shared worktree/developer session**. After each task it:
  - records the files it actually touched,
  - checks a pre-execution cross-bundle scan for file overlap with *other*
    active bundles (non-blocking — just logged and recorded), and
  - diffs actual vs. expected files (inferred from `scope_rationale` +
    description) — if unexpected files show up, it writes a non-blocking
    conflict report to `project/queue/conflict-<task_id>.md` (this is what
    the E32_S07 tasks you have staged — conflict reporting and cross-bundle
    checks — implement).
  - On any task failure, it resets the worktree back to `anchor_sha` and
    aborts the rest of the bundle.
- **Threshold values are passed through, not re-derived**: `/jenga`
  Phase 4 and `/do` both reuse the exact `inline_max_files`,
  `inline_max_lines`, `story_max_files`, and `bundle_lock_ttl_minutes`
  values loaded once at the top of the run.

## 4. How the configuration (`scope-thresholds.json`) affects the skill

```json
{
  "threshold_version": 1,
  "inline_max_files": 1,
  "inline_max_lines": 20,
  "story_max_files": 5,
  "bundle_lock_ttl_minutes": 30
}
```

This file is the *only* place these numbers live — changing it changes
behavior immediately on the next `/jenga` or `/do` run, with no code change
needed:

| Field | Controls | Effect of raising it | Effect of lowering it |
|---|---|---|---|
| `inline_max_files` | how many files a task may touch and still qualify for `inline` | more tasks skip the subagent/worktree entirely (faster, but no tester coverage since `needs_docs` is always `false` for inline) | fewer tasks qualify inline; more go through full isolation |
| `inline_max_lines` | max diff size for `inline` | larger diffs get fast-tracked without review | small diffs get pushed to full `task` scope, adding worktree+developer+tester overhead for trivial changes |
| `story_max_files` | max total files across a story's tasks to qualify for bundling | bigger stories get bundled into one shared worktree (fewer subagent spin-ups, but one failure rolls back the whole bundle) | stories bundle less often; more tasks fall back to individual isolated execution |
| `bundle_lock_ttl_minutes` | how long an epic-level bundle lock is honored before being considered stale | a crashed/stuck bundle blocks other bundles in the same epic longer before the lock is reclaimable | stale locks get reclaimed faster, but a genuinely slow (not crashed) bundle risks a second bundle in the same epic starting prematurely |

Because both skills treat a missing/malformed config as a hard stop rather
than falling back to defaults, the config isn't just a tuning surface — it's
a load-bearing precondition for `/jenga` and `/do` to run at all.

## 5. When to use it / not

You don't "opt in" to E32 — it's load-bearing in `/jenga` and `/do` for
every task once the scrum-master assigns `execution_scope`. Where it matters
practically:

- **Tuning behavior**: edit `project/configs/scope-thresholds.json` to make
  the board more aggressive about inlining/bundling (fewer subagents, less
  isolation) or more conservative (more isolation, more tester coverage).
- **Debugging unexpected routing**: if a task ran inline (or got bundled)
  when you expected full isolation, check its `scope_rationale` against the
  current thresholds — the scrum-master's assignment is a snapshot at
  breakdown time and won't retroactively update if you change the config
  later.
- **Manual override**: a human can force a specific scope by hand-editing a
  task's frontmatter, but must also set `jenga_assigned: false` plus a
  non-empty `override_justification` — `/do` hard-halts on override tasks
  that are missing the justification.

## Example (grounded in this repo's board)

A task like "add a `divergence_flag` field to the task schema doc" that
touches exactly 1 file (`SCRUM_BOARD_SCHEMA.md`) with a ~15-line, purely
additive diff:

- **Before** (current thresholds: `inline_max_files: 1`,
  `inline_max_lines: 20`): qualifies for `inline` scope. `/do` implements it
  directly in the current session, commits, and self-verifies — no
  developer subagent, no worktree, no tester invocation.
- **After** (hypothetically lowering `inline_max_lines` to `10`): the same
  15-line diff now exceeds the threshold, so the scrum-master would instead
  assign `task` scope at breakdown time. `/do` would spin up a full
  developer subagent in an isolated worktree and hand off to the tester for
  what is still a trivial, single-file change — more isolation and review,
  at the cost of more overhead.
