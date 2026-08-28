#!/usr/bin/env bash
# scripts/worktree-remove-guard.sh — hard-block-by-default liveness
# precondition for `git worktree remove`, wired into the `WorktreeRemove`
# hook in (root, canonical) settings.json.
#
# Why this exists: see project/board/epics/E37_inter-agent-completion-signaling.md
# and project/board/stories/E37_S03_worktree-remove-liveness-precondition.md.
# `git worktree remove --force` previously ran unconditionally as soon as
# the WorktreeRemove hook fired, with no precondition of any kind — this is
# how a 2026-08-25 incident's orphaned shell polling loops got their cwd
# deleted out from under them. This script now runs
# scripts/check-worktree-liveness.sh (E37_S03_T01) first, and only proceeds
# to `git worktree remove --force` if that check reports the path clear (or
# an explicit override is set).
#
# Invocation modes:
#
#   1. Hook mode (no positional worktree-path argument): reads a JSON
#      payload from stdin and extracts `.worktree_path` (required) and an
#      optional `.force_ignore_liveness` boolean field. This is how the
#      WorktreeRemove hook actually invokes this script — matching the
#      pre-existing `jq -r '.worktree_path'` convention this script
#      replaces. Note: the native harness's WorktreeRemove hook JSON
#      schema is outside this repo's control (its `ExitWorktree` tool
#      exposes only `action`/`discard_changes`, no pass-through custom
#      field), so `.force_ignore_liveness` on the payload is supported for
#      any caller that *does* control the JSON directly (e.g. a script
#      invoking this guard outside the native tool), but is not the primary
#      override mechanism for the native hook path — see the environment
#      variable below for that.
#
#   2. CLI mode (direct/manual invocation — used for this script's own
#      testing and any other scripted use outside the hook):
#        scripts/worktree-remove-guard.sh [--force-ignore-liveness] <worktree-path>
#
# Override (works in both modes): set the environment variable
#   WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS=1
# immediately before invoking this script (directly, or before whatever
# triggers the WorktreeRemove hook). Accepted truthy values: 1, true, TRUE,
# True, yes, YES. This is the one lever guaranteed to work regardless of
# invocation mode or what JSON the calling harness does or doesn't pass
# through. It must be set explicitly on each invocation — it is never read
# from a file, never cached, and never a default; every invocation re-reads
# the environment fresh.
#
# Decision logic:
#   - If an override is set (CLI flag, JSON field, or env var): skip the
#     liveness check, print a visible bypass notice to stderr, and run
#     `git worktree remove --force <path>`.
#   - Otherwise, run scripts/check-worktree-liveness.sh <path>. ANY non-zero
#     exit blocks removal by default — not just exit 1 ("live process
#     found"), but also exit 2/3/4 (usage error / invalid path / liveness
#     indeterminate), since none of those represent "the path is
#     affirmatively clear," consistent with that script's own fail-closed
#     design. `git worktree remove` is never invoked in this branch. The
#     liveness check's own PID/command output (or error message) is
#     surfaced to the caller, plus a note on how to override.
#   - On a clear (exit 0) result: proceed to `git worktree remove --force
#     <path>` exactly as the old unconditional one-liner did, with no extra
#     output — the "clear worktree" case must behave exactly as before,
#     with no added friction.
#
# Exit codes:
#   *   whatever `git worktree remove --force <path>` itself exits with, if
#       removal proceeded (clear path, or override set)
#   1   blocked — liveness check reported non-zero and no override was set;
#       git worktree remove was NOT run
#   2   usage error — no worktree path resolvable from CLI args or stdin
#       JSON, or an unrecognized flag

set -u

SCRIPT_NAME="worktree-remove-guard.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
LIVENESS_SCRIPT="$SCRIPT_DIR/check-worktree-liveness.sh"

# Resolve a safe anchor directory to relocate this process's own cwd into
# further below (see the "Caller-cwd self-detection hardening" block after
# argument parsing) — the main repository's working-tree root, derived from
# the shared git common dir so it resolves correctly regardless of which
# worktree this script's own cwd currently happens to be in. Must be
# computed now, from the ORIGINAL cwd, since `git rev-parse` depends on
# being inside a git working tree.
GIT_COMMON_DIR_RAW="$(git rev-parse --git-common-dir 2>/dev/null)"
SAFE_ANCHOR=""
if [ -n "$GIT_COMMON_DIR_RAW" ]; then
  SAFE_ANCHOR="$(cd "$(dirname "$GIT_COMMON_DIR_RAW")" >/dev/null 2>&1 && pwd -P)"
fi

FORCE_OVERRIDE=0
WORKTREE_PATH=""

# --- Parse CLI-style args, if any. ---
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force-ignore-liveness)
      FORCE_OVERRIDE=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "$SCRIPT_NAME: unknown flag '$1'" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done
if [ "$#" -ge 1 ]; then
  WORKTREE_PATH="$1"
fi

# --- Hook mode: no positional worktree path given, so read the JSON
#     payload the WorktreeRemove hook receives on stdin. ---
if [ -z "$WORKTREE_PATH" ]; then
  if [ -t 0 ]; then
    echo "$SCRIPT_NAME: no worktree path given (expected a positional argument, or JSON on stdin with a 'worktree_path' field)" >&2
    exit 2
  fi
  PAYLOAD="$(cat)"
  WORKTREE_PATH="$(printf '%s' "$PAYLOAD" | jq -r '.worktree_path // empty' 2>/dev/null)"
  if [ "$FORCE_OVERRIDE" -eq 0 ]; then
    PAYLOAD_OVERRIDE="$(printf '%s' "$PAYLOAD" | jq -r 'if .force_ignore_liveness == true then "true" else "false" end' 2>/dev/null)"
    [ "$PAYLOAD_OVERRIDE" = "true" ] && FORCE_OVERRIDE=1
  fi
fi

if [ -z "$WORKTREE_PATH" ]; then
  echo "$SCRIPT_NAME: no worktree path provided (expected a positional argument, or a 'worktree_path' field on stdin JSON)" >&2
  exit 2
fi

# Resolve WORKTREE_PATH to an absolute, symlink-resolved path NOW, while
# still in the original cwd — we're about to relocate this process's own
# cwd away (hardening below), and a relative path would no longer resolve
# correctly against the caller's original cwd afterward. (In practice the
# hook always supplies an absolute path — see WorktreeCreate's own
# `DIR="$JENGA_PROJECT_DIR/.claude/worktrees/$NAME"` construction — this
# also makes relative paths work correctly for CLI-mode/manual use.) If
# resolution fails (path does not exist), fall through with the original,
# unresolved string; check-worktree-liveness.sh and/or `git worktree
# remove` will report the appropriate error themselves.
WORKTREE_PATH_RESOLVED="$(cd "$WORKTREE_PATH" 2>/dev/null && pwd -P)"
[ -n "$WORKTREE_PATH_RESOLVED" ] && WORKTREE_PATH="$WORKTREE_PATH_RESOLVED"

# --- Environment override — checked last so it can force the bypass
#     regardless of how the path was supplied. ---
case "${WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS:-}" in
  1|true|TRUE|True|yes|YES)
    FORCE_OVERRIDE=1
    ;;
esac

# Caller-cwd self-detection hardening (this script's own layer of it — see
# the matching comment block in check-worktree-liveness.sh for the
# underlying check script's own layer, which protects only its own spawned
# subprocesses). THIS script is what actually invokes that check below —
# if this script's own process was itself launched with a cwd already
# inside the worktree being removed (a real, expected scenario: the
# WorktreeRemove hook may fire from a session whose cwd is inside the
# worktree about to be removed, right before cleanup), this script's own
# PID would itself be "a live process rooted in" that path at the moment
# the check runs — check-worktree-liveness.sh's $$-exclusion only ever
# covers its own PID, not its caller's. Relocating to the main repo root
# (resolved above, before WORKTREE_PATH is used any further) — rather than
# to `/` — means both the liveness check AND the eventual `git worktree
# remove` below keep working normally (git needs to run from inside some
# working tree), while still guaranteeing neither this script's own process
# nor the check script it spawns as a child can be cwd'd inside the target,
# regardless of what cwd the original caller had. Falls back to `/` only if
# the repo-root anchor could not be resolved (a degenerate case; `git
# worktree remove` itself will then fail with its own clear error).
# (Residual, out-of-our-control limitation: if some ancestor further up the
# process chain — e.g. the harness's own hook-runner shell, if it stays
# resident rather than exec'ing straight into this script — independently
# keeps its own cwd inside the target and stays alive while waiting on this
# script, that ancestor is a separate process this script cannot
# retroactively relocate; the courtesy $$-style exclusion pattern used
# throughout these two scripts only ever covers processes each script
# itself controls.)
cd "${SAFE_ANCHOR:-/}" 2>/dev/null || true

if [ "$FORCE_OVERRIDE" -eq 1 ]; then
  echo "$SCRIPT_NAME: liveness check explicitly bypassed (--force-ignore-liveness / WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS) for '$WORKTREE_PATH' — proceeding to remove without checking for live processes." >&2
  git worktree remove --force "$WORKTREE_PATH"
  exit $?
fi

LIVENESS_OUTPUT="$("$LIVENESS_SCRIPT" "$WORKTREE_PATH" 2>&1)"
LIVENESS_EXIT=$?

if [ "$LIVENESS_EXIT" -eq 0 ]; then
  git worktree remove --force "$WORKTREE_PATH"
  exit $?
fi

echo "$SCRIPT_NAME: BLOCKED — not removing '$WORKTREE_PATH' (liveness check exited $LIVENESS_EXIT):" >&2
[ -n "$LIVENESS_OUTPUT" ] && echo "$LIVENESS_OUTPUT" >&2
echo "$SCRIPT_NAME: git worktree remove was NOT run. If this is expected (e.g. a known, accepted background process), re-run with an explicit override: pass --force-ignore-liveness (CLI mode), a true 'force_ignore_liveness' field on the input JSON (hook mode), or set WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS=1 in the environment (either mode)." >&2
exit 1
