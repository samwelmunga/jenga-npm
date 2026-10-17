#!/usr/bin/env bash
################################################################################
# test-gate-decide.sh - the decision half of the j.commit test gate (E72_S04_T01)
#
# Per CLAUDE.md's "Scripts Over Inline Logic" principle the model never decides
# whether to ask about tests, never parses the answer, and never judges whether a
# result lets the commit proceed: skills/j-commit/SKILL.md (wired up by
# E72_S04_T04) relays this script's output and prompts the user itself. This
# script is pure logic: it runs no test, calls no `git`, reads no network, writes
# no file and never prompts interactively. Its only input besides its arguments
# is one optional read of `test-config.json` (by `resolve`).
#
# This header is the normative contract. E72_S04_T04 (wiring), T05 (end to end)
# and T06 (documentation) are written against it.
#
# Usage
#   test-gate-decide.sh resolve  [--tests <ask|skip|scoped|full>]
#                                [--caller <interactive|noninteractive>]
#                                [--inline] [--root <dir>]
#   test-gate-decide.sh prompt   [--default <skip|scoped|full>]
#   test-gate-decide.sh answer   <raw> [--default <skip|scoped|full>]
#   test-gate-decide.sh fallback-prompt --reason "<text>"
#   test-gate-decide.sh fallback-answer <raw>
#   test-gate-decide.sh failure-prompt  --failed "<names>" [--kind <failed|error>]
#   test-gate-decide.sh failure-answer  <raw>
#   test-gate-decide.sh directive <result> [--choice <fix|anyway|abort>]
#   test-gate-decide.sh --help
#
# Exit codes (every subcommand)
#   0  success: one record on stdout (`directive` exits 0 only for PROCEED)
#   1  `answer`, `fallback-answer`, `failure-answer`: invalid answer, NOTHING on
#      stdout and one message on stderr naming the input and the valid range.
#      `directive`: the outcome is HALT (`GATE=HALT` on stdout).
#      `resolve`: `jq` is not installed (a message naming it on stderr).
#   2  usage error: unknown subcommand or flag, a flag missing its value, a value
#      outside its enumeration (an empty string is outside every enumeration),
#      an unknown `directive` result. Nothing on stdout, a message and the usage
#      line on stderr.
#   Callers must treat any non-zero status as "do not proceed".
#
# resolve - decide whether the gate prompts, runs or skips
#   Prints exactly one compact JSON line, keys in this order:
#     {"action":"prompt|run|skip","choice":"scoped|full|skip|null",
#      "recorded_default":"","default_source":"config|absent|invalid",
#      "noninteractive":false,"reason":"...","warnings":[]}
#   `choice` is the JSON value null (not the string) when `action` is `prompt`.
#   Rules, applied in this order; the first that matches decides:
#     0. `--tests` and `--caller` are validated first. A value outside their
#        enumeration exits 2 for every caller, so a typo is never silently
#        swallowed; a VALID `--tests` is then ignored by rule 1.
#     1. NON-INTERACTIVE WINS. `noninteractive` is true when `--caller
#        noninteractive`, `--inline`, JENGA_COMMIT_INLINE=1 or
#        JENGA_COMMIT_NONINTERACTIVE=1 (exactly the value `1`). Then
#        action=skip, choice=skip, reason `non-interactive caller: tests are not
#        run on an agent's behalf`, ignoring BOTH `--tests` and the recorded
#        default: a flag an agent passes is not a human decision, and a
#        background agent never self-certifies a test result.
#     2. Interactive with `--tests`: ask -> action=prompt; skip -> action=skip;
#        scoped|full -> action=run with that choice. Reason `per-invocation
#        override`.
#     3. Interactive without `--tests`: the recorded default decides. "" ->
#        action=prompt (reason `no recorded default`); skip -> action=skip;
#        scoped|full -> action=run. Reason `recorded default` for the last two.
#   `--tests ask` with a recorded default is how the user is shown the prompt
#   that names it: the caller passes a non-empty `recorded_default` on to
#   `prompt --default` and `answer --default`.
#   The recorded default is the flat key `commit_prompt_default` of
#   `test-config.json` in the configs directory resolved through
#   scripts/resolve-root.sh (JENGA_PROJECT_ROOT, `--root <dir>`, or the upward
#   search from $PWD), never a hardcoded path. It is read on EVERY path (so the
#   JSON always reports it) but only rule 3 acts on it:
#     - no configs directory, no file, no key, or the value null:
#         recorded_default "" , default_source `absent`, no warning
#     - key holds "", "skip", "scoped" or "full":
#         recorded_default echoes it, default_source `config`
#     - the file is unreadable, empty, not valid JSON, not an object, is not a
#       regular file, or the value is anything else (a different string, a
#       number, a boolean, an object, an array):
#         recorded_default "", default_source `invalid`, and `warnings` holds
#         one line naming the problem and, for a bad value, the value itself.
#   None of these is an error: an invalid default degrades to "ask".
#   `--root <dir>` anchors configs resolution at <dir> instead of $PWD.
#
# prompt - the main prompt, byte for byte (trailing newline included)
#     Run tests before committing?
#     1. Test covering committed scope (scoped run)
#     2. Run j.test (full suite)
#     3. Skip tests
#     Enter selection (1-3), or blank to skip:
#   With `--default X` the last line is instead
#     Enter selection (1-3), 'default' or blank for the recorded default (X):
#
# answer <raw> [--default X] - parse the main prompt's answer
#   Prints `scoped`, `full` or `skip`. <raw> is the FIRST argument after the
#   subcommand, so text that looks like a flag is still just an answer. It is
#   trimmed of whitespace and compared case-insensitively:
#     1|scoped -> scoped      2|full -> full      3|skip -> skip
#     blank    -> X when `--default X` is given, else skip
#     default  -> X when `--default X` is given, else INVALID
#   Anything else (`1,2`, `4`, `0`, `all`, `1 2`) is invalid: exit 1. The raw text
#   is only ever compared, never evaluated. A missing <raw> is a blank answer.
#
# fallback-prompt --reason "<text>"
#   The zero-mapped or mapping-failed prompt: <text> verbatim as the first line
#   (it is the explanation), then
#     What would you like to do?
#     1. Run j.test (full suite)
#     2. Skip tests
# fallback-answer <raw>
#   Prints `full` or `skip`: 1|full -> full, 2|skip -> skip (case-insensitive,
#   trimmed), blank -> skip. Anything else exits 1 as `answer` does.
#
# failure-prompt --failed "<names>" [--kind <failed|error>]
#     Tests failed: <names>
#     What would you like to do?
#     1. Fix first (nothing is committed)
#     2. Commit anyway (the failure is logged; the next commit is gated again)
#     3. Abort the commit (nothing is committed)
#   With `--kind error` the first line is `Tests could not be run: <names>`.
#   `--failed` must be a non-empty string.
# failure-answer <raw>
#   Prints `fix`, `anyway` or `abort`: 1|2|3 or the words, case-insensitive,
#   trimmed. BLANK IS INVALID (exit 1): the failure prompt has no default, so an
#   unanswered prompt can never turn into a commit.
#
# directive <result> [--choice <fix|anyway|abort>] - the proceed/halt table
#   <result> is one of passed, skipped, unavailable, failed, error, interrupted.
#   Prints one line, `GATE=PROCEED` (exit 0) or `GATE=HALT` (exit 1):
#     passed, skipped            any choice   PROCEED
#     unavailable                any choice   PROCEED (no runnable suite: the
#                                              skill must say nothing ran, and
#                                              never report it as a pass)
#     failed, error              anyway       PROCEED (an override)
#     failed, error              fix, abort,  HALT
#                                or no choice
#     interrupted                any choice   HALT (the user stopped it; no prompt)
#   An unknown result or choice exits 2 (so a caller's typo can never proceed).
#   HALT with no choice is deliberate: a caller that forgot to ask must not commit.
#
# Constraints: macOS bash 3.2 compatible (no associative arrays, no mapfile, no
# ${var,,}; lower-casing is done with tr; no arrays at all). Requires `jq` for
# `resolve` only. LC_ALL=C. Output is byte-identical for identical arguments,
# environment and configuration. Writes nothing, calls no `git`, no network.
################################################################################

set -euo pipefail
export LC_ALL=C

SCRIPT_NAME="test-gate-decide.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-commit/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

usage() {
  cat <<'EOF'
usage: test-gate-decide.sh <subcommand> [args]
  resolve [--tests <ask|skip|scoped|full>] [--caller <interactive|noninteractive>] [--inline] [--root <dir>]
  prompt [--default <skip|scoped|full>]
  answer <raw> [--default <skip|scoped|full>]
  fallback-prompt --reason "<text>"
  fallback-answer <raw>
  failure-prompt --failed "<names>" [--kind <failed|error>]
  failure-answer <raw>
  directive <result> [--choice <fix|anyway|abort>]
EOF
}

# Exit 2: a usage line on stderr, nothing on stdout.
usage_error() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  usage >&2
  exit 2
}

# Exit 1 from an answer parser: the input (control characters replaced) and the
# valid range on stderr, nothing on stdout. $1 = raw input, $2 = explanation.
invalid_answer() {
  local shown
  shown="$(printf '%s' "$1" | tr -c '[:print:]' '?')"
  printf "%s: invalid answer '%s': %s\n" "$SCRIPT_NAME" "$shown" "$2" >&2
  exit 1
}

# Flags that take a value: $1 = flag, $2 = number of arguments left (including the flag).
need_value() {
  [ "$2" -ge 2 ] || usage_error "$1 requires a value"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Normalised answer text: trimmed and lower-cased.
norm() {
  lower "$(trim "$1")"
}

# --default value check: skip|scoped|full only.
check_default() {
  case "$1" in
    skip|scoped|full) ;;
    *) usage_error "--default must be one of skip, scoped, full (got '$1')" ;;
  esac
}

# ---- resolve --------------------------------------------------------------------

RECORDED=""
SOURCE="absent"
WARNINGS=""
NONINT="false"

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

# Prints the configs directory, or nothing when it cannot be resolved.
config_dir() {
  local root_arg="$1" resolver root dir="" rel=""
  resolver="$(find_resolver)" || return 0
  if [ -n "$root_arg" ]; then
    root="$(cd -- "$root_arg" 2>/dev/null && pwd)" || usage_error "--root is not a directory: $root_arg"
    dir="$(JENGA_PROJECT_ROOT="$root" bash "$resolver" get configs 2>/dev/null)" || dir=""
    if [ -z "$dir" ]; then
      rel="$(cd -- "$root" && JENGA_PROJECT_ROOT="" bash "$resolver" --relative get configs 2>/dev/null)" || rel=""
      [ -z "$rel" ] || dir="$root/$rel"
    fi
  else
    dir="$(bash "$resolver" get configs 2>/dev/null)" || dir=""
  fi
  printf '%s' "$dir"
}

add_warning() {
  WARNINGS="${WARNINGS}$1"$'\n'
}

# Sets RECORDED, SOURCE and WARNINGS. Never fails.
read_recorded_default() {
  local dir cfg val
  RECORDED=""
  SOURCE="absent"
  WARNINGS=""
  dir="$(config_dir "$1")"
  [ -n "$dir" ] || return 0
  cfg="$dir/test-config.json"
  if [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then
    return 0
  fi
  # Classified in one jq pass: A = absent/null, V<value> = valid, I<json> = invalid.
  if [ ! -f "$cfg" ] || [ ! -r "$cfg" ] \
     || ! val="$(jq -r 'if type == "object"
                        then (.commit_prompt_default
                              | if . == null then "A"
                                elif type == "string" and (. == "" or . == "skip" or . == "scoped" or . == "full")
                                  then "V" + .
                                else "I" + tojson end)
                        else error("not an object") end' "$cfg" 2>/dev/null)"; then
    SOURCE="invalid"
    add_warning "test-config.json could not be read as a JSON object; treating commit_prompt_default as unset"
    return 0
  fi
  case "$val" in
    A) ;;
    V*)
      RECORDED="${val#V}"
      SOURCE="config"
      ;;
    I*)
      SOURCE="invalid"
      add_warning "test-config.json: commit_prompt_default is ${val#I}, expected \"\", \"skip\", \"scoped\" or \"full\"; treating it as unset"
      ;;
    *)
      SOURCE="invalid"
      add_warning "test-config.json could not be read as a JSON object; treating commit_prompt_default as unset"
      ;;
  esac
}

# emit <action> <choice|""> <reason>
emit() {
  jq -nc --arg action "$1" --arg choice "$2" --arg rec "$RECORDED" --arg src "$SOURCE" \
    --argjson ni "$NONINT" --arg reason "$3" --arg w "$WARNINGS" \
    '{action: $action,
      choice: (if $choice == "" then null else $choice end),
      recorded_default: $rec,
      default_source: $src,
      noninteractive: $ni,
      reason: $reason,
      warnings: ($w | split("\n") | map(select(. != "")))}'
}

cmd_resolve() {
  local tests="" caller="" inline=0 root="" tests_given=0 caller_given=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --tests) need_value "$1" $#; tests="$2"; tests_given=1; shift 2 ;;
      --caller) need_value "$1" $#; caller="$2"; caller_given=1; shift 2 ;;
      --inline) inline=1; shift ;;
      --root) need_value "$1" $#; root="$2"; shift 2 ;;
      *) usage_error "resolve: unknown argument '$1'" ;;
    esac
  done
  # Rule 0: validate enumerations (an explicit empty string is outside them).
  if [ "$tests_given" = "1" ]; then
    case "$tests" in
      ask|skip|scoped|full) ;;
      *) usage_error "--tests must be one of ask, skip, scoped, full (got '$tests')" ;;
    esac
  fi
  if [ "$caller_given" = "1" ]; then
    case "$caller" in
      interactive|noninteractive) ;;
      *) usage_error "--caller must be one of interactive, noninteractive (got '$caller')" ;;
    esac
  fi
  command -v jq >/dev/null 2>&1 || {
    printf '%s: jq is required but was not found on PATH\n' "$SCRIPT_NAME" >&2
    exit 1
  }

  read_recorded_default "$root"

  if [ "$caller" = "noninteractive" ] || [ "$inline" = "1" ] \
     || [ "${JENGA_COMMIT_INLINE:-}" = "1" ] || [ "${JENGA_COMMIT_NONINTERACTIVE:-}" = "1" ]; then
    NONINT="true"
    emit skip skip "non-interactive caller: tests are not run on an agent's behalf"
    return 0
  fi

  if [ -n "$tests" ]; then
    case "$tests" in
      ask) emit prompt "" "per-invocation override" ;;
      skip) emit skip skip "per-invocation override" ;;
      *) emit run "$tests" "per-invocation override" ;;
    esac
    return 0
  fi

  case "$RECORDED" in
    "") emit prompt "" "no recorded default" ;;
    skip) emit skip skip "recorded default" ;;
    *) emit run "$RECORDED" "recorded default" ;;
  esac
}

# ---- prompts ----------------------------------------------------------------------

cmd_prompt() {
  local def=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --default) need_value "$1" $#; check_default "$2"; def="$2"; shift 2 ;;
      *) usage_error "prompt: unknown argument '$1'" ;;
    esac
  done
  printf '%s\n' "Run tests before committing?"
  printf '%s\n' "1. Test covering committed scope (scoped run)"
  printf '%s\n' "2. Run j.test (full suite)"
  printf '%s\n' "3. Skip tests"
  if [ -n "$def" ]; then
    printf "%s\n" "Enter selection (1-3), 'default' or blank for the recorded default ($def):"
  else
    printf '%s\n' "Enter selection (1-3), or blank to skip:"
  fi
}

cmd_fallback_prompt() {
  local reason="" have=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) need_value "$1" $#; reason="$2"; have=1; shift 2 ;;
      *) usage_error "fallback-prompt: unknown argument '$1'" ;;
    esac
  done
  [ "$have" = "1" ] && [ -n "$reason" ] || usage_error "fallback-prompt requires a non-empty --reason"
  printf '%s\n' "$reason"
  printf '%s\n' "What would you like to do?"
  printf '%s\n' "1. Run j.test (full suite)"
  printf '%s\n' "2. Skip tests"
}

cmd_failure_prompt() {
  local failed="" kind="failed"
  while [ $# -gt 0 ]; do
    case "$1" in
      --failed) need_value "$1" $#; failed="$2"; shift 2 ;;
      --kind) need_value "$1" $#; kind="$2"; shift 2 ;;
      *) usage_error "failure-prompt: unknown argument '$1'" ;;
    esac
  done
  [ -n "$failed" ] || usage_error "failure-prompt requires a non-empty --failed"
  case "$kind" in
    failed) printf 'Tests failed: %s\n' "$failed" ;;
    error) printf 'Tests could not be run: %s\n' "$failed" ;;
    *) usage_error "--kind must be one of failed, error (got '$kind')" ;;
  esac
  printf '%s\n' "What would you like to do?"
  printf '%s\n' "1. Fix first (nothing is committed)"
  printf '%s\n' "2. Commit anyway (the failure is logged; the next commit is gated again)"
  printf '%s\n' "3. Abort the commit (nothing is committed)"
}

# ---- answers ----------------------------------------------------------------------

cmd_answer() {
  local raw="" def="" t
  if [ $# -gt 0 ]; then
    raw="$1"
    shift
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --default) need_value "$1" $#; check_default "$2"; def="$2"; shift 2 ;;
      *) usage_error "answer: unknown argument '$1'" ;;
    esac
  done
  t="$(norm "$raw")"
  case "$t" in
    1|scoped) printf 'scoped\n' ;;
    2|full) printf 'full\n' ;;
    3|skip) printf 'skip\n' ;;
    "")
      if [ -n "$def" ]; then
        printf '%s\n' "$def"
      else
        printf 'skip\n'
      fi
      ;;
    default)
      if [ -n "$def" ]; then
        printf '%s\n' "$def"
      else
        invalid_answer "$raw" "there is no recorded default; valid answers are 1-3 (scoped, full, skip), or blank to skip"
      fi
      ;;
    *)
      if [ -n "$def" ]; then
        invalid_answer "$raw" "valid answers are 1-3 (scoped, full, skip), 'default', or blank for the recorded default ($def)"
      else
        invalid_answer "$raw" "valid answers are 1-3 (scoped, full, skip), or blank to skip"
      fi
      ;;
  esac
}

cmd_fallback_answer() {
  local raw="" t
  if [ $# -gt 0 ]; then
    raw="$1"
    shift
  fi
  [ $# -eq 0 ] || usage_error "fallback-answer: unknown argument '$1'"
  t="$(norm "$raw")"
  case "$t" in
    1|full) printf 'full\n' ;;
    2|skip|"") printf 'skip\n' ;;
    *) invalid_answer "$raw" "valid answers are 1-2 (full, skip), or blank to skip" ;;
  esac
}

cmd_failure_answer() {
  local raw="" t
  if [ $# -gt 0 ]; then
    raw="$1"
    shift
  fi
  [ $# -eq 0 ] || usage_error "failure-answer: unknown argument '$1'"
  t="$(norm "$raw")"
  case "$t" in
    1|fix) printf 'fix\n' ;;
    2|anyway) printf 'anyway\n' ;;
    3|abort) printf 'abort\n' ;;
    "") invalid_answer "$raw" "the failure prompt has no default; valid answers are 1-3 (fix, anyway, abort)" ;;
    *) invalid_answer "$raw" "valid answers are 1-3 (fix, anyway, abort)" ;;
  esac
}

# ---- directive --------------------------------------------------------------------

cmd_directive() {
  local result="" choice="" have_choice=0
  [ $# -gt 0 ] || usage_error "directive requires a <result>"
  result="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --choice) need_value "$1" $#; choice="$2"; have_choice=1; shift 2 ;;
      *) usage_error "directive: unknown argument '$1'" ;;
    esac
  done
  case "$result" in
    passed|skipped|unavailable|failed|error|interrupted) ;;
    *) usage_error "directive: unknown result '$result' (expected passed, skipped, unavailable, failed, error or interrupted)" ;;
  esac
  if [ "$have_choice" = "1" ]; then
    case "$choice" in
      fix|anyway|abort) ;;
      *) usage_error "directive: --choice must be one of fix, anyway, abort (got '$choice')" ;;
    esac
  fi
  case "$result" in
    passed|skipped|unavailable)
      printf 'GATE=PROCEED\n'
      ;;
    failed|error)
      if [ "$choice" = "anyway" ]; then
        printf 'GATE=PROCEED\n'
      else
        printf 'GATE=HALT\n'
        exit 1
      fi
      ;;
    interrupted)
      printf 'GATE=HALT\n'
      exit 1
      ;;
  esac
}

# ---- dispatch ---------------------------------------------------------------------

[ $# -gt 0 ] || usage_error "a subcommand is required"
sub="$1"
shift
case "$sub" in
  --help|-h|help) usage ;;
  resolve) cmd_resolve "$@" ;;
  prompt) cmd_prompt "$@" ;;
  answer) cmd_answer "$@" ;;
  fallback-prompt) cmd_fallback_prompt "$@" ;;
  fallback-answer) cmd_fallback_answer "$@" ;;
  failure-prompt) cmd_failure_prompt "$@" ;;
  failure-answer) cmd_failure_answer "$@" ;;
  directive) cmd_directive "$@" ;;
  *) usage_error "unknown subcommand '$sub'" ;;
esac
