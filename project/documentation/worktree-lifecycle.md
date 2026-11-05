# Worktree and branch lifecycle

How a Jenga worktree comes into existence, what keeps it alive, and the contract under which it is
reclaimed. Owner: `E56_S06` (worktree and branch garbage collection). The implementation is the
`j.tidy` skill (`skills/j-tidy/`), invoked directly or as step 6.6 of `/reconcile`.

---

## 1. The populations

| Population | Shape | Created by | Previously reclaimed by |
|---|---|---|---|
| `board-task` | `<E##_S##_T##-slug>` | `scripts/create-task-worktree.sh`, via the `WorktreeCreate` hook and the developer agent | `/reconcile`, per task, driven off the board |
| `bundle` | `bundle-E##_S##` | `E32_S05` story-bundle execution | `/reconcile`, the same way |
| `agent` | `agent-<hash>` | the native `EnterWorktree` tool, and subagents with `isolation: "worktree"` | **nothing** |
| `other` | anything else, including the primary checkout | by hand, or by a tool that does not follow the convention | nothing |

The `agent` population is the reason this feature exists. `/reconcile` matches a worktree to a
task by the task-ID slug; `agent-<hash>` never matches, so every pre-existing cleanup path was
blind to it. The harness removes such a worktree automatically only when it is unchanged on exit,
and the ones that accumulate are precisely those that were changed.

Local branches are their own population in practice: a branch outlives the worktree that created
it, so the branch count runs ahead of the worktree count and the surplus is reclaimable on its own.

### The measured baseline (Jenga repo, 2026-11-04, before any of this existed)

| Metric | Value |
|---|---|
| Registered worktrees | 229 (228 besides the primary checkout) |
| Local branches | 350 |
| Disk in `.claude/worktrees` | **9.5 GB** |
| `.git` | 245 MB |
| `git worktree prune --dry-run` finds | nothing |

`git worktree prune` finds nothing because no registration is corrupt — every directory still
exists. These worktrees were never removed, not broken. A sampled ten measured 31–85 MB apiece.

---

## 2. The four safety conditions

An entry is classified `reclaimable` only when **all four** hold, and `retained` otherwise, with
the failing condition named in its reason:

1. **It carries no content that is not already in its target ref.** Content-based, not an
   ancestry check — see §3.
2. **Its commit count ahead of the target is measured and reported.** `ahead = 0` means a plain
   ancestor; `ahead > 0` with nothing unique means squash-merged. Both qualify; the reason text
   says which.
3. **Its working tree is clean.** `git status --porcelain` empty, so **modified and untracked both
   count as dirty**. An untracked file is somebody's unsaved work as often as it is a build
   artifact, and the classifier cannot tell which.
4. **No OS process has its cwd inside it.** `scripts/check-worktree-liveness.sh` (`E37_S03_T01`),
   reused and never reimplemented. Any non-zero exit retains the entry — including exit 4,
   "cannot determine liveness on this platform", which is not the same as clear.

### The bias is deliberately asymmetric

Wrongly retained costs some disk. Wrongly reclaimed destroys the only copy of someone's work.
Every condition that cannot be affirmatively evaluated — unresolvable ref, failing `merge-base`,
unreadable path, missing directory, indeterminate liveness, even a path containing a newline that
would corrupt the comparison — yields `retained`. There is no code path to `reclaimable` that
skips a condition, and when the liveness script cannot be located at all the classifier **refuses
to run** rather than quietly degrading to three conditions.

### Three entries are structurally never reclaimable

The primary checkout, the worktree the run is standing in, and the target ref itself. Their reason
begins `excluded: `, they are reported rather than silently dropped, and they are refused by the
reaper in both of its modes — confirmation or not. Without the third of these, a self-comparison
would classify `main` as carrying nothing unique and offer to delete it.

---

## 3. The squash-merge case, and why ancestry alone is not the test

For a ref `R` and target `T`, the classifier computes:

```
mb     = git merge-base T R          the fork point
P      = git diff --name-only mb R   paths R touched since the fork point
D      = git diff --name-only T R    paths where R differs from T right now
unique = P ∩ D
```

`unique` empty means `R` holds no content that is not already in `T`.

Both obvious one-liners are wrong here:

- **two-dot `git diff T R`** alone is non-empty for every entry that is merely *behind* `T`, so it
  would retain the entire backlog in any repository whose `main` keeps moving;
- **three-dot `git diff T...R`** (that is, `mb → R`) is non-empty for exactly the squash-merged
  case, because `mb` predates the squashed work;
- **`git merge-base --is-ancestor`** is non-empty-equivalent: a squash merge replaces a branch's
  commits with one new commit, so the branch tip is not an ancestor of `T` even though all of its
  content is there.

The intersection is empty for a plain ancestor (`P` is empty), empty for a squash-merged branch
whose touched files now match `T`, and non-empty whenever `R` holds content `T` does not — the only
direction that can destroy work. If `T` later changes one of those files again, the intersection
becomes non-empty and the entry is retained: conservative, and correct for a tool whose worst
outcome is deleting the wrong thing.

The test suite pins this with an explicit squash-merge fixture, including a case that asserts
`merge-base --is-ancestor` disagrees with the content verdict, so nobody can "simplify" the
classifier back to an ancestry check without a red test.

**Measured note, 2026-11-04.** `E56_S06`'s story file records that an ancestry-only check
classified 0 of 228 worktrees as reclaimable. That figure did not reproduce: against this
repository, all 230 entries the content classifier calls reclaimable are also ancestors of `main`,
so an ancestry check would have found the same 230. The inverted-argument form
(`git merge-base --is-ancestor main <entry>`, i.e. "is the entry up to date with main?") does
return 0 of 230, which is the most likely origin of the recorded figure. The content test is kept
regardless: it is strictly safer, it is the only form that survives a squash-merge workflow, and
`/j-mirror-public` does squash onto its public counterpart.

---

## 4. Reclamation

Two modes, and the gate is the shape of the interface rather than a convention an agent has to
remember:

- **`reap.sh --auto`** removes every `reclaimable` entry with no prompting, and is structurally
  incapable of touching a `retained` one — the verdict is the filter and no flag widens it.
- **`reap.sh --confirm <name>`** removes exactly one named `retained` entry, because a human said
  so about that entry. There is no `--confirm all`, no glob, no list form, and no `--force`. A name
  matching zero or more than one record is refused rather than guessed at.

Declining a confirmation means `--confirm` is simply never invoked for that entry, so the entry is
left untouched by construction and there is nothing to undo.

Every entry is **re-classified individually immediately before it is touched**, through the same
classifier that produced the original verdict, because a record stream can be minutes old (a full
pass over this repository measured 11m31s) and a process can start or a file can change inside that
window. A changed verdict means the entry is skipped and the new reason reported.

### Removal mechanics

- Worktree removal is `scripts/worktree-remove-guard.sh <path>` and nothing else — never
  `git worktree remove --force` directly, never `--force-ignore-liveness`, never
  `WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS`. The guard is the hard-block-by-default liveness
  precondition added by `E37_S03_T02` after a real 2026-08-25 incident in which a completed
  agent's shell polling loops had their cwd deleted out from under them. **A guard refusal is
  reported and skipped, never retried with force.**
- Branch deletion is `git branch -d`, the merge-checking form, with **no `-D` fallback anywhere**.
  A refusal means git and the classifier disagree about the branch being merged, and git wins: the
  branch is kept and the refusal is reported. This is the routine outcome for a squash-merged
  branch — its worktree goes, its branch stays — and is reported as the partial outcome
  `removed-worktree-branch-kept`, which is neither a success nor a failure.
- Outcomes are kept apart in the summary: removals, partial removals, branches kept, guard
  refusals, failures, skips. A failed removal is never folded into the success count and its disk
  is never counted as reclaimed.

---

## 5. Thresholds

`tidy-config.json` holds the nag thresholds, read at run time. Resolution order:
`JENGA_TIDY_CONFIG_FILE`, then `$(scripts/resolve-root.sh get configs)/tidy-config.json`, then the
shipped `templates/tidy-config.json`. A project instance replaces the shipped default whole; there
is no merging.

| Key | Default | Meaning |
|---|---|---|
| `retention_age_days` | 14 | Age, from the entry's last commit, at which it counts as stale |
| `worktree_count_ceiling` | 40 | Registered worktrees above this are reported as a crossed ceiling |
| `branch_count_ceiling` | 80 | Branches with no worktree above this are reported as a crossed ceiling |
| `disk_ceiling_mb` | 2048 | Measured worktree disk above this is reported as a crossed ceiling |
| `report_max_rows_per_group` | 15 | Rows per group before truncation — which always states its omission count |

**No threshold number exists in any script.** When no config can be resolved, the report says the
ceiling checks were skipped and truncates nothing, rather than substituting a hidden default that
would misreport a project which never configured one. `report.sh --print-thresholds` names the
resolved values and the file they came from. Field-by-field documentation is in
`project/configs/README.md`.

All three ceilings are crossed by the measured baseline above. That is intentional: the state that
prompted this work must read as a crossed ceiling, not as normal.

---

## 6. Explicit non-goals

- **Unwatched deletion.** `j.tidy` is not a `SessionEnd` hook, is not scheduled, and has no
  background mode. Reaping happens while someone is watching, by decision (`E56_S06`'s locked
  decisions). This is a non-goal, not an unimplemented feature; do not add a hook that calls it.
- **A `--force` path.** There is deliberately no way to overrule the remove guard or `git branch
  -d` from inside this skill. If the guard is wrong about a specific path, that is a conversation
  about that path, held by a human, using the guard's own documented override — not something this
  skill ever does on anyone's behalf.
- **Deciding board status.** `j.tidy` never writes a task, story or epic status. It reports on
  disk and git state; `/reconcile` owns what the board should say.

---

## 7. Open follow-up

**Target-ref resolution is a single seam, and `E56_S01` must revisit it.**
`skills/j-tidy/scripts/target-ref.sh` is the only place that answers "what ref should this entry's
work have reached?", and it answers `main` for every population today because `E56_S01` (story
branches) is not built — see `E56_S06`'s "Dependency relaxed" section. That is the conservative
direction: work on an unmerged task branch is genuinely not in `main`, so it classifies `retained`.
When `E56_S01` lands, give `board-task` (and `bundle`, if story branches get their own worktrees) a
resolution that returns the entry's story branch and falls back to `main` when it does not exist.
Nothing else in the skill needs to change, and a test fails if any other script in it names the ref
directly.


## First real run: clearing the existing backlog (2026-11-04, `E56_S06_T04`)

Run attended, from the main checkout, through `reap.sh --auto` after a `--dry-run` preview. The
thresholds in `project/configs/tidy-config.json` were tuned against this baseline.

| | Before | After |
|---|---|---|
| Registered worktrees | 230 | **92** |
| Local branches | 351 | **120** |
| `.claude/worktrees` | ~9.5 GB | **4.10 GB** |
| `.git` | 253 MB | **185 MB** |

**Reclaimed:** 138 worktrees and 93 branch-only entries (231 branches in all), 5.42 GB. Zero
refused by the guard, zero failed, zero skipped, and `git branch -d` never refused.

**Every reclaimed entry was a plain ancestor of `main`.** None depended on the squash-merge content
test, so this run exercised the ancestry-equivalent path only; the squash-merge path remains
covered by fixtures alone, not by real data.

**Retained, and why (120 entries, nothing touched):**

| Reason | Entries |
|---|---|
| Dirty working tree | 70 worktrees: 42 dirty on `project/logs/events.json` alone (1.96 GB), 28 holding other changes |
| Carries content not in `main` | 49 (28 branches, 21 worktrees), mostly deliberately kept `deploy-*` and `release/*` branches |
| Excluded: primary checkout | 1 |

The 42 `events.json`-only worktrees are retained because the event log is tracked, so removal would
drop any lines that exist only in that copy. Whether `main` already has them was not established.
They are a decision for a person, not something the classifier should widen to claim.

**Measured, not assumed:** the `agent-<hash>` population is 12 entries (about 0.4 GB), not the bulk
of the disk. The bulk was 196 `board-task` and 20 `bundle` worktrees.

**Known defect found by this run:** the reap summary's "disk retained" counts the primary checkout,
which nests `.claude/worktrees`, so it double-counts (it reported 14.6 GB after the run against a
real 4.10 GB). Cosmetic, filed separately.

### Second pass: the 42 `events.json`-only worktrees (2026-11-04)

Removed one at a time with `reap.sh --confirm`, through the guard, after a decision that their
only unsaved content was low-value. Each was re-checked immediately before removal to still be dirty
on `project/logs/events.json` and nothing else.

| | Before | After |
|---|---|---|
| Worktrees | 92 | **50** |
| Branches | 120 | **78** |
| `.claude/worktrees` | 4.10 GB | **2.15 GB** |

All 42 removed, zero skipped, zero refused. All 42 branches were deleted by `git branch -d`, and
every deleted tip is an ancestor of `main`.

**What was deliberately discarded.** 76 of the 77 uncommitted event-log lines in those worktrees
were not in `main`'s log, compared as parsed JSON because the two logs serialise differently (a
literal line match wrongly reports 0 of 42 as present). They were 45 `commit_test_gate`, 10 malformed
fragments (all in `E68_S04_T01`), 8 `advisory_checkpoint`, 5 `session_start`, 4 `sender_received`,
2 `status_set`, 1 `tester_test_fix` and 1 `tester_verdict`. Nothing in the repository reads them: the
only live consumers (`checkin-gate.sh`, `collect-liveness.sh`) look at the current session, and
`commit_test_gate` is write-only. The loss is a gap in the historical audit trail, which is the
shared-log merge problem epic `E75` addresses.

The 28 worktrees holding other changes, and the 49 holding content not in `main`, are untouched.
