---
name: j.verify
description: Verify one already-built task by dispatching the Tester against evidence you supply — commit SHAs or file paths — and stop at the verdict, for work that was registered on the board after it was built and so has no EST-tagged commits for j.close-task to find.
keywords:
  - verify task
  - verify with evidence
  - retroactive verification
  - no tagged commits
  - call the tester
  - j-verify
examples:
  - "verify E87_S01_T01 against these commits"
  - "j-verify E88_S02 — the work is already built, here are the files"
  - "have the tester judge this task, I'll give you the evidence"
  - "verify the tasks of E87, it was registered after the fact"
---

# verify — Judge an Already-Built Task Against Supplied Evidence

`skills/j-verify/` is the canonical, hand-edited directory for this skill.

## Purpose

`/j-verify <id>` has the Tester judge a task whose implementation already exists, using evidence the
**caller supplies** rather than evidence the board can derive. It exists for one specific situation: work
that was built first and registered on the board afterwards, in a session that never went through
`j.do`. No commit for that work carries an EST id, so every mechanism that derives SHAs from commit
messages finds nothing and refuses.

`<id>` may be a task, a story or an epic. The **task is the unit of work** — a story or epic id is an
input convenience that expands to the tasks beneath it, which you then pick from. There is no
story-level or epic-level verdict, so no story-status decision and no partial-failure semantics.

This skill sets no `prefered_agent` because it orchestrates the Tester itself, the way `j.close-task`
does. It never writes a status or a trigger.

## How this differs from `j.do` and `j.close-task`

The three are easy to confuse. The difference is what each one assumes already exists:

| Skill | Assumes | Does | Ends with |
|---|---|---|---|
| `j.do` | a task that is **not built yet** | implements it, then verifies | implementation plus a verdict |
| `j.close-task` | a task **built and committed with its EST id** | derives the SHAs itself, verifies, then rolls up | the story and epic statuses |
| `j.verify` | a task **built, with no usable commit trail** | takes evidence as input, verifies | the verdict, and nothing else |

So: `j.do` implements then verifies; `j.close-task` verifies a committed task and rolls up; `j.verify`
verifies against supplied evidence and stops.

Prefer `j.close-task` whenever the task's commits carry its EST id — it needs no evidence argument and it
completes the rollup. Reach for `j.verify` only when that derivation comes up empty, which is exactly
the case `j.close-task`'s guard refuses.

## Instructions

Throughout, `VC` is the helper from `E87_S07_T01`:

```bash
VC="$([ -f skills/j-verify/scripts/verify-context.sh ] && echo skills/j-verify/scripts/verify-context.sh || echo node_modules/@jenga-ai/agent/skills/j-verify/scripts/verify-context.sh)"
```

Everything deterministic lives in that script — id classification, board resolution, the frontmatter
walk, evidence checking and the sender object. Do not re-derive any of it here.

### 1. Expand the id

```bash
bash "$VC" expand <id>
```

It accepts `E##`, `E##_S##` and `E##_S##_T##` and prints one task per line, TAB-separated:
`<task_id>\t<status>\t<title>`. Exit 5 means the story or epic contains no tasks — report its message
and stop; there is nothing to verify. Exit 2 is a malformed id and exit 1 a missing or ambiguous board
file: report the stderr line and stop.

If no `<id>` was given at all, ask for one. A line whose status reads `missing` is a board
inconsistency the script warned about — surface it and do not offer it as a choice.

### 2. Pick the tasks

With exactly one task, go to step 3 with it.

With more than one, present them as a numbered list before any dispatch, free text last, per CLAUDE.md's
Interaction Pattern — showing each task's status and title so an already-`Passed` task is visible as
such:

    Which task would you like the Tester to verify?
    1. E87_S01_T01 — Pending — Add the close-task-context.sh helper and its bats tests
    2. E87_S01_T02 — Pending — Write the j.close-task SKILL.md orchestration
    3. All of them, one at a time
    4. Other (describe below)

Then work the chosen tasks **one at a time**, repeating steps 3 to 5 for each.

### 3. Get the evidence for this task

Evidence is what the Tester will read to judge the task: commit SHAs, repo-relative file paths, or both,
as one comma-separated list. If the caller already supplied it, use it verbatim. If not, ask for it —
and ask in terms of the task at hand, naming the files its board entry points at.

Never infer evidence from a plausible-looking commit or file, and never substitute your own reading of
the code for it. Supplying evidence is the caller's job; this skill's whole reason to exist is that the
automatic derivation is unavailable here.

### 4. Resolve the context

```bash
bash "$VC" context <task_id> --evidence "<the list>" [--session <id>]
```

Omit `--evidence` only when the task does have EST-tagged commits and you want the normal derivation.
Pass `--session <id>` when an orchestrator supplied a session id, so the sender object reuses it.

The script prints one JSON object carrying the task file path, the story and epic ids, the task's current
status and status class, the derived `commits` and `other_branch_commits`, the resolved `evidence`,
`evidence_shas`, `evidence_paths`, `evidence_source`, and a ready-to-use `sender` object whose `paths`
are the evidence. Branch on its exit code:

| Exit | Meaning | Action |
|---|---|---|
| 0 | evidence resolved | continue to step 5 |
| 3 | **no evidence** — none supplied, none derivable | **do not dispatch.** The JSON was still printed: report `task_status`, and that both `commits` and `other_branch_commits` are empty, so the caller can see *why* nothing was derivable. Ask for evidence and retry step 4. Never dispatch the Tester with empty `paths`. |
| 4 | an evidence item is unusable | report the script's message, which names the item — an unresolvable SHA or a path that does not exist. Ask for a correction and retry step 4. |
| 2 | usage | fix the invocation. |
| 1 | board file missing or ambiguous, or helper unavailable | report the stderr line and stop. |

Exit 3 is **not** a generic failure and must not be collapsed into one: it is the one outcome where the
printed JSON is the useful part.

Before dispatching, also check `status_class`. On `completed` or `ladder` the task is already closed —
say so and confirm the caller still wants it re-verified. On `Blocked` or `Rejected`, stop: neither is a
state this skill may override.

### 5. Dispatch the Tester

Dispatch the `tester` agent once for this task. Its prompt carries, unchanged from step 4's output: the
`sender` object, the task file path, the story and epic ids, and the evidence — stating plainly which
items are commit SHAs and which are file paths, and that the evidence was **supplied by the caller
because the task has no EST-tagged commits**, so the Tester does not go looking for a commit trail that
does not exist.

Call it directly and use its return value. Never poll for its completion — no waiting loop on a branch,
a SHA or a file (`agents/developer.md`, "Prohibited — ad-hoc completion-polling loops").

The Tester writes the judged status; this skill does not. On a `failed` or `error` return, report the
status and the rapport path and stop — do not continue to the next chosen task unless the caller asks.

### 6. Report, and name the rollup

For each task verified, report the task id, the verdict the Tester returned, the status it wrote, and the
evidence that was judged. Then stop.

Close by naming the rollup path rather than performing it:

> Verified. This skill stops at the verdict — it does not roll up. To close the story and epic above,
> run `j.close-task <task_id>`, which drains the trigger queue through the Scrum Master.

If the Tester wrote a `story_rollup` trigger because this was the story's last open task, say that the
trigger is queued and still needs `j.close-task` to process it. Do not process it here.

## What this skill never does

- **Never writes a board status.** The Tester is the only writer of a judged status
  (`templates/SCRUM_BOARD_SCHEMA.md`, "Status Writers").
- **Never writes a queue trigger**, and never edits `project/queue/`.
- **Never dispatches the scrum-master**, and never rolls up a story or an epic. Rollup is named, not
  performed — that is `j.close-task`'s job.
- **Never invents evidence.** Exit 3 stops the run; it is not a cue to go hunting for a likely commit.
