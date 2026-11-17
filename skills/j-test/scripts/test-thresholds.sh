#!/usr/bin/env bash
################################################################################
# test-thresholds.sh — the one reader of the test-run thresholds: the two
# long-running test thresholds (E77_S06_T02) and the two run-budget numbers
# (E95_S02_T02)
#
# Every consumer that needs to know how long is "too long" for a test file (the
# long-running report, the timing script, the manual-only notice text) asks THIS
# script; none keeps its own copy of either number. The script only reads: it
# writes nothing, runs no suite and no project code.
#
# Usage:
#   test-thresholds.sh get <mirror-gate|manual-only|confirm-file-count|ask-before-run>
#                          [--root <dir>] [--config <file>]
#   test-thresholds.sh list [--root <dir>] [--config <file>]
#   test-thresholds.sh --help
#
#   get <name>        print the effective value, a whole number, on one line.
#   list              print all four, one `<name><TAB><value>` line each, in the
#                     order below.
#   --root <dir>      project root the configs directory is resolved against
#                     (JENGA_PROJECT_ROOT semantics of scripts/resolve-root.sh, with
#                     the resolver's relative `configs` path joined onto the root as
#                     the fallback). Default: the configs directory the resolver
#                     finds from $PWD (or JENGA_PROJECT_ROOT). Must be a directory.
#   --config <file>   read this file instead of <configs dir>/test-config.json.
#                     Wins over --root for locating the file.
#
# THE TWO THRESHOLDS. They decide different things and stay separate:
#
#   name          config key                       default  meaning
#   mirror-gate   mirror_gate_threshold_seconds       50    A test file that, run
#                                                            alone, takes longer than
#                                                            this is too slow for the
#                                                            pre-push test gate and is
#                                                            a candidate for the
#                                                            gate's exclusion list. It
#                                                            still runs in local runs.
#   manual-only   manual_only_threshold_seconds      600    A test file that, run
#                                                            alone, takes longer than
#                                                            this should be tagged
#                                                            manual-only (never run
#                                                            automatically, even
#                                                            locally). Advisory: the
#                                                            in-file marker read by
#                                                            manual-only.sh, not this
#                                                            number, is what defines
#                                                            a manual-only file.
#
# THE TWO RUN-BUDGET NUMBERS (E95_S02_T02). They bound a whole run, not one file:
#
#   name                config key                   default  meaning
#   confirm-file-count  full_run_confirm_file_count     60    A runner selection of
#                                                            more test files than
#                                                            this is refused without
#                                                            --confirm-full (unit:
#                                                            files, not seconds).
#   ask-before-run      ask_before_run_seconds         300    An agent asks the user
#                                                            before starting a run
#                                                            whose estimate
#                                                            (scripts/test-estimate.sh)
#                                                            exceeds this many seconds.
#
# `pre-push-gate` is accepted as an alias of `mirror-gate` (the config key is named
# after it). All four keys are flat top-level integers of test-config.json, editable
# with
#   jenga config set test-config.<key> <n>
#
# STDOUT. `get` prints exactly one line, the integer, and nothing else. Warnings and
# usage go to stderr only.
#
# ABSENT versus INVALID (neither is a failure; the fallback is the default above):
#   - Absent. No test-config.json, an empty or whitespace-only file, or a JSON
#     object without the key: the default is printed, silently, exit 0. Older
#     configs lack the keys; that is not an error.
#   - Invalid. The key is present but is not a positive whole number (a string, a
#     fraction, zero, a negative number, a boolean, null, an object, an array, or a
#     value above 2147483647): the default is printed, exit 0, and ONE warning line
#     goes to stderr naming the key, the offending value (as JSON) and the default:
#       test-thresholds.sh: manual_only_threshold_seconds is "ten", expected a positive whole number of seconds; using the default 600
#     (for full_run_confirm_file_count the message says "of files").
#   - Unreadable. The file exists but cannot be read, is not valid JSON, is not a
#     JSON object, or neither jq nor python3 is installed: exit 6, nothing on
#     stdout, one message on stderr. (Exit 6 matches `jenga config`.)
#
# ORDER WARNING. A file cannot be too slow to run at all yet fine for the pre-push
# gate, so when the effective manual-only value is below the effective mirror-gate
# value, one warning line goes to stderr from `get` and `list` and the values are
# printed unchanged (exit 0). The run-budget numbers take no part in this check.
#
# EXIT CODES
#   0    resolved (including every fallback and the order warning)
#   2    usage error (stdout empty, message plus usage on stderr): no or unknown
#        subcommand or name, extra argument, unknown option, an option without its
#        argument, or a --root that is not a directory
#   6    the config file is unreadable or malformed, or no JSON reader is installed
#
# Uses jq when present, python3 otherwise. macOS bash 3.2 compatible.
################################################################################

set -u

SCRIPT_NAME="test-thresholds.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
REPO_ROOT="$(jenga_package_root "$SCRIPT_DIR")" || true
GATE_KEY="mirror_gate_threshold_seconds"
GATE_DEFAULT=50
MANUAL_KEY="manual_only_threshold_seconds"
MANUAL_DEFAULT=600
CONFIRM_KEY="full_run_confirm_file_count"
CONFIRM_DEFAULT=60
ASK_KEY="ask_before_run_seconds"
ASK_DEFAULT=300
MAX_VALUE=2147483647

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

usage() {
  cat <<'EOF'
Usage: test-thresholds.sh get <name> [--root <dir>] [--config <file>]
       test-thresholds.sh list [--root <dir>] [--config <file>]
       test-thresholds.sh --help

Print the effective test-run thresholds, as whole numbers.

  get <name>        one integer for <name>: mirror-gate (default 50 s),
                    manual-only (default 600 s), confirm-file-count (default 60
                    files) or ask-before-run (default 300 s)
  list              all four, as `<name><TAB><value>` lines
  --root <dir>      project root to resolve the configs directory against
  --config <file>   read this file instead of <configs dir>/test-config.json
  --help            show this help and exit 0

mirror-gate:  a test file slower than this is too slow for the pre-push test gate
(key mirror_gate_threshold_seconds; `pre-push-gate` is accepted as an alias).
manual-only:  a test file slower than this should be tagged manual-only
(key manual_only_threshold_seconds); advisory, the in-file marker defines the set.
confirm-file-count: a runner selection of more files than this needs --confirm-full
(key full_run_confirm_file_count).
ask-before-run:  an agent asks the user before a run estimated above this many
seconds (key ask_before_run_seconds).

An absent key or file prints the default silently; an invalid value prints the
default plus one warning on stderr. Set a value with
`jenga config set test-config.<key> <n>`.

Exit: 0 resolved, 2 usage error, 6 config unreadable or malformed
EOF
}

die_usage() {
  err "$1"
  usage >&2
  exit 2
}

# A checkout first, then the installed-package location (the sibling pattern).
find_resolver() {
  local candidate
  for candidate in "$REPO_ROOT/scripts/resolve-root.sh" \
                   "$REPO_ROOT/node_modules/@jenga-ai/agent/scripts/resolve-root.sh"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Prints the configs directory, or nothing when it cannot be resolved. $1 is the
# (already validated and absolute) --root, or empty.
config_dir() {
  local root="$1" resolver dir="" rel=""
  if resolver="$(find_resolver)"; then
    if [ -n "$root" ]; then
      dir="$(JENGA_PROJECT_ROOT="$root" bash "$resolver" get configs 2>/dev/null)" || dir=""
      if [ -z "$dir" ]; then
        rel="$(cd -- "$root" && JENGA_PROJECT_ROOT="" bash "$resolver" --relative get configs 2>/dev/null)" || rel=""
        [ -z "$rel" ] || dir="$root/$rel"
      fi
    else
      dir="$(bash "$resolver" get configs 2>/dev/null)" || dir=""
    fi
  elif [ -n "$root" ]; then
    # No resolver installed: the consuming-project default layout.
    dir="$root/project/configs"
  fi
  printf '%s' "$dir"
}

# ---- arguments ----------------------------------------------------------------
SUBCOMMAND=""
NAME=""
ROOT_ARG=""
CONFIG_ARG=""
CONFIG_GIVEN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --root)
      [ "$#" -ge 2 ] || die_usage "--root needs a directory argument"
      ROOT_ARG="$2"
      shift 2
      ;;
    --config)
      [ "$#" -ge 2 ] || die_usage "--config needs a file argument"
      CONFIG_ARG="$2"
      CONFIG_GIVEN=1
      shift 2
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      if [ -z "$SUBCOMMAND" ]; then
        SUBCOMMAND="$1"
      elif [ -z "$NAME" ]; then
        NAME="$1"
      else
        die_usage "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -n "$SUBCOMMAND" ] || die_usage "missing subcommand (expected: get or list)"
case "$SUBCOMMAND" in
  get)
    [ -n "$NAME" ] || die_usage "missing name (expected: mirror-gate, manual-only, confirm-file-count or ask-before-run)"
    case "$NAME" in
      pre-push-gate|mirror-gate) NAME="mirror-gate" ;;
      manual-only|confirm-file-count|ask-before-run) ;;
      *) die_usage "unknown name: $NAME (expected: mirror-gate, manual-only, confirm-file-count or ask-before-run)" ;;
    esac
    ;;
  list)
    [ -z "$NAME" ] || die_usage "unexpected argument: $NAME"
    ;;
  *)
    die_usage "unknown subcommand: $SUBCOMMAND (expected: get or list)"
    ;;
esac

ROOT=""
if [ -n "$ROOT_ARG" ]; then
  [ -d "$ROOT_ARG" ] || die_usage "--root is not a directory: $ROOT_ARG"
  ROOT="$(cd -- "$ROOT_ARG" && pwd)"
fi

# ---- locate the file ------------------------------------------------------------
if [ "$CONFIG_GIVEN" -eq 1 ]; then
  CFG="$CONFIG_ARG"
else
  CFG_DIR="$(config_dir "$ROOT")"
  CFG=""
  [ -z "$CFG_DIR" ] || CFG="$CFG_DIR/test-config.json"
fi

fail_unreadable() {
  err "cannot read the thresholds: $1"
  exit 6
}

# ---- read -----------------------------------------------------------------------
# read_key <key>: prints one token. A = key absent, V<n> = valid, I<json> = present
# but invalid. Exits 6 through fail_unreadable on an unreadable or malformed file.
# Only called once the file is known to exist, be readable and be non-blank.
read_key() {
  local key="$1" out=""
  if command -v jq >/dev/null 2>&1; then
    if ! out="$(jq -r --arg k "$key" --argjson max "$MAX_VALUE" '
          if type == "object"
          then (if has($k) | not then "A"
                else (.[$k]
                      | if type == "number" and . == floor and . >= 1 and . <= $max
                        then "V" + (floor | tostring)
                        else "I" + tojson end)
                end)
          else error("not an object") end' "$CFG" 2>/dev/null)"; then
      fail_unreadable "$(basename -- "$CFG") is not valid JSON or not a JSON object"
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if ! out="$(python3 - "$CFG" "$key" "$MAX_VALUE" <<'PY' 2>/dev/null
import json, sys
path, key, mx = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path) as fh:
    data = json.load(fh)
if not isinstance(data, dict):
    sys.exit(3)
if key not in data:
    print("A")
else:
    v = data[key]
    ok = False
    if isinstance(v, bool):
        ok = False
    elif isinstance(v, int):
        ok = 1 <= v <= mx
    elif isinstance(v, float):
        ok = v == int(v) and 1 <= v <= mx
    if ok:
        print("V%d" % int(v))
    else:
        print("I" + json.dumps(v, separators=(",", ":")))
PY
    )"; then
      fail_unreadable "$(basename -- "$CFG") is not valid JSON or not a JSON object"
    fi
  else
    fail_unreadable "neither jq nor python3 is installed"
  fi
  printf '%s' "$out"
}

GATE_VALUE="$GATE_DEFAULT"
MANUAL_VALUE="$MANUAL_DEFAULT"

# resolve_one <key> <default> <warn:0|1> [unit]: sets RESOLVED to the effective
# value. [unit] names the unit in the invalid-value warning (default: seconds).
RESOLVED=""
resolve_one() {
  local key="$1" default="$2" warn="$3" unit="${4:-seconds}" tok
  RESOLVED="$default"
  [ "$FILE_STATE" = "ok" ] || return 0
  tok="$(read_key "$key")" || exit $?
  case "$tok" in
    A) ;;
    V*) RESOLVED="${tok#V}" ;;
    I*)
      [ "$warn" -eq 0 ] || err "$key is ${tok#I}, expected a positive whole number of $unit; using the default $default"
      ;;
    *) fail_unreadable "unexpected result reading $(basename -- "$CFG")" ;;
  esac
  return 0
}

# FILE_STATE: absent (no file, or blank) or ok (exists, readable, has content).
FILE_STATE="absent"
if [ -n "$CFG" ] && { [ -e "$CFG" ] || [ -L "$CFG" ]; }; then
  [ -f "$CFG" ] || fail_unreadable "$CFG is not a regular file"
  [ -r "$CFG" ] || fail_unreadable "$CFG is not readable"
  if grep -q '[^[:space:]]' "$CFG" 2>/dev/null; then
    FILE_STATE="ok"
  fi
fi

# Warn about an invalid value only for what the caller asked for.
WARN_CONFIRM=0; WARN_ASK=0
case "$SUBCOMMAND:$NAME" in
  get:mirror-gate) WARN_GATE=1; WARN_MANUAL=0 ;;
  get:manual-only)   WARN_GATE=0; WARN_MANUAL=1 ;;
  get:confirm-file-count) WARN_GATE=0; WARN_MANUAL=0; WARN_CONFIRM=1 ;;
  get:ask-before-run)     WARN_GATE=0; WARN_MANUAL=0; WARN_ASK=1 ;;
  *)                 WARN_GATE=1; WARN_MANUAL=1; WARN_CONFIRM=1; WARN_ASK=1 ;;
esac

resolve_one "$GATE_KEY" "$GATE_DEFAULT" "$WARN_GATE";       GATE_VALUE="$RESOLVED"
resolve_one "$MANUAL_KEY" "$MANUAL_DEFAULT" "$WARN_MANUAL"; MANUAL_VALUE="$RESOLVED"
resolve_one "$CONFIRM_KEY" "$CONFIRM_DEFAULT" "$WARN_CONFIRM" files; CONFIRM_VALUE="$RESOLVED"
resolve_one "$ASK_KEY" "$ASK_DEFAULT" "$WARN_ASK";          ASK_VALUE="$RESOLVED"

if [ "$MANUAL_VALUE" -lt "$GATE_VALUE" ]; then
  err "$MANUAL_KEY ($MANUAL_VALUE) is below $GATE_KEY ($GATE_VALUE); a file cannot be too slow to run at all yet fine for the pre-push test gate, so raise $MANUAL_KEY or lower $GATE_KEY"
fi

case "$SUBCOMMAND" in
  get)
    case "$NAME" in
      mirror-gate)        printf '%s\n' "$GATE_VALUE" ;;
      manual-only)        printf '%s\n' "$MANUAL_VALUE" ;;
      confirm-file-count) printf '%s\n' "$CONFIRM_VALUE" ;;
      ask-before-run)     printf '%s\n' "$ASK_VALUE" ;;
    esac
    ;;
  list)
    printf 'mirror-gate\t%s\nmanual-only\t%s\nconfirm-file-count\t%s\nask-before-run\t%s\n' \
      "$GATE_VALUE" "$MANUAL_VALUE" "$CONFIRM_VALUE" "$ASK_VALUE"
    ;;
esac
exit 0
