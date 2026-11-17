#!/usr/bin/env bash
# scripts/diagnostics/mkdir-atomicity-probe.sh - E77_S05_T01 diagnostic probe (not production, not a suite)
#
# scripts/with-lock.sh's whole mutual exclusion rests on one claim: when several processes run `mkdir <dir>`
# on a path that does not exist yet, exactly one exits 0 and the others fail with EEXIST. This probe checks that
# claim for one mkdir binary, with no with-lock.sh, checklist.sh or python involved.
#
# Usage: mkdir-atomicity-probe.sh [mkdir-command] [rounds] [contenders]
#   mkdir-command  the command to exercise (default: mkdir, i.e. whatever is first in PATH). On Ubuntu 26.04 pass
#                  /usr/bin/gnumkdir to run the same probe against GNU coreutils as the control.
#   rounds         fresh directory names to race for (default 500)
#   contenders     simultaneous mkdir processes per round (default 2)
# Output: "<command>: rounds=<n> contenders=<c> double_wins=<k>", where double_wins counts rounds in which more than
#         one contender exited 0. Anything above 0 means the command is not usable as a lock primitive.
# Exit status: 0 no round had two winners, 1 otherwise.
set -u
CMD="${1:-mkdir}"
ROUNDS="${2:-500}"
N="${3:-2}"
W="$(mktemp -d "${TMPDIR:-/tmp}/mkdir-probe.XXXXXX")"
double=0
for r in $(seq 1 "$ROUNDS"); do
  go="$W/go-$r"
  for c in $(seq 1 "$N"); do
    (
      while [ ! -e "$go" ]; do :; done
      "$CMD" "$W/dir-$r" 2>/dev/null
      echo "$?" > "$W/rc-$r-$c"
    ) &
  done
  : > "$go"
  wait
  wins="$(grep -l -x 0 "$W"/rc-"$r"-* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$wins" -gt 1 ] && double=$((double + 1))
done
rm -rf "$W"
echo "$CMD: rounds=$ROUNDS contenders=$N double_wins=$double"
[ "$double" -eq 0 ]
