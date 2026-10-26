#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/run-compute.sh - run one `compute` step of a workflow run, with a timeout, and record the
# outcome (epic E80, task E80_S04_T03)
#
# A compute step names an allow-listed script (the step's `command`) and optional `args`. This script is the one
# place that executes it: it reads the step, confines the command, runs it from the project anchor under a
# watchdog, and records the result in the run state so that NO outcome leaves the step `in_progress`:
#   - success with conforming output  -> the verified (possibly normalised) output is stored, step `completed`
#   - non-zero exit, timeout, rejected command, bad fields, unresolvable reference, or an output that violates its
#     declared type -> the step is `failed`, the run is `failed`, and the reason is recorded.
# It writes only the step it was given. Steps that were completed earlier keep their status and outputs. It never
# sets or clears the pre-flight situation marker.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   run-compute.sh <run_id> <step_id>
#   run-compute.sh -h | --help          print this usage on stdout, exit 0
#
# STDOUT is one JSON line:
#   success:  {"status": "completed", "step_id": "<id>", "checkpoint": true|false}
#   failure:  {"status": "halted", "step_id": "<id>", "reason": "<why>"}
# The command's own stdout is captured (it becomes the step output), its stderr is passed to this script's stderr
# unchanged, and it gets no stdin (/dev/null). On a failure the reason is also printed on stderr.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  the command ran, exited 0, its output conformed (or the step declares none) and the step is `completed`
#   1  the step FAILED and the failure was recorded (step `failed`, run `failed`): non-zero exit
#      (`exited with code N`), `timed out after Ns`, a rejected command (resolve-compute-command.sh's message),
#      invalid `args` or `timeout_seconds`, an unresolvable ${...} reference, or an output type violation
#   2  nothing was run and nothing was written: usage error, invalid run or step id, the step is not in the run,
#      the step is not a `compute` step, the run is not `running`, or the step is not `pending`/`in_progress`
#   3  the run does not exist (passed through from step-state.sh)
#   4  the run state is corrupt or unreadable (passed through)
#   5  environment failure: jq missing, a lock not obtained, the output verifier could not run (the command HAS
#      run in that case and the step stays `in_progress`; fix the cause and run the step again), or a state write
#      failed
#
# ---------------------------------------------------------------------------
# WHAT IT DOES, IN ORDER
# ---------------------------------------------------------------------------
#   1. Reads the run (step-state.sh get) and refuses, with exit 2 and no write, unless the step exists, has
#      type `compute`, the run is `running`, and the step is `pending` or `in_progress`. A `pending` step is
#      moved to `in_progress` (this is the only write before the command runs).
#   2. Reads the step with its references substituted: resolve-refs.sh <run_id> <step_id> (E80_S03_T03). Fields:
#        command          string, one relative path (see resolve-compute-command.sh)
#        args             array of strings, default none
#        timeout_seconds  positive integer, default DEFAULT_TIMEOUT_SECONDS (the constant below)
#        outputs          declared outputs: [{name, kind, type}]
#      E80_S01's schema (templates/workflow-schema.json) names `command` and `args` exactly as above. It does not
#      list `timeout_seconds` for compute steps; the validator ignores unknown keys, so this script reads
#      `timeout_seconds` as the task specifies. Recorded in the E80_S04_T03 summary for a schema follow-up.
#   3. Resolves `command` with resolve-compute-command.sh (E80_S04_T02). A rejection fails the step with that
#      message before any process is started.
#   4. Runs the resolved script with the args, from the project anchor (scripts/resolve-root.sh root), under the
#      watchdog below.
#   5. Records the outcome (see RECORDING).
#
# ---------------------------------------------------------------------------
# TIMEOUT MECHANISM (macOS has no timeout(1); this is plain bash 3.2 plus kill/sleep)
# ---------------------------------------------------------------------------
#   - `set -m` (job control) is switched on while the command and the watcher are launched, so each background
#     job becomes the leader of its OWN process group (pgid == its pid). The command's stdout goes to a temporary
#     file; its stderr is inherited; its stdin is /dev/null.
#   - The watcher is a background subshell: sleep <timeout>; create a flag file; kill -TERM the command's whole
#     process group; sleep KILL_GRACE_SECONDS; kill -KILL the group.
#   - The main flow `wait`s for the command. A command that finishes first ends the race: the watcher's own group
#     is killed (so its `sleep` cannot linger), and the exit status is used as is. A command that was killed by
#     the watcher is reported as `timed out after Ns` (flag file present and a non-zero status).
#   - After the command is gone, the whole command group is sent KILL once more, so a background process the
#     command started and left behind does not outlive the step. Limit: a descendant that creates its own session
#     or process group (setsid, set -m) is outside the group and is not reached.
#
# ---------------------------------------------------------------------------
# RECORDING (the recorder interface)
# ---------------------------------------------------------------------------
#   The task text calls the recorder `complete-step.sh <run_id> <step_id> passed|failed <value|note>`. That script
#   (E80_S03_T08) does not exist yet. The recorder that does exist is the pair of primitives it will be built on,
#   and this script uses them directly, in two functions that are the only place to change when complete-step.sh
#   lands:
#       record_passed  <-> complete-step.sh passed   verify-output.sh per declared output, step-state.sh
#                                                    set-output, set-step completed, checkpoint
#       record_failed  <-> complete-step.sh failed   step-state.sh set-step failed, set-run-status failed
#   Normalisation and type checking are NOT reimplemented: verify-output.sh (which reuses the type registry,
#   templates/playbook-types.json, through validate-typed-object.sh) is the only judge, and the value stored is
#   the verified, normalised value it prints.
#     - No declared outputs: nothing is stored; a non-empty stdout is ignored with a note on stderr.
#     - One declared output: the whole stdout (trailing newlines removed by the capture) is the value.
#     - Several declared outputs: stdout must be one JSON object keyed by output name with exactly the declared
#       names; a string value is used as is, any other value as compact JSON.
#     - Every output is verified BEFORE any is stored, so a violation stores nothing.
#     - Publishing (E80_S06_T13): AFTER every value is stored and BEFORE the step is set `completed`, each declared
#       output is published to the workflow output registry with publish-output.sh, the helper complete-step.sh uses
#       for the same job (artifacts.sh register --replace): a `data` output is registered with its declared type, so
#       `artifacts.sh list`, `get` and `latest` return it once the run is completed; an `artifact` output only when
#       the value names an existing file. Only the passed path publishes: a non-zero exit, a timeout, a rejected
#       command, an unresolvable reference or an output type violation reaches record_failed and registers nothing.
#       A registration failure marks the step and the run failed with the registry message (exit 1, step not
#       completed), as complete-step.sh does. A re-run of the same run id swaps its own record (--replace).
#     - A step whose state entry has checkpoint true gets step-state.sh checkpoint after it is completed.
#   Where the failure reason lives: the state format has no per-step note, so the reason is written to the note of
#   the run's `-> failed` history entry as "step <step_id>: <reason>".
#
# Requires jq. Compatible with macOS bash 3.2 and safe under `set -u`.
# ---------------------------------------------------------------------------

set -u

# The default compute timeout, in seconds, used when a step has no `timeout_seconds`. The one place it is defined.
DEFAULT_TIMEOUT_SECONDS=60
# Seconds between the TERM and the KILL that the watcher sends to a command that outlived its timeout.
KILL_GRACE_SECONDS=1

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
STEP_STATE="$SELF_DIR/step-state.sh"
VERIFY_OUTPUT="$SELF_DIR/verify-output.sh"
RESOLVE_REFS="$SELF_DIR/resolve-refs.sh"
RESOLVE_COMMAND="$SELF_DIR/resolve-compute-command.sh"
RESOLVE_ROOT="$SELF_DIR/../resolve-root.sh"
PUBLISH_OUTPUT="$SELF_DIR/publish-output.sh"

# shellcheck source=run-state.sh
. "$SELF_DIR/run-state.sh"

RC_RUN_ID=""
RC_STEP_ID=""
RC_WORKFLOW_ID=""
TMP_DIR=""
CMD_PID=""
WATCH_PID=""

rc_err() { printf 'run-compute.sh: %s\n' "$*" >&2; }

rc_usage() {
  printf '%s\n' \
    "Usage: run-compute.sh <run_id> <step_id>" \
    "       run-compute.sh -h | --help" \
    "" \
    "Runs the compute step <step_id> of workflow run <run_id> with a timeout and records the outcome." \
    "Prints {\"status\": \"completed\"|\"halted\", \"step_id\": ...}. Exit: 0 completed, 1 step failed (recorded)," \
    "2 refused or usage error (nothing written), 3 run not found, 4 corrupt state, 5 environment failure."
}

# Kills a process group, quietly. $1 = leader pid, $2 = signal name.
rc_kill_group() {
  [ -n "$1" ] || return 0
  kill "-$2" -- "-$1" 2>/dev/null || true
}

rc_cleanup() {
  rc_kill_group "$WATCH_PID" KILL
  rc_kill_group "$CMD_PID" KILL
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap rc_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Prints $1 on one line (newlines and tabs become spaces) and limited to 600 characters.
rc_oneline() {
  local s
  s="$(printf '%s' "$1" | tr '\n\t' '  ')"
  if [ "${#s}" -gt 600 ]; then
    s="$(printf '%s' "$s" | cut -c1-600)..."
  fi
  printf '%s' "$s"
}

# record_failed <reason>: marks the step failed, the run failed, writes the reason to the failing history entry,
# prints the halted line on stdout and the reason on stderr, and exits 1 (5 when the state cannot be written).
record_failed() {
  local reason note
  reason="$(rc_oneline "$1")"
  note="step $RC_STEP_ID: $reason"
  if ! bash "$STEP_STATE" set-step "$RC_RUN_ID" "$RC_STEP_ID" failed >/dev/null; then
    rc_err "could not record step '$RC_STEP_ID' as failed (reason: $reason)"
    exit 5
  fi
  if ! bash "$STEP_STATE" set-run-status "$RC_RUN_ID" failed >/dev/null; then
    rc_err "could not set run '$RC_RUN_ID' to failed (step '$RC_STEP_ID' is failed; reason: $reason)"
    exit 5
  fi
  run_state_update "$RC_RUN_ID" '
    (.history | length) as $n
    | if $n > 0 and .history[$n - 1].to == "failed" then .history[$n - 1].note = $note else . end' \
    --arg note "$note" >/dev/null || rc_err "the failure note could not be written to the run history"
  rc_err "step '$RC_STEP_ID' failed: $reason"
  jq -n -c --arg id "$RC_STEP_ID" --arg r "$reason" '{status: "halted", step_id: $id, reason: $r}'
  exit 1
}

# record_passed <checkpoint true|false> <name> <kind> <type> <value> [<name> <kind> <type> <value> ...]: stores each
# (already verified) output, publishes it to the output registry through publish-output.sh (the logic complete-step.sh
# uses; E80_S06_T13), marks the step completed, sets the checkpoint when asked, prints the completed line, exits 0.
# Publishing comes after the values are stored and before the step is completed, as in complete-step.sh. A
# registration failure records the step (and the run) as failed with the registry message, exits 1, and leaves the
# step not completed. This function is only reached once every output is verified, so a failed step never registers.
record_passed() {
  local cp="$1" name kind type value i msg
  local -a PN PK PT PV
  shift
  PN=(); PK=(); PT=(); PV=()
  while [ "$#" -ge 4 ]; do
    name="$1"; kind="$2"; type="$3"; value="$4"
    shift 4
    if ! bash "$STEP_STATE" set-output "$RC_RUN_ID" "$RC_STEP_ID" "$name" "$value" >/dev/null; then
      rc_err "could not store output '$name' of step '$RC_STEP_ID'"
      exit 5
    fi
    PN+=("$name"); PK+=("$kind"); PT+=("$type"); PV+=("$value")
  done
  i=0
  while [ "$i" -lt "${#PN[@]}" ]; do
    if ! msg="$(bash "$PUBLISH_OUTPUT" "$RC_RUN_ID" "$RC_WORKFLOW_ID" "$RC_STEP_ID" "${PN[$i]}" "${PK[$i]}" "${PT[$i]}" "${PV[$i]}" 2>&1 >/dev/null)"; then
      record_failed "registry: output '${PN[$i]}' could not be registered: $msg"
    fi
    i=$((i + 1))
  done
  if ! bash "$STEP_STATE" set-step "$RC_RUN_ID" "$RC_STEP_ID" completed >/dev/null; then
    rc_err "could not record step '$RC_STEP_ID' as completed"
    exit 5
  fi
  if [ "$cp" = "true" ]; then
    if ! bash "$STEP_STATE" checkpoint "$RC_RUN_ID" "$RC_STEP_ID" >/dev/null; then
      rc_err "could not write the checkpoint for step '$RC_STEP_ID'"
      exit 5
    fi
  fi
  jq -n -c --arg id "$RC_STEP_ID" --argjson cp "$cp" '{status: "completed", step_id: $id, checkpoint: $cp}'
  exit 0
}

rc_main() {
  local state state_rc stype sstatus rstatus cp step rc msg
  local command timeout raw_timeout script root outf flag timed_out out
  local nout i oname otype okind value vout vr names_json extra
  local -a ARGS NAMES VALUES KINDS TYPES

  case "${1-}" in
    -h|--help)
      if [ "$#" -eq 1 ]; then
        rc_usage
        exit 0
      fi
      ;;
  esac
  if [ "$#" -ne 2 ]; then
    rc_usage >&2
    exit 2
  fi
  RC_RUN_ID="$1"
  RC_STEP_ID="$2"
  if [ -z "$RC_RUN_ID" ] || [ -z "$RC_STEP_ID" ] || [ "${RC_RUN_ID#-}" != "$RC_RUN_ID" ] || [ "${RC_STEP_ID#-}" != "$RC_STEP_ID" ]; then
    rc_err "run id and step id must be non-empty and must not start with '-'"
    exit 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    rc_err "jq is required but was not found"
    exit 5
  fi

  # 1. Pre-checks: exit 2 (or the state's own status) and nothing written.
  state="$(bash "$STEP_STATE" get "$RC_RUN_ID")"
  state_rc=$?
  [ "$state_rc" -eq 0 ] || exit "$state_rc"
  RC_WORKFLOW_ID="$(printf '%s' "$state" | jq -r '.workflow_id // empty')"
  stype="$(printf '%s' "$state" | jq -r --arg s "$RC_STEP_ID" '[.steps[] | select(.id == $s)] | .[0].type // empty')"
  if [ -z "$stype" ]; then
    rc_err "run '$RC_RUN_ID' has no step '$RC_STEP_ID' (valid steps: $(printf '%s' "$state" | jq -r '[.steps[].id] | join(", ")'))"
    exit 2
  fi
  if [ "$stype" != "compute" ]; then
    rc_err "step '$RC_STEP_ID' is a '$stype' step; run-compute.sh only runs compute steps"
    exit 2
  fi
  rstatus="$(printf '%s' "$state" | jq -r '.status')"
  if [ "$rstatus" != "running" ]; then
    rc_err "run '$RC_RUN_ID' is $rstatus; a compute step only runs while the run is running"
    exit 2
  fi
  sstatus="$(printf '%s' "$state" | jq -r --arg s "$RC_STEP_ID" '[.steps[] | select(.id == $s)] | .[0].status')"
  case "$sstatus" in
    pending|in_progress) ;;
    *)
      rc_err "step '$RC_STEP_ID' is $sstatus; only a pending or in_progress step can be run"
      exit 2
      ;;
  esac
  cp="$(printf '%s' "$state" | jq -r --arg s "$RC_STEP_ID" '[.steps[] | select(.id == $s)] | .[0].checkpoint == true')"

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run-compute.XXXXXX")" || {
    rc_err "could not create a temporary directory"
    exit 5
  }
  if [ "$sstatus" = "pending" ]; then
    if ! bash "$STEP_STATE" set-step "$RC_RUN_ID" "$RC_STEP_ID" in_progress >/dev/null; then
      rc_err "could not move step '$RC_STEP_ID' to in_progress"
      exit 5
    fi
  fi

  # 2. The step, with references substituted. From here on every problem is recorded as a step failure.
  step="$(bash "$RESOLVE_REFS" "$RC_RUN_ID" "$RC_STEP_ID" 2>"$TMP_DIR/err")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    msg="$(cat "$TMP_DIR/err")"
    case "$rc" in
      3|4|5)
        rc_err "$msg"
        exit "$rc"
        ;;
      1) record_failed "a reference in the step could not be resolved: $msg" ;;
      *) record_failed "the step definition could not be read: $msg" ;;
    esac
  fi

  command="$(printf '%s' "$step" | jq -r 'if (.command | type) == "string" then .command else "" end')"
  raw_timeout="$(printf '%s' "$step" | jq -r 'if has("timeout_seconds") and .timeout_seconds != null then (.timeout_seconds | tojson) else "" end')"
  timeout="$DEFAULT_TIMEOUT_SECONDS"
  if [ -n "$raw_timeout" ]; then
    case "$raw_timeout" in
      ''|*[!0-9]*|0*) record_failed "invalid timeout_seconds $raw_timeout: it must be a positive integer" ;;
    esac
    timeout="$raw_timeout"
  fi
  if ! printf '%s' "$step" | jq -e '(.args // []) | (type == "array" and all(.[]; type == "string"))' >/dev/null 2>&1; then
    record_failed "invalid args: they must be an array of strings"
  fi
  ARGS=()
  while IFS= read -r -d '' value; do
    ARGS+=("$value")
  done < <(printf '%s' "$step" | jq -j '(.args // [])[] | (., "\u0000")')

  # 3. The allow-list. A rejection fails the step before any process is started.
  script="$(bash "$RESOLVE_COMMAND" "$command" 2>"$TMP_DIR/err")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    msg="$(cat "$TMP_DIR/err")"
    record_failed "command rejected: ${msg#Error: }"
  fi
  root="$(bash "$RESOLVE_ROOT" root 2>"$TMP_DIR/err")" || record_failed "the project anchor cannot be resolved: $(cat "$TMP_DIR/err")"
  [ -d "$root" ] || record_failed "the project anchor '$root' is not a directory"

  # 4. Run under the watchdog.
  outf="$TMP_DIR/stdout"
  flag="$TMP_DIR/timed-out"
  : > "$outf"
  set -m
  ( cd "$root" && exec "$script" ${ARGS[@]+"${ARGS[@]}"} ) >"$outf" </dev/null &
  CMD_PID=$!
  ( sleep "$timeout"; : > "$flag"; kill -TERM -- "-$CMD_PID" 2>/dev/null; sleep "$KILL_GRACE_SECONDS"; kill -KILL -- "-$CMD_PID" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
  WATCH_PID=$!
  set +m
  { wait "$CMD_PID"; } 2>/dev/null
  rc=$?
  rc_kill_group "$WATCH_PID" KILL
  { wait "$WATCH_PID"; } 2>/dev/null
  rc_kill_group "$CMD_PID" KILL
  timed_out=0
  if [ -e "$flag" ] && [ "$rc" -ne 0 ]; then
    timed_out=1
  fi
  WATCH_PID=""
  CMD_PID=""

  if [ "$timed_out" -eq 1 ]; then
    record_failed "timed out after ${timeout}s"
  fi
  if [ "$rc" -ne 0 ]; then
    record_failed "exited with code $rc"
  fi
  out="$(cat "$outf")"

  # 5. Verify every declared output before storing any.
  nout="$(printf '%s' "$step" | jq -r '(.outputs // []) | length')"
  NAMES=()
  VALUES=()
  KINDS=()
  TYPES=()
  if [ "$nout" -eq 0 ]; then
    if [ -n "$out" ]; then
      rc_err "step '$RC_STEP_ID' declares no outputs; its stdout is ignored"
    fi
  else
    if [ "$nout" -gt 1 ]; then
      names_json="$(printf '%s' "$step" | jq -c '[.outputs[].name]')"
      if ! printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1; then
        record_failed "step declares $nout outputs, so its stdout must be one JSON object keyed by output name"
      fi
      extra="$(printf '%s' "$out" | jq -r --argjson names "$names_json" 'keys - $names | join(", ")')"
      if [ -n "$extra" ]; then
        record_failed "stdout names undeclared output(s): $extra"
      fi
    fi
    i=0
    while [ "$i" -lt "$nout" ]; do
      oname="$(printf '%s' "$step" | jq -r --argjson i "$i" '.outputs[$i].name')"
      otype="$(printf '%s' "$step" | jq -r --argjson i "$i" '.outputs[$i].type')"
      okind="$(printf '%s' "$step" | jq -r --argjson i "$i" '.outputs[$i].kind // "data"')"
      if [ "$nout" -eq 1 ]; then
        value="$out"
      else
        if ! printf '%s' "$out" | jq -e --arg k "$oname" 'has($k)' >/dev/null 2>&1; then
          record_failed "output '$oname' is missing from the stdout JSON object"
        fi
        value="$(printf '%s' "$out" | jq -j --arg k "$oname" '.[$k] | if type == "string" then . else tojson end')"
      fi
      vout="$(bash "$VERIFY_OUTPUT" "$otype" "$value" 2>"$TMP_DIR/err")"
      vr=$?
      msg="$(cat "$TMP_DIR/err")"
      msg="${msg#verify-output.sh: }"
      case "$vr" in
        0)
          NAMES+=("$oname")
          VALUES+=("$vout")
          KINDS+=("$okind")
          TYPES+=("$otype")
          ;;
        1)
          record_failed "output '$oname' violates type '$otype': $msg"
          ;;
        *)
          rc_err "output '$oname' of step '$RC_STEP_ID' could not be verified (type '$otype'): $msg; the step stays in_progress"
          exit 5
          ;;
      esac
      i=$((i + 1))
    done
  fi

  # 6. Record.
  set -- "$cp"
  i=0
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    set -- "$@" "${NAMES[$i]}" "${KINDS[$i]}" "${TYPES[$i]}" "${VALUES[$i]}"
    i=$((i + 1))
  done
  record_passed "$@"
}

rc_main "$@"
