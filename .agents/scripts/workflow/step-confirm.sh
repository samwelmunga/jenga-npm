#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/step-confirm.sh - the executor for a workflow `confirm` step (epic E80, task E80_S03_T06)
#
# A `confirm` step pauses the run for a user decision. The Bash tool runs a command to completion and returns, so
# a script cannot block waiting for the user. This follows the two-invocation idiom of
# skills/jenga/scripts/render-confirmation.sh: one call renders the question and persists it, a later call
# consumes the reply. Unlike that script (state in a mktemp file), the pending gate lives in the durable run
# state through scripts/workflow/step-state.sh set-gate, so it survives the session and can be read back by a
# separate process (a later session resumes the run and finds the same question waiting).
#
# The calling agent relays the stdout of `start` (and of a rejected `reply`) to the user verbatim, then passes the
# user's raw chat reply to `reply`. It never polls: after `start` the agent's turn ends and the reply arrives as
# the next user message.
#
# This script never reads or writes the pre-flight situation marker, and never edits the state file itself: every
# change goes through step-state.sh.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   step-confirm.sh start <run_id> <step_id>
#   step-confirm.sh reply <run_id> <step_id> "<raw reply>"
#   step-confirm.sh status <run_id>
#   step-confirm.sh -h | --help       print this usage on stdout, exit 0
#
#   start    Reads the step through resolve-refs.sh (so ${inputs.*} and ${steps.*.outputs.*} are already
#            substituted), which must be a `confirm` step that is not completed or skipped, in a run whose status
#            is `running`. Renders the prompt followed by the options as a numbered list (CLAUDE.md Interaction
#            Pattern), free text last: when the definition's options do not already end with an other/free-text
#            entry ("Other ...", "Free text ...", "Something else ..."), the entry "Other (describe below)" is
#            appended as the final number. Persists {step_id, prompt, options, rendered} with set-gate, moves the
#            run to `awaiting_confirmation`, and prints the rendering on stdout for the agent to relay verbatim.
#            Calling start while this step's gate is already pending reprints the stored rendering and changes
#            nothing. A gate pending for a different step is refused.
#   reply    Needs this step's gate to be pending. <raw reply> is a number (`2`), or the exact text of an option
#            (`Skip`). If the chosen option is the free-text entry the reply must carry text after the number
#            (`4: because it is late`); that text is stored. A valid choice stores the answer with set-output
#            (output name `answer`: the option text, or the free text for the free-text entry), marks the step
#            `completed`, returns the run to `running`, drops the gate with clear-gate, and prints the choice
#            as one JSON line:
#            {"index": <1-based>, "option": "<option text>", "free_text": <bool>, "text": "<text>" | null,
#             "answer": "<stored value>"}
#            An invalid reply (empty, out of range, not a number or option text, a bare free-text number, text
#            after a number that is not the free-text entry) prints one error line and then the stored
#            rendering on stdout, exits 3, and changes no state at all (the state file stays byte-identical).
#            Every state change is idempotent, so a reply interrupted half way is finished by repeating it.
#   status   Prints the pending gate record (step-state.sh get-gate: step_id, created_at, gate) as JSON, or
#            exits 1 when no gate is pending.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  ok (start rendered or reprinted, reply accepted, status printed a gate)
#   1  refused: status found no pending gate; reply with no pending gate or one for another step; start with
#      another step's gate pending, a step already completed or skipped, or a run that is not `running`; reply
#      to a run that is neither awaiting_confirmation nor running. The cause is on stderr.
#   2  usage error, an invalid run or step id, a step the run or its definition does not have, a step that is
#      not a `confirm` step, or a reference in the step that cannot be resolved (resolve-refs.sh's message)
#   3  invalid reply (reply only): error line and rendering on stdout, nothing changed
#   4  the run does not exist, or its state file is corrupt (step-state.sh's message on stderr)
#   5  jq missing, or a lock was not obtained in time (nothing was written)
#
# Requires jq. Compatible with macOS bash 3.2 and safe under "set -u". Sourcing is not supported.
# ---------------------------------------------------------------------------
set -u

_SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SC_STEP_STATE="$_SC_DIR/step-state.sh"
_SC_RESOLVE="$_SC_DIR/resolve-refs.sh"

# The label appended as the final option when the definition does not end with an other/free-text entry.
_SC_FREE_LABEL="Other (describe below)"

# jq definition: true for an other/free-text option label. Shared by start (to decide whether to append the
# entry) and reply (to know which option takes text), so both always agree on what the free-text option is.
_SC_JQ_DEFS='def isother: ascii_downcase | test("^\\s*(other|free[ -]?text|something else)([^a-z0-9]|$)");'

_sc_err() { printf '%s\n' "$*" >&2; }

_sc_usage() {
  sed -n '/^# USAGE$/,/^# EXIT CODES$/p' "${BASH_SOURCE[0]}" | sed -e '1,2d' -e '/^# -\{20,\}$/,$d' -e 's/^# \{0,1\}//'
}

_sc_usage_fail() {
  _sc_err "Usage: step-confirm.sh start <run_id> <step_id> | reply <run_id> <step_id> \"<raw reply>\" | status <run_id>"
  return 2
}

# Maps a step-state.sh / resolve-refs.sh status to this script's exit codes (run missing or corrupt -> 4).
_sc_map_rc() {
  case "$1" in
    0) return 0 ;;
    1) return 1 ;;
    3|4) return 4 ;;
    5) return 5 ;;
    *) return 2 ;;
  esac
}

# Loads the run state into _SC_STATE; returns the mapped status on failure (the cause is already on stderr).
_sc_load() {
  local rc
  _SC_STATE=$(bash "$_SC_STEP_STATE" get "$1")
  rc=$?
  [ "$rc" -eq 0 ] || { _sc_map_rc "$rc"; return $?; }
  return 0
}

_sc_has_gate() {
  printf '%s' "$_SC_STATE" | jq -e 'has("pending_gate") and .pending_gate != null' >/dev/null 2>&1
}

_sc_print_rendering() {
  printf '%s' "$_SC_STATE" | jq -r '.pending_gate.gate.rendered'
}

_sc_cmd_start() {
  [ "$#" -eq 2 ] || { _sc_usage_fail; return 2; }
  local run="$1" step="$2" gstep rstatus sstatus stepjson rc gate

  _sc_load "$run" || return $?

  if _sc_has_gate; then
    gstep=$(printf '%s' "$_SC_STATE" | jq -r '.pending_gate.step_id')
    if [ "$gstep" = "$step" ]; then
      _sc_print_rendering
      return 0
    fi
    _sc_err "step-confirm: run '$run' already has a gate pending for step '$gstep'; answer it before starting '$step'"
    return 1
  fi

  rstatus=$(printf '%s' "$_SC_STATE" | jq -r '.status')
  if [ "$rstatus" != "running" ]; then
    _sc_err "step-confirm: run '$run' is '$rstatus', not 'running'; a confirmation can only start in a running run"
    return 1
  fi

  sstatus=$(printf '%s' "$_SC_STATE" | jq -r --arg s "$step" '[.steps[] | select(.id == $s) | .status][0] // "unknown"')
  if [ "$sstatus" = "unknown" ]; then
    _sc_err "step-confirm: run '$run' has no step '$step'"
    return 2
  fi
  if [ "$sstatus" = "completed" ] || [ "$sstatus" = "skipped" ]; then
    _sc_err "step-confirm: step '$step' is already $sstatus"
    return 1
  fi

  stepjson=$(bash "$_SC_RESOLVE" "$run" "$step")
  rc=$?
  [ "$rc" -eq 0 ] || { _sc_map_rc "$rc"; rc=$?; [ "$rc" -eq 1 ] && rc=2; return "$rc"; }
  if ! printf '%s' "$stepjson" | jq -e '.type == "confirm" and (.prompt | type) == "string" and (.options | type) == "array"' >/dev/null 2>&1; then
    _sc_err "step-confirm: step '$step' is not a confirm step with a prompt and options"
    return 2
  fi

  gate=$(printf '%s' "$stepjson" | jq -c --arg sid "$step" --arg fb "$_SC_FREE_LABEL" "$_SC_JQ_DEFS"'
    .options as $o
    | (if ($o | length) > 0 and ($o[-1] | isother) then $o else $o + [$fb] end) as $opts
    | {step_id: $sid, prompt: .prompt, options: $opts,
       rendered: (.prompt + "\n\n" + ($opts | to_entries | map("\(.key + 1). \(.value)") | join("\n")))}') || {
    _sc_err "step-confirm: could not build the gate for step '$step'"
    return 2
  }

  bash "$_SC_STEP_STATE" set-gate "$run" "$step" "$gate" || { _sc_map_rc $?; return $?; }
  if ! bash "$_SC_STEP_STATE" set-run-status "$run" awaiting_confirmation; then
    rc=$?
    bash "$_SC_STEP_STATE" clear-gate "$run" >/dev/null 2>&1
    _sc_map_rc "$rc"
    return $?
  fi
  printf '%s' "$gate" | jq -r '.rendered'
}

# Prints "<error>" then the stored rendering, and returns 3. The state is not touched.
_sc_reject() {
  printf 'Invalid reply: %s\n\n' "$1"
  _sc_print_rendering
  return 3
}

_sc_cmd_reply() {
  [ "$#" -eq 3 ] || { _sc_usage_fail; return 2; }
  local run="$1" step="$2" raw="$3" gstep rstatus n ft opt idx="" text="" answer is_ft

  _sc_load "$run" || return $?

  if ! _sc_has_gate; then
    _sc_err "step-confirm: run '$run' has no pending gate"
    return 1
  fi
  gstep=$(printf '%s' "$_SC_STATE" | jq -r '.pending_gate.step_id')
  if [ "$gstep" != "$step" ]; then
    _sc_err "step-confirm: the pending gate of run '$run' is for step '$gstep', not '$step'"
    return 1
  fi
  rstatus=$(printf '%s' "$_SC_STATE" | jq -r '.status')
  if [ "$rstatus" != "awaiting_confirmation" ] && [ "$rstatus" != "running" ]; then
    _sc_err "step-confirm: run '$run' is '$rstatus'; it cannot take a reply now"
    return 1
  fi

  n=$(printf '%s' "$_SC_STATE" | jq -r '.pending_gate.gate.options | length')
  ft=$(printf '%s' "$_SC_STATE" | jq -r "$_SC_JQ_DEFS"' .pending_gate.gate.options as $o | if ($o | length) > 0 and ($o[-1] | isother) then ($o | length) else 0 end')

  # trim
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"

  if [ -z "$raw" ]; then
    _sc_reject "the reply is empty. Reply with a number from 1 to $n or the exact text of an option."
    return $?
  fi

  # 1. the exact text of an option
  idx=$(printf '%s' "$_SC_STATE" | jq -r --arg r "$raw" '.pending_gate.gate.options | index($r) // empty')
  if [ -n "$idx" ]; then
    idx=$((idx + 1))
  else
    # 2. a number, optionally followed by ": text"
    local re_num='^([0-9]{1,6})$' re_text='^([0-9]{1,6})[[:space:]]*:[[:space:]]*(.*)$'
    if [[ "$raw" =~ $re_num ]]; then
      idx=$((10#${BASH_REMATCH[1]}))
    elif [[ "$raw" =~ $re_text ]]; then
      idx=$((10#${BASH_REMATCH[1]}))
      text="${BASH_REMATCH[2]}"
    else
      _sc_reject "'$raw' is neither a number nor the text of an option. Reply with a number from 1 to $n or the exact text of an option."
      return $?
    fi
  fi

  if [ "$idx" -lt 1 ] || [ "$idx" -gt "$n" ]; then
    _sc_reject "option $idx does not exist. Reply with a number from 1 to $n or the exact text of an option."
    return $?
  fi

  is_ft=false
  [ "$idx" -eq "$ft" ] && is_ft=true
  if [ "$is_ft" = true ]; then
    if [ -z "$text" ]; then
      _sc_reject "option $idx takes free text. Reply with the number, a colon and your text, for example \"$idx: your reason\"."
      return $?
    fi
  elif [ -n "$text" ]; then
    _sc_reject "option $idx does not take text. Reply with just \"$idx\"."
    return $?
  fi

  opt=$(printf '%s' "$_SC_STATE" | jq -r --argjson i "$idx" '.pending_gate.gate.options[$i - 1]')
  answer="$opt"
  [ "$is_ft" = true ] && answer="$text"

  # State changes, each idempotent so an interrupted reply is finished by repeating it. The gate goes last.
  bash "$_SC_STEP_STATE" set-output "$run" "$step" answer "$answer" || { _sc_map_rc $?; return $?; }
  bash "$_SC_STEP_STATE" set-step "$run" "$step" completed || { _sc_map_rc $?; return $?; }
  if [ "$rstatus" = "awaiting_confirmation" ]; then
    bash "$_SC_STEP_STATE" set-run-status "$run" running || { _sc_map_rc $?; return $?; }
  fi
  bash "$_SC_STEP_STATE" clear-gate "$run" || { _sc_map_rc $?; return $?; }

  jq -cn --argjson i "$idx" --arg o "$opt" --argjson ft "$is_ft" --arg t "$text" --arg a "$answer" \
    '{index: $i, option: $o, free_text: $ft, text: (if $ft then $t else null end), answer: $a}'
}

_sc_cmd_status() {
  [ "$#" -eq 1 ] || { _sc_usage_fail; return 2; }
  bash "$_SC_STEP_STATE" get-gate "$1"
  _sc_map_rc $?
}

_sc_main() {
  local cmd="${1-}"
  if [ "$#" -eq 0 ]; then
    _sc_usage_fail
    return $?
  fi
  shift
  case "$cmd" in
    -h|--help) _sc_usage; return 0 ;;
  esac
  command -v jq >/dev/null 2>&1 || { _sc_err "step-confirm: jq is required and was not found"; return 5; }
  case "$cmd" in
    start) _sc_cmd_start "$@" ;;
    reply) _sc_cmd_reply "$@" ;;
    status) _sc_cmd_status "$@" ;;
    *)
      _sc_err "step-confirm: unknown command '$cmd'"
      _sc_usage_fail
      ;;
  esac
}

_sc_main "$@"
exit $?
