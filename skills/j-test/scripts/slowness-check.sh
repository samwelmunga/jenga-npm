#!/usr/bin/env bash
################################################################################
# slowness-check.sh — the j.test skill's seam to the slowness probe
#
# The skill, not run-suites.sh, decides when to measure and what to do about a slow machine,
# so this script gives it four deterministic operations over scripts/slowness-probe.sh and the
# machine-local threshold file <root>/project/logs/slowness-threshold (git-ignored).
#
# Usage:
#   slowness-check.sh [--root <dir>] probe
#   slowness-check.sh [--root <dir>] threshold
#   slowness-check.sh [--root <dir>] set-threshold <n|default>
#   slowness-check.sh [--root <dir>] reclassify
#   slowness-check.sh --help
#
#   probe            run the probe and show its report. Exit code is the probe's: 0 healthy,
#                    1 the reference file failed, 3 skipped (bats or the reference file absent),
#                    10 slow, 130 interrupted.
#   threshold        print "<n> <source>": the number wall/CPU must exceed to count as slow, and
#                    where it comes from (option, environment, saved or default).
#   set-threshold    save <n> (a number above 0) as this machine's threshold; "default" removes
#                    the saved value so the built-in 2.5 applies again. Written atomically.
#                    $JENGA_SLOWNESS_THRESHOLD, when set, still wins over a saved value and a
#                    note says so.
#   reclassify       judge the most recent logged probe against the threshold that applies now,
#                    without measuring again. Prints one line. Exit 0 healthy, 10 slow, 3 when
#                    there is no usable logged probe.
#
# Exit codes of the script itself: 2 usage error, plus the per-subcommand codes above.
# bash 3.2 compatible.
################################################################################

set -uo pipefail
export LC_NUMERIC=C

SCRIPT_NAME="slowness-check.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent when installed.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
die_usage() { err "$1"; exit 2; }
usage() { sed -n '2,/^####/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

ROOT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --root) [ "$#" -ge 2 ] || die_usage "--root needs a directory argument"; ROOT="$2"; shift 2 ;;
    *) break ;;
  esac
done

[ "$#" -ge 1 ] || die_usage "a subcommand is required (probe, threshold, set-threshold, reclassify)"
SUB="$1"
shift

PROBE="$(resolve_helper scripts/slowness-probe.sh)" || die_usage "could not locate scripts/slowness-probe.sh"
if [ -z "$ROOT" ]; then
  RESOLVER="$(resolve_helper scripts/resolve-root.sh)" || die_usage "could not locate scripts/resolve-root.sh"
  ROOT="$(bash "$RESOLVER" root)" || die_usage "could not resolve the working root"
fi
[ -d "$ROOT" ] || die_usage "root is not a directory: $ROOT"
ROOT="$(cd -- "$ROOT" && pwd)"

THRESHOLD_FILE="$ROOT/project/logs/slowness-threshold"
PROBE_LOG="$ROOT/project/logs/slowness-probe.jsonl"

case "$SUB" in
  probe)
    [ "$#" -eq 0 ] || die_usage "probe takes no arguments"
    bash "$PROBE" --root "$ROOT" </dev/null
    exit $?
    ;;

  threshold)
    [ "$#" -eq 0 ] || die_usage "threshold takes no arguments"
    bash "$PROBE" --root "$ROOT" --print-threshold
    exit $?
    ;;

  set-threshold)
    [ "$#" -eq 1 ] || die_usage "set-threshold needs one argument: a number above 0, or 'default'"
    value="$1"
    if [ "$value" = "default" ]; then
      rm -f "$THRESHOLD_FILE"
      printf 'slow threshold reset: wall above 2.5 times CPU counts as slow on this machine\n'
    else
      case "$value" in
        ''|*[!0-9.]*|.|*.*.*) die_usage "threshold must be a number above 0 (for example 4), got '$value'" ;;
      esac
      awk -v t="$value" 'BEGIN { exit !(t > 0) }' || die_usage "threshold must be a number above 0, got '$value'"
      mkdir -p "$(dirname -- "$THRESHOLD_FILE")" || die_usage "could not create $(dirname -- "$THRESHOLD_FILE")"
      tmp="$(mktemp "$THRESHOLD_FILE.XXXXXX")" || die_usage "could not write next to $THRESHOLD_FILE"
      if ! { printf '%s\n' "$value" > "$tmp" && mv -f "$tmp" "$THRESHOLD_FILE"; }; then
        rm -f "$tmp"
        die_usage "could not write $THRESHOLD_FILE"
      fi
      printf 'slow threshold saved: wall above %s times CPU counts as slow on this machine\n' "$value"
    fi
    if [ -n "${JENGA_SLOWNESS_THRESHOLD:-}" ]; then
      printf 'note: JENGA_SLOWNESS_THRESHOLD=%s is set in this environment and overrides the saved value\n' "$JENGA_SLOWNESS_THRESHOLD"
    fi
    exit 0
    ;;

  reclassify)
    [ "$#" -eq 0 ] || die_usage "reclassify takes no arguments"
    command -v jq >/dev/null 2>&1 || die_usage "jq is required but was not found on PATH"
    if [ ! -s "$PROBE_LOG" ]; then
      printf 'no logged probe to judge\n'
      exit 3
    fi
    ratio="$(tail -n 1 "$PROBE_LOG" | jq -r '.ratio // empty' 2>/dev/null)"
    case "$ratio" in
      ''|*[!0-9.]*|.|*.*.*) printf 'the last logged probe has no usable ratio\n'; exit 3 ;;
    esac
    read -r threshold source < <(bash "$PROBE" --root "$ROOT" --print-threshold) || die_usage "could not read the threshold"
    if awk -v r="$ratio" -v t="$threshold" 'BEGIN { exit !(r > t) }'; then
      printf 'last probe: wall %s times CPU, above the threshold %s (%s): still slow\n' "$ratio" "$threshold" "$source"
      exit 10
    fi
    printf 'last probe: wall %s times CPU, within the threshold %s (%s): not slow\n' "$ratio" "$threshold" "$source"
    exit 0
    ;;

  *)
    die_usage "unknown subcommand: $SUB (probe, threshold, set-threshold, reclassify)"
    ;;
esac
