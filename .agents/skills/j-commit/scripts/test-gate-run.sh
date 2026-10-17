#!/usr/bin/env bash
################################################################################
# test-gate-run.sh - the execution half of the j.commit test gate (E72_S04_T03)
#
# Runs a selection of suites through skills/j-test/scripts/run-suites.sh, turns
# the outcome into one machine-readable result word and appends an audit event.
# It decides nothing about proceed or halt: that table is
# `test-gate-decide.sh directive <result> [--choice ...]` (E72_S04_T01). The
# selection comes either from the full catalog (`full`) or from
# test-gate-scoped.sh's plan (`scoped`, E72_S04_T02). It runs only the command
# strings the catalog declares (never an argument of its own) and never edits a
# j-test script.
#
# The j-test scripts are located next to this skill through BASH_SOURCE
# (../../j-test/scripts), so the script works from a checkout and from
# node_modules/@jenga-ai/agent/. scripts/resolve-root.sh and scripts/with-lock.sh
# are found the same way (checkout first, then node_modules/@jenga-ai/agent).
#
# Usage:
#   test-gate-run.sh full   --out-dir <dir> [--root <dir>] [--discovery-file <file>]
#   test-gate-run.sh scoped --plan <plan.json> [--root <dir>] [--out-dir <dir>]
#   test-gate-run.sh log    --action <action> [--choice <value>] [--reason <text>]
#                           [--failed <names>] [--caller <interactive|noninteractive>]
#                           [--root <dir>]
#   test-gate-run.sh --help
#
# full    Builds the runnable catalog once (build-catalog.sh, from
#         --discovery-file when given, else a discovery run) into
#         <out-dir>/catalog.json, then runs EVERY runnable suite, in catalog
#         order, through run-suites.sh. <out-dir> must be an existing directory.
#         With no runnable suite it runs nothing, prints the plain line
#           No runnable test suites were found; no tests were run.
#         and then the trailer with TEST_GATE_RESULT=unavailable, exit 3. An empty
#         run is never a pass.
# scoped  Reads the plan JSON (its `status`, `selection`, `catalog_file`). Only
#         `status: mapped` runs: the plan's `selection`, against the plan's own
#         `catalog_file`, through `run-suites.sh --catalog`. A plan whose status is
#         `zero` or `error`, an unreadable plan, a plan without a usable selection
#         and a `catalog_file` that is missing or unreadable are all REFUSED:
#         exit 2, one message on stderr, nothing run and NO TEST_GATE_ line (the
#         skill then offers the full suite or skip). run.log goes to --out-dir,
#         default the directory holding the plan.
# log     Appends one `commit_test_gate` event to events.json (below).
#
# RUN BEHAVIOUR (full and scoped). run-suites.sh's stdout and stderr are streamed
# to this script's stdout and stderr as they are produced, and are also appended
# to <out-dir>/run.log (truncated at the start of each run; stdout and stderr are
# two streams, so their relative order in the file is not guaranteed). The copy is
# made through two private FIFOs and `tee`, not a pipeline: the run's own exit
# code reaches this script directly, so capturing output can never mask a failing
# suite. A suite that exits 127 or prints nothing is a failure like any other.
# After the run, the LAST TWO lines of stdout are:
#
#   TEST_GATE_RESULT=passed|failed|error|interrupted|unavailable
#   TEST_GATE_FAILED=<names of failed suites joined by ';', empty when none>
#
# Result words, from run-suites.sh's exit code (also this script's own exit code,
# except where noted):
#   0   -> passed        exit 0
#   1   -> failed        exit 1
#   130 -> interrupted   exit 130 (SIGINT/SIGTERM sent to this script is forwarded
#                        to run-suites.sh as SIGTERM, which stops the running suite)
#   2 or any other -> error, exit 2: the run could not execute or validate (a
#                        selection run-suites.sh refused, a catalog that cannot be
#                        built). A catalog `full` could not build is `error` too.
#   (full only, no runnable suite) -> unavailable, exit 3
# The failed names are read from the `✗ <name> (<type>)` lines of the last
# `Test Results` block, never from stderr: the k-th status line of the block is
# the k-th selected suite, so a failed line resolves to the catalog's own `name`
# (a name containing `;` is not escaped). With `failed` and no parsable line,
# TEST_GATE_FAILED is `unknown suite`, never empty. Names found on an
# `interrupted` or `error` run are reported as they are.
# Exit 2 has two meanings that the caller tells apart by the result line: with
# `TEST_GATE_RESULT=error` the run was attempted and could not execute; with no
# TEST_GATE_ line at all (a refused plan, a usage error) it was never attempted.
#
# EVENTS (`log`). One event is appended to the `events.json` inside the logs
# directory (`scripts/resolve-root.sh get logs`; with --root <dir> the lookup is
# anchored at <dir>):
#   {"event":"commit_test_gate","agent":"j.commit","action":"<action>",
#    "choice":<string|null>,"reason":<string|null>,"failed_suites":[...],
#    "caller":<"interactive"|"noninteractive"|null>,"date":"<UTC ISO 8601>"}
#   --action   required: skip passed failed error override halt fallback
#              unavailable interrupted
#   --choice / --reason   free text, an empty value is null
#   --failed   `;`-separated names -> failed_suites (empty items dropped, absent -> [])
#   --caller   interactive | noninteractive, absent -> null
# The whole read-modify-write runs under `with-lock.sh <events.json> -- bash -c
# ...` (the pattern of hooks/on_session_end.sh): a `mktemp` file in the SAME
# directory, then an atomic `mv`. A missing or empty events.json becomes a
# one-element array. A file that is not exactly one JSON array is left untouched
# and the call fails (exit 1). `log` writes nothing else: in particular it never
# writes test-config.json, so a failure choice is never persisted.
#
# EXIT CODES
#   0    run: passed.  log: the event was appended.
#   1    run: failed.  log: the append failed (events.json not a JSON array, not
#        writable, jq missing); nothing was written.
#   2    usage error, a refused scoped plan, or a run that could not execute
#        (see the note on the result line above)
#   3    full: no runnable suite (unavailable)
#   4    log: the lock was not acquired within the timeout; nothing was written
#   130  interrupted
#
# Constraints: macOS bash 3.2 compatible (no associative arrays, no mapfile, no
# case-modifying expansions). LC_ALL is NOT exported here, because run-suites.sh
# hands the caller's locale to the suites; only this script's own text tools run
# under LC_ALL=C. Requires jq, mkfifo, tee and awk.
################################################################################

set -u

SCRIPT_NAME="test-gate-run.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-commit/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
JTEST_DIR="$SCRIPT_DIR/../../j-test/scripts"

ACTIONS=" skip passed failed error override halt fallback unavailable interrupted "
NO_SUITES_LINE="No runnable test suites were found; no tests were run."

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

usage_text() {
  cat <<'EOF'
Usage: test-gate-run.sh full   --out-dir <dir> [--root <dir>] [--discovery-file <file>]
       test-gate-run.sh scoped --plan <plan.json> [--root <dir>] [--out-dir <dir>]
       test-gate-run.sh log    --action <skip|passed|failed|error|override|halt|fallback|unavailable|interrupted>
                               [--choice <value>] [--reason <text>] [--failed <names>]
                               [--caller <interactive|noninteractive>] [--root <dir>]
       test-gate-run.sh --help

Exit: 0 passed / logged, 1 failed / log failed, 2 usage, refused plan or run could
      not execute, 3 no runnable suite, 4 lock timeout (log), 130 interrupted
EOF
}

usage_error() {
  err "$1"
  usage_text >&2
  exit 2
}

need_value() {
  # need_value <flag> <argc>: the flag needs one more argument.
  [ "$2" -ge 2 ] || usage_error "$1 needs a value"
}

# Checkout first, then the installed-package location.
find_script() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# ---- the run -------------------------------------------------------------------

TMP_DIR=""
# shellcheck disable=SC2329  # invoked indirectly, through the EXIT trap in run_selection
cleanup() {
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}

SIGNALLED=0
RS_PID=""
# shellcheck disable=SC2329  # invoked indirectly, through the INT/TERM trap below
on_signal() {
  SIGNALLED=1
  [ -z "$RS_PID" ] || kill -TERM "$RS_PID" 2>/dev/null || true
}

# Prints the status lines (✓/✗/-) of the LAST `Test Results` block of a log.
result_block() {
  LC_ALL=C awk '
    /^Test Results$/ { buf = ""; state = 1; next }
    state == 1 { state = 2; next }
    state == 2 { if ($0 == "") { state = 3; next } buf = buf $0 "\n"; next }
    END { printf "%s", buf }
  ' "$1"
}

# emit_result <result> [<failed>]: the two trailer lines.
emit_result() {
  printf 'TEST_GATE_RESULT=%s\n' "$1"
  printf 'TEST_GATE_FAILED=%s\n' "${2:-}"
}

# run_selection <catalog> <out-dir> <root-or-empty> <n>...
# Runs the selection, prints the trailer, exits with the mapped code.
run_selection() {
  local catalog="$1" outdir="$2" root="$3" log rc=0 result code failed="" runner
  shift 3
  runner="$JTEST_DIR/run-suites.sh"
  [ -f "$runner" ] || { err "run-suites.sh not found next to this skill: $runner"; emit_result error; exit 2; }
  log="$outdir/run.log"
  : > "$log" 2>/dev/null || { err "cannot write $log"; emit_result error; exit 2; }

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-gate-run.XXXXXX")" \
    || { err "cannot create a scratch directory under ${TMPDIR:-/tmp}"; emit_result error; exit 2; }
  trap cleanup EXIT
  mkfifo "$TMP_DIR/out" "$TMP_DIR/err" \
    || { err "mkfifo failed"; emit_result error; exit 2; }

  local tee_out tee_err
  tee -a "$log" < "$TMP_DIR/out" &
  tee_out=$!
  tee -a "$log" >&2 < "$TMP_DIR/err" &
  tee_err=$!

  trap on_signal INT TERM
  if [ -n "$root" ]; then
    bash "$runner" --catalog "$catalog" --root "$root" "$@" > "$TMP_DIR/out" 2> "$TMP_DIR/err" &
  else
    bash "$runner" --catalog "$catalog" "$@" > "$TMP_DIR/out" 2> "$TMP_DIR/err" &
  fi
  RS_PID=$!

  # `wait` returns early (128+n) when a trapped signal arrives; the handler has
  # already told run-suites.sh to stop, so keep waiting for its real status.
  while :; do
    rc=0
    wait "$RS_PID" || rc=$?
    kill -0 "$RS_PID" 2>/dev/null || break
  done
  RS_PID=""
  # Both tees finish once run-suites.sh's write ends are closed.
  wait "$tee_out" "$tee_err" 2>/dev/null || true
  # A signal during the trailer must not cut it short.
  trap '' INT TERM

  case "$rc" in
    0) result="passed"; code=0 ;;
    1) result="failed"; code=1 ;;
    130) result="interrupted"; code=130 ;;
    *)
      if [ "$SIGNALLED" -eq 1 ] && [ "$rc" -ge 128 ]; then
        result="interrupted"; code=130
      else
        result="error"; code=2
      fi
      ;;
  esac

  failed="$(failed_names "$catalog" "$log" "$@")"
  if [ "$result" = "failed" ] && [ -z "$failed" ]; then
    failed="unknown suite"
  fi
  [ "$result" != "error" ] || err "run-suites.sh exited $rc: the selection could not be run"

  emit_result "$result" "$failed"
  exit "$code"
}

# failed_names <catalog> <log> <n>...: the names of the suites the last Test Results
# block marks failed, joined by ';'. The k-th status line is the k-th selected suite.
failed_names() {
  local catalog="$1" log="$2" k=0 line text name sel_json joined="" count_lines=0 count_names=0
  local lines=() names=()
  shift 2
  while IFS= read -r line; do
    lines+=("$line")
    count_lines=$((count_lines + 1))
  done <<EOF
$(result_block "$log")
EOF
  # the here-document above always yields one (possibly empty) line
  if [ "$count_lines" -eq 1 ] && [ -z "${lines[0]}" ]; then
    return 0
  fi

  sel_json="$(printf '%s\n' "$@" | jq -R 'tonumber? // empty' | jq -cs '.' 2>/dev/null)" || sel_json="[]"
  while IFS= read -r name; do
    names+=("$name")
    count_names=$((count_names + 1))
  done <<EOF
$(jq -r --argjson sel "${sel_json:-[]}" \
    '. as $c | $sel[] as $n | ([$c.runnable[]? | select(.n == $n)] | first | (.name // .id // "suite \($n)") | tostring)' \
    "$catalog" 2>/dev/null)
EOF

  k=0
  while [ "$k" -lt "$count_lines" ]; do
    line="${lines[$k]}"
    case "$line" in
      "✗ "*)
        text="${line#✗ }"
        if [ "$count_lines" -eq "$count_names" ] && [ -n "${names[$k]}" ]; then
          name="${names[$k]}"
        else
          # Fall back to the label: drop one trailing ` (type)`.
          case "$text" in
            *" ("*")") name="${text% (*)}" ;;
            *) name="$text" ;;
          esac
        fi
        if [ -z "$joined" ]; then joined="$name"; else joined="$joined;$name"; fi
        ;;
    esac
    k=$((k + 1))
  done
  printf '%s' "$joined"
}

# ---- full ----------------------------------------------------------------------

cmd_full() {
  local outdir="" root="" disc="" catalog builder n count
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out-dir) need_value "$1" $#; outdir="$2"; shift 2 ;;
      --root) need_value "$1" $#; root="$2"; shift 2 ;;
      --discovery-file) need_value "$1" $#; disc="$2"; shift 2 ;;
      *) usage_error "full: unknown argument '$1'" ;;
    esac
  done
  [ -n "$outdir" ] || usage_error "full: --out-dir <dir> is required"
  [ -d "$outdir" ] || usage_error "full: --out-dir is not an existing directory: $outdir"
  [ -z "$root" ] || [ -d "$root" ] || usage_error "full: --root is not a directory: $root"
  command -v jq >/dev/null 2>&1 || { err "jq is required but was not found on PATH"; emit_result error; exit 2; }

  builder="$JTEST_DIR/build-catalog.sh"
  [ -f "$builder" ] || { err "build-catalog.sh not found next to this skill: $builder"; emit_result error; exit 2; }
  catalog="$outdir/catalog.json"

  local bargs=()
  [ -z "$root" ] || bargs+=(--root "$root")
  [ -z "$disc" ] || bargs+=(--discovery-file "$disc")
  if ! bash "$builder" ${bargs[@]+"${bargs[@]}"} > "$catalog"; then
    err "build-catalog.sh failed; the catalog could not be built"
    emit_result error
    exit 2
  fi
  if ! jq -e 'type == "object" and (.runnable | type == "array")' "$catalog" >/dev/null 2>&1; then
    err "build-catalog.sh printed no usable catalog"
    emit_result error
    exit 2
  fi

  count="$(jq -r '.runnable | length' "$catalog")"
  if [ "$count" -eq 0 ]; then
    printf '%s\n' "$NO_SUITES_LINE"
    emit_result unavailable
    exit 3
  fi

  local nums=()
  while IFS= read -r n; do
    nums+=("$n")
  done <<EOF
$(jq -r '.runnable[].n' "$catalog")
EOF
  run_selection "$catalog" "$outdir" "$root" "${nums[@]}"
}

# ---- scoped --------------------------------------------------------------------

cmd_scoped() {
  local plan="" root="" outdir="" status catalog n
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan) need_value "$1" $#; plan="$2"; shift 2 ;;
      --root) need_value "$1" $#; root="$2"; shift 2 ;;
      --out-dir) need_value "$1" $#; outdir="$2"; shift 2 ;;
      *) usage_error "scoped: unknown argument '$1'" ;;
    esac
  done
  [ -n "$plan" ] || usage_error "scoped: --plan <plan.json> is required"
  [ -z "$root" ] || [ -d "$root" ] || usage_error "scoped: --root is not a directory: $root"
  command -v jq >/dev/null 2>&1 || { err "jq is required but was not found on PATH"; exit 2; }

  if [ ! -f "$plan" ] || [ ! -r "$plan" ] || ! jq -e 'type == "object"' "$plan" >/dev/null 2>&1; then
    err "the plan is not a readable JSON object: $plan; no tests were run"
    exit 2
  fi
  status="$(jq -r '.status // "" | tostring' "$plan")"
  if [ "$status" != "mapped" ]; then
    err "the plan's status is '${status:-missing}', not 'mapped': no scoped run was made and no tests were run"
    exit 2
  fi
  if ! jq -e '(.selection | type == "array") and (.selection | length > 0) and (.selection | all(type == "number" and . >= 1 and . == floor))' \
      "$plan" >/dev/null 2>&1; then
    err "the plan has no usable selection (a non-empty array of suite numbers); no tests were run"
    exit 2
  fi
  catalog="$(jq -r '.catalog_file // "" | if type == "string" then . else "" end' "$plan")"
  if [ -z "$catalog" ] || [ ! -f "$catalog" ] || [ ! -r "$catalog" ]; then
    err "the plan's catalog_file is missing or unreadable: ${catalog:-null}; no tests were run"
    exit 2
  fi
  [ -n "$outdir" ] || outdir="$(cd -- "$(dirname -- "$plan")" && pwd)"
  [ -d "$outdir" ] || usage_error "scoped: --out-dir is not an existing directory: $outdir"

  local nums=()
  while IFS= read -r n; do
    nums+=("$n")
  done <<EOF
$(jq -r '.selection[] | floor' "$plan")
EOF
  run_selection "$catalog" "$outdir" "$root" "${nums[@]}"
}

# ---- log -----------------------------------------------------------------------

# The locked read-modify-write, run through `bash -c` with positional arguments
# (never interpolated into the script text), as hooks/on_session_end.sh does.
APPEND_EVENT_SCRIPT=$(cat <<'EOS'
events_log="$1"
entry="$2"
tmp_file=$(mktemp "$(dirname "$events_log")/events_tmp.XXXXXX") || exit 1
trap 'rm -f "$tmp_file"' EXIT
if [ -s "$events_log" ]; then
  jq -s --argjson e "$entry" \
    'if length == 1 and (.[0] | type == "array") then .[0] + [$e] else error("events.json is not a single JSON array") end' \
    "$events_log" > "$tmp_file" || exit 1
else
  jq -n --argjson e "$entry" '[$e]' > "$tmp_file" || exit 1
fi
[ -s "$tmp_file" ] || exit 1
mv "$tmp_file" "$events_log" || exit 1
EOS
)

# Prints the logs directory, or nothing when it cannot be resolved.
logs_dir() {
  local root_arg="$1" resolver root dir="" rel=""
  resolver="$(find_script scripts/resolve-root.sh)" || return 0
  if [ -n "$root_arg" ]; then
    # --root was validated by cmd_log (a usage_error here would only leave this subshell).
    root="$(cd -- "$root_arg" 2>/dev/null && pwd)" || return 0
    dir="$(JENGA_PROJECT_ROOT="$root" bash "$resolver" get logs 2>/dev/null)" || dir=""
    if [ -z "$dir" ]; then
      rel="$(cd -- "$root" && JENGA_PROJECT_ROOT="" bash "$resolver" --relative get logs 2>/dev/null)" || rel=""
      [ -z "$rel" ] || dir="$root/$rel"
    fi
  else
    dir="$(bash "$resolver" get logs 2>/dev/null)" || dir=""
  fi
  printf '%s' "$dir"
}

cmd_log() {
  local action="" choice="" reason="" failed="" caller="" root="" dir events entry date_now rc=0 locker
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --action) need_value "$1" $#; action="$2"; shift 2 ;;
      --choice) need_value "$1" $#; choice="$2"; shift 2 ;;
      --reason) need_value "$1" $#; reason="$2"; shift 2 ;;
      --failed) need_value "$1" $#; failed="$2"; shift 2 ;;
      --caller) need_value "$1" $#; caller="$2"; shift 2 ;;
      --root) need_value "$1" $#; root="$2"; shift 2 ;;
      *) usage_error "log: unknown argument '$1'" ;;
    esac
  done
  [ -n "$action" ] || usage_error "log: --action is required"
  case "$ACTIONS" in
    *" $action "*) ;;
    *) usage_error "log: unknown action '$action' (valid:${ACTIONS% })" ;;
  esac
  case "$caller" in
    ""|interactive|noninteractive) ;;
    *) usage_error "log: --caller must be interactive or noninteractive, not '$caller'" ;;
  esac
  command -v jq >/dev/null 2>&1 || { err "jq is required but was not found on PATH"; exit 1; }

  [ -z "$root" ] || [ -d "$root" ] || usage_error "log: --root is not a directory: $root"
  dir="$(logs_dir "$root")"
  [ -n "$dir" ] || { err "could not resolve the logs directory"; exit 1; }
  mkdir -p -- "$dir" 2>/dev/null || { err "cannot create the logs directory: $dir"; exit 1; }
  events="$dir/events.json"

  date_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  entry="$(jq -cn --arg action "$action" --arg choice "$choice" --arg reason "$reason" \
      --arg failed "$failed" --arg caller "$caller" --arg date "$date_now" '
    {event: "commit_test_gate", agent: "j.commit", action: $action,
     choice: (if $choice == "" then null else $choice end),
     reason: (if $reason == "" then null else $reason end),
     failed_suites: ($failed | split(";") | map(select(length > 0))),
     caller: (if $caller == "" then null else $caller end),
     date: $date}')" || { err "could not build the event"; exit 1; }

  locker="$(find_script scripts/with-lock.sh)" || { err "scripts/with-lock.sh not found; the event was not written"; exit 1; }
  bash "$locker" "$events" -- bash -c "$APPEND_EVENT_SCRIPT" _ "$events" "$entry" || rc=$?
  case "$rc" in
    0) exit 0 ;;
    2) err "could not acquire the lock on $events; the event was not written"; exit 4 ;;
    *) err "could not append to $events (it must be a single JSON array); nothing was written"; exit 1 ;;
  esac
}

# ---- dispatch ------------------------------------------------------------------

[ "$#" -ge 1 ] || usage_error "a subcommand is required (full, scoped or log)"
sub="$1"
shift
case "$sub" in
  --help|-h) usage_text; exit 0 ;;
  full) cmd_full "$@" ;;
  scoped) cmd_scoped "$@" ;;
  log) cmd_log "$@" ;;
  *) usage_error "unknown subcommand: $sub" ;;
esac
