#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/render-artifact.sh - run one `render` step of a workflow run: no model call, deterministic,
# published through the artifact registry (epic E80, task E80_S04_T06)
#
# A render step turns already-known values (run inputs and earlier step outputs) into a file. This script is the
# one place that executes it: it substitutes the step's references, renders the file with the chosen renderer into
# a temporary file, publishes it through artifacts.sh for every declared `kind: artifact` output, and records the
# outcome in the run state so that NO outcome leaves the step `in_progress`:
#   - success -> every artifact output holds its registry path as value, the step is `completed`
#   - any error -> nothing is published, the step is `failed`, the run is `failed`, and the reason (which names the
#     offending reference) is recorded.
# It writes only the step it was given; steps completed earlier keep their status and outputs. It never sets or
# clears the pre-flight situation marker.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   render-artifact.sh <run_id> <step_id>
#   render-artifact.sh -h | --help          print this usage on stdout, exit 0
#
# STDOUT is one JSON line:
#   success:  {"status": "completed", "step_id": "<id>", "checkpoint": true|false, "artifacts": ["<path>", ...]}
#   failure:  {"status": "halted", "step_id": "<id>", "reason": "<why>"}
# On a failure the reason is also printed on stderr.
#
# ---------------------------------------------------------------------------
# FIELD MAPPING (what E80_S01's schema calls things; the task text used other names)
# ---------------------------------------------------------------------------
#   Schema (templates/workflow-schema.json) render step: required `template` (string), optional `inputs` (string
#   map), plus the common `outputs` and `checkpoint`. It has NO `renderer` key. This script reads:
#     renderer   OPTIONAL, additive (the validator ignores unknown keys): `json` or `markdown`. When absent the
#                renderer is taken from the extension of `template`: `.json` -> json, `.md` -> markdown.
#                Anything else (html, an unknown name, an unknown extension) is rejected BEFORE any file exists.
#     template   string. For `json` it only selects the renderer by extension and is otherwise not read; the
#                `markdown` renderer reads it as the template file (see THE markdown RENDERER).
#     inputs     the field map of the json renderer: output key -> a string, which may contain references.
#     outputs    [{name, kind, type}]. Every `kind: artifact` entry is published under its `name`; `data` entries
#                are not produced by a render step and are ignored.
#   References: the task text said `{{inputs.<key>}}` and `{{steps.<step_id>.<output_name>}}`; the repository's
#   grammar (schema key substitution.pattern) is `${inputs.<name>}` and `${steps.<step_id>.outputs.<output_name>}`.
#   This script follows the schema. Substitution is done entirely by resolve-refs.sh (E80_S03_T03); there is no
#   second resolver here. A reference to a missing input, an undeclared output, a failed, skipped or not yet
#   completed step, or a malformed reference is an error that names the reference.
#
# ---------------------------------------------------------------------------
# THE json RENDERER
# ---------------------------------------------------------------------------
#   The substituted `inputs` map is the document. Output is `jq -S`: keys sorted at every level, 2-space indent,
#   one trailing newline, and nothing time- or host-dependent, so the same run state always produces a
#   byte-identical file. A step without an `inputs` object is an error.
#
# ---------------------------------------------------------------------------
# THE markdown RENDERER (E80_S04_T07)
# ---------------------------------------------------------------------------
#   Reads the step's `template` file and substitutes {{...}} placeholders. No model call; output depends only on
#   the template and the run state. Publishing, atomicity and step recording are the json renderer's code paths.
#
#   Template path. Resolved like a compute command (resolve-compute-command.sh): ONE plain token of
#   A-Z a-z 0-9 . _ @ + / -, relative to the project anchor (scripts/resolve-root.sh root), no absolute path, no
#   `..` segment, and the REAL (symlink-resolved) path of the file must lie inside the real anchor. Anything else
#   is rejected BEFORE the file is opened. Recommended home: the `templates` directory inside the workflows
#   directory (resolve-root.sh get workflows); this script never names it, it is just a path under the anchor.
#
#   Placeholders (single line each; the step `inputs` map is not used by this renderer):
#     {{inputs.<name>}}                  a run input        (the same value ${inputs.<name>} gives)
#     {{steps.<step_id>.<output_name>}}  a step output      (the same value ${steps.<step_id>.outputs.<output_name>}
#                                                            gives)
#   There is no second resolver: each placeholder is rewritten to the repository reference and resolved by
#   resolve-refs.sh's own _rr_resolve (sourced), so a failed, skipped or not yet completed step, a missing input
#   and an output the step never stored are refused exactly as in the json renderer. Names follow the schema:
#   ^[a-z][a-z0-9_]*$. No whitespace is allowed inside the braces.
#
#   Single pass. The template is scanned once; a substituted value is appended to the output and never scanned
#   again, so a step output that contains `{{inputs.x}}` appears verbatim. Escape: `\{{` in the template writes
#   a literal `{{` (the backslash is dropped, what follows is plain text). A backslash directly before `{{` always
#   escapes it; there is no way to write a literal backslash right before a placeholder. A `}}` outside a
#   placeholder is plain text.
#
#   Strict. Each of these fails the step (nothing published, no registry record) and the reason names the
#   placeholder and the template line number of its `{{`:
#     - an unresolvable placeholder (missing input, unknown step or output, step not completed/failed/skipped)
#     - an unterminated `{{` (no `}}` later on the same line)
#     - an unsupported or malformed placeholder: a namespace other than `inputs` and `steps`, an empty
#       placeholder, or a name that does not match the schema pattern
#   A value is never blank-substituted and a placeholder is never left in the output unreplaced.
#
#   Deterministic. No timestamp, no environment value, no host data. Line endings are kept as the template has
#   them (a CR before a line's LF stays). The file ends in exactly one LF: a missing final newline is added and
#   trailing empty lines of the result are collapsed (the shell strips trailing LFs before the one is written),
#   so repeated renders are byte-identical. A template containing a NUL byte is rejected.
#
# ---------------------------------------------------------------------------
# ATOMIC PUBLISH
# ---------------------------------------------------------------------------
#   The temporary file is created only AFTER the step rendered successfully, inside the run's artifact directory
#   (so it is on the same filesystem as the final location), and is removed on every exit path. Publishing is
#   `artifacts.sh register <workflow_id> <run_id> <step_id> <name> --kind artifact --type <type> --file <tmp>
#   --replace` for each declared artifact output, which stages and renames the file and writes the registry record.
#   --replace only swaps this run's own record, so retrying a step that crashed after publishing is safe.
#   A render error therefore leaves no file under the artifacts root and no registry record. Limit: a step with
#   several artifact outputs whose later register fails cannot roll back the earlier ones (artifacts.sh has no
#   unregister command); the step is still recorded as failed.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  rendered, published and the step is `completed`
#   1  the step FAILED and the failure was recorded (step `failed`, run `failed`)
#   2  nothing was run and nothing was written: usage error, invalid run or step id, the step is not in the run,
#      is not a `render` step, the run is not `running`, or the step is not `pending`/`in_progress`
#   3  the run does not exist (passed through from step-state.sh)
#   4  the run state is corrupt or unreadable (passed through)
#   5  environment failure: jq missing, a lock not obtained, or a state write failed
#
# Requires jq. Compatible with macOS bash 3.2 and safe under `set -u`.
# ---------------------------------------------------------------------------

set -u

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
STEP_STATE="$SELF_DIR/step-state.sh"
RESOLVE_REFS="$SELF_DIR/resolve-refs.sh"
ARTIFACTS="$SELF_DIR/artifacts.sh"
RESOLVE_ROOT="$SELF_DIR/../resolve-root.sh"

# shellcheck source=run-state.sh
. "$SELF_DIR/run-state.sh"
# shellcheck source=resolve-refs.sh
# Sourcing only defines functions; the markdown renderer reuses its _rr_resolve for {{...}} placeholders.
. "$SELF_DIR/resolve-refs.sh"

RA_RUN_ID=""
RA_STEP_ID=""
RA_TMP_DIR=""
RA_TMP_FILE=""

ra_err() { printf 'render-artifact.sh: %s\n' "$*" >&2; }

ra_usage() {
  printf '%s\n' \
    "Usage: render-artifact.sh <run_id> <step_id>" \
    "       render-artifact.sh -h | --help" \
    "" \
    "Renders the render step <step_id> of workflow run <run_id> (json or markdown renderer) and publishes it as an artifact." \
    "Prints {\"status\": \"completed\"|\"halted\", \"step_id\": ...}. Exit: 0 completed, 1 step failed (recorded)," \
    "2 refused or usage error (nothing written), 3 run not found, 4 corrupt state, 5 environment failure."
}

# Global variables only (never locals): the EXIT trap runs after functions have returned.
ra_cleanup() {
  [ -z "$RA_TMP_FILE" ] || rm -f "$RA_TMP_FILE"
  if [ -n "$RA_TMP_DIR" ] && [ -d "$RA_TMP_DIR" ]; then
    rm -rf "$RA_TMP_DIR"
  fi
}
trap ra_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Prints $1 on one line (newlines and tabs become spaces) and limited to 600 characters.
ra_oneline() {
  local s
  s="$(printf '%s' "$1" | tr '\n\t' '  ')"
  if [ "${#s}" -gt 600 ]; then
    s="$(printf '%s' "$s" | cut -c1-600)..."
  fi
  printf '%s' "$s"
}

# record_failed <reason>: step failed, run failed, reason in the note of the run's `-> failed` history entry,
# halted line on stdout, reason on stderr, exit 1 (5 when the state cannot be written).
record_failed() {
  local reason note
  reason="$(ra_oneline "$1")"
  note="step $RA_STEP_ID: $reason"
  if ! bash "$STEP_STATE" set-step "$RA_RUN_ID" "$RA_STEP_ID" failed >/dev/null; then
    ra_err "could not record step '$RA_STEP_ID' as failed (reason: $reason)"
    exit 5
  fi
  if ! bash "$STEP_STATE" set-run-status "$RA_RUN_ID" failed >/dev/null; then
    ra_err "could not set run '$RA_RUN_ID' to failed (step '$RA_STEP_ID' is failed; reason: $reason)"
    exit 5
  fi
  run_state_update "$RA_RUN_ID" '
    (.history | length) as $n
    | if $n > 0 and .history[$n - 1].to == "failed" then .history[$n - 1].note = $note else . end' \
    --arg note "$note" >/dev/null || ra_err "the failure note could not be written to the run history"
  ra_err "step '$RA_STEP_ID' failed: $reason"
  jq -n -c --arg id "$RA_STEP_ID" --arg r "$reason" '{status: "halted", step_id: $id, reason: $r}'
  exit 1
}

# render_json <step json>: prints the json document on stdout; returns 1 with a reason on stderr when the step has
# no `inputs` object. render_markdown (E80_S04_T07) sits beside it; step 5 of ra_main picks one.
render_json() {
  if ! printf '%s' "$1" | jq -e '(.inputs | type) == "object"' >/dev/null 2>&1; then
    printf '%s\n' "the json renderer needs an 'inputs' map (output key -> value or reference)" >&2
    return 1
  fi
  printf '%s' "$1" | jq -S '.inputs'
}

# ra_template_path <template>: prints the absolute real path of a markdown template, or returns 1 with the reason
# on stderr. Nothing is opened here; every check is on the path and on symlink targets.
ra_template_path() {
  local tpl="$1" anchor ranchor cand p n t d b real
  if [ -z "$tpl" ]; then
    printf '%s\n' "template path is empty" >&2
    return 1
  fi
  case "$tpl" in
    *[!A-Za-z0-9._@+/-]*)
      printf '%s\n' "template path '$tpl' must be one plain path token (letters, digits and . _ @ + / - only)" >&2
      return 1
      ;;
    /*)
      printf '%s\n' "template path '$tpl' must be relative to the project anchor: absolute paths are not allowed" >&2
      return 1
      ;;
  esac
  case "/$tpl/" in
    */../*)
      printf '%s\n' "template path '$tpl' must not contain a '..' segment" >&2
      return 1
      ;;
  esac
  anchor="$(bash "$RESOLVE_ROOT" root 2>/dev/null)" || {
    printf '%s\n' "the project anchor cannot be resolved" >&2
    return 1
  }
  ranchor="$(CDPATH='' cd -P -- "$anchor" 2>/dev/null && pwd -P)" || {
    printf '%s\n' "the project anchor '$anchor' is not a directory" >&2
    return 1
  }
  cand="${ranchor%/}/$tpl"
  if [ ! -e "$cand" ]; then
    printf '%s\n' "template '$tpl' does not exist" >&2
    return 1
  fi
  # Resolve symlinks in the final component by hand (no realpath on macOS bash 3.2), then the directory part.
  p="$cand"
  n=0
  while [ -L "$p" ]; do
    n=$((n + 1))
    if [ "$n" -gt 40 ]; then
      printf '%s\n' "template '$tpl' is a symlink loop" >&2
      return 1
    fi
    t="$(readlink "$p")" || return 1
    case "$t" in
      /*) p="$t" ;;
      *) p="${p%/*}/$t" ;;
    esac
  done
  d="${p%/*}"
  b="${p##*/}"
  [ -n "$d" ] || d="/"
  d="$(CDPATH='' cd -P -- "$d" 2>/dev/null && pwd -P)" || {
    printf '%s\n' "template '$tpl' does not exist" >&2
    return 1
  }
  if [ "$d" = "/" ]; then real="/$b"; else real="$d/$b"; fi
  case "$real" in
    "${ranchor%/}"/*) ;;
    *)
      printf '%s\n' "template '$tpl' resolves outside the project anchor" >&2
      return 1
      ;;
  esac
  if [ ! -f "$real" ]; then
    printf '%s\n' "template '$tpl' is not a regular file" >&2
    return 1
  fi
  if [ ! -r "$real" ]; then
    printf '%s\n' "template '$tpl' is not readable" >&2
    return 1
  fi
  printf '%s\n' "$real"
}

# ra_placeholder_value <name> <line number> <errfile>: resolves one placeholder body (the text between the braces)
# and sets RA_VALUE to its exact value. Returns 1 with the reason, which names the placeholder and the line, on
# stderr. Uses resolve-refs.sh's _rr_resolve, so the rules are the json renderer's rules.
ra_placeholder_value() {
  local name="$1" line="$2" errfile="$3" ns ref sid oname cause rc v
  ns="${name%%.*}"
  if [ "$ns" != "inputs" ] && [ "$ns" != "steps" ]; then
    if [ -z "$name" ]; then
      printf '%s\n' "template line $line: placeholder '{{}}' is empty (expected {{inputs.<name>}} or {{steps.<step_id>.<output_name>}})" >&2
    else
      printf '%s\n' "template line $line: placeholder '{{$name}}' has an unsupported namespace '$ns' (only inputs and steps are supported)" >&2
    fi
    return 1
  fi
  if [ "$ns" = "inputs" ]; then
    oname="${name#inputs.}"
    if [ "$oname" = "$name" ] || ! printf '%s' "$oname" | grep -E -q '^[a-z][a-z0-9_]*$'; then
      printf '%s\n' "template line $line: placeholder '{{$name}}' is malformed (expected {{inputs.<name>}} with a name matching ^[a-z][a-z0-9_]*\$)" >&2
      return 1
    fi
    ref="\${inputs.$oname}"
  else
    v="${name#steps.}"
    sid="${v%%.*}"
    oname="${v#*.}"
    if [ "$v" = "$name" ] || [ "$oname" = "$v" ] || ! printf '%s' "$sid" | grep -E -q '^[a-z][a-z0-9_]*$' || ! printf '%s' "$oname" | grep -E -q '^[a-z][a-z0-9_]*$'; then
      printf '%s\n' "template line $line: placeholder '{{$name}}' is malformed (expected {{steps.<step_id>.<output_name>}}, names matching ^[a-z][a-z0-9_]*\$)" >&2
      return 1
    fi
    ref="\${steps.$sid.outputs.$oname}"
  fi
  _rr_resolve "$ref" 2>"$errfile"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    cause="$(cat "$errfile")"
    case "$cause" in
      *"cannot be resolved: "*) cause="${cause#*cannot be resolved: }" ;;
    esac
    printf '%s\n' "template line $line: placeholder '{{$name}}' cannot be resolved: $cause" >&2
    return 1
  fi
  # _rr_resolve leaves the value as a JSON string; decode it without losing trailing newlines.
  v="$(printf '%s' "$_RR_VALUE_JSON" | jq -j '.'; printf x)"
  RA_VALUE="${v%x}"
  return 0
}

# render_markdown <step json>: prints the rendered text on stdout (the caller's command substitution then drops
# trailing LFs and one is written back). Returns 1 with the reason on stderr; nothing has been written to disk.
render_markdown() {
  local tpl file out line rest pre after name lineno open close errfile
  open='{{'
  close='}}'
  tpl="$(printf '%s' "$1" | jq -r 'if (.template | type) == "string" then .template else "" end')"
  file="$(ra_template_path "$tpl")" || return 1
  if [ "$(LC_ALL=C tr -d '\0' < "$file" | wc -c | tr -d ' ')" != "$(wc -c < "$file" | tr -d ' ')" ]; then
    printf '%s\n' "template '$tpl' contains a NUL byte" >&2
    return 1
  fi
  # The resolver state: the run as it is now (inputs and the status and outputs of earlier steps).
  _RR_RUN_ID="$RA_RUN_ID"
  _RR_STEP_ID="$RA_STEP_ID"
  _RR_STATE="$(bash "$STEP_STATE" get "$RA_RUN_ID")" || {
    printf '%s\n' "the run state could not be read" >&2
    return 1
  }
  errfile="$RA_TMP_DIR/ph-err"
  out=""
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    rest="$line"
    while :; do
      case "$rest" in
        *"$open"*) ;;
        *)
          out="$out$rest"
          break
          ;;
      esac
      pre="${rest%%"$open"*}"
      after="${rest#*"$open"}"
      # A backslash directly before the braces escapes them: the backslash is dropped, the braces are literal.
      if [ "${pre%\\}" != "$pre" ]; then
        out="$out${pre%\\}$open"
        rest="$after"
        continue
      fi
      case "$after" in
        *"$close"*) ;;
        *)
          printf '%s\n' "template line $lineno: unterminated placeholder '{{${after}' (no closing braces on the line)" >&2
          return 1
          ;;
      esac
      name="${after%%"$close"*}"
      rest="${after#*"$close"}"
      ra_placeholder_value "$name" "$lineno" "$errfile" || return 1
      out="$out$pre$RA_VALUE"
    done
    out="$out"$'\n'
  done < "$file"
  printf '%s' "$out"
}

ra_main() {
  local state state_rc stype sstatus rstatus cp step rc msg wf renderer template ext
  local artifacts_root dir doc rec path nart i oname otype paths_json

  case "${1-}" in
    -h|--help)
      if [ "$#" -eq 1 ]; then
        ra_usage
        exit 0
      fi
      ;;
  esac
  if [ "$#" -ne 2 ]; then
    ra_usage >&2
    exit 2
  fi
  RA_RUN_ID="$1"
  RA_STEP_ID="$2"
  if [ -z "$RA_RUN_ID" ] || [ -z "$RA_STEP_ID" ] || [ "${RA_RUN_ID#-}" != "$RA_RUN_ID" ] || [ "${RA_STEP_ID#-}" != "$RA_STEP_ID" ]; then
    ra_err "run id and step id must be non-empty and must not start with '-'"
    exit 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    ra_err "jq is required but was not found"
    exit 5
  fi

  # 1. Pre-checks: exit 2 (or the state's own status) and nothing written.
  state="$(bash "$STEP_STATE" get "$RA_RUN_ID")"
  state_rc=$?
  [ "$state_rc" -eq 0 ] || exit "$state_rc"
  stype="$(printf '%s' "$state" | jq -r --arg s "$RA_STEP_ID" '[.steps[] | select(.id == $s)] | .[0].type // empty')"
  if [ -z "$stype" ]; then
    ra_err "run '$RA_RUN_ID' has no step '$RA_STEP_ID' (valid steps: $(printf '%s' "$state" | jq -r '[.steps[].id] | join(", ")'))"
    exit 2
  fi
  if [ "$stype" != "render" ]; then
    ra_err "step '$RA_STEP_ID' is a '$stype' step; render-artifact.sh only runs render steps"
    exit 2
  fi
  rstatus="$(printf '%s' "$state" | jq -r '.status')"
  if [ "$rstatus" != "running" ]; then
    ra_err "run '$RA_RUN_ID' is $rstatus; a render step only runs while the run is running"
    exit 2
  fi
  sstatus="$(printf '%s' "$state" | jq -r --arg s "$RA_STEP_ID" '[.steps[] | select(.id == $s)] | .[0].status')"
  case "$sstatus" in
    pending|in_progress) ;;
    *)
      ra_err "step '$RA_STEP_ID' is $sstatus; only a pending or in_progress step can be run"
      exit 2
      ;;
  esac
  cp="$(printf '%s' "$state" | jq -r --arg s "$RA_STEP_ID" '[.steps[] | select(.id == $s)] | .[0].checkpoint == true')"
  wf="$(printf '%s' "$state" | jq -r '.workflow_id // empty')"

  RA_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/render-artifact.XXXXXX")" || {
    ra_err "could not create a temporary directory"
    exit 5
  }
  if [ "$sstatus" = "pending" ]; then
    if ! bash "$STEP_STATE" set-step "$RA_RUN_ID" "$RA_STEP_ID" in_progress >/dev/null; then
      ra_err "could not move step '$RA_STEP_ID' to in_progress"
      exit 5
    fi
  fi

  # 2. The step, with references substituted. From here on every problem is recorded as a step failure.
  step="$(bash "$RESOLVE_REFS" "$RA_RUN_ID" "$RA_STEP_ID" 2>"$RA_TMP_DIR/err")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    msg="$(cat "$RA_TMP_DIR/err")"
    case "$rc" in
      3|4|5)
        ra_err "$msg"
        exit "$rc"
        ;;
      1) record_failed "a reference in the step could not be resolved: $msg" ;;
      *) record_failed "the step definition could not be read: $msg" ;;
    esac
  fi

  # 3. The renderer, decided before anything is rendered or written.
  renderer="$(printf '%s' "$step" | jq -r 'if (.renderer | type) == "string" then .renderer else "" end')"
  if [ -z "$renderer" ]; then
    template="$(printf '%s' "$step" | jq -r 'if (.template | type) == "string" then .template else "" end')"
    ext="${template##*.}"
    [ "$ext" != "$template" ] || ext=""
    case "$ext" in
      json) renderer="json" ;;
      md) renderer="markdown" ;;
      *) record_failed "no renderer: the step has no 'renderer' and its template '$template' does not end in .json or .md" ;;
    esac
  fi
  case "$renderer" in
    json) ;;
    markdown) ;;
    *) record_failed "unknown renderer '$renderer': the v1 renderers are json and markdown" ;;
  esac

  # 4. The declared artifact outputs. A render step with nothing to publish is a definition error.
  nart="$(printf '%s' "$step" | jq -r '[(.outputs // [])[] | select(.kind == "artifact")] | length')"
  if [ "$nart" -lt 1 ]; then
    record_failed "the step declares no output with kind 'artifact', so there is nothing to publish"
  fi
  if ! printf '%s' "$step" | jq -e '[(.outputs // [])[] | select(.kind == "artifact") | .name] | all(type == "string" and test("^[a-z][a-z0-9_]*$"))' >/dev/null 2>&1; then
    record_failed "an artifact output has a name that does not match ^[a-z][a-z0-9_]*\$"
  fi

  # 5. Render in memory. A failure here has written nothing.
  if [ "$renderer" = "markdown" ]; then
    doc="$(render_markdown "$step" 2>"$RA_TMP_DIR/err")"
  else
    doc="$(render_json "$step" 2>"$RA_TMP_DIR/err")"
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    record_failed "$renderer render failed: $(cat "$RA_TMP_DIR/err")"
  fi

  # 6. The first file: a temporary one next to the final location (same filesystem), only now that rendering worked.
  artifacts_root="$(bash "$RESOLVE_ROOT" get workflow_artifacts 2>"$RA_TMP_DIR/err")" || record_failed "the artifacts root cannot be resolved: $(cat "$RA_TMP_DIR/err")"
  [ -n "$wf" ] || record_failed "the run has no workflow_id"
  dir="${artifacts_root%/}/$wf/$RA_RUN_ID"
  mkdir -p "$dir" 2>/dev/null || record_failed "could not create the artifact directory '$dir'"
  RA_TMP_FILE="$(mktemp "$dir/.render.XXXXXX")" || record_failed "could not create a temporary file in '$dir'"
  printf '%s\n' "$doc" > "$RA_TMP_FILE" || record_failed "could not write the rendered file"

  # 7. Publish through the registry, one record per declared artifact output.
  paths_json='[]'
  i=0
  while [ "$i" -lt "$nart" ]; do
    oname="$(printf '%s' "$step" | jq -r --argjson i "$i" '[(.outputs // [])[] | select(.kind == "artifact")] | .[$i].name')"
    otype="$(printf '%s' "$step" | jq -r --argjson i "$i" '[(.outputs // [])[] | select(.kind == "artifact")] | .[$i].type // "text"')"
    rec="$(bash "$ARTIFACTS" register "$wf" "$RA_RUN_ID" "$RA_STEP_ID" "$oname" --kind artifact --type "$otype" --file "$RA_TMP_FILE" --replace 2>"$RA_TMP_DIR/err")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      record_failed "publishing artifact '$oname' failed (artifacts.sh exit $rc): $(cat "$RA_TMP_DIR/err")"
    fi
    path="$(printf '%s' "$rec" | jq -r '.path // empty')"
    [ -n "$path" ] || record_failed "artifacts.sh registered '$oname' but returned no path"
    if ! bash "$STEP_STATE" set-output "$RA_RUN_ID" "$RA_STEP_ID" "$oname" "$path" >/dev/null; then
      ra_err "could not store output '$oname' of step '$RA_STEP_ID'"
      exit 5
    fi
    paths_json="$(printf '%s' "$paths_json" | jq -c --arg p "$path" '. + [$p]')"
    i=$((i + 1))
  done

  # 8. Record success.
  if ! bash "$STEP_STATE" set-step "$RA_RUN_ID" "$RA_STEP_ID" completed >/dev/null; then
    ra_err "could not record step '$RA_STEP_ID' as completed"
    exit 5
  fi
  if [ "$cp" = "true" ]; then
    if ! bash "$STEP_STATE" checkpoint "$RA_RUN_ID" "$RA_STEP_ID" >/dev/null; then
      ra_err "could not write the checkpoint for step '$RA_STEP_ID'"
      exit 5
    fi
  fi
  jq -n -c --arg id "$RA_STEP_ID" --argjson cp "$cp" --argjson a "$paths_json" '{status: "completed", step_id: $id, checkpoint: $cp, artifacts: $a}'
  exit 0
}

ra_main "$@"
