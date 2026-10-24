# How finished task work reaches the base branch today (E78_S02_T01)

Internal. Verified 2026-10-20 against `main` at `6566d76f`. This is the written finding that the second
acceptance criterion of `E78_S02` requires before any merge-target code (`E78_S02_T04`) is written.

## Verdict

**No structural merge back exists.** No agent, skill, hook or script contains a command that merges a task
branch into anything on the task-completion path. Nothing in the finding contradicts the E78 design: the
merge-back is **added** by `E78_S02`, not redirected, so `E78_S02_T04` keeps its scope.

## 1. Every place a task branch is merged

Searched: `agents/`, `skills/` (SKILL.md, assets, scripts), `hooks/`, `scripts/`, `settings.json`,
`templates/permission-levels/*.json`, for `git merge`, `cherry-pick`, `rebase`, `--ff-only`, `--no-ff`, and
for prose that tells an agent to merge, land or fold a branch or worktree.

| Place | File:line | Command or instruction | Target branch |
|---|---|---|---|
| Developer prose | `agents/developer.md:111` | "When the work is complete and verified, merge and remove the worktree" | none stated, no command given |
| Reconcile, phase 2 | `skills/j-reconcile/SKILL.md:187` | `git merge <branch>`, only after user confirmation, only for a task whose status says completed but whose implementation cannot be confirmed and whose branch or worktree still exists | the **checked-out branch** of the tree the skill runs in ("the current branch") |
| Reconcile, phase 3 | `skills/j-reconcile/SKILL.md:238` | the opposite: "Do **not** merge the branch/worktree found in check 5 yourself" (in-flight work) | n/a |

That is the complete list. Everything else the search surfaced is not a merge of a task branch:

- `git merge-base --is-ancestor` (`skills/j-do/scripts/bundle-resume.sh:91`, `scripts/mark-deployed.sh:331`,
  `skills/j-mirror-public/scripts/mirror.sh:1505`) only asks an ancestry question.
- `skills/j-commit/SKILL.md:42` ("Skip any worktree merge logic" in inline mode) refers to logic that does not
  exist in the skill's normal mode either; it is a no-op statement, not a merge.
- The board status `Merged` (`templates/SCRUM_BOARD_SCHEMA.md:204`, script-set) means a `/self-sync` file diff
  touched the ticket's files. It is unrelated to a git merge and a task can be `Passed` and unmerged.
- `hooks/on_preflight_check.sh:51` and `:629` only **gate** a `git merge` or `git worktree remove` command when
  the `pre-reconcile` phase marker is active. They do not issue one.
- `skills/j-do/SKILL.md` (lines 192, 616, 719) creates, names and spawns into worktrees but contains no merge
  step; the story bundle's shared `bundle-<E##_S##>` worktree (`:192`) has no merge or removal step on the
  success path either (the only later mention, `:293`, is the `j.break` halt path: "left untouched"). The
  bundle branch reached `main` by hand too (`merge bundle-E73_S01` in the reflog).

## 2. Who merges today, and what happens afterwards

No codified actor merges. In practice the merge is **manual, outside any procedure**: `git reflog show main`
shows a plain `git merge <task-branch>` run with `main` checked out, for example
`merge E78_S01_T04-perceived-branch-bats: Fast-forward`, `merge E78_S01_T02-perceived-branch-script:
Fast-forward`, `merge E75_S01_T02-event-log-merge-strategy: Merge made by the 'ort' strategy` and
`merge bundle-E73_S01: Merge made by the 'ort' strategy`. The ort ones are recorded as `merge: <branch>`
commits (the subject form `skills/j-commit/scripts/commit-subject-check.sh:10` accepts). The reflog does not
record which agent or person ran them (inference: the orchestrating session or the user, since no skill or
agent file issues the command).

| Actor | Merges a task branch? |
|---|---|
| Developer (`agents/developer.md`) | No. One prose sentence (`:111`), no command, no target. It ends the task with a tester call, not a merge. |
| Tester (`agents/tester.md`) | No. Writes status only; the commit guard (`scripts/install-worktree-commit-guard.sh`) exists to stop it committing onto the wrong branch. |
| `j.do` / `j.dooo` | No. They create worktrees and dispatch; no merge step. |
| `j.reconcile` | Only the recovery case above (phase 2), after confirmation, into the checked-out branch. |
| A human or the orchestrating session | Yes, by hand, case by case. |

After the work: the `WorktreeRemove` hook (`settings.json:42`, command `scripts/worktree-remove-guard.sh`)
runs `git worktree remove --force <path>` (`scripts/worktree-remove-guard.sh:189`, `:197`) when no live process
is in the worktree. It removes the checkout only. The **task branch survives** (verified in a scratch repo:
`worktree remove --force` leaves the branch), so an unmerged task branch is exactly what `j.reconcile`
phase 2 later finds. Nothing deletes task branches.

## 3. Start-point of both worktree-creation paths

Both use the implicit start-point, `HEAD` of the **working tree the command runs from**, i.e. the main tree's
checked-out branch in normal use. Neither passes a start-point argument.

| Path | File:line | Command |
|---|---|---|
| `WorktreeCreate` hook (root) | `settings.json:37` | `git worktree add "$DIR" -b "$NAME" 2>&1` |
| the same hook in the 5 templates | `templates/permission-levels/level-1-locked.json:44`, `level-2-guarded.json:37`, `level-3-standard.json:35`, `level-4-elevated.json:33`, `level-5-unrestricted.json:31` | identical command string |
| Manual path in the developer agent | `agents/developer.md:384` | `git worktree add "$DIR" -b "$NAME" 2>&1`, inside the `Hooks` frontmatter example |

Two facts that matter for `E78_S02_T02`/`T03`:

- The "manual" path is not a separate prose instruction: the only `git worktree add` in `agents/developer.md`
  is the YAML example of the hook (`:384`). The agent's prose (`:99`, `:108`) just says "create a worktree".
  So there are two **literal command sites** (the hook, in 6 files, and the example in `developer.md`) and, in
  practice, one behaviour. `j.do`'s full-pipeline fallback (`skills/j-do/SKILL.md:616`) also says only "create
  a worktree named `<E##_S##_T##-short-slug>`".
- The hook receives only `.name` on stdin (`jq -r '.name'`), so any start-point has to be derived inside the
  hook (from `scripts/perceived-branch.sh`), not passed in.

Verified in a scratch repo: with no start-point, the new branch is cut from `HEAD` of the cwd's working tree,
which is the tip of whatever the main tree has checked out (and, if run from inside a linked worktree, that
worktree's tip). The task branch name must also be unused: `-b` fails on an existing branch.

## 4. Merge-target behaviour E78_S02 adds

Scoped narrowly; the existing prose procedure stays the baseline.

| Perceived branch (`scripts/perceived-branch.sh get --perceived`) | Task worktree start-point | Finished task work |
|---|---|---|
| Set and **different** from the checked-out branch | the perceived branch (explicit start-point) | merged into the perceived branch from a **dedicated worktree of that branch**; the main tree is neither moved nor dirtied |
| Set and **equal** to the checked-out branch | unchanged (`HEAD`) | nothing new: existing prose procedure (`agents/developer.md:111`) |
| **Not set** | unchanged (`HEAD`) | nothing new: existing prose procedure |

Why a dedicated worktree is required (verified in a scratch repo): a branch checked out in one tree cannot be
checked out in another (`fatal: '<branch>' is already checked out at ...`), and `git merge` merges into
whatever the current tree has checked out. Merging into the perceived branch from the main tree would
therefore require moving the main tree's checkout; running the merge inside a linked worktree on the perceived
branch merges there and leaves the main tree's branch and `git status` untouched. If the main tree has the
perceived branch checked out, that case is the "equal" row and needs no dedicated worktree.

A conflict follows the existing rule (`agents/developer.md` Conflict Resolution: three attempts, rapport,
`Blocked`, halt). A missing perceived branch at worktree-creation time stops with a message naming it; it does
not fall back to `HEAD` (story acceptance criterion).

Observation, outside this story's scope: `j.reconcile` phase 2's `git merge <branch>` (section 1) targets the
checked-out branch, so under a perceived branch an orphan recovered by reconcile lands on the **real** branch.
`E78_S02` does not change `j.reconcile`; it is recorded here so a later task can decide.

## 5. Seam with E56 (story branches)

`E56` (Pending) plans two-level merging: task work merges into a story branch, and the story branch merges
into `main` once, at story close. It assumes, as this finding confirms, that nothing merges task work back
today. If `E56` lands, the perceived branch becomes the parent that story branches are cut from and merge
into, in place of `main`; the perceived-branch start-point and merge target defined here then apply one level
up. This epic changes nothing about `E56` and adds no story-branch logic: `E78_S02` handles exactly one level,
task worktree to perceived branch.
