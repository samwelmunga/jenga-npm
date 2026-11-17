#!/usr/bin/env bash
# scripts/diagnostics/tick-race-stress.sh - E77_S05_T01 diagnostic harness (not production, not part of any suite)
#
# Replays the body of tests/checklist-sh.bats "concurrency: two parallel ticks of a run-scoped item pair under the
# same run id both land" without bats, N times, each round against a fresh run id in one shared state directory,
# and counts the rounds in which one of the two ticks did not land. Needs only bash, python3 and jq, so it runs
# unchanged on macOS and in a Linux container.
#
# Usage: tick-race-stress.sh [rounds] [--trace]
#   rounds   how many two-writer rounds to run (default 200)
#   --trace  run each writer under `bash -x` with a timestamped PS4, so the logs of a round that lost a tick
#            show the interleaving of both writers
# Output: one line per lost round, then "rounds=<n> lost=<k> workdir=<dir>". The stderr/xtrace logs of every lost
#         round are kept as <dir>/lost-<round>-{a,b}.log; the workdir is kept so the state can be inspected.
# Exit status: 0 no tick was ever lost, 1 at least one round lost a tick.
set -u
ROUNDS="${1:-200}"
TRACE=0
[ "${2:-}" = "--trace" ] && TRACE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKLIST="$HERE/scripts/checklist.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-race.XXXXXX")"
mkdir -p "$W/proj/project/configs"
echo '{}' > "$W/proj/project/configs/workflow.json"
jq -n '{checklist_version:1, situations:["pre-deploy"], items:[
  {id:"pair-a",text:"Item pair-a.",situations:["pre-commit"],kind:"judgment",enforcement:"confirm",tick_scope:"run"},
  {id:"pair-b",text:"Item pair-b.",situations:["pre-commit"],kind:"judgment",enforcement:"confirm",tick_scope:"run"}]}' > "$W/checklists.json"
export JENGA_PROJECT_ROOT="$W/proj" JENGA_CHECKLISTS_FILE="$W/checklists.json" \
       JENGA_CHECKLISTS_DEFAULT_FILE="$W/none.json" JENGA_CHECKLIST_STATE_DIR="$W/state" \
       WITH_LOCK_TIMEOUT_SECONDS=45 WITH_LOCK_POLL_SECONDS=0.05
unset JENGA_CHECKLIST_RUN_ID JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES WITH_LOCK_STALE_SECONDS

tick() { # <who> <item> <run> <log>
  if [ "$TRACE" -eq 1 ]; then
    PS4='+ $(python3 -c "import time;print(\"%.4f\"%time.time())") ' \
      bash -x "$CHECKLIST" tick "$2" --run "$3" --by "agent:$1" >/dev/null 2>"$4"
  else
    bash "$CHECKLIST" tick "$2" --run "$3" --by "agent:$1" >/dev/null 2>"$4"
  fi
  echo "rc=$?" >> "$4"
}

lost=0
for r in $(seq 1 "$ROUNDS"); do
  run="conc-run-$r"
  tick a pair-a "$run" "$W/a.log" &
  tick b pair-b "$run" "$W/b.log" &
  wait
  stored=""
  for f in "$W"/state/run-*.json; do
    [ -f "$f" ] || continue
    s="$(jq -r --arg r "$run" 'select(.run_id == $r) | .ticks | keys | join(",")' "$f" 2>/dev/null)"
    [ -n "$s" ] && stored="$s"
  done
  if [ "$stored" != "pair-a,pair-b" ]; then
    lost=$((lost + 1))
    echo "round $r: LOST (ticks stored: ${stored:-none})"
    cp "$W/a.log" "$W/lost-$r-a.log"
    cp "$W/b.log" "$W/lost-$r-b.log"
  fi
done
echo "rounds=$ROUNDS lost=$lost workdir=$W"
[ "$lost" -eq 0 ]
