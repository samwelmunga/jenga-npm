#!/usr/bin/env bash
# scripts/diagnostics/with-lock-exclusion-stress.sh - E77_S05_T01 diagnostic harness (not production, not a suite)
#
# Tests scripts/with-lock.sh's mutual exclusion on its own, without checklist.sh or python in the picture. Each
# round starts WORKERS contenders at (as near as a busy-wait barrier allows) the same instant; every contender
# runs `with-lock.sh <file> -- <read-increment-write>` on one shared counter file that does not exist at the start
# of the round. If the lock is exclusive the counter equals WORKERS at the end of every round; a lower value is a
# lost update, which is exactly the symptom in E77_S05.
#
# Usage: with-lock-exclusion-stress.sh [rounds] [workers] [hold-seconds]
#   rounds        default 300
#   workers       default 2
#   hold-seconds  how long the critical section idles between the read and the write (default 0 = none; a small
#                 value such as 0.01 widens the window so a broken lock is caught sooner)
# Environment: WITH_LOCK_UNDER_TEST=<path> tests that locker instead of scripts/with-lock.sh (to try a candidate fix).
#              WITH_LOCK_XTRACE=1 runs every contender under `bash -x` with a microsecond-stamped PS4 and keeps the
#              traces of lost rounds as <workdir>/lost-<round>-<worker>.trace, to see the interleaving.
# Output: one line per round that lost an update, then "rounds=<n> workers=<w> lost=<k>".
# Exit status: 0 no lost update, 1 at least one.
set -u
ROUNDS="${1:-300}"
WORKERS="${2:-2}"
HOLD="${3:-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCKER="${WITH_LOCK_UNDER_TEST:-$HERE/scripts/with-lock.sh}"
W="$(mktemp -d "${TMPDIR:-/tmp}/with-lock-stress.XXXXXX")"
export WITH_LOCK_TIMEOUT_SECONDS=45 WITH_LOCK_POLL_SECONDS=0.05
unset WITH_LOCK_STALE_SECONDS

# The critical section: read the counter (absent means 0), optionally idle, write counter+1 atomically.
CRIT='f="$1"; c=0; [ -f "$f" ] && c="$(cat "$f")"; [ "$2" != 0 ] && sleep "$2"; echo $((c + 1)) > "$f.new" && mv "$f.new" "$f"'

lost=0
for r in $(seq 1 "$ROUNDS"); do
  f="$W/counter-$r"
  go="$W/go-$r"
  for w in $(seq 1 "$WORKERS"); do
    (
      while [ ! -e "$go" ]; do :; done
      if [ "${WITH_LOCK_XTRACE:-0}" = 1 ]; then
        PS4='+ $EPOCHREALTIME ' bash -x "$LOCKER" "$f" -- bash -c "$CRIT" _ "$f" "$HOLD" >/dev/null 2>"$W/err-$r-$w"
      else
        bash "$LOCKER" "$f" -- bash -c "$CRIT" _ "$f" "$HOLD" >/dev/null 2>"$W/err-$r-$w"
      fi
      echo "$?" > "$W/rc-$r-$w"
    ) &
  done
  : > "$go"
  wait
  got="$(cat "$f" 2>/dev/null || echo none)"
  if [ "$got" != "$WORKERS" ]; then
    lost=$((lost + 1))
    for w in $(seq 1 "$WORKERS"); do cp "$W/err-$r-$w" "$W/lost-$r-$w.trace"; done
    echo "round $r: counter=$got expected=$WORKERS rc=$(cat "$W"/rc-$r-* | tr '\n' ' ') stderr=$(cat "$W"/err-$r-* | tr '\n' ' ')"
  fi
done
echo "rounds=$ROUNDS workers=$WORKERS lost=$lost workdir=$W"
[ "$lost" -eq 0 ]
