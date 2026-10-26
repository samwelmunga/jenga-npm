#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/complete-step.sh - report the outcome of a workflow step (epic E80, task E80_S03_T08)
#
# How the driving agent reports what happened for a step that next-step.sh handed out (signal `step`, so the step
# is `in_progress`). `passed` verifies the step's typed outputs, stores them, completes the step and writes a
# checkpoint when the step asks for one. `failed` marks the step failed and halts the run: from then on
# next-step.sh returns `halted` until the run is explicitly resumed (run-state.sh resume). This script never
# resets a failed run itself.
#
# It composes the sibling scripts and holds no state logic of its own:
#   step-state.sh      get, set-output, set-step, checkpoint
#   verify-output.sh   checks a value against a playbook type and returns the normalised value
#   load-workflows.sh  lookup <workflow_id>: the step's declared `outputs` (name, kind, type)
#   publish-output.sh  publishes one output to the workflow output registry with artifacts.sh register (E80_S04_T09;
#                      shared with run-compute.sh since E80_S06_T13)
#   run-state.sh       step <run> <step> failed --note: one atomic write for the step, its note and the run move
# It never edits the state file itself and never reads or writes the pre-flight situation marker.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   complete-step.sh <run_id> <step_id> passed [value]
#   complete-step.sh <run_id> <step_id> failed [note]
#   complete-step.sh -h | --help       print this usage on stdout, exit 0
#
#   passed   The step must be `in_progress` (a step that is pending, completed, failed or skipped is refused with
#            no state change) in a run that is `running` or `paused`. What [value] means depends on the step's
#            declared `outputs`:
#              none      nothing is stored; a supplied value is ignored with a note on stderr
#              one       [value] is required and is the plain value of that output
#              several   [value] is required and is ONE JSON object keyed by output name, one key per declared
#                        output (a missing or an undeclared key is refused). A string member is used as is; any
#                        other member is stored as compact JSON text.
#            Every output is checked against its declared `type` with verify-output.sh BEFORE anything is written,
#            so one bad output stores nothing. The verified value is stored (the normalised form, when the type
#            normalises) with step-state.sh set-output, the step is set `completed`, and when the step has
#            `checkpoint: true` step-state.sh checkpoint records it as last_checkpoint. The writes are repeatable:
#            if the process stops half way the step is still `in_progress` and `passed` can simply be sent again.
#            Publishing (E80_S04_T09): AFTER the values are stored and BEFORE the step is set `completed`, each
#            declared output is published with artifacts.sh register, always with --replace (it only swaps this
#            run's own record, so a retried step is never blocked by an earlier partial one):
#              kind data      the stored value is written to a temporary file (one line per element for a list
#                             type, as in run state) and registered with --kind data and the declared type
#              kind artifact  not registered here (render-artifact.sh owns that), EXCEPT when the stored value is
#                             the path of an existing regular file: that file is registered with --kind artifact
#              no outputs     no registry call is made and the registry directory is not created
#            A type violation returns before any of this, so no record and no file is written. If a registration
#            fails the step is NOT completed: it is marked `failed` with the registry error as its note (the same
#            atomic write and run move as a `failed` report), stdout carries the halted object below, and the exit
#            status is 1. Run state and registry therefore never disagree about a completed step.
#            stdout: {"status": "completed", "step_id": "<id>", "checkpoint": true|false}   (checkpoint is true
#            exactly when this call wrote one).
#   failed   Same preconditions on the step. [note] is optional free text. In one locked atomic write the step
#            becomes `failed` with the note stored on the step (the field next-step.sh reports in `halted`) and the
#            run moves running -> failed, with a history entry. A paused run keeps its status (the step is marked
#            failed; the run is resumed from the failed step later).
#            stdout: {"status": "halted", "run_id": "<id>", "step_id": "<id>", "note": "<note>"}
#   A `confirm` step is refused (exit 1) before anything else with a pointer to
#   `step-confirm.sh reply <run_id> <step_id> "<raw reply>"`: a gate is completed by the user's answer, not by
#   the agent's report.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  the report was recorded (stdout has the JSON object above)
#   1  refused, nothing changed, cause on stderr (except a registry failure, where the step was marked failed
#      with the registry error and stdout carries the halted object): the step is a confirm step, the step is not in_progress, the run
#      is not running or paused, `passed` without a required value, a value that is not a JSON object for a
#      multi-output step (or lacks / adds a key), or a value that violates its declared type (the verifier's
#      failing rule is relayed, prefixed with the output name). The agent may send `passed` again with a corrected
#      value, or report `failed`.
#   2  usage error (wrong argument count, a status other than passed or failed), an invalid run or step id, a
#      step the run or its workflow definition does not have, a workflow definition that cannot be looked up, or a
#      verifier environment failure (verify-output.sh exit 2: unknown type, missing validator), relayed as is.
#      Nothing was changed.
#   3  the run does not exist
#   4  the run's state file is corrupt or unreadable (never modified)
#   5  jq is missing, or a lock was not obtained in time (nothing was written)
#
# Requires jq. Compatible with macOS bash 3.2 and safe under "set -u". Sourcing is not supported.
# Mirror safety: every path is reached through the sibling scripts; this file names no working-file tree.
# ---------------------------------------------------------------------------
set -u

_CS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CS_STEP_STATE="$_CS_DIR/step-state.sh"
_CS_VERIFY="$_CS_DIR/verify-output.sh"
_CS_LOAD="$_CS_DIR/load-workflows.sh"
_CS_RUN_STATE="$_CS_DIR/run-state.sh"

_CS_PUBLISH="$_CS_DIR/publish-output.sh"

_CS_ERRF=""

_cs_err() { printf '%s\n' "$*" >&2; }

_cs_usage() {
  sed -n '/^# USAGE$/,/^# EXIT CODES$/p' "${BASH_SOURCE[0]}" | sed -e '1,2d' -e '/^# -\{20,\}$/,$d' -e 's/^# \{0,1\}//'
}

_cs_usage_fail() {
  _cs_err "Usage: complete-step.sh <run_id> <step_id> passed [value] | failed [note]"
  return 2
}

_cs_cleanup() {
  [ -z "$_CS_ERRF" ] || rm -f "$_CS_ERRF"
}

# Maps a sibling script's status onto this script's: 0..5 pass through, anything else is a usage-class failure.
_cs_map_rc() {
  case "$1" in
    0|1|2|3|4|5) return "$1" ;;
    *) return 2 ;;
  esac
}

# Verifies value $3 against type $2 for output $1. On success the verified (possibly normalised) value is left in
# _CS_VERIFIED, without the single newline verify-output.sh appends. Returns 1 for a violation (message already
# printed), 2 or more for an environment failure (message printed).
_cs_verify() {
  local name="$1" type="$2" value="$3" out rc msg
  _CS_VERIFIED=""
  out=$(bash "$_CS_VERIFY" "$type" "$value" 2>"$_CS_ERRF"; rc=$?; printf 'x'; exit "$rc")
  rc=$?
  out="${out%x}"
  msg=$(cat "$_CS_ERRF" 2>/dev/null)
  case "$rc" in
    0)
      _CS_VERIFIED="${out%$'\n'}"
      return 0
      ;;
    1)
      _cs_err "complete-step: output '$name' (type '$type') was rejected; the step is not completed and nothing was stored."
      [ -z "$msg" ] || _cs_err "$msg"
      return 1
      ;;
    *)
      _cs_err "complete-step: output '$name' (type '$type') could not be checked; nothing was changed."
      [ -z "$msg" ] || _cs_err "$msg"
      return 2
      ;;
  esac
}

# Publishes output $4 of the step to the registry through the shared helper publish-output.sh (also used by
# run-compute.sh). Arguments: run workflow step name kind type value.
# Leaves the registry's message in _CS_REGERR and returns non-zero when the registration failed; returns 0 when it
# registered or when there is nothing to register here (an artifact output that does not name an existing file).
_cs_publish() {
  local run="$1" wf="$2" step="$3" name="$4" kind="$5" type="$6" value="$7" msg
  _CS_REGERR=""
  msg=$(bash "$_CS_PUBLISH" "$run" "$wf" "$step" "$name" "$kind" "$type" "$value" 2>&1 >/dev/null)
  if [ "$?" -ne 0 ]; then
    _CS_REGERR="$msg"
    return 1
  fi
  return 0
}

_cs_main() {
  local run step status value="" have_value=0 state rc stype sstatus rstatus cp wf def noutputs
  local i name type raw missing extra n

  case "${1:-}" in
    -h|--help) _cs_usage; return 0 ;;
  esac
  if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    _cs_usage_fail
    return $?
  fi
  run="$1"; step="$2"; status="$3"
  if [ "$#" -eq 4 ]; then
    have_value=1
    value="$4"
  fi
  case "$status" in
    passed|failed) ;;
    *)
      _cs_err "complete-step: unknown report '$status' (use passed or failed)"
      _cs_usage_fail
      return $?
      ;;
  esac
  command -v jq >/dev/null 2>&1 || { _cs_err "complete-step: jq is required"; return 5; }

  state=$(bash "$_CS_STEP_STATE" get "$run")
  rc=$?
  [ "$rc" -eq 0 ] || { _cs_map_rc "$rc"; return $?; }

  if [ -z "$step" ] || ! printf '%s' "$state" | jq -e --arg s "$step" '.steps | any(.[]; .id == $s)' >/dev/null 2>&1; then
    _cs_err "complete-step: run '$run' has no step '$step' (steps of this run: $(printf '%s' "$state" | jq -r '[.steps[].id] | join(", ")'))"
    return 2
  fi
  stype=$(printf '%s' "$state" | jq -r --arg s "$step" '.steps[] | select(.id == $s) | .type')
  sstatus=$(printf '%s' "$state" | jq -r --arg s "$step" '.steps[] | select(.id == $s) | .status')
  cp=$(printf '%s' "$state" | jq -r --arg s "$step" '.steps[] | select(.id == $s) | (.checkpoint == true)')
  rstatus=$(printf '%s' "$state" | jq -r '.status')

  if [ "$stype" = "confirm" ]; then
    _cs_err "complete-step: step '$step' is a confirm step: a gate is completed by the user's answer, not by a report. Pass the reply to: step-confirm.sh reply $run $step \"<raw reply>\""
    return 1
  fi
  if [ "$sstatus" != "in_progress" ]; then
    _cs_err "complete-step: step '$step' is '$sstatus', not 'in_progress'; only a step handed out by next-step.sh can be reported. Nothing was changed."
    return 1
  fi
  if [ "$rstatus" != "running" ] && [ "$rstatus" != "paused" ]; then
    _cs_err "complete-step: run '$run' is '$rstatus', not 'running' or 'paused'; a step cannot be reported now. Nothing was changed."
    return 1
  fi

  # --- failed ---------------------------------------------------------------
  if [ "$status" = "failed" ]; then
    if [ "$have_value" -eq 1 ] && [ -n "$value" ]; then
      bash "$_CS_RUN_STATE" step "$run" "$step" failed --note "$value" >/dev/null
    else
      bash "$_CS_RUN_STATE" step "$run" "$step" failed >/dev/null
    fi
    rc=$?
    [ "$rc" -eq 0 ] || { _cs_map_rc "$rc"; return $?; }
    jq -cn --arg run "$run" --arg s "$step" --arg n "$value" '{status: "halted", run_id: $run, step_id: $s, note: $n}'
    return 0
  fi

  # --- passed ---------------------------------------------------------------
  wf=$(printf '%s' "$state" | jq -r '.workflow_id')
  def=$(bash "$_CS_LOAD" lookup "$wf")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _cs_err "complete-step: cannot read the definition of workflow '$wf' to find the outputs of step '$step'"
    return 2
  fi
  if ! printf '%s' "$def" | jq -e --arg s "$step" '.steps | any(.[]; .id == $s)' >/dev/null 2>&1; then
    _cs_err "complete-step: workflow '$wf' no longer defines step '$step'; cannot verify its outputs"
    return 2
  fi
  noutputs=$(printf '%s' "$def" | jq -r --arg s "$step" '[.steps[] | select(.id == $s) | (.outputs // [])[]] | length')

  _CS_ERRF=$(mktemp "${TMPDIR:-/tmp}/complete-step.XXXXXX") || { _cs_err "complete-step: cannot create a temporary file"; return 2; }
  trap _cs_cleanup EXIT
  trap 'exit 2' INT TERM

  # Names, types and verified values of the outputs to store (parallel arrays, bash 3.2 safe).
  local -a names types kinds vals
  names=(); types=(); kinds=(); vals=()

  if [ "$noutputs" -eq 0 ]; then
    if [ "$have_value" -eq 1 ] && [ -n "$value" ]; then
      _cs_err "complete-step: step '$step' declares no outputs; the supplied value is ignored."
    fi
  else
    if [ "$have_value" -eq 0 ]; then
      _cs_err "complete-step: step '$step' declares $noutputs output(s) ($(printf '%s' "$def" | jq -r --arg s "$step" '[.steps[] | select(.id == $s) | .outputs[].name] | join(", ")')); passed needs a value. The step is not completed."
      return 1
    fi
    i=0
    while [ "$i" -lt "$noutputs" ]; do
      name=$(printf '%s' "$def" | jq -r --arg s "$step" --argjson i "$i" '[.steps[] | select(.id == $s) | .outputs[]][$i].name')
      type=$(printf '%s' "$def" | jq -r --arg s "$step" --argjson i "$i" '[.steps[] | select(.id == $s) | .outputs[]][$i].type')
      names[$i]="$name"
      types[$i]="$type"
      kinds[$i]="$(printf '%s' "$def" | jq -r --arg s "$step" --argjson i "$i" '[.steps[] | select(.id == $s) | .outputs[]][$i].kind // "data"')"
      i=$((i + 1))
    done

    if [ "$noutputs" -eq 1 ]; then
      vals[0]="$value"
    else
      if ! printf '%s' "$value" | jq -e 'type == "object"' >/dev/null 2>&1; then
        _cs_err "complete-step: step '$step' declares $noutputs outputs; the value must be one JSON object keyed by output name ($(printf '%s' "$def" | jq -r --arg s "$step" '[.steps[] | select(.id == $s) | .outputs[].name] | join(", ")')). The step is not completed."
        return 1
      fi
      missing=$(printf '%s' "$value" | jq -r --argjson want "$(printf '%s\n' "${names[@]}" | jq -R . | jq -sc .)" '. as $v | [$want[] | . as $k | select($v | has($k) | not)] | join(", ")')
      if [ -n "$missing" ]; then
        _cs_err "complete-step: the value for step '$step' lacks the output(s): $missing. The step is not completed."
        return 1
      fi
      extra=$(printf '%s' "$value" | jq -r --argjson want "$(printf '%s\n' "${names[@]}" | jq -R . | jq -sc .)" '[keys[] | select(. as $k | $want | index($k) | not)] | join(", ")')
      if [ -n "$extra" ]; then
        _cs_err "complete-step: the value for step '$step' names undeclared output(s): $extra. The step is not completed."
        return 1
      fi
      i=0
      while [ "$i" -lt "$noutputs" ]; do
        raw=$(printf '%s' "$value" | jq -j --arg n "${names[$i]}" '.[$n] | if type == "string" then . else tojson end'; printf 'x')
        raw="${raw%x}"
        vals[$i]="$raw"
        i=$((i + 1))
      done
    fi

    # Verify every output before writing anything.
    i=0
    while [ "$i" -lt "$noutputs" ]; do
      _cs_verify "${names[$i]}" "${types[$i]}" "${vals[$i]}"
      rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      vals[$i]="$_CS_VERIFIED"
      i=$((i + 1))
    done
  fi

  # --- all outputs conform: write ----------------------------------------------
  i=0
  while [ "$i" -lt "$noutputs" ]; do
    bash "$_CS_STEP_STATE" set-output "$run" "$step" "${names[$i]}" "${vals[$i]}"
    rc=$?
    [ "$rc" -eq 0 ] || { _cs_map_rc "$rc"; return $?; }
    i=$((i + 1))
  done
  # Publish second, so run state never holds a completed step the registry does not know about.
  if [ "$noutputs" -gt 0 ]; then
    i=0
    while [ "$i" -lt "$noutputs" ]; do
      if ! _cs_publish "$run" "$wf" "$step" "${names[$i]}" "${kinds[$i]}" "${types[$i]}" "${vals[$i]}"; then
        _cs_err "complete-step: output '${names[$i]}' could not be registered; the step is marked failed, not completed."
        [ -z "$_CS_REGERR" ] || _cs_err "$_CS_REGERR"
        n="registry: output '${names[$i]}' could not be registered: $_CS_REGERR"
        bash "$_CS_RUN_STATE" step "$run" "$step" failed --note "$n" >/dev/null
        rc=$?
        [ "$rc" -eq 0 ] || { _cs_map_rc "$rc"; return $?; }
        jq -cn --arg run "$run" --arg s "$step" --arg n "$n" '{status: "halted", run_id: $run, step_id: $s, note: $n}'
        return 1
      fi
      i=$((i + 1))
    done
  fi
  bash "$_CS_STEP_STATE" set-step "$run" "$step" completed
  rc=$?
  [ "$rc" -eq 0 ] || { _cs_map_rc "$rc"; return $?; }
  if [ "$cp" = "true" ]; then
    bash "$_CS_STEP_STATE" checkpoint "$run" "$step"
    rc=$?
    [ "$rc" -eq 0 ] || { _cs_map_rc "$rc"; return $?; }
  fi
  n=false
  [ "$cp" = "true" ] && n=true
  jq -cn --arg s "$step" --argjson c "$n" '{status: "completed", step_id: $s, checkpoint: $c}'
}

_cs_main "$@"
exit $?
