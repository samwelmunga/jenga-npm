# Commit traceability reliability contract

**Epic:** `E79` (project-specific commit format for board commits). **Story:** `E79_S01`. **Task:** `E79_S01_T01`.
**Status: DRAFT.** The horizon in section 4 is a proposal. This contract is not final until the user answers
Open Decision 3 (section 7). Nothing here selects a commit-to-task mapping; it defines the bar any mapping must clear.

**Sources.** Solution assessment, Problem 2 ("Reliably traceable undefined; client facts unknown"), Solution A, plus
sections 6B and 6C, in `project/documentation/plans/solution-assessment-project-specific-commit-conventions.md`.
Decisions and current behaviour: `project/documentation/plans/project-specific-commit-conventions.md`. This contract
adds no decision to that plan and does not contradict it; where the plan leaves a question open, this document
leaves it open too.

## 1. Why this exists

Today "a commit is traceable to a task" means "the task id appears in the commit message", and every consumer
searches for it with `git log --grep`. Once an opted-in project stops putting the id in the subject, any proposed
mapping can be argued to be "reliable enough". This contract replaces the adjective with a table of checkable
cells: an operation, a point in the history's life (horizon), a pass/fail criterion and an observable.

## 2. Definitions

- **Trace set `T(id)`.** The commits that carried task `id`'s work, recorded by the test fixture when it builds the
  history (full SHAs plus `git patch-id --stable` for each). SHAs change under rebase, amend and cherry-pick, so
  "the same set" always means equal by patch-id, never equal by SHA. After a squash it means the one squash commit
  whose diff equals the task's net change.
- **Resolver.** Whatever a candidate mapping provides that turns a task id into a commit set (today: each
  consumer's own `git log --grep`; planned: `scripts/commits-for-item.sh <id>`, epic `E79_S02`).
- **Eligible task.** A task whose board status is `Passed`, `Passed with remarks`, or a lifecycle status beyond them
  (`Merged` and later). Only such a task is expected to have commits.
- **Exact.** Zero missed commits and zero extra commits, compared through `T(id)`.
- **Applies to.** The opted-in path. A project that has not opted in keeps today's behaviour byte for byte (epic
  `E79` Definition of Done), including the zero-stat output of `extract-task-diff-stats.sh` lines 45-51.
- **Reachability.** A fresh clone only has the refs a default clone fetches. A commit reachable from no such ref
  (for example a deleted task branch that was never merged) is outside `T(id)` for fresh-clone horizons.

## 3. The five reliability criteria

A mapping may replace the `Jenga-Task: <id>` trailer (the design default in the epic) only if **all five** hold
(solution assessment, Problem 2, Solution A). Failing any one justifies keeping the trailer.

1. **Completeness.** On a fixture matrix covering every operation the client actually performs (rebase, amend,
   cherry-pick, squash, fast-forward, `--no-ff`, mixed EST plus template history), the resolver returns exactly
   `T(id)`: zero missed, zero extra, on 100% of fixtures. Section 5 is this criterion made concrete.
2. **Horizon.** It holds at the longest consumer horizon the user names (section 4), not only the local same-day
   `close-story` case.
3. **Non-invasive.** It needs no change to client git config (no `notes.rewriteRef`, no push refspecs, no fetch
   refspecs) and no extra commits or tracked files the client would not accept.
4. **Concurrency-safe.** Parallel task worktrees cannot corrupt or conflict on it. Observable: two worktrees
   committing at the same time leave `T(id)` exact for both tasks, with no merge conflict in any file the mapping
   owns.
5. **Fail-loud.** A task that is eligible and resolves to zero commits is an error, never zero stats (section 6).

Criteria 1 and 2 are evaluated cell by cell in section 5. Criteria 3, 4 and 5 are cross-cutting gates evaluated once
per candidate; a candidate that passes every cell but fails a gate still fails the contract.

## 4. Proposed horizon (PROPOSAL, pending Open Decision 3)

**Proposed:** `reconcile` run on a fresh clone, 90 days after a client merge. In the matrix this is cell
`O3.H7`; by implication every cell in the `O3` row and the `H1` to `H7` columns up to and including it must hold.

This is a proposal, not a settled requirement. The user has not confirmed it. Two questions travel with it and
are also open (Open Decision 3):

- **A. Horizon.** Is 90 days after a client merge on a fresh clone the right longest horizon, or should it be
  shortened (for example dropping the 90-day column) or lengthened?
- **B. Squash.** What is acceptable behaviour after a squash-merge (`H4`, and `H7` when the client squashes)? The
  strict reading used in the cells below is "exact `T(id)`, i.e. the squash commit". The reduced reading, if the
  user accepts it, is "a loud error naming the cause, never an empty or partial result". Section 6C of the
  assessment notes that this reduced position is the honest one if the client forbids any body content.

Until the user answers, the strict reading stands in the cells marked **(B)** and the horizon stays a proposal.

## 5. The matrix: operations x horizons

### 5.1 Operations (rows)

| Id | Operation | Consumer today | What it must produce |
|----|-----------|----------------|----------------------|
| `O1` | `close-story` per-task diff stats | `skills/j-close-story/scripts/extract-task-diff-stats.sh`, `extract-diff-stats.sh` | `actual_files_changed` and `actual_lines_delta` for the task |
| `O2` | `mark-merged` | `skills/j-self-sync/scripts/mark-merged.sh` (`commits_for_ticket`, `collect_touched_files`) | The set of tasks it marks `Merged`, from the union of files their commits touched |
| `O3` | `reconcile` implementation evidence | `skills/j-reconcile/SKILL.md` section 2 (`git log --all --oneline --grep`) | "Implementation confirmed" or "cannot be confirmed" per eligible task |
| `O4` | `est_provenance` (uncharted-code detection) | `skills/j-reconcile/scripts/detect-unlinked-code.sh` (`est_provenance`) | Board-id attribution per commit, hence which files count as having board provenance |
| `O5` | `redo` lookup | `skills/j-redo/SKILL.md` section 1 | Task or story commit set for a given SHA or epic/story id |

Row `O5` today finds work by SHA, or by epic/story title keyword, not by task id. The contract states the bar a
resolver-backed lookup must meet; how far today's code is from it is the job of the consumer audit
(`project/documentation/commit-consumer-audit.md`, task `E79_S01_T02`) and is not judged here.

### 5.2 Horizons (columns)

| Id | Horizon | How the fixture produces it |
|----|---------|-----------------------------|
| `H1` | Same session | Commits made in this clone minutes earlier; no history rewrite |
| `H2` | After rebase or amend | `git rebase` onto an advanced base, `git rebase -i` reword/squash-fixup, and `git commit --amend`; SHAs change |
| `H3` | After cherry-pick | Task commits cherry-picked (with and without `-x`) onto another branch; the original branch deleted |
| `H4` | After squash-merge | Task branch squash-merged into the target; task branch deleted |
| `H5` | Fresh clone | `git clone` with default config: no notes refs, no extra refspecs, only fetched refs |
| `H6` | Shallow CI clone | `git clone --depth N`; run twice, with N covering the task's commits and with N too small |
| `H7` | 90 days after a client merge | Client merge (method per Open Decision 4) with all dates set 90 days back via `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE`, reflog expired and unreachable objects pruned (`git reflog expire --expire=now --all && git gc --prune=now`), then a fresh clone |

Every cell is also run once against **mixed history** (EST-form commits and template-form commits interleaved),
and once for each of `--no-ff` and fast-forward merges where the horizon involves a merge.

### 5.3 Cell template

Each cell below has the form: **Pass when** (the criterion) and **Observable** (the evidence that proves it). A
cell fails if the observable is absent, differs, or is produced only by an empty or default value. "Exact" is as
defined in section 2.

### 5.4 Row O1: `close-story` per-task diff stats

| Cell | Pass when | Observable |
|------|-----------|------------|
| `O1.H1` | Stats equal the sum over `T(id)` | The two output lines equal the reference `actual_files_changed` and `actual_lines_delta` recorded at fixture build |
| `O1.H2` | Same values as before the rewrite | Both lines byte-identical to the `O1.H1` run on the pre-rebase history |
| `O1.H3` | Same values on the target branch after the pick | Both lines equal the reference computed over the patch-id-equal cherry-picked commits |
| `O1.H4` **(B)** | Stats describe the squash commit (the task's net change) | Both lines equal `git show --shortstat` of the squash commit; non-zero exit with a named reason if the squash commit cannot be tied to the task |
| `O1.H5` | Same values as `O1.H1` | Both lines byte-identical to the original clone's output |
| `O1.H6` | Exact when the depth covers the task; otherwise a loud error | Covering depth: both lines equal the reference. Too-small depth: non-zero exit and a message containing the word `shallow`, with `git rev-parse --is-shallow-repository` printing `true`; never `0` and `0` |
| `O1.H7` | Same values as `O1.H1` | Both lines byte-identical to `O1.H1` after the date shift, reflog expiry and fresh clone |

### 5.5 Row O2: `mark-merged`

| Cell | Pass when | Observable |
|------|-----------|------------|
| `O2.H1` | The task's touched-file union equals the reference union and the task is marked `Merged` | `collect_touched_files <id>` output equals the reference file list; board status becomes `Merged` |
| `O2.H2` | Same union, same outcome | File list identical to `O2.H1`; same task marked |
| `O2.H3` | Same union on the target branch | File list identical to `O2.H1`; same task marked |
| `O2.H4` **(B)** | Union equals the squash commit's file list; the task is marked `Merged` | File list equals `git diff --name-only <squash>~1 <squash>`; a task never silently left unmarked |
| `O2.H5` | Same union, same outcome | File list identical to `O2.H1` |
| `O2.H6` | Exact when the depth covers the task; otherwise a loud error | Covering depth: identical to `O2.H1`. Too-small depth: non-zero exit naming `shallow`; the task is not reported as "no matching commits" |
| `O2.H7` | Same union, same outcome | File list identical to `O2.H1` after the date shift, reflog expiry and fresh clone |

### 5.6 Row O3: `reconcile` implementation evidence

| Cell | Pass when | Observable |
|------|-----------|------------|
| `O3.H1` | Evidence is the exact `T(id)` and the task is confirmed | Reconcile output lists the reference commits (compared by patch-id) and proposes no demotion |
| `O3.H2` | Same evidence after the rewrite | Same commit set by patch-id; no demotion proposed |
| `O3.H3` | Same evidence on the target branch | Same commit set by patch-id; no demotion proposed |
| `O3.H4` **(B)** | Evidence is the squash commit; task confirmed | Reconcile lists the squash commit; no demotion proposed. A demotion of an implemented task to `Pending` is a failure |
| `O3.H5` | Same evidence on a fresh clone | Same commit set by patch-id; no demotion proposed |
| `O3.H6` | Exact when the depth covers the task; otherwise a loud error | Covering depth: as `O3.H1`. Too-small depth: reconcile reports "cannot verify (shallow)" and writes no status change; never demotes |
| `O3.H7` **(proposed horizon, pending Open Decision 3)** | Same evidence 90 days after a client merge on a fresh clone | Same commit set by patch-id as `O3.H1`; no demotion proposed; run with dates shifted back 90 days, reflog expired and objects pruned |

### 5.7 Row O4: `est_provenance`

| Cell | Pass when | Observable |
|------|-----------|------------|
| `O4.H1` | Every commit in `T(id)` is attributed to `id`; no commit outside it is | Per-commit provenance output maps each reference commit to `id`; zero commits mapped to another id |
| `O4.H2` | Same attribution | Attribution table identical to `O4.H1` by patch-id |
| `O4.H3` | Same attribution on the target branch | Attribution table identical to `O4.H1` by patch-id |
| `O4.H4` **(B)** | The squash commit is attributed to `id` | The squash commit maps to `id`; its files are absent from the "no board provenance" list |
| `O4.H5` | Same attribution on a fresh clone | Attribution table identical to `O4.H1` |
| `O4.H6` | Exact within the depth; commits beyond it are reported unattributable, not uncharted | Commits inside the depth map to `id`. Files whose commits are cut off are reported as "history unavailable (shallow)", not as uncharted code |
| `O4.H7` | Same attribution 90 days after a client merge | Attribution table identical to `O4.H1`; zero board files flagged as uncharted code |

### 5.8 Row O5: `redo` lookup

| Cell | Pass when | Observable |
|------|-----------|------------|
| `O5.H1` | From any SHA in `T(id)` the lookup names `id`; from `id`, its story or its epic it returns the exact union of its tasks' sets | Reverse lookup of each reference SHA returns `id`; forward lookup equals the reference union |
| `O5.H2` | Same answers by patch-id | Forward and reverse results equal `O5.H1` by patch-id |
| `O5.H3` | Same answers on the target branch | Forward and reverse results equal `O5.H1` by patch-id |
| `O5.H4` **(B)** | The squash commit names `id`; the forward lookup returns the squash commit | Reverse lookup of the squash SHA returns `id`; forward lookup equals the squash commit |
| `O5.H5` | Same answers on a fresh clone | Forward and reverse results equal `O5.H1` |
| `O5.H6` | Exact within the depth; otherwise a loud error | Forward lookup equal to `O5.H1` when the depth covers it; non-zero exit naming `shallow` otherwise; never an empty list |
| `O5.H7` | Same answers 90 days after a client merge | Forward and reverse results equal `O5.H1` after the date shift, reflog expiry and fresh clone |

## 6. Fail-loud rule: an empty result for an eligible task is an error

**An eligible task (`Passed`, `Passed with remarks`, or beyond) that resolves to zero commits is a contract
violation. The consumer reports it as an error, not as "no commits".**

- **Observable.** Non-zero exit status and a message that names the task id and the horizon or condition
  (for example `shallow clone`, `no commit carries this task`). It never prints zero stats, an empty list, a
  silent skip, or a status demotion derived from the empty result.
- **Why.** Today `extract-task-diff-stats.sh` prints `actual_files_changed: 0` and `actual_lines_delta: 0` with
  exit 0 when nothing matches (lines 45-51), and `mark-merged.sh` treats empty output as "zero matched commits".
  An id-free message turns every such lookup into that silent success, so lifecycle statuses go stale unnoticed
  (plan: "Silent-empty failures (High)").
- **Scope.** The rule applies to the opted-in path. A task that is not eligible (for example `Pending`) may
  legitimately have zero commits and is not an error.
- **Shallow clones.** A zero result in a shallow clone is reported as "history unavailable", which is also an
  error for an eligible task, but with a different message from "no commit carries this task".

This is reliability criterion 5 (section 3). The planned mechanism is a `--require-nonempty` flag on the shared
resolver (`E79_S02`), turned on for `close-story` and `mark-merged` in the opted-in path (`E79_S06`); this contract
defines the bar, not that mechanism. The resolver exists as `scripts/commits-for-item.sh` (task `E79_S02_T01`): empty
exits 1, empty in a shallow clone exits 3 with a `shallow` message, and its mapping onto the consumers is in
`project/documentation/commit-consumer-audit.md` section 13.

## 7. Open decisions this contract touches

None of these is answered. They are recorded, not decided.

| Decision (epic `E79` numbering) | Question | State |
|---------------------------------|----------|-------|
| 3 | Longest horizon (proposed: `reconcile` on a fresh clone 90 days after a client merge) and acceptable behaviour after a squash-merge. Includes the assessment's 6B item 4: accept the five criteria in section 3, or amend them (for example drop the 90-day horizon). | **Open.** Contract stays DRAFT until answered. To be answered by the user, with evidence from `E79_S01` |
| 4 | Client facts: merge method (decides which of `H4`/`H7` merge variants apply), squash-body behaviour, commitlint rules for body and footers, whether hooks run in task worktrees. | **Open.** Recorded in `project/documentation/commit-client-fact-sheet.md` (task `E79_S01_T03`) |
| 6 | Do `chore(board)`, roll-up, merge, `chore(self-sync)` and mirror commits keep their Jenga forms or inherit the ref? Decides whether those commits belong in `T(id)` at all. | **Open.** Evidence from the consumer audit |
| 1, 2, 10 | Whether the trailer is the sanctioned design; whether it is the durable default; whether Decision 2 of `E69` is reversed only for opted-in projects. | **Open.** They gate `E79_S03` to `E79_S06`, not this document |

When Decision 3 is answered, the follow-up edit to this file is: replace section 4 with the answer, remove the
**(B)** markers or replace the strict squash reading with the accepted one, and change the status line from DRAFT to
FINAL.

## 8. How the contract is used

1. `E79_S02` builds the differential and history-rewrite fixtures for sections 5.2 and 5.4 to 5.8, and the shared
   resolver (`scripts/commits-for-item.sh`, shipped by `E79_S02_T01`).
2. Each candidate mapping from the assessment (trailer, ledger, git notes, topology, external key) is scored against
   every cell and the three gates. The result is recorded per candidate.
3. A candidate other than the trailer is adopted only if it passes everything inside the accepted horizon.
4. A claim of the form "reliably traceable" anywhere in the epic means "passes this table", not an adjective.
