#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/resolve-refs.sh - substitute run-input and step-output references in one step
# (epic E80, task E80_S03_T03)
#
# The runtime half of the reference syntax E80_S01 defines and validate-workflow.sh checks statically: given a
# run and one of its steps, it replaces every reference in the step's string fields with the real value and
# prints the step object as JSON. Deterministic, single pass, and all-or-nothing: every reference is resolved
# BEFORE anything is printed, so a failure leaves stdout empty and never produces an empty-string substitution.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   resolve-refs.sh <run_id> <step_id>
#   resolve-refs.sh -h | --help       print this usage on stdout, exit 0
#
#   Output: the whole step object (as defined in the run's workflow definition) on stdout, pretty-printed with
#   keys sorted (jq -S), so two runs against the same state print byte-identical text. A step with no
#   references is printed unchanged, in the same key-sorted form.
#
# ---------------------------------------------------------------------------
# GRAMMAR - SOURCE OF TRUTH
# ---------------------------------------------------------------------------
#   The reference grammar lives in templates/workflow-schema.json, key substitution.pattern (found through
#   workflow_schema_path in lib.sh; this script does not repeat it):
#       ${inputs.<name>}      ${steps.<step_id>.outputs.<output_name>}
#   validate-workflow.sh reads the same key. ONE duplication remains and is deliberate: to tell a malformed
#   reference from text that is not a reference at all, both scripts hard-code the same loose token regex
#       \$\{(?:inputs|steps)(?:\.[^}]*)?\}
#   (validator: reference_problems; here: _RR_LOOSE). A token that matches the loose regex but not the schema
#   pattern is malformed (exit 1). Any other ${...}, such as ${HOME}, is not a reference and is emitted as is.
#   If the loose regex ever changes, change both scripts. project/documentation/workflows.md records this.
#
#   There is NO escape syntax in that grammar (no "$${", no backslash), so none is implemented here. The only
#   literal pass-through is the one the grammar defines: text that is not a reference is left alone. A
#   substituted value is never rescanned, so a value that itself looks like a reference stays literal.
#
# ---------------------------------------------------------------------------
# WHICH FIELDS, AND WHERE VALUES COME FROM
# ---------------------------------------------------------------------------
#   Every string value in the step is substituted (including strings nested in arrays such as options and args,
#   and in maps such as args and a render step's inputs) except the fields id, type, skill, playbook, outputs and
#   checkpoint. Object keys are never substituted.
#   Run inputs: the "inputs" object of the run state (scripts/workflow/step-state.sh get <run_id>); a value that
#   is not a string is inserted as compact JSON.
#   Step outputs: ONLY scripts/workflow/step-state.sh get-output <run_id> <step_id> <output_name>. The step's
#   definition comes from scripts/workflow/load-workflows.sh lookup <workflow_id>, with workflow_id taken from
#   the state file (see the header of run-state.sh for the state format).
#
# ---------------------------------------------------------------------------
# ERRORS (exit 1; stdout stays empty; stderr names the reference and the cause)
# ---------------------------------------------------------------------------
#   - a reference to a run input the run does not have
#   - a reference to an output of a step that is skipped, or failed (get-output's own refusal is quoted)
#   - a reference to a step that has not completed yet (status pending or in_progress, including the step itself)
#   - a reference to an output the step does not have (get-output's refusal is quoted)
#   - a reference to a step the run does not have
#   - a malformed reference (matches the loose regex, not the schema pattern)
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   the resolved step was printed
#   1   a reference could not be resolved, or a reference is malformed
#   2   usage error, an invalid run or step id, a step id the workflow does not define, or the workflow definition
#       cannot be looked up (load-workflows.sh lookup's own status)
#   3   the run does not exist (step-state.sh / run-state.sh status, passed through)
#   4   the run state file is corrupt (passed through)
#   5   jq is missing, or a lock was not obtained in time (passed through)
#
# A value read through get-output keeps its exact text: get-output ends it with one newline, which is removed
# here, so even a value with trailing newlines is substituted unchanged.
# Requires jq. Compatible with macOS bash 3.2 and safe under "set -u". Sourcing prints nothing and creates nothing
# beyond the lib.sh functions.
# ---------------------------------------------------------------------------

set -u

_RR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
. "$_RR_DIR/lib.sh"

# The loose token regex shared (by duplication) with validate-workflow.sh's reference_problems. See the header.
_RR_LOOSE='\$\{(?:inputs|steps)(?:\.[^}]*)?\}'
# Step fields that are never substituted (the schema's substitutable_fields rule plus outputs and checkpoint).
_RR_EXCLUDED='["id","type","skill","playbook","outputs","checkpoint"]'

_rr_err() {
  printf '%s\n' "$*" >&2
}

_rr_usage_text() {
  cat <<'USAGE'
Usage: resolve-refs.sh <run_id> <step_id>
       resolve-refs.sh -h | --help

Prints the step <step_id> of run <run_id> as JSON (keys sorted) with every ${inputs.<name>} and
${steps.<step_id>.outputs.<output_name>} reference replaced by its value. Nothing is printed on failure.
Exit: 0 ok, 1 reference error or malformed reference, 2 usage or unknown step, 3 run not found,
4 corrupt state, 5 jq missing or lock timeout.
USAGE
}

_rr_usage_fail() {
  _rr_usage_text >&2
  return 2
}

# Resolves one reference token $1 against the state in $_RR_STATE. On success sets _RR_VALUE_JSON to the value
# as a JSON string and returns 0. On failure prints the message and returns the exit code.
_rr_resolve() {
  local ref="$1" body kind name rest sid oname status raw rc val

  body="${ref:2:${#ref}-3}"
  kind="${body%%.*}"

  if [ "$kind" = "inputs" ]; then
    name="${body#inputs.}"
    if ! printf '%s' "$_RR_STATE" | jq -e --arg n "$name" '(.inputs | type == "object") and (.inputs | has($n))' >/dev/null 2>&1; then
      _rr_err "resolve-refs: step '$_RR_STEP_ID': reference '$ref' cannot be resolved: the run has no input named '$name'"
      return 1
    fi
    _RR_VALUE_JSON="$(printf '%s' "$_RR_STATE" | jq -c --arg n "$name" '.inputs[$n] | if type == "string" then . else tojson end')" || return 5
    return 0
  fi

  rest="${body#steps.}"
  sid="${rest%%.outputs.*}"
  oname="${rest#*.outputs.}"
  status="$(printf '%s' "$_RR_STATE" | jq -r --arg s "$sid" '[.steps[] | select(.id == $s)] | .[0] | if . == null then "" else .status end')" || return 5
  if [ -z "$status" ]; then
    _rr_err "resolve-refs: step '$_RR_STEP_ID': reference '$ref' cannot be resolved: the run has no step '$sid'"
    return 1
  fi
  case "$status" in
    completed|skipped|failed) ;;
    *)
      _rr_err "resolve-refs: step '$_RR_STEP_ID': reference '$ref' cannot be resolved: step '$sid' has not completed yet (status: $status)"
      return 1
      ;;
  esac

  # stdout and stderr are captured together; the exit status rides at the end after a marker character so
  # command substitution cannot eat the value's trailing newlines.
  raw="$(bash "$_RR_DIR/step-state.sh" get-output "$_RR_RUN_ID" "$sid" "$oname" 2>&1; printf 'x%s' "$?")"
  rc="${raw##*x}"
  raw="${raw%x*}"
  if [ "$rc" -ne 0 ]; then
    _rr_err "resolve-refs: step '$_RR_STEP_ID': reference '$ref' cannot be resolved: ${raw%$'\n'}"
    [ "$rc" -eq 1 ] && return 1
    return "$rc"
  fi
  val="${raw%$'\n'}"
  _RR_VALUE_JSON="$(printf '%s' "$val" | jq -Rs .)" || return 5
  return 0
}

_rr_main() {
  local state_rc def_rc wf_id def step refs bad good ref map rc pattern schema

  case "${1-}" in
    -h|--help)
      if [ "$#" -eq 1 ]; then
        _rr_usage_text
        return 0
      fi
      ;;
  esac
  if [ "$#" -ne 2 ]; then
    _rr_usage_fail
    return $?
  fi
  _RR_RUN_ID="$1"
  _RR_STEP_ID="$2"
  if [ -z "$_RR_RUN_ID" ] || [ -z "$_RR_STEP_ID" ] || [ "${_RR_STEP_ID#-}" != "$_RR_STEP_ID" ] || [ "${_RR_RUN_ID#-}" != "$_RR_RUN_ID" ]; then
    _rr_err "resolve-refs: run id and step id must be non-empty and must not start with '-'"
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    _rr_err "resolve-refs: jq is required but was not found"
    return 5
  fi

  _RR_STATE="$(bash "$_RR_DIR/step-state.sh" get "$_RR_RUN_ID")"
  state_rc=$?
  if [ "$state_rc" -ne 0 ]; then
    return "$state_rc"
  fi
  wf_id="$(printf '%s' "$_RR_STATE" | jq -r '.workflow_id // empty')"
  if [ -z "$wf_id" ]; then
    _rr_err "resolve-refs: run '$_RR_RUN_ID' has no workflow_id in its state"
    return 4
  fi

  def="$(bash "$_RR_DIR/load-workflows.sh" lookup "$wf_id")"
  def_rc=$?
  if [ "$def_rc" -ne 0 ]; then
    _rr_err "resolve-refs: cannot look up workflow '$wf_id' of run '$_RR_RUN_ID'"
    return "$def_rc"
  fi
  step="$(printf '%s' "$def" | jq -c --arg s "$_RR_STEP_ID" '[.steps[]? | select(.id == $s)] | .[0] // empty')"
  if [ -z "$step" ]; then
    _rr_err "resolve-refs: workflow '$wf_id' has no step '$_RR_STEP_ID'"
    return 2
  fi

  schema="$(workflow_schema_path)" || return 2
  pattern="$(jq -r '.substitution.pattern // empty' "$schema")"
  if [ -z "$pattern" ]; then
    _rr_err "resolve-refs: $schema has no substitution.pattern"
    return 2
  fi

  # Collect the distinct reference candidates of the substitutable strings; split them into well-formed and
  # malformed against the schema pattern.
  refs="$(printf '%s' "$step" | jq -c --arg loose "$_RR_LOOSE" --arg pat "^${pattern}\$" --argjson ex "$_RR_EXCLUDED" '
    with_entries(select(.key as $k | ($ex | index($k)) == null))
    | [ .. | strings | scan($loose) ] | unique
    | { good: map(select(test($pat))), bad: map(select(test($pat) | not)) }')" || return 5

  bad="$(printf '%s' "$refs" | jq -r '.bad[] | "  " + @json')"
  if [ -n "$bad" ]; then
    _rr_err "resolve-refs: step '$_RR_STEP_ID' has malformed reference(s) (expected \${inputs.<name>} or \${steps.<step_id>.outputs.<output_name>}):"
    _rr_err "$bad"
    return 1
  fi

  map='{}'
  good="$(printf '%s' "$refs" | jq -r '.good[]')"
  if [ -n "$good" ]; then
    while IFS= read -r ref; do
      _rr_resolve "$ref"
      rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      map="$(printf '%s' "$map" | jq -c --arg k "$ref" --argjson v "$_RR_VALUE_JSON" '. + {($k): $v}')" || return 5
    done <<< "$good"
  fi

  # One pass: every match is looked up in the map, so a substituted value is never scanned again.
  printf '%s' "$step" | jq -S --arg loose "$_RR_LOOSE" --argjson ex "$_RR_EXCLUDED" --argjson map "$map" '
    with_entries(
      if (.key as $k | ($ex | index($k)) != null) then .
      else .value |= walk(if type == "string" then gsub("(?<ref>" + $loose + ")"; $map[.ref]) else . end)
      end)' || return 5
}

# Dispatch only when executed, never when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _rr_main "$@"
  exit $?
fi
