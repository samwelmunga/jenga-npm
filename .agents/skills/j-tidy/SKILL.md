---
name: j.tidy
description: Report, and then reclaim, stale git worktrees and branches — a sweep that enumerates every registered worktree and every local branch, classifies each one reclaimable or retained against four safety conditions, and states the disk each group represents. Report-only by default; reclaiming provably-safe entries is automatic and everything else needs an explicit decision.
keywords:
  - stale worktrees
  - clean up worktrees
  - delete old branches
  - disk usage
  - garbage collection
  - j-tidy
examples:
  - "j-tidy"
  - "how much disk are the old worktrees using?"
  - "clean up the stale worktrees and branches"
  - "which worktrees are safe to delete?"
  - "the repo has hundreds of worktrees, tidy it up"
  - "garbage-collect the branches that are already merged"
---

# Tidy — Worktree and Branch Garbage Collection

`skills/j-tidy/` is the **canonical, hand-edited** directory for this skill; the frontmatter name is
`j.tidy`, never `j.j-tidy` (CLAUDE.md, "The Canonical Naming Contract").

Every deterministic step — enumeration, classification, size accounting, threshold comparison,
rendering, removal — is a script under `skills/j-tidy/scripts/`, and those scripts' header comments
are the contracts. This file holds only what needs judgment: presenting the report, asking for the
confirmation, and interpreting a result that does not look right. Do not restate or re-implement
the scripts' logic here.

The lifecycle this skill implements — the populations, the four safety conditions, the squash-merge
case, the thresholds and the explicit non-goals — is documented in
`project/documentation/worktree-lifecycle.md`. Read it before changing a safety condition.

## Boundaries

- **Bare invocation reports and changes nothing.** There is no flag on the report path that
  deletes anything; `report.sh` has no removal code in it at all.
- **It never writes board status.** A `j.tidy` verdict is a statement about disk and git state, not
  about any task, story or epic.
- **It is not a `SessionEnd` hook and never runs unattended.** Reaping is watched, by decision
  (`E56_S06`'s locked decisions). Nothing here is scheduled, and unwatched deletion is an explicit
  non-goal, not an unimplemented feature.
- **Worktree removal always goes through `scripts/worktree-remove-guard.sh`**, and branch deletion
  always through `git branch -d`. No `git worktree remove --force` call, no use of the guard's
  override, no `-D` fallback — anywhere, under any circumstances.
- **It is the single implementation behind two entry points**: invoked directly, and invoked as a
  step by `/reconcile`. `/reconcile` calls this skill; it does not carry a copy of the sweep.

## What it covers, and why that matters

Two distinct populations live in `.claude/worktrees/`, and before this skill only one of them was
covered by anything:

| Population | Shape | Previously covered by |
|---|---|---|
| `board-task` | `<E##_S##_T##-slug>` | `/reconcile`, per task, driven off the board |
| `bundle` | `bundle-E##_S##` (`E32_S05` story bundles) | `/reconcile`, same way |
| `agent` | `agent-<hash>` — the native `EnterWorktree` tool and `isolation: "worktree"` subagents | **nothing** |
| `other` | anything else, including hand-made worktrees and the primary checkout | nothing |

`/reconcile` walks tasks and asks "does this task have a worktree?", matching on the task-ID slug.
`agent-<hash>` never matches that pattern, so those worktrees are invisible to every pre-existing
cleanup path — and they were the bulk of the 9.5 GB measured in this repo on 2026-11-04. This
sweep enumerates from the **filesystem and git** rather than from the board, which is what lets it
see them. The two mechanisms are not duplicates: `/reconcile` decides what the board should say,
`j.tidy` decides what is still needed on disk.

Local branches are enumerated too, including those with no worktree — the measured 350-vs-229 gap,
because a branch outlives the worktree that created it. Such a branch is reclaimable on its own.

## The four safety conditions

An entry is `reclaimable` only when **all** of these hold, and `retained` otherwise, with the
failing condition named:

1. it carries no content that is not already in its target ref (content-based, **not** an
   ancestry check — see `classify.sh`'s header for why, at length);
2. its commit count ahead of the target is reported, and a squash-merged entry whose touched
   files already match the target still qualifies;
3. its working tree is clean — modified **and** untracked both count as dirty;
4. `scripts/check-worktree-liveness.sh` reports no OS process with its cwd inside the path.

**The bias is deliberately asymmetric.** Wrongly retained costs some disk. Wrongly reclaimed
destroys the only copy of someone's work. Any condition that cannot be evaluated — unresolvable
ref, unreadable path, a failing git invocation, an indeterminate liveness answer — yields
`retained`. If you are tempted to loosen that, read `classify.sh`'s header first.

Three entries are reported but **structurally never reclaimable**, with a reason beginning
`excluded: ` — the primary checkout, the worktree the run is standing in, and the target ref
itself. Never offer those for removal, not even on confirmation.

## Thresholds

Retention age and the count and disk ceilings are read at run time from `tidy-config.json`
(`project/configs/tidy-config.json`, falling back to the shipped `templates/tidy-config.json`;
a project instance replaces the shipped file whole). No threshold number exists anywhere in the
scripts, and when no config can be resolved the report says the ceiling checks were skipped rather
than substituting a guess. `report.sh --print-thresholds` prints the resolved values and the file
they came from.

## Instructions

Resolve the scripts directory once. Shell variables do not survive between separate commands, so
define it again in each later command:

```bash
TIDY_DIR="$([ -d skills/j-tidy/scripts ] && echo skills/j-tidy/scripts || echo node_modules/@jenga-ai/agent/skills/j-tidy/scripts)"
```

### 1. Report (the default, and the whole of a bare invocation)

```bash
bash "$TIDY_DIR/report.sh"
```

Print the report. Then, in one or two sentences, say the part a human actually wants: how much disk
is reclaimable right now, whether any ceiling is crossed, and whether anything retained looks like
it needs a person rather than a sweep (unmerged work on a board-task branch, say). Do not
paraphrase or re-derive a verdict — the reasons come from the classifier and are already specific.

A full disk pass over a few hundred worktrees is slow (measured: about 11 minutes for 351 entries
in this repo, without the `du` pass). If the user wants a quick answer, add `--no-disk`; the report
then states that disk was not measured, and you must not present a disk figure it did not measure.

### 2. Reap — only when the user asks for it

A bare `j.tidy` stops at the report. Reaping is `reap.sh`, and it has exactly two modes, which is
the gate: `--auto` can only ever touch entries the classifier verdicted `reclaimable`, and
`--confirm <name>` takes **one** named `retained` entry at a time. There is no `--confirm all`, no
glob and no `--force`. Every entry is re-classified individually immediately before it is touched,
so a record stream that has gone stale cannot cause a removal.

**Preview first** when the user is at all unsure, or whenever the sweep is large:

```bash
bash "$TIDY_DIR/reap.sh" --auto --dry-run
```

**Then the provably-safe set**, which needs no per-entry prompting because all four conditions
held:

```bash
bash "$TIDY_DIR/reap.sh" --auto
```

Read the outcome lines back honestly. `removed-worktree-branch-kept` is a partial result, not a
success: the worktree is gone and `git branch -d` refused, which is the expected outcome for a
squash-merged branch and means the branch is still there. `refused` means the remove guard blocked
it because a process is live inside — report it and move on; never retry it with force, and never
reach for the guard's override.

**Then the retained entries, one at a time.** For each one, show the user its name, its disk, and
the reason the classifier retained it, and ask — a numbered question, per `CLAUDE.md`'s interaction
pattern:

```
`<name>` — <disk>, retained because <reason>.
1. Remove it anyway (the work it holds is not needed)
2. Keep it
3. Stop asking and leave the rest alone
4. Other (describe below)
```

Only on answer 1 do you run, for that single entry:

```bash
bash "$TIDY_DIR/reap.sh" --confirm "<name>"
```

Answer 2 means you simply do not run that command — declining leaves the entry untouched by
construction, with nothing to undo. Answer 3 ends the reap step; report what was done so far.

Never batch these. Never infer consent from an earlier "yes" to a different entry, from silence,
or from the fact that the permission system did not prompt: this task is `crucial_level: gated`,
and a confirmation that the user did not actually give is the one failure mode that destroys work.
If you cannot ask — a non-interactive run, say — do the `--auto` half and report the retained list
for a human to decide later.

### 3. Report what actually happened

Repeat the reap summary's own categories, keeping them apart: removals, partial removals, branches
kept because git refused `-d`, guard refusals, failures, and skips. A failed removal is never
reported as a success, and disk is only claimed as reclaimed when the removal actually succeeded.

## Interpreting an unexpected result

- **Everything is `retained` with "target ref does not exist"** — the repository has no `main`.
  That is a correct fail-closed answer, not a bug. Say so and stop.
- **`classify.sh` exits 3** — `scripts/check-worktree-liveness.sh` could not be located, so
  condition 4 is unevaluable and nothing could be safely reclaimed. Report it; do not work around
  it by skipping the condition.
- **A `retained` reason names content you believe is merged** — the entry's target ref is `main`
  for every population today, because `E56_S01` (story branches) is not built. Work sitting on an
  unmerged task branch is genuinely not in `main`, so `retained` is correct. Resolution happens in
  exactly one place, `skills/j-tidy/scripts/target-ref.sh`.
- **A count looks lower than you expected** — check for a truncation line. Truncation always
  states how many entries were not shown; if the number still looks wrong, raise
  `report_max_rows_per_group` or pass `--max-rows 0` and look again. A missing count is a
  reporting bug worth a rapport, not something to shrug at.
