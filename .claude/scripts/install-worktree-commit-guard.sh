#!/usr/bin/env bash
# scripts/install-worktree-commit-guard.sh — install a branch-guard pre-commit
# hook into a given git worktree.
#
# Usage:
#   scripts/install-worktree-commit-guard.sh <worktree-path> <branch-name>
#
# Writes a `pre-commit` hook that rejects any commit attempted while HEAD is
# on a branch other than <branch-name>. This exists because a tester once
# committed its verification of a task to `main` instead of the branch it was
# actually verifying, from inside the worktree created for that task —
# nothing mechanically prevented it (see E37's Purpose / E37_S02). Written
# rules alone have a documented track record of drifting in this project
# (E17 rollup note: two of its own stories were marked complete without the
# underlying change landing), so this is a real guard, not just a documented
# rule.
#
# IMPORTANT — why this does NOT just write to `git rev-parse --git-path
# hooks`: that path resolves to the *shared* `hooks` directory common to the
# main repository and every one of its linked worktrees (verified against
# git 2.39: `git -C <any-worktree> rev-parse --git-path hooks` returns the
# same common path for every worktree of the same repo, including the main
# one). A naive install there would mean each new worktree's guard silently
# clobbers every other worktree's guard (only the most-recently-created
# worktree's branch would ever be accepted), and every *other* worktree would
# then have its commits blocked outright, since the current branch would
# never match the last-installed expected branch. That is worse than doing
# nothing: it defeats the isolation this task exists to provide.
#
# The actual fix is git's per-worktree config file
# (`$GIT_DIR/worktrees/<name>/config.worktree`, gated behind the
# `extensions.worktreeConfig` repo extension) combined with the `core.hooksPath`
# setting, which git DOES resolve per-worktree when scoped that way. This
# script:
#   1. enables `extensions.worktreeConfig` on the repo if not already set
#      (idempotent, additive, does not disturb any existing config value —
#      it only enables the *possibility* of per-worktree config overrides)
#   2. resolves this worktree's own private git-dir via
#      `git -C <worktree-path> rev-parse --absolute-git-dir` (this IS
#      genuinely private per worktree — `.git/worktrees/<name>` for a linked
#      worktree, verified distinct per worktree in the same test)
#   3. points `core.hooksPath`, set with `git config --worktree` (so it lands
#      in that worktree's own config.worktree file, not the shared config),
#      at a private `hooks-guard` directory under that private git-dir
#   4. writes the branch-guard `pre-commit` hook there
#
# This was manually verified end-to-end against a scratch repo with two
# worktrees: installing the guard for worktree A blocked wrong-branch commits
# in A and had zero effect on worktree B or the main repo, both of which kept
# using the shared default hooks directory untouched.
#
# This script is intended to be called automatically at the end of the
# `WorktreeCreate` hook in the canonical root `settings.json`, immediately
# after `git worktree add "$DIR" -b "$NAME"` — see that file for the wiring.
# It can also be run manually against any existing worktree, and is safe to
# re-run against the same worktree (idempotent — simply overwrites the hook).
#
# Exit codes:
#   0   hook installed successfully
#   1   invalid usage (wrong argument count)
#   2   <worktree-path> is not a valid git working tree

set -u

usage() {
  echo "Usage: $0 <worktree-path> <branch-name>" >&2
  exit 1
}

[ "$#" -eq 2 ] || usage
WORKTREE_PATH="$1"
BRANCH_NAME="$2"

[ -n "$WORKTREE_PATH" ] || usage
[ -n "$BRANCH_NAME" ] || usage

if ! git -C "$WORKTREE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "install-worktree-commit-guard: '$WORKTREE_PATH' is not a valid git working tree" >&2
  exit 2
fi

# Enable per-worktree config overrides on the repo, if not already enabled.
# This is a one-time, repo-wide, additive flag — it does not move or change
# any existing config value, it only makes `git config --worktree` (used
# below) actually take effect instead of silently writing to a file git
# never reads.
if [ "$(git -C "$WORKTREE_PATH" config --get extensions.worktreeConfig 2>/dev/null)" != "true" ]; then
  git -C "$WORKTREE_PATH" config extensions.worktreeConfig true
fi

# This worktree's own private git-dir. For a linked worktree this resolves to
# `.git/worktrees/<name>` (private to this worktree); for the main working
# tree it resolves to the common `.git` dir itself. Either way it is safe to
# scope a private hooks directory under it.
PRIVATE_GIT_DIR="$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir)"

# A distinctly-named directory (not the default `hooks`) so this never
# collides with, or gets confused for, whatever the shared default hooks
# directory may already contain.
HOOKS_DIR="$PRIVATE_GIT_DIR/hooks-guard"
mkdir -p "$HOOKS_DIR"

# Scope the override to THIS worktree only, via its private config.worktree
# file — not the shared/common config, which would affect every worktree.
git -C "$WORKTREE_PATH" config --worktree core.hooksPath "$HOOKS_DIR"

HOOK_FILE="$HOOKS_DIR/pre-commit"

# The expected branch name is baked into the generated hook as a literal
# comparison value (it is fixed at install time — the branch this worktree
# was created for). The *actual* branch is always re-checked live, at commit
# time, via `git rev-parse --abbrev-ref HEAD`.
cat > "$HOOK_FILE" <<EOF
#!/usr/bin/env bash
# Installed by scripts/install-worktree-commit-guard.sh — do not edit by hand.
# Rejects any commit made while this worktree is not checked out on its
# assigned branch: '$BRANCH_NAME'.
set -u

expected_branch="$BRANCH_NAME"
current_branch="\$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

if [ "\$current_branch" != "\$expected_branch" ]; then
  echo "pre-commit: commit blocked — this worktree is assigned to branch '\$expected_branch' but HEAD is currently on '\$current_branch'." >&2
  echo "pre-commit: verification/implementation commits for this worktree must land on '\$expected_branch', never on any other branch (including main)." >&2
  exit 1
fi

exit 0
EOF

chmod +x "$HOOK_FILE"

echo "install-worktree-commit-guard: installed branch guard for '$BRANCH_NAME' at $HOOK_FILE (core.hooksPath scoped to this worktree only)"
