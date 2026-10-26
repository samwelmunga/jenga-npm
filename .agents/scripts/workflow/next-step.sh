#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/next-step.sh - "what do I do now" for a workflow run (epic E80, task E80_S03_T07)
#
# The single question the driving agent asks a run. It reads the run, decides which of a fixed set of signals
# applies, and prints ONE compact JSON object on stdout:
#
#   {"signal": "...", "run_id": "...", "step_id": "..." | null, "type": "..." | null, "payload": {...}}
#
# It composes the sibling scripts in this directory and holds no logic of their own beyond the decision table:
#   step-state.sh     current-step, set-step, set-run-status, get (the run state)
#   resolve-refs.sh   substitutes ${inputs.*} and ${steps.*.outputs.*} in the step before it is dispatched
#   step-skill.sh     skill step payload (and the unknown-skill check)
#   step-playbook.sh  playbook step payload (--resume for a step that was already in progress)
#   step-confirm.sh   confirm step: start (render + persist the gate), status (read the stored gate)
#   run-compute.sh    compute step: executed HERE, not by the agent (E80_S04_T08)
#   render-artifact.sh render step: executed HERE, not by the agent (E80_S04_T08)
# It never edits the state file itself, never executes a skill or playbook (a shell script cannot; the calling
# agent does), and never reads or writes the pre-flight situation marker.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   next-step.sh <run_id>
#   next-step.sh -h | --help        print the usage on stdout, exit 0
#
# ---------------------------------------------------------------------------
# SIGNALS (every one of them is exit 0; a non-zero exit is a usage or environment error, never a run state)
# ---------------------------------------------------------------------------
# The run's own status is looked at first, then its steps:
#
#   run status               signal                  what it means
#   ----------------------   ---------------------   ------------------------------------------------------
#   failed                   halted                  Refuses to advance. Repeated calls keep returning
#                                                    halted and dispatch nothing: the run must be resumed or
#                                                    retried explicitly (run-state.sh resume); there is no
#                                                    silent skip-ahead. step_id/type name the failed step;
#                                                    payload {"failed_step", "note"} (the step's note, else the
#                                                    last history note, else "").
#   paused                   paused                  Nothing is dispatched. payload {"status": "paused"}.
#   cancelled                cancelled               Nothing is dispatched. payload {"status": "cancelled"}.
#   completed                complete                Idempotent. payload {"status": "completed"}.
#   awaiting_confirmation    awaiting_confirmation   A gate is pending; the stored rendering is returned
#                                                    unchanged (step-confirm.sh status), the same on every call.
#                                                    step_id is the gate's step, type "confirm", payload the
#                                                    gate: {"step_id", "prompt", "options", "rendered"}.
#   running                  step | complete | halted | error   see below
#
# For a running run the current step is the first one that is neither completed nor skipped
# (step-state.sh current-step):
#   - none left                 -> the run is set to `completed` (step-state.sh set-run-status) and the signal is
#                                  `complete` (payload {"status": "completed"}).
#   - otherwise                 -> it is routed by `type` through the dispatch table (_ns_table, one function,
#                                  one row per type) to a handler. An AGENT step (skill, playbook, confirm) has
#                                  its references resolved (resolve-refs.sh), is marked `in_progress`
#                                  (step-state.sh set-step) and, on success, the signal is `step` with step_id,
#                                  type and the type payload. A DETERMINISTIC step (compute, render) is executed
#                                  by this script (see below) and the run is then evaluated again.
#
# A completed or skipped step is never dispatched (it is never "current"). A step that is already `in_progress`
# and is not a playbook (an interrupted earlier session) is dispatched again as the same action. A `failed` step
# in a running run (after a retry resume) is dispatched like a pending one.
#
# ---------------------------------------------------------------------------
# PAYLOAD PER STEP TYPE (signal `step`)
# ---------------------------------------------------------------------------
#   skill      step-skill.sh's object plus the step's resolved args:
#                {"skill", "skill_path", "invoke_as", "instruction", "prefered_agent", "args"}
#              "instruction" is the step's `args` map as `key=value` pairs, keys sorted, joined with single
#              spaces (empty when the step has no args); "args" is the map itself. The agent invokes
#              `invoke_as` with the instruction and reports the outcome.
#   playbook   step-playbook.sh's object plus the step's resolved args:
#                {"playbook_id", "name", "steps", "reinitialised", "args"} and, for a step that was already
#              in_progress, "reinitialised": true with a "note" (the playbook restarts from its first step).
#   confirm    the gate that step-confirm.sh start persisted (the run is now `awaiting_confirmation`):
#                {"step_id", "prompt", "options", "rendered"}
#              The agent relays "rendered" verbatim and passes the user's reply to step-confirm.sh reply.
#   compute    never handed to the agent: executed by `run-compute.sh <run_id> <step_id>`. No `step` signal.
#   render     never handed to the agent: executed by `render-artifact.sh <run_id> <step_id>`. No `step` signal.
#
# ---------------------------------------------------------------------------
# DETERMINISTIC STEPS (compute, render; E80_S04_T08)
# ---------------------------------------------------------------------------
# They need no agent judgment, so one call executes every consecutive compute or render step itself and returns
# the first thing the agent must act on: a skill, playbook or confirm step, or a terminal signal (complete,
# halted, paused, awaiting_confirmation, cancelled) or an error. The executors record every outcome themselves
# (output stored and step completed, or step and run failed); this script only reads the result back.
#   - A step that completes is not reported; the run is re-read and the next step is evaluated in the same call.
#   - A step that fails is the existing `halted` signal (step_id/type name it, payload.note is the recorded
#     reason). The run is `failed`, so every later call returns `halted` again and executes nothing; only
#     `run-state.sh resume` (retry after failure) lets the step run again. An executor refusing the step
#     (exit 2) or failing for an environment reason is an `error` signal, see below.
#   - A completed or skipped step is never current, so a resumed run never re-executes it.
#   - Retry: a retried render step re-registers its artifact with `artifacts.sh register --replace` (done inside
#     render-artifact.sh), so a step that crashed after publishing can be run again.
#   - Loop guard: each step is executed at most once per call, and a call executes at most as many deterministic
#     steps as the definition has steps (NEXT_STEP_MAX_DETERMINISTIC, a positive integer, may only LOWER that
#     cap; it exists for tests and for a deliberately short leash). Hitting a guard is an `error` signal and
#     leaves the state as the executors left it; the next call carries on.
#
# ---------------------------------------------------------------------------
# THE `error` SIGNAL
# ---------------------------------------------------------------------------
# {"signal": "error", "run_id", "step_id", "type", "reason": "<code>", "payload": {"reason": "<code>", "message": "<text>"}}
# (the reason is repeated at top level for convenience). A handler failure is an error SIGNAL, not a failed step:
# the step is put back to the status it had before this call (pending), so a bad skill name does not poison the
# run and the same call can be repeated after the definition or catalog is fixed. Reasons:
#   unknown_skill                      step-skill.sh found no such skill (exit 1)
#   unknown_playbook                   step-playbook.sh found no such playbook, or it is invalid (exit 1)
#   unresolved_reference               resolve-refs.sh exit 1: a reference to a skipped or failed step, a step that
#                                      has not completed, a missing output or input, or a malformed reference.
#                                      The step is left as it was; nothing was dispatched.
#   compute_failed, render_failed      the executor refused the step (its exit 2: not a running run, not
#                                      pending or in_progress, ...) or reported something unreadable; the message
#                                      carries its stderr. A step that FAILED is `halted`, not this.
#   deterministic_step_cap             a call executed as many compute/render steps as the cap allows
#   step_not_advanced                  an executor exited 0 but the step is still current (guard, never expected)
#   confirm_failed                     step-confirm.sh could not render or persist the gate
#   awaiting_confirmation_without_gate the run says awaiting_confirmation but no gate is stored
#   skill_failed, playbook_failed, resolve_failed
#                                      the handler or resolver failed in some other way (usage error, missing
#                                      tool); the message carries its stderr
#   unknown_step_type                  the step's type has no row in the dispatch table
#   unknown_run_status                 the run's status is not one of the six known values
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  a signal was printed (any signal, including `error`)
#   1  internal failure: the state could not be updated for a reason other than 2 to 5; stderr has the cause
#   2  usage error, or an invalid run id (step-state.sh's message on stderr). Nothing on stdout.
#   3  the run does not exist. Nothing on stdout.
#   4  the run's state file is corrupt or unreadable. Nothing on stdout, file untouched.
#   5  jq is missing, or a lock was not obtained in time (nothing was written)
#
# Requires jq. Compatible with macOS bash 3.2 and safe under "set -u". Sourcing is not supported.
# Mirror safety: every path is reached through the sibling scripts; this file names no working-file tree.
# ---------------------------------------------------------------------------
set -u

_NS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_NS_STEP_STATE="$_NS_DIR/step-state.sh"
_NS_RESOLVE="$_NS_DIR/resolve-refs.sh"
_NS_SKILL="$_NS_DIR/step-skill.sh"
_NS_PLAYBOOK="$_NS_DIR/step-playbook.sh"
_NS_CONFIRM="$_NS_DIR/step-confirm.sh"
_NS_COMPUTE="$_NS_DIR/run-compute.sh"
_NS_RENDER="$_NS_DIR/render-artifact.sh"

_NS_RUN=""
_NS_ERRF=""
# Per call: how many deterministic steps were executed, which ones, and whether to evaluate the run again.
_NS_EXECUTED=0
_NS_EXECUTED_IDS=" "
_NS_AGAIN=0
# Set by a deterministic handler: "completed" or "failed" (the executor recorded it); _NS_EXIT is a passed-through
# executor exit code (3, 4, 5) that ends the call without a signal.
_NS_OUTCOME=""
_NS_EXIT=0
# Set by a handler: on success _NS_PAYLOAD (a JSON object); on failure _NS_REASON and _NS_MSG.
_NS_PAYLOAD="{}"
_NS_REASON=""
_NS_MSG=""

_ns_err() { printf '%s\n' "$*" >&2; }

_ns_usage() {
  sed -n '/^# USAGE$/,/^# SIGNALS/p' "${BASH_SOURCE[0]}" | sed -e '1,2d' -e '/^# -\{20,\}$/,$d' -e 's/^# \{0,1\}//'
}

# The dispatch table: one row per step type, "type|handler function|marks the step in_progress (yes/no)|executed
# here (yes/no)". An agent step (executed here = no) is handed out as a `step` signal. A deterministic step
# (executed here = yes) is run by its handler, which reports `completed` or `failed` through _NS_OUTCOME, and the
# run is then evaluated again. Its handler resolves the references itself (the executor does), so the dispatcher
# neither resolves them nor marks the step: the executor owns the step's status for its whole life.
_ns_table() {
  cat <<'TABLE'
skill|_ns_h_skill|yes|no
playbook|_ns_h_playbook|yes|no
confirm|_ns_h_confirm|yes|no
compute|_ns_h_compute|no|yes
render|_ns_h_render|no|yes
TABLE
}

# _ns_emit <signal> <step_id> <type> <payload json>
_ns_emit() {
  jq -cn --arg sig "$1" --arg run "$_NS_RUN" --arg sid "$2" --arg ty "$3" --argjson p "$4" \
    '{signal: $sig, run_id: $run, step_id: (if $sid == "" then null else $sid end),
      type: (if $ty == "" then null else $ty end), payload: $p}'
}

# _ns_error <reason> <message> [step_id] [type]
_ns_error() {
  jq -cn --arg run "$_NS_RUN" --arg r "$1" --arg m "$2" --arg sid "${3-}" --arg ty "${4-}" \
    '{signal: "error", run_id: $run, step_id: (if $sid == "" then null else $sid end),
      type: (if $ty == "" then null else $ty end), reason: $r, payload: {reason: $r, message: $m}}'
}

# The stderr of the last sibling call, one line.
_ns_lasterr() {
  tr '\n' ' ' < "$_NS_ERRF" | sed -e 's/[[:space:]]*$//'
}

# --- handlers: no output of their own; they set _NS_PAYLOAD, or _NS_REASON and _NS_MSG and return 1 --------

# _ns_h_skill <step_id> <resolved step json> <prior status>
_ns_h_skill() {
  local stepjson="$2" skill instr out rc args
  skill=$(printf '%s' "$stepjson" | jq -r '.skill')
  instr=$(printf '%s' "$stepjson" | jq -r '(.args // {}) | to_entries | sort_by(.key) | map(.key + "=" + (.value | tostring)) | join(" ")')
  args=$(printf '%s' "$stepjson" | jq -c '.args // {}')
  out=$(bash "$_NS_SKILL" "$skill" "$instr" 2>"$_NS_ERRF")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _NS_REASON="unknown_skill"
    [ "$rc" -eq 1 ] || _NS_REASON="skill_failed"
    _NS_MSG="$(_ns_lasterr)"
    return 1
  fi
  _NS_PAYLOAD=$(printf '%s' "$out" | jq -c --argjson a "$args" '. + {args: $a}') || {
    _NS_REASON="skill_failed"; _NS_MSG="step-skill.sh printed an unreadable result"; return 1; }
}

# _ns_h_playbook <step_id> <resolved step json> <prior status>
_ns_h_playbook() {
  local stepjson="$2" prior="$3" pid out rc args
  pid=$(printf '%s' "$stepjson" | jq -r '.playbook')
  args=$(printf '%s' "$stepjson" | jq -c '.args // {}')
  if [ "$prior" = "in_progress" ]; then
    out=$(bash "$_NS_PLAYBOOK" "$pid" --resume 2>"$_NS_ERRF")
  else
    out=$(bash "$_NS_PLAYBOOK" "$pid" 2>"$_NS_ERRF")
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _NS_REASON="unknown_playbook"
    [ "$rc" -eq 1 ] || _NS_REASON="playbook_failed"
    _NS_MSG="$(_ns_lasterr)"
    return 1
  fi
  _NS_PAYLOAD=$(printf '%s' "$out" | jq -c --argjson a "$args" '. + {args: $a}') || {
    _NS_REASON="playbook_failed"; _NS_MSG="step-playbook.sh printed an unreadable result"; return 1; }
}

# _ns_h_confirm <step_id> <resolved step json> <prior status>
_ns_h_confirm() {
  local gate
  if ! bash "$_NS_CONFIRM" start "$_NS_RUN" "$1" >/dev/null 2>"$_NS_ERRF"; then
    _NS_REASON="confirm_failed"; _NS_MSG="$(_ns_lasterr)"; return 1
  fi
  if ! gate=$(bash "$_NS_CONFIRM" status "$_NS_RUN" 2>"$_NS_ERRF"); then
    _NS_REASON="confirm_failed"; _NS_MSG="$(_ns_lasterr)"; return 1
  fi
  _NS_PAYLOAD=$(printf '%s' "$gate" | jq -c '.gate') || {
    _NS_REASON="confirm_failed"; _NS_MSG="step-confirm.sh printed an unreadable gate"; return 1; }
}

# _ns_exec <executor script> <reason prefix> <step_id>: runs a deterministic step's executor.
# Exit 0 -> completed, 1 -> failed (both recorded by the executor); 3, 4, 5 end the call; anything else is an error.
_ns_exec() {
  local script="$1" prefix="$2" sid="$3" rc
  _NS_OUTCOME=""
  bash "$script" "$_NS_RUN" "$sid" >/dev/null 2>"$_NS_ERRF"
  rc=$?
  case "$rc" in
    0) _NS_OUTCOME="completed" ;;
    1) _NS_OUTCOME="failed" ;;
    3|4|5) _NS_EXIT="$rc"; _NS_MSG="$(_ns_lasterr)"; _NS_REASON="${prefix}_failed"; return 1 ;;
    *) _NS_REASON="${prefix}_failed"; _NS_MSG="$(_ns_lasterr)"; return 1 ;;
  esac
}

# _ns_h_compute <step_id> <resolved step json> <prior status>
_ns_h_compute() { _ns_exec "$_NS_COMPUTE" compute "$1"; }

# _ns_h_render <step_id> <resolved step json> <prior status>
_ns_h_render() { _ns_exec "$_NS_RENDER" render "$1"; }

# --- the run-level signals ---------------------------------------------------------------------------------

_ns_halted() {
  local info sid ty
  info=$(printf '%s' "$_NS_STATE" | jq -c '
    (first(.steps[] | select(.status == "failed")) // null) as $f
    | {id: ($f.id // ""), type: ($f.type // ""),
       payload: {failed_step: ($f.id // null), note: (($f.note // (.history | last | .note) // "") | tostring)}}')
  sid=$(printf '%s' "$info" | jq -r '.id')
  ty=$(printf '%s' "$info" | jq -r '.type')
  _ns_emit halted "$sid" "$ty" "$(printf '%s' "$info" | jq -c '.payload')"
}

_ns_awaiting() {
  local gate rc
  gate=$(bash "$_NS_CONFIRM" status "$_NS_RUN" 2>"$_NS_ERRF")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _ns_error awaiting_confirmation_without_gate "the run is awaiting_confirmation but no gate is stored: $(_ns_lasterr)"
    return 0
  fi
  _ns_emit awaiting_confirmation "$(printf '%s' "$gate" | jq -r '.step_id')" confirm "$(printf '%s' "$gate" | jq -c '.gate')"
}

# The most deterministic steps one call may execute: the definition's step count, optionally lowered by
# NEXT_STEP_MAX_DETERMINISTIC (a positive integer; anything else is ignored).
_ns_cap() {
  local cap env="${NEXT_STEP_MAX_DETERMINISTIC-}"
  cap=$(printf '%s' "$_NS_STATE" | jq -r '.steps | length')
  case "$env" in
    ''|*[!0-9]*|0) ;;
    *) [ "$env" -lt "$cap" ] && cap="$env" ;;
  esac
  printf '%s' "$cap"
}

# The running run: pick, route. An agent step ends the call with a `step` signal. A deterministic step is executed
# and sets _NS_AGAIN so that _ns_main evaluates the run again.
_ns_advance() {
  local cur stype prior row handler marks exec resolved rc msg

  cur=$(bash "$_NS_STEP_STATE" current-step "$_NS_RUN") || return $?
  if [ -z "$cur" ]; then
    bash "$_NS_STEP_STATE" set-run-status "$_NS_RUN" completed || return $?
    _ns_emit complete "" "" '{"status":"completed"}'
    return 0
  fi

  stype=$(printf '%s' "$_NS_STATE" | jq -r --arg s "$cur" '.steps[] | select(.id == $s) | .type')
  prior=$(printf '%s' "$_NS_STATE" | jq -r --arg s "$cur" '.steps[] | select(.id == $s) | .status')

  row=$(_ns_table | awk -F'|' -v t="$stype" '$1 == t { print; exit }')
  if [ -z "$row" ]; then
    _ns_error unknown_step_type "step '$cur' has type '$stype', which has no row in the dispatch table" "$cur" "$stype"
    return 0
  fi
  handler=$(printf '%s' "$row" | cut -d'|' -f2)
  marks=$(printf '%s' "$row" | cut -d'|' -f3)
  exec=$(printf '%s' "$row" | cut -d'|' -f4)

  _NS_PAYLOAD="{}"; _NS_REASON=""; _NS_MSG=""; _NS_EXIT=0

  if [ "$exec" = "yes" ]; then
    # the loop guards, checked before anything is executed
    case "$_NS_EXECUTED_IDS" in
      *" $cur "*)
        _ns_error step_not_advanced "step '$cur' was already executed in this call and is still current; stopping" "$cur" "$stype"
        return 0 ;;
    esac
    if [ "$_NS_EXECUTED" -ge "$(_ns_cap)" ]; then
      _ns_error deterministic_step_cap "this call already executed $_NS_EXECUTED compute/render step(s), the most it may; call next-step.sh again to continue" "$cur" "$stype"
      return 0
    fi
    _NS_EXECUTED=$((_NS_EXECUTED + 1))
    _NS_EXECUTED_IDS="$_NS_EXECUTED_IDS$cur "
    if ! "$handler" "$cur" "{}" "$prior"; then
      if [ "$_NS_EXIT" -ne 0 ]; then
        _ns_err "$_NS_MSG"
        return "$_NS_EXIT"
      fi
      _ns_error "${_NS_REASON:-handler_failed}" "${_NS_MSG:-the handler failed}" "$cur" "$stype"
      return 0
    fi
    _NS_STATE=$(bash "$_NS_STEP_STATE" get "$_NS_RUN") || return $?
    if [ "$_NS_OUTCOME" = "failed" ]; then
      _ns_halted
      return 0
    fi
    _NS_AGAIN=1
    return 0
  fi

  resolved=$(bash "$_NS_RESOLVE" "$_NS_RUN" "$cur" 2>"$_NS_ERRF")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    msg="$(_ns_lasterr)"
    case "$rc" in
      1) _ns_error unresolved_reference "$msg" "$cur" "$stype"; return 0 ;;
      3|4|5) _ns_err "$msg"; return "$rc" ;;
      *) _ns_error resolve_failed "$msg" "$cur" "$stype"; return 0 ;;
    esac
  fi

  if [ "$marks" = "yes" ] && [ "$prior" != "in_progress" ]; then
    bash "$_NS_STEP_STATE" set-step "$_NS_RUN" "$cur" in_progress || return $?
  fi

  if ! "$handler" "$cur" "$resolved" "$prior"; then
    # A handler failure is an error signal; the step goes back to the status it had (pending), not to failed.
    if [ "$marks" = "yes" ] && [ "$prior" != "in_progress" ]; then
      bash "$_NS_STEP_STATE" set-step "$_NS_RUN" "$cur" "$prior" || return $?
    fi
    _ns_error "${_NS_REASON:-handler_failed}" "${_NS_MSG:-the handler failed}" "$cur" "$stype"
    return 0
  fi
  _ns_emit step "$cur" "$stype" "$_NS_PAYLOAD"
}

# One evaluation of the run, from a fresh read of its state.
_ns_route() {
  _NS_AGAIN=0
  _NS_STATE=$(bash "$_NS_STEP_STATE" get "$_NS_RUN") || return $?

  case "$(printf '%s' "$_NS_STATE" | jq -r '.status')" in
    failed) _ns_halted ;;
    paused) _ns_emit paused "" "" '{"status":"paused"}' ;;
    cancelled) _ns_emit cancelled "" "" '{"status":"cancelled"}' ;;
    completed) _ns_emit complete "" "" '{"status":"completed"}' ;;
    awaiting_confirmation) _ns_awaiting ;;
    running) _ns_advance ;;
    *) _ns_error unknown_run_status "the run has an unknown status" ;;
  esac
}

_ns_main() {
  local rc=0
  case "${1-}" in
    -h|--help) _ns_usage; return 0 ;;
  esac
  if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    _ns_err "Usage: next-step.sh <run_id>"
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { _ns_err "next-step: jq is required and was not found"; return 5; }

  _NS_RUN="$1"
  _NS_ERRF=$(mktemp "${TMPDIR:-/tmp}/next-step.XXXXXX") || { _ns_err "next-step: cannot create a temporary file"; return 1; }
  trap 'rm -f "$_NS_ERRF"' EXIT

  # A deterministic step is executed and the run evaluated again, until an agent step or a terminal signal.
  while :; do
    _ns_route
    rc=$?
    if [ "$rc" -ne 0 ] || [ "$_NS_AGAIN" -ne 1 ]; then break; fi
  done
  return "$rc"
}

_ns_main "$@"
exit $?
