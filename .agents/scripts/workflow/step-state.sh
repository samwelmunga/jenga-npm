#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/step-state.sh - step-level state primitives for workflow runs (epic E80, task E80_S03_T01)
#
# The one place that changes a workflow run at step granularity: which step is current, a step's status and
# outputs, the run's status for the few transitions story E80_S03 needs, the pending confirmation gate and the
# last checkpoint. The dispatcher and executors of E80_S03 (next-step, complete-step, the confirmation gate)
# call these subcommands instead of editing the state file themselves.
#
# It is a layer over scripts/workflow/run-state.sh (E80_S02), which is sourced and not edited. The state file
# format, its location, the corrupt-file rules and the lock/atomic-write behaviour are all run-state.sh's:
#   - location:  <workflow_runs>/<run_id>.json, from "scripts/resolve-root.sh get workflow_runs" (through
#                run-state.sh). This script names no working-file tree directory itself.
#   - format:    schema_version 1, twelve required top-level keys, steps[] with id, type, checkpoint, status,
#                started_at, finished_at, outputs. See the header of run-state.sh, the single source of truth.
#   - writes:    every write goes through run_state_update: under scripts/with-lock.sh on the state file, the
#                result written to a temporary file in the same directory, re-validated, then renamed over the
#                state file (temp file then mv). A lock not obtained within WITH_LOCK_TIMEOUT_SECONDS (default 30)
#                aborts with exit 5 and writes nothing; the file stays byte-identical. A filter or result that
#                run-state.sh rejects leaves the file byte-identical too.
#   - reads:     a missing file is exit 3, an unreadable, empty, non-JSON, wrong-shape or wrong-version file is
#                exit 4, on every subcommand. A corrupt file is never printed and never modified.
#
# ---------------------------------------------------------------------------
# COMMANDS (every command takes <run_id> first; ids follow run-state.sh's rules)
# ---------------------------------------------------------------------------
#   step-state.sh get <run_id>
#       Prints the run's state JSON (pretty, keys sorted), exactly as run-state.sh status does.
#   step-state.sh current-step <run_id>
#       Prints the id of the first step, in definition order, whose status is neither completed nor skipped.
#       It never moves past a failed step: a failed step is itself the current step. Prints nothing and exits 0
#       when every step is completed or skipped.
#   step-state.sh set-step <run_id> <step_id> <status>
#       status is one of pending, in_progress, completed, failed, skipped. Timestamps use the step's own fields:
#       in_progress sets started_at to now and clears finished_at (so a retry restarts the clock); completed,
#       failed and skipped set finished_at to now and leave started_at as it was; pending clears both. Any
#       status may follow any other; ordering rules belong to the dispatcher. Does not touch the run's status or
#       history. An unknown step id or an unknown status is exit 2.
#   step-state.sh set-output <run_id> <step_id> <output_name> <value>
#       Stores <value> as a string in steps[].outputs[<output_name>] of that step (the slot run-state.sh
#       reserves), replacing an earlier value of the same name. <output_name> must not be empty; <value> may be.
#       Typed verification of the value is the caller's job (verify-output.sh).
#   step-state.sh get-output <run_id> <step_id> <output_name>
#       Prints the stored value on stdout (a string as is, anything else as compact JSON). Refuses, with
#       nothing on stdout and the cause on stderr, when the step is skipped ("skipped: it produces no output"),
#       when the step failed ("failed: its outputs are not available") and when the step has no output of that
#       name. Exit 1 in each case; never an empty success.
#   step-state.sh set-run-status <run_id> <status>
#       Moves the run's status. Only these transitions are allowed:
#           running -> awaiting_confirmation      awaiting_confirmation -> running
#           running -> failed                     running -> completed
#       Any other transition (including to the same status) is refused with exit 1; a status that is not one of
#       running, paused, awaiting_confirmation, failed, completed, cancelled is exit 2. A successful transition
#       appends {"at", "from", "to", "note"} to history, with note "step-state set-run-status". Pausing,
#       resuming and cancelling a run are run-state.sh's commands, not this one.
#   step-state.sh set-gate <run_id> <step_id> <json>
#       Persists the pending confirmation gate record. <json> is one valid JSON document other than null (the
#       gate's prompt and options, as the gate executor defines them). It is stored under a top-level key
#       "pending_gate" as {"step_id": "<step_id>", "created_at": "<UTC ISO 8601>", "gate": <json>}. A gate that
#       is already pending is replaced. Invalid or null JSON, or an unknown step, is exit 2.
#   step-state.sh get-gate <run_id>
#       Prints the pending_gate record (pretty, keys sorted). Exit 1 with nothing on stdout when no gate is
#       pending.
#   step-state.sh clear-gate <run_id>
#       Removes the pending_gate key. Idempotent: with no gate pending it exits 0 and does not write.
#   step-state.sh checkpoint <run_id> <step_id>
#       Sets last_checkpoint to <step_id>, only when that step's status is completed and its checkpoint field
#       (copied from the workflow definition when the run started) is true. Otherwise exit 1 and nothing
#       changes. An unknown step is exit 2.
#   step-state.sh -h | --help
#       Prints the usage text on stdout, exit 0.
#   No arguments, a wrong number of arguments or an unknown command: usage on stderr, exit 2.
#
# ---------------------------------------------------------------------------
# THE pending_gate KEY (a deliberate extension of the format)
# ---------------------------------------------------------------------------
# The run-state.sh format has no place for a pending gate. This script adds one optional top-level key,
# "pending_gate", rather than overloading a step's outputs or the history. run-state.sh's validation requires its
# twelve named keys and does not reject others, so a file with pending_gate is still a valid state file for
# run-state.sh status, list, and every later reader; the key is simply absent when no gate is pending (clear-gate
# deletes it, it is not set to null). A file that this script never wrote a gate to is byte-for-byte what
# run-state.sh produced. Readers that ignore unknown keys need no change.
#
# ---------------------------------------------------------------------------
# CHECKS AND RACES
# ---------------------------------------------------------------------------
# Each write first checks its preconditions against a read of the file, to give a precise message and exit code,
# and then repeats the same rule as a guard inside the jq filter, so it is re-evaluated under the lock. A
# concurrent writer can therefore never cause an illegal write; in that rare race the refusal comes from the
# store as exit 2 instead of exit 1 (the file is unchanged either way).
#
# ---------------------------------------------------------------------------
# EXIT CODES (the first six match run-state.sh)
# ---------------------------------------------------------------------------
#   0  ok
#   1  refused: illegal run transition, checkpoint precondition not met, or get-output / get-gate has nothing to
#      return (the cause is named on stderr)
#   2  usage error: bad argument or argument count, unknown step id, unknown status, invalid run id, invalid
#      gate JSON, or a rejected update
#   3  run not found
#   4  corrupt or unreadable state
#   5  lock timeout (nothing was written)
#
# Requires jq. Compatible with macOS bash 3.2 and safe under "set -u". Sourcing this file prints nothing, exits
# nothing and creates nothing; it also sources run-state.sh.
# ---------------------------------------------------------------------------

_SS_SELF="${BASH_SOURCE[0]}"
_SS_DIR="$(cd "$(dirname "$_SS_SELF")" && pwd)"

# run-state.sh defines run_state_read, run_state_update and run_state_path, and dispatches only when executed.
# shellcheck source=run-state.sh
. "$_SS_DIR/run-state.sh"

_SS_STEP_STATUSES="pending in_progress completed failed skipped"
_SS_RUN_STATUSES="running paused awaiting_confirmation failed completed cancelled"
# The only run transitions set-run-status performs, as "from>to". One list, shared by the pre-check and the guard.
_SS_RUN_TRANSITIONS='["running>awaiting_confirmation","awaiting_confirmation>running","running>failed","running>completed"]'

_ss_err() {
  printf '%s\n' "$*" >&2
}

_ss_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

_ss_usage_text() {
  cat <<'USAGE'
Usage: step-state.sh get <run_id>
       step-state.sh current-step <run_id>
       step-state.sh set-step <run_id> <step_id> <pending|in_progress|completed|failed|skipped>
       step-state.sh set-output <run_id> <step_id> <output_name> <value>
       step-state.sh get-output <run_id> <step_id> <output_name>
       step-state.sh set-run-status <run_id> <status>
       step-state.sh set-gate <run_id> <step_id> <json>
       step-state.sh get-gate <run_id>
       step-state.sh clear-gate <run_id>
       step-state.sh checkpoint <run_id> <step_id>
       step-state.sh -h | --help

  get             print the run's state JSON
  current-step    print the first step that is neither completed nor skipped (nothing when all are terminal)
  set-step        set a step's status and stamp its started_at / finished_at
  set-output      store a step output value
  get-output      print a step output value (refused for a skipped or failed step or a missing output)
  set-run-status  running <-> awaiting_confirmation, running -> failed, running -> completed only
  set-gate        persist the pending confirmation gate record
  get-gate        print the pending gate record (exit 1 when none)
  clear-gate      drop the pending gate record
  checkpoint      record last_checkpoint (step must be completed and have checkpoint: true)

Exit codes: 0 ok, 1 refused, 2 usage error, 3 run not found, 4 corrupt or unreadable state, 5 lock timeout.
USAGE
}

_ss_usage_fail() {
  _ss_usage_text >&2
  return 2
}

# True when $1 is one of the space-separated words in $2.
_ss_in() {
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Reads run $1 into _SS_STATE. Returns run_state_read's status (3 missing, 4 corrupt, 2 invalid id).
_ss_load() {
  _SS_STATE=""
  _SS_STATE=$(run_state_read "$1") || return $?
  return 0
}

# Requires step $1 in the loaded _SS_STATE. Exit 2 naming the known steps otherwise.
_ss_need_step() {
  local step="$1" known
  if [ -z "$step" ]; then
    _ss_err "step-state: empty step id"
    return 2
  fi
  if ! printf '%s' "$_SS_STATE" | jq -e --arg s "$step" '.steps | any(.[]; .id == $s)' >/dev/null 2>&1; then
    known=$(printf '%s' "$_SS_STATE" | jq -r '[.steps[].id] | join(", ")')
    _ss_err "step-state: unknown step '$step' (steps of this run: ${known:-none})"
    return 2
  fi
  return 0
}

# Prints field $2 of step $1 from the loaded _SS_STATE.
_ss_step_field() {
  printf '%s' "$_SS_STATE" | jq -r --arg s "$1" '.steps[] | select(.id == $s) | '"$2"' | if . == null then "" else tostring end'
}

# Writes through the store. Passes the store's status through (0, 2, 3, 4, 5).
_ss_update() {
  run_state_update "$@"
}

_ss_cmd_get() {
  [ "$#" -eq 1 ] || { _ss_usage_fail; return 2; }
  run_state_read "$1"
}

_ss_cmd_current_step() {
  [ "$#" -eq 1 ] || { _ss_usage_fail; return 2; }
  _ss_load "$1" || return $?
  printf '%s' "$_SS_STATE" | jq -r 'first(.steps[] | select(.status != "completed" and .status != "skipped") | .id) // empty'
}

_ss_cmd_set_step() {
  [ "$#" -eq 3 ] || { _ss_usage_fail; return 2; }
  local id="$1" step="$2" st="$3"
  if ! _ss_in "$st" "$_SS_STEP_STATUSES"; then
    _ss_err "step-state: illegal step status '$st' (allowed: pending, in_progress, completed, failed, skipped)"
    return 2
  fi
  _ss_load "$id" || return $?
  _ss_need_step "$step" || return $?
  _ss_update "$id" '
    if any(.steps[]; .id == $s) | not then error("unknown step " + $s) else . end
    | .steps |= map(if .id == $s then
        .status = $st
        | if $st == "in_progress" then .started_at = $now | .finished_at = null
          elif $st == "pending" then .started_at = null | .finished_at = null
          else .finished_at = $now end
      else . end)' \
    --arg s "$step" --arg st "$st" --arg now "$(_ss_now)"
}

_ss_cmd_set_output() {
  [ "$#" -eq 4 ] || { _ss_usage_fail; return 2; }
  local id="$1" step="$2" name="$3" value="$4"
  if [ -z "$name" ]; then
    _ss_err "step-state: empty output name"
    return 2
  fi
  _ss_load "$id" || return $?
  _ss_need_step "$step" || return $?
  _ss_update "$id" '
    if any(.steps[]; .id == $s) | not then error("unknown step " + $s) else . end
    | .steps |= map(if .id == $s then .outputs[$n] = $v else . end)' \
    --arg s "$step" --arg n "$name" --arg v "$value"
}

_ss_cmd_get_output() {
  [ "$#" -eq 3 ] || { _ss_usage_fail; return 2; }
  local id="$1" step="$2" name="$3" cause
  if [ -z "$name" ]; then
    _ss_err "step-state: empty output name"
    return 2
  fi
  _ss_load "$id" || return $?
  _ss_need_step "$step" || return $?
  cause=$(printf '%s' "$_SS_STATE" | jq -r --arg s "$step" --arg n "$name" '
    .steps[] | select(.id == $s)
    | if .status == "skipped" then "skipped"
      elif .status == "failed" then "failed"
      elif ((.outputs | type) == "object") and (.outputs | has($n)) then "ok"
      else "missing" end')
  case "$cause" in
    ok)
      printf '%s' "$_SS_STATE" | jq -r --arg s "$step" --arg n "$name" '
        .steps[] | select(.id == $s) | .outputs[$n] | if type == "string" then . else tojson end'
      ;;
    skipped)
      _ss_err "step-state: step '$step' is skipped: it produces no output, so '$name' is not available"
      return 1
      ;;
    failed)
      _ss_err "step-state: step '$step' failed: its outputs are not available, so '$name' cannot be read"
      return 1
      ;;
    *)
      _ss_err "step-state: step '$step' has no output named '$name' (missing output; step status: $(_ss_step_field "$step" .status))"
      return 1
      ;;
  esac
}

_ss_cmd_set_run_status() {
  [ "$#" -eq 2 ] || { _ss_usage_fail; return 2; }
  local id="$1" to="$2" from
  if ! _ss_in "$to" "$_SS_RUN_STATUSES"; then
    _ss_err "step-state: illegal run status '$to' (allowed: running, paused, awaiting_confirmation, failed, completed, cancelled)"
    return 2
  fi
  _ss_load "$id" || return $?
  from=$(printf '%s' "$_SS_STATE" | jq -r '.status')
  if ! printf '%s' "$_SS_RUN_TRANSITIONS" | jq -e --arg t "$from>$to" 'index($t) != null' >/dev/null; then
    _ss_err "step-state: refused transition of run '$id' from '$from' to '$to' (allowed: running -> awaiting_confirmation, awaiting_confirmation -> running, running -> failed, running -> completed)"
    return 1
  fi
  _ss_update "$id" '
    (.status + ">" + $to) as $t
    | if ($allowed | index($t)) == null then error("refused transition " + $t) else . end
    | .history += [{at: $now, from: .status, to: $to, note: "step-state set-run-status"}]
    | .status = $to' \
    --arg to "$to" --arg now "$(_ss_now)" --argjson allowed "$_SS_RUN_TRANSITIONS"
}

_ss_cmd_set_gate() {
  [ "$#" -eq 3 ] || { _ss_usage_fail; return 2; }
  local id="$1" step="$2" gate="$3"
  if ! printf '%s' "$gate" | jq -e -s 'length == 1 and .[0] != null' >/dev/null 2>&1; then
    _ss_err "step-state: the gate record is not one valid JSON document (or is null)"
    return 2
  fi
  _ss_load "$id" || return $?
  _ss_need_step "$step" || return $?
  _ss_update "$id" '
    if any(.steps[]; .id == $s) | not then error("unknown step " + $s) else . end
    | .pending_gate = {step_id: $s, created_at: $now, gate: $g}' \
    --arg s "$step" --arg now "$(_ss_now)" --argjson g "$gate"
}

_ss_cmd_get_gate() {
  [ "$#" -eq 1 ] || { _ss_usage_fail; return 2; }
  _ss_load "$1" || return $?
  if ! printf '%s' "$_SS_STATE" | jq -e 'has("pending_gate") and .pending_gate != null' >/dev/null; then
    _ss_err "step-state: run '$1' has no pending gate"
    return 1
  fi
  printf '%s' "$_SS_STATE" | jq -S '.pending_gate'
}

_ss_cmd_clear_gate() {
  [ "$#" -eq 1 ] || { _ss_usage_fail; return 2; }
  _ss_load "$1" || return $?
  if ! printf '%s' "$_SS_STATE" | jq -e 'has("pending_gate")' >/dev/null; then
    return 0
  fi
  _ss_update "$1" 'del(.pending_gate)'
}

_ss_cmd_checkpoint() {
  [ "$#" -eq 2 ] || { _ss_usage_fail; return 2; }
  local id="$1" step="$2" st cp
  _ss_load "$id" || return $?
  _ss_need_step "$step" || return $?
  st=$(_ss_step_field "$step" .status)
  cp=$(_ss_step_field "$step" .checkpoint)
  if [ "$st" != "completed" ]; then
    _ss_err "step-state: cannot checkpoint step '$step': its status is '$st', not 'completed'"
    return 1
  fi
  if [ "$cp" != "true" ]; then
    _ss_err "step-state: cannot checkpoint step '$step': its definition does not set checkpoint: true"
    return 1
  fi
  _ss_update "$id" '
    (first(.steps[] | select(.id == $s)) // error("unknown step " + $s)) as $st
    | if $st.status != "completed" or $st.checkpoint != true then error("step " + $s + " is not a completed checkpoint step") else . end
    | .last_checkpoint = $s' \
    --arg s "$step"
}

_ss_main() {
  local cmd="${1-}"
  if [ "$#" -eq 0 ]; then
    _ss_usage_fail
    return $?
  fi
  shift
  case "$cmd" in
    -h|--help) _ss_usage_text ;;
    get) _ss_cmd_get "$@" ;;
    current-step) _ss_cmd_current_step "$@" ;;
    set-step) _ss_cmd_set_step "$@" ;;
    set-output) _ss_cmd_set_output "$@" ;;
    get-output) _ss_cmd_get_output "$@" ;;
    set-run-status) _ss_cmd_set_run_status "$@" ;;
    set-gate) _ss_cmd_set_gate "$@" ;;
    get-gate) _ss_cmd_get_gate "$@" ;;
    clear-gate) _ss_cmd_clear_gate "$@" ;;
    checkpoint) _ss_cmd_checkpoint "$@" ;;
    *)
      _ss_err "step-state: unknown command '$cmd'"
      _ss_usage_fail
      ;;
  esac
}

# Dispatch only when executed, never when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _ss_main "$@"
  exit $?
fi
