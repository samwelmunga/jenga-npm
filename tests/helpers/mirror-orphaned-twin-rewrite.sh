#!/usr/bin/env bash
#
# Test harness for mirror.sh's rewrite_orphaned_twin_names (E50_S07_T07).
#
# skills/mirror-public/scripts/mirror.sh cannot be sourced: it is a top-to-bottom
# release script that clones the public repo, rsyncs, commits and pushes as a
# side effect of being read. That untestability is precisely why the E28_S11
# regression this function exists to prevent went live again -- silently, and for
# 34 skills. See:
#   project/rapports/problems/E50_S07_T06-mirror-orphaned-twin-rewrite-dead-code.md
#
# So rather than copy the function into the test suite -- where the copy would
# drift away from the real code and assert nothing about what actually ships --
# this harness extracts the *real* function body out of the *real* mirror.sh by
# source range, evaluates it against a stub `log` and a caller-supplied
# WORKTREE_PATH, and runs it. Every assertion in
# tests/mirror-orphaned-twin-rewrite.bats is therefore made against the shipping
# implementation.
#
# The extraction contract is: the function opens with a line reading exactly
# `rewrite_orphaned_twin_names() {` at column 0 and closes with a `}` at column 0.
# That contract is checked below and exits 90 if it ever stops holding, so a
# refactor of mirror.sh produces a loud harness failure rather than a suite that
# silently tests nothing -- which is the exact fail-open shape of the defect
# under test.
#
# Usage: mirror-orphaned-twin-rewrite.sh <path-to-mirror.sh> <scratch-worktree-path>

set -euo pipefail

MIRROR_SH="${1:?usage: mirror-orphaned-twin-rewrite.sh <mirror.sh> <worktree>}"
WORKTREE_PATH="${2:?usage: mirror-orphaned-twin-rewrite.sh <mirror.sh> <worktree>}"
export WORKTREE_PATH

# Stubbed to match mirror.sh's own log() exactly, so log-line assertions read
# against the real output format.
log() {
  printf 'mirror.sh: %s\n' "$*"
}

fn_body="$(awk '/^rewrite_orphaned_twin_names\(\) \{$/,/^\}$/' "$MIRROR_SH")"

case "$fn_body" in
  *'rewrite_orphaned_twin_names() {'*) ;;
  *)
    printf 'harness: could not extract rewrite_orphaned_twin_names() from %s\n' "$MIRROR_SH" >&2
    printf 'harness: extraction contract broken (opening line and closing } must both sit at column 0)\n' >&2
    exit 90
    ;;
esac

eval "$fn_body"

rewrite_orphaned_twin_names
