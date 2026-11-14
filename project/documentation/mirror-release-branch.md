# /mirror-public release branches

Story `E28_S20`. A real `/mirror-public` run no longer mirrors whatever is on `main`. It builds a dedicated release branch
from the last shipped state, lets the maintainer choose which of the commits made since then go into it, and runs the
unchanged `mirror.sh` from that branch. The skill-facing flow is in `skills/j-mirror-public/SKILL.md` ("Release branch");
the mechanics are in `skills/j-mirror-public/scripts/release-prep.sh`. This page records why it works the way it does.

## Why a branch

`mirror.sh` rsyncs the **working tree** of the checked-out branch. It has no notion of commits, so choosing commits only
has an effect if the working tree is built from the choice. A release branch does that: branch from the private commit
that was last shipped, cherry-pick only the chosen commits onto it, mirror from there. `mirror.sh`, its invariants, the
staging branch and the CI gate are untouched.

## Finding the baseline

1. List the public repo's tags and keep `vX.Y.Z` and `vX.Y.Z-stage`. The highest version by numeric comparison wins; a
   final tag and a `-stage` tag of the same version are the same release, so either is a valid baseline. Counting
   `-stage` tags means a staged but not yet final release is not offered again.
2. Fetch that tag into the existing scratch clone (`config.json` `worktreePath`); no second clone is made.
3. Walk first-parent history back from the tag's commit to the nearest commit whose message has a
   `Source-Commit: <40-hex>` trailer, the squash commit `mirror.sh` writes. That SHA is the **private base**.
4. Suggested next version: the tag's patch bump with any `-stage` removed (`v4.3.0-stage` gives `v4.3.1`).

Fallbacks: no tags (or no trailer behind the tag) uses the newest trailer on the public default branch; no trailer
anywhere means a first release, the base is empty and every commit on `main` is a candidate. A base SHA that is not in the
local repo stops the run: fetch it, or restore the release branch it came from.

## Choosing commits

`release-prep.sh candidates --base <sha>` runs `git cherry <base> main` and keeps the `+` lines, oldest first, merge
commits excluded. `git cherry` compares **patch ids**, which matters because a later baseline is a release-branch tip,
not a `main` commit. A commit that an earlier release cherry-picked (new SHA, same patch) is therefore not offered again,
while one that was listed and left unselected is.

The user answers with `all`, numbers, comma lists or ranges (`2,5-7`); `parse-selection` / `select` validate that in
code. `all` branches from `main` HEAD with no cherry-picking. Anything else branches from the base and cherry-picks the
selection in order. A conflict aborts the pick, names the commit, leaves the branch checked out and clean, and exits
non-zero before any mirror step runs; there is no auto-resolution.

The branch is `release/<next-version>-<YYYYMMDD>` (`release-prep.sh name`), for example `release/v4.3.1-20261021`. It
refuses a dirty tree (untracked files count, since the mirror ships the working tree), an existing branch of that name
and a missing base, each before changing anything. Nothing here pushes or deletes a branch. (In worktree mode, below,
the main tree may be dirty: the branch is built in a fresh worktree, which is what the mirror ships.)

## Consequences

- **`Source-Commit:` names the release-branch tip.** The trailer on the squash commit is the SHA `mirror.sh` ran from,
  which is on the release branch and not on `main`. That is why candidates use patch ids, and why **release branches must
  be kept**: each is the baseline of the next run. Deleting one makes the next `baseline` stop on a missing SHA.
- **Auto-reconcile lands on the release branch.** The version-only auto-reconcile commit (see "Version-only
  auto-reconciliation" in the skill) is made on the current branch, now the release branch, so it is not on `main`.
  **Decision: leave it there; the skill does not cherry-pick it back to `main`.** The next release's baseline carries it
  either way, committing on `main` as a side effect of a mirror run was not asked for, and the worst case is that a later
  `--here` or `all` run re-reconciles the same version once. The run summary prints the commit SHA if the maintainer wants
  to `git cherry-pick` it onto `main` by hand.
- **Board-only commits show up in the list.** Many `main` commits touch only the board; there is no path filter. A filter
  is a possible follow-up if the list proves too noisy.

## deploy-public: the release branch in a worktree (`E88_S06`)

The `/mirror-public` flow above switches the main checkout to the release branch, and that is unchanged. The private
`deploy-public` workflow used to do the same, which once left the maintainer's real checkout on
`release/<version>-<date>` with ongoing work continuing there by mistake. It now builds the branch **without moving the
main checkout**:

- **Worktree mode of `release-prep.sh branch`.** `branch ... --worktree <path>` creates the branch and checks it out in a
  new git worktree (`git worktree add -b`), and runs every cherry-pick there. The main tree's `HEAD`, index and files
  never change, so it may be dirty; the clean-tree check applies to the fresh worktree instead. It refuses an existing
  `<path>` before any mutation, and on a conflict leaves the worktree on the new branch with the picks applied so far
  and a clean tree, printing the path and both recovery routes (resolve by hand there, or
  `git worktree remove <path>` plus `git branch -D <name>` and re-run). Success adds a `worktree=<path>` line. The
  caller chooses the path: `deploy-public` uses `.claude/worktrees/<branch with / turned into ->`, gitignored and
  deterministic.
- **Why the worktree, not just "do not switch".** `mirror.sh` mirrors the branch checked out in the repo its own file
  lives in. Dropping the switch alone would make the preview and the mirror ship `main` `HEAD`. So `preview` and
  `mirror` run the **worktree's** `mirror.sh` through `mirror-from-worktree.sh`, which refuses a missing worktree or one
  on another branch, and points the scratch clone at the main tree's `.mirror-worktrees/public` so no second clone of
  the public repo is made inside the worktree. That is the release branch's own `mirror.sh` and `.publicignore`, the
  same ones the switch-based flow ran, and the squash commit's `Source-Commit:` trailer still names the release-branch
  tip.
- **The perceived branch.** `create_branch` records the release branch as the session's perceived branch
  (`scripts/perceived-branch.sh set`, what `j.checkout` does) after reading the previous one. It is a session
  convenience, not the guarantee of what ships (the worktree is), so a missing session key is reported and never
  fails the run. While it is set, task worktrees created in the same session start from the release branch.
- **`finish` no longer switches back to `main`.** It restores the previous perceived branch (or clears it when none was
  set), only while the perceived branch still points at the release branch, removes the release worktree through
  `scripts/worktree-remove-guard.sh` (leaving it in place, with the reason, when a process is still inside it or it has
  uncommitted changes) and keeps the release branch, which stays the next run's baseline.

One consequence to know: the version-only auto-reconcile commit, and the Publicized-status writes a real mirror run
makes, now land in the release worktree (its branch and its files), not in the main tree. The commit is on the release
branch exactly as before. Uncommitted status writes make the worktree dirty, so `finish` then leaves it in place and
lists the changed paths instead of removing it.

## Unchanged and escape hatch

`--dry-run`, `--inventory` and `--exclude <path>` never create a branch and behave exactly as before. `--here` skips the
release-branch steps and mirrors the current branch as it did before this story; it is for recovery and for the existing
mirror tests. `mirror.sh` accepts `--here` as a no-op so one argument list works through the skill.

## Rehearsal

Everything is testable against a local bare remote: set `MIRROR_PUBLIC_URL_OVERRIDE` and `MIRROR_WORKTREE_PATH_OVERRIDE`
(and `RELEASE_PREP_REPO` to point at a throwaway private repo). `tests/mirror-release-prep.bats` does exactly that and
never touches the real `jenga-npm`. The worktree-based `deploy-public` path is covered by
`tests/deploy-public-prep-worktree.bats` and, end to end against a clone and a local bare remote, by
`tests/deploy-public-worktree-e2e.bats`.
