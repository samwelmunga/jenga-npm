#!/usr/bin/env bash
# scripts/with-lock.sh — atomic, cross-platform exclusive file lock wrapper
#
# Usage:
#   scripts/with-lock.sh <target-file> -- <command> [args...]
#
# Acquires an exclusive lock keyed to <target-file> before running <command>,
# and always releases the lock afterward — on success, on failure, and on
# signal (INT/TERM sent to this script are forwarded to the wrapped command,
# which is then waited on before the lock is released — see the signal
# handling note further down). The wrapped command's exit code is preserved
# as this script's own exit code.
#
# This replaces the purely advisory "check for a .lock file, wait, retry,
# then create/delete it yourself" convention previously described in
# templates/SCRUM_BOARD_SCHEMA.md. That convention relied on every caller
# implementing check-wait-retry-cleanup correctly, including on error paths,
# with nothing to mechanically stop two writers from both deciding the lock
# is free at the same time. This script enforces exclusivity instead.
#
# Lock primitive: `mkdir` on a lock directory, NOT `flock`. `flock` is a
# Linux-only (util-linux) utility and is not present by default on macOS/BSD
# (this repo runs on Darwin). POSIX `mkdir` is atomic on every platform this
# repo targets: the kernel guarantees that when multiple processes race to
# create the same directory, exactly one succeeds and every other call fails
# with EEXIST. That atomicity — not any cooperative check beforehand — is
# what makes this a real mutual-exclusion lock instead of advisory prose.
#
# Environment overrides (all optional):
#   WITH_LOCK_TIMEOUT_SECONDS   Max time to wait for a held lock (default: 30)
#   WITH_LOCK_POLL_SECONDS      Poll interval while waiting (default: 0.2)
#   WITH_LOCK_STALE_SECONDS     Age after which a still-held lock is treated
#                               as abandoned (crashed holder) and reclaimed
#                               (default: 60)
#
# Exit codes:
#   0    lock acquired, command ran, exit code is the command's own
#   1    invalid usage
#   2    could not acquire the lock within the timeout — the command was
#        NEVER run (fail safe; no partial or silently-clobbered write)
#   *    otherwise, the wrapped command's own exit code

set -u

usage() {
  echo "Usage: $0 <target-file> -- <command> [args...]" >&2
  exit 1
}

[ "$#" -ge 1 ] || usage
TARGET_FILE="$1"
shift

[ "${1:-}" = "--" ] || usage
shift

[ "$#" -ge 1 ] || usage

TIMEOUT_SECONDS="${WITH_LOCK_TIMEOUT_SECONDS:-30}"
POLL_SECONDS="${WITH_LOCK_POLL_SECONDS:-0.2}"
STALE_SECONDS="${WITH_LOCK_STALE_SECONDS:-60}"

LOCK_DIR="${TARGET_FILE}.lock.d"
LOCK_PID_FILE="${LOCK_DIR}/pid"

now_epoch() {
  date +%s
}

# Portable mtime lookup: GNU stat (Linux) uses -c, BSD stat (macOS) uses -f.
# Try GNU form first, fall back to BSD form. Echoes nothing (and returns
# non-zero) if the directory vanished in the meantime.
lock_mtime_epoch() {
  stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null
}

# If the held lock looks abandoned (older than STALE_SECONDS), reclaim it.
# This does NOT grant the lock by itself — it only clears the way. The next
# mkdir attempt in the polling loop is still the sole arbiter of who
# proceeds, so simultaneous reclaim attempts by multiple waiters never let
# more than one of them through.
maybe_reclaim_stale_lock() {
  local mtime now age
  mtime="$(lock_mtime_epoch)" || return 0
  now="$(now_epoch)"
  age=$(( now - mtime ))
  if [ "$age" -ge "$STALE_SECONDS" ]; then
    echo "with-lock: reclaiming stale lock '$LOCK_DIR' (age ${age}s >= ${STALE_SECONDS}s)" >&2
    rm -rf "$LOCK_DIR" 2>/dev/null
  fi
}

acquire_lock() {
  local start now elapsed
  start="$(now_epoch)"
  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_PID_FILE" 2>/dev/null || true
      return 0
    fi

    maybe_reclaim_stale_lock

    now="$(now_epoch)"
    elapsed=$(( now - start ))
    if [ "$elapsed" -ge "$TIMEOUT_SECONDS" ]; then
      return 1
    fi
    sleep "$POLL_SECONDS" 2>/dev/null || sleep 1
  done
}

release_lock() {
  rm -rf "$LOCK_DIR" 2>/dev/null
}

if ! acquire_lock; then
  echo "with-lock: failed to acquire lock on '$TARGET_FILE' within ${TIMEOUT_SECONDS}s (lock dir: $LOCK_DIR) — command was not run" >&2
  exit 2
fi

# Always release the lock on exit, regardless of how the wrapped command
# (or this script itself) terminates.
trap release_lock EXIT

# Signal handling note: the wrapped command is run in the background and
# waited on explicitly (rather than exec'd directly in the foreground) so
# that INT/TERM delivered to this script are handled promptly. Bash defers
# non-EXIT traps until a foreground command completes, so a script that
# instead ran `"$@"` directly in the foreground would not react to a signal
# sent to its own PID until the wrapped command finished on its own —
# release would then only happen once the command exited naturally (or, in
# the worst case, once WITH_LOCK_STALE_SECONDS elapsed and another waiter
# reclaimed the lock). Backgrounding + `wait` avoids that: the trap fires as
# soon as the signal arrives, forwards it to the child, waits for the child
# to actually exit, then this script exits (triggering the EXIT trap above,
# which releases the lock).
CHILD_PID=""

forward_signal_and_exit() {
  local sig="$1" exit_code="$2"
  if [ -n "$CHILD_PID" ]; then
    kill -s "$sig" "$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
  fi
  exit "$exit_code"
}

trap 'forward_signal_and_exit TERM 143' TERM
trap 'forward_signal_and_exit INT 130' INT

"$@" &
CHILD_PID=$!
wait "$CHILD_PID"
status=$?
CHILD_PID=""

exit "$status"
