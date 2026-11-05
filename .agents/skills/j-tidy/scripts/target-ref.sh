#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-tidy/scripts/target-ref.sh - THE SINGLE TARGET-REF SEAM for j.tidy (E56_S06_T01)
#
# One question, one answer, one place: "what ref should this entry's work have reached?"
#
# Every comparison in this skill - ahead counts, content diffs, branch-only assessment - resolves its
# target through this file and nowhere else. The literal string "main" must not appear in any other
# j-tidy script. That is a hard contract, not a style preference: E56_S06's story file requires the
# resolution to be a single seam so that E56_S01 (story-level branch isolation) can retarget task
# worktrees onto their story branch by editing THIS FILE ONLY.
#
# ---------------------------------------------------------------------------
# WHY EVERYTHING TARGETS main TODAY
# ---------------------------------------------------------------------------
# E56's eventual model is two-level: a task worktree's work should reach its STORY branch, and a
# story branch's work should reach main. E56_S01 has not been built, so that model does not exist
# yet. E56_S06's story file ("Dependency relaxed", 2026-11-04) therefore relaxed the dependency and
# settled on main for every population in the interim.
#
# That is the CONSERVATIVE direction, which is why it is safe to ship ahead of E56_S01:
#   - work sitting on an unmerged task branch is not in main, so it classifies as `retained`,
#     never as reclaimable;
#   - the `agent-<hash>` population (the bulk of the measured 9.5 GB) has no board provenance and
#     targets main regardless, so it needs no story-branch model at all.
#
# WHEN E56_S01 LANDS: give `board-task` (and, if story branches get their own worktrees, `bundle`)
# a resolution that returns the entry's story branch, falling back to main when that branch does
# not exist. Nothing else in this skill needs to change.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
# Executed (one entry, prints the ref on stdout):
#   target-ref.sh <population> [<name>]
#   target-ref.sh --default                print the fallback target ref
#   target-ref.sh -h | --help              print this usage, exit 0
#
#     <population>  board-task | bundle | agent | other
#     <name>        the entry's branch or directory name (unused today; passed so the signature
#                   does not have to change when E56_S01 needs it)
#
# Sourced (the form j-tidy's own scripts use, so no subprocess per entry):
#   . target-ref.sh          # prints nothing, creates nothing
#   tidy_target_ref <population> [<name>]
#
# Exit codes: 0 ok, 2 usage error (unknown population, wrong argument count).
# ---------------------------------------------------------------------------

# The one place the default target ref is written down.
TIDY_DEFAULT_TARGET_REF="main"

# tidy_target_ref <population> [<name>] - print the ref this entry's work should have reached.
tidy_target_ref() {
  local population="${1:-}"
  # shellcheck disable=SC2034  # reserved for E56_S01's story-branch resolution; see header.
  local name="${2:-}"

  case "$population" in
    board-task|bundle|agent|other)
      # E56_S01 wires the two-level model in here, per population. Until then: main for all.
      printf '%s\n' "$TIDY_DEFAULT_TARGET_REF"
      ;;
    *)
      printf 'target-ref.sh: unknown population %s (expected board-task, bundle, agent or other)\n' \
        "${population:-(empty)}" >&2
      return 2
      ;;
  esac
}

# Executed form only. `return` succeeds in a sourced file and fails in an executed one, which is the
# portable bash 3.2 way to tell the two apart without BASH_SOURCE games.
if ! (return 0 2>/dev/null); then
  case "${1:-}" in
    -h|--help|help)
      sed -n '2,/^# ----*$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --default)
      printf '%s\n' "$TIDY_DEFAULT_TARGET_REF"
      exit 0
      ;;
    "")
      printf 'target-ref.sh: usage: target-ref.sh <population> [<name>] | --default\n' >&2
      exit 2
      ;;
  esac
  tidy_target_ref "$1" "${2:-}"
  exit $?
fi
