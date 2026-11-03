#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-recorder/scripts/emit-workflow.sh - the emission layer (epic E89, task E89_S04_T01)
#
# Turns a CLOSED recording into a runnable workflow definition. This is the first path that produces a definition
# from observed behaviour rather than from an author writing JSON, and it is what makes epic E89 belong next to
# epic E80: the definition it writes is the file `j.workflow list` shows and `j.workflow run` executes.
#
#   emit-workflow.sh <recording-path>
#
# writes <id>.json into the directory `scripts/resolve-root.sh get workflows` prints and prints that path on
# stdout, and nothing else. Nothing in this file names that directory.
#
# Like its siblings it reads and writes only the recording path it is GIVEN. The parse contract is
# recording-format.sh (sourced); annotations are read and written ONLY through record-answer.sh, so this file adds
# no second parser and no second writer of the annotation format.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   emit-workflow.sh [--answer <step-id>=<type>]... <recording-path>
#   emit-workflow.sh -h | --help | help              print this usage on stdout, exit 0
#
#   --answer <step-id>=<type>   the Scrum Master's step-type judgment for a step that has none yet. <type> is one
#                               of skill, playbook, confirm, compute, render. Repeatable. Written into the
#                               recording through `record-answer.sh <path> <step-id> step-type <type>` BEFORE
#                               emission continues, so the judgment is made once and persisted. Refused (exit 2,
#                               nothing written) for an unknown step, an excluded step, a step that already has a
#                               step-type annotation (use record-answer.sh --replace to change a judgment on
#                               purpose), or a type outside the five.
#
# ---------------------------------------------------------------------------
# HOW A STEP BECOMES A DEFINITION STEP
# ---------------------------------------------------------------------------
# 1. EXCLUSION, FIRST AND ABSOLUTE. A step carrying deviation: out-of-process is not emitted - a single positive
#    membership test, the one record-answer.sh's header specifies. It is decided before anything else is read, so
#    an excluded step is never asked for a step type, and a `relevance` body on it is NEVER emitted. That second
#    half is the E89_S06_T17 precedence rule: the interrogation ladder may leave a step with BOTH an out-of-process
#    verdict and a relevance body (a detour inside a continuing process), and exclusion wins.
# 2. STEP TYPE IS A PERSISTED JUDGMENT, NEVER A LOOKUP. Each included step maps to one of E80's five types. There
#    is deliberately no table from "which tool ran" to a type: the recording knows what the user wrote, not
#    reliably which tool executed. A step-type annotation is used VERBATIM and never re-judged. A step with none
#    cannot be emitted: the script prints the unannotated steps (see EXIT 9), the Scrum Master judges them, and the
#    answers go back in through --answer, which persists them with record-answer.sh. Judgment is not reproducible;
#    persisting it is what makes re-emission deterministic.
# 3. THE TYPE'S REQUIRED FIELDS COME FROM THE STEP'S TEXT, not from a tool and not from a second judgment:
#      skill      skill = the first word of the text, `/j-x` or `j.x` normalised to `j.x` (or jenga,
#                 jenga-config, jenga-permission-level); the rest of the text becomes args.input.
#      playbook   the first word is `j.playbook`/`/j-playbook`; playbook = the second word (a slug).
#      confirm    prompt = the text; options = ["Yes", "No"] (step-confirm.sh appends the free-text entry).
#      compute    command = the first word, which must be a plain relative path token (the shape
#                 resolve-compute-command.sh confines to); the remaining words become args.
#      render     template = the first word, a relative path token ending in .json or .md.
#    If a judged type cannot be filled from its text, the script does NOT guess: it exits 10 naming every such
#    step, the field that is missing and the way out (record-answer.sh --replace to a type that fits).
# 4. DESCRIPTION. An included step's `description` is its stated relevance when it has one (the body of its
#    `relevance` annotation), else its recorded text. Both verbatim.
# 5. Step ids: the recording's `step-003` becomes `step_003`, which satisfies the schema's underscore rule and is
#    unique because the recording's ids are.
#
# THE DOCUMENT: id = the recording's file name minus _RECORDING.md (it must match the schema's id_pattern, which is
# read from templates/workflow-schema.json, not restated); name = the recording's "# Recording:" heading;
# description = a one-line statement of where the definition came from; source_recording = the recording's file
# name; steps. Key order is fixed and nothing time-dependent is written, so EMITTING TWICE FROM THE SAME
# FULLY-ANNOTATED RECORDING PRODUCES BYTE-IDENTICAL JSON.
#
# ---------------------------------------------------------------------------
# VALIDATION - THE EXISTING VALIDATOR, ONE CANDIDATE, NOTHING LEFT BEHIND
# ---------------------------------------------------------------------------
# The candidate is written next to its destination under a hidden name that the workflow loader's *.json glob does
# not match, and is checked with scripts/workflow/validate-workflow.sh (there is no second validator). Only a clean
# pass moves it into place, with one mv on the same filesystem. On a failure the validator's own text is printed on
# stderr, the candidate is removed (and a directory this run created, if still empty), nothing exists at the
# destination that this run put there, and the exit code is 8. A failure never leaves a file claiming to be valid.
#
# ---------------------------------------------------------------------------
# THE CROSS-LINK, IN THE SAME PASS
# ---------------------------------------------------------------------------
#   recording  -> definition   `emitted_workflow: <id>` in the recording's frontmatter (added, or replaced when a
#                              re-emission finds it). The rewrite is a same-directory temp file and an atomic mv,
#                              the way close-recording.sh seals a recording; everything below the frontmatter is
#                              byte-identical.
#   definition -> recording    `source_recording: <file name>` at the top level of the JSON. The schema does not
#                              list this key; it declares no additionalProperties rule and the validator ignores
#                              unknown keys (as it does for the `timeout_seconds` and `renderer` keys other
#                              definitions already carry), so it is additive. The file NAME, not a path, so a
#                              committed definition carries nothing machine-specific.
# A re-emission may overwrite a definition only when the recording already names it. If the destination exists and
# the recording does not name that id, it belongs to something else and is refused (exit 7), untouched.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   emitted. The definition's path is on stdout. Nothing else is.
#   2   usage error: an unknown option, a missing recording path, or a bad --answer (see above). Nothing written.
#   3   the recording does not exist or is not readable.
#   4   the recording is not closed (frontmatter status is not `closed`). Emission runs against a sealed
#       recording so the definition cannot disagree with its own source. Nothing written.
#   5   the recording cannot be emitted from as it stands: ambiguous markers (recording-format.sh's rec_check), no
#       steps section, a file name that is not <slug>_RECORDING.md, or a slug that does not match the schema's
#       id_pattern. Nothing written.
#   6   the environment is incomplete: jq, a sibling script, the validator, the schema, or the workflows
#       directory could not be found or resolved. Nothing written.
#   7   a write was refused or failed: the destination belongs to another definition, or a temp file, mv or the
#       recording's frontmatter rewrite failed. A definition this run put in place is taken back out.
#   8   the candidate failed validation. The validator's text is on stderr; nothing remains at the destination.
#   9   one or more included steps have no step-type annotation. STDOUT is `<step-id><TAB><first line of the
#       step's text>`, one line per such step; stderr explains how to answer. Answers given with --answer in the
#       same call are already persisted. Nothing is emitted; re-run with --answer for the rest.
#   10  an included step has a judged type that cannot be filled from its text (see HOW A STEP BECOMES...). stderr
#       names each step. Nothing is emitted.
#
# ENVIRONMENT
#   JENGA_RECORDER_NOW   is honoured by record-answer.sh (the stamp on a written annotation); this script writes no
#                        timestamp itself.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe under
# `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$SCRIPT_DIR/../../../scripts"
RESOLVE_ROOT="$SHARED_DIR/resolve-root.sh"
VALIDATOR="$SHARED_DIR/workflow/validate-workflow.sh"
WORKFLOW_LIB="$SHARED_DIR/workflow/lib.sh"
ANSWER_SCRIPT="$SCRIPT_DIR/record-answer.sh"
FORMAT_LIB="$SCRIPT_DIR/recording-format.sh"

RECORDING_SUFFIX='_RECORDING.md'
LINK_KEY='emitted_workflow'
TYPES='skill playbook confirm compute render'

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'USAGE'
usage:
  emit-workflow.sh [--answer <step-id>=<type>]... <recording-path>
  emit-workflow.sh -h | --help | help

Writes a workflow definition from a CLOSED recording into the directory `resolve-root.sh get workflows` prints, and
prints the definition's path. Step types are the Scrum Master's persisted judgment (the step-type annotation):
a step without one makes the script print it and exit 9; answer with --answer <step-id>=<type> (skill, playbook,
confirm, compute, render) and the judgment is written into the recording before emission continues.
Out-of-process steps are excluded; a stated relevance becomes the step's description. The candidate is validated
by scripts/workflow/validate-workflow.sh and only a clean pass is moved into place. The recording and the
definition name each other. Full contract and exit codes: the header of this script.
USAGE
}

# ---- cleanup -----------------------------------------------------------------------------------------------------
CANDIDATE=""
REC_TMP=""
MADE_DIR=""
cleanup() {
  [ -n "$CANDIDATE" ] && rm -f "$CANDIDATE"
  [ -n "$REC_TMP" ] && rm -f "$REC_TMP"
  if [ -n "$MADE_DIR" ]; then rmdir "$MADE_DIR" 2>/dev/null; fi
  return 0
}
trap cleanup EXIT INT TERM

# ---- arguments ---------------------------------------------------------------------------------------------------
REC=""
ANSWERS=""   # newline-separated "<step-id>=<type>"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage; trap - EXIT INT TERM; exit 0 ;;
    --answer)
      [ "$#" -ge 2 ] || { usage >&2; die 2 "--answer needs <step-id>=<type>"; }
      case "$2" in
        ?*=?*) ANSWERS="${ANSWERS}${2}
" ;;
        *) die 2 "--answer wants <step-id>=<type>, got \"$2\"" ;;
      esac
      shift 2 ;;
    --answer=*)
      case "${1#--answer=}" in
        ?*=?*) ANSWERS="${ANSWERS}${1#--answer=}
" ;;
        *) die 2 "--answer wants <step-id>=<type>, got \"${1#--answer=}\"" ;;
      esac
      shift ;;
    -*) usage >&2; die 2 "unknown option: $1" ;;
    *)
      [ -z "$REC" ] || die 2 "more than one recording path given: $REC and $1"
      REC="$1"; shift ;;
  esac
done
[ -n "$REC" ] || { usage >&2; die 2 "a recording path is required"; }

# ---- environment -------------------------------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || die 6 "jq is required and was not found; nothing was written"
[ -r "$FORMAT_LIB" ] || die 6 "cannot read the parse contract library $FORMAT_LIB; refusing to parse a recording without it"
# shellcheck source=recording-format.sh
. "$FORMAT_LIB"
[ -f "$ANSWER_SCRIPT" ] || die 6 "cannot find $ANSWER_SCRIPT; nothing was written"
[ -f "$VALIDATOR" ] || die 6 "cannot find the workflow validator $VALIDATOR; nothing was written"
[ -f "$RESOLVE_ROOT" ] || die 6 "cannot find $RESOLVE_ROOT; nothing was written"
[ -f "$WORKFLOW_LIB" ] || die 6 "cannot find $WORKFLOW_LIB; nothing was written"
# shellcheck source=/dev/null
. "$WORKFLOW_LIB" || die 6 "could not load $WORKFLOW_LIB"
SCHEMA="$(workflow_schema_path 2>/dev/null)" || die 6 "could not locate templates/workflow-schema.json; nothing was written"
[ -r "$SCHEMA" ] || die 6 "cannot read the schema $SCHEMA; nothing was written"
ID_PATTERN="$(jq -r '.top_level.id_pattern // empty' "$SCHEMA" 2>/dev/null)"
STEP_ID_PATTERN="$(jq -r '.step_common.step_id_pattern // empty' "$SCHEMA" 2>/dev/null)"
[ -n "$ID_PATTERN" ] && [ -n "$STEP_ID_PATTERN" ] || die 6 "$SCHEMA carries no id_pattern / step_id_pattern; nothing was written"

# ---- the recording -----------------------------------------------------------------------------------------------
[ -f "$REC" ] || die 3 "no such recording: $REC"
[ -r "$REC" ] || die 3 "recording is not readable: $REC"
[ "$(rec_frontmatter_value "$REC" status)" = "closed" ] || \
  die 4 "$REC is not closed (frontmatter status is not 'closed'); seal it with close-recording.sh first. Nothing was written."
rec_has_steps_section "$REC" || die 5 "$REC has no steps section; nothing to emit from"
if ! problems="$(rec_check "$REC")"; then
  err "the recording's markers are ambiguous, so it cannot be parsed safely:"
  printf '%s\n' "$problems" | sed 's/^/  /' >&2
  exit 5
fi

BASE="$(basename "$REC")"
case "$BASE" in
  *"$RECORDING_SUFFIX") WF_ID="${BASE%"$RECORDING_SUFFIX"}" ;;
  *) die 5 "$BASE does not end in $RECORDING_SUFFIX, so no workflow id can be derived from it" ;;
esac
printf '%s\n' "$WF_ID" | grep -Eq "$ID_PATTERN" || \
  die 5 "the id \"$WF_ID\" derived from $BASE does not match the schema's id_pattern $ID_PATTERN"

DEST_DIR="$(bash "$RESOLVE_ROOT" get workflows 2>/dev/null)" && [ -n "$DEST_DIR" ] || \
  die 6 "could not resolve the workflows directory with resolve-root.sh get workflows; nothing was written"
DEST="$DEST_DIR/$WF_ID.json"

# A definition already at the destination is overwritten only when this recording already names it.
if [ -e "$DEST" ] && [ "$(rec_frontmatter_value "$REC" "$LINK_KEY")" != "$WF_ID" ]; then
  die 7 "$DEST already exists and $BASE does not name it as its own (no '$LINK_KEY: $WF_ID' in its frontmatter); refusing to overwrite another definition"
fi

# ---- reading annotations (only ever through record-answer.sh) ----------------------------------------------------
ANN=""
# ann_value <step-id> <kind>: sets ANN and returns 0, or returns 1 when the step has no such annotation.
ann_value() {
  local out rc
  out="$(bash "$ANSWER_SCRIPT" --value "$REC" "$1" "$2" 2>/dev/null)"; rc=$?
  case "$rc" in
    0) ANN="$out"; return 0 ;;
    1) ANN=""; return 1 ;;
    *) die 5 "record-answer.sh --value failed (exit $rc) reading $2 on $1 in $REC" ;;
  esac
}
# ann_text <step-id> <kind>: sets ANN to the verbatim answer text.
ann_text() {
  local out rc
  out="$(bash "$ANSWER_SCRIPT" --text "$REC" "$1" "$2" 2>/dev/null)"; rc=$?
  case "$rc" in
    0) ANN="$out"; return 0 ;;
    1) ANN=""; return 1 ;;
    *) die 5 "record-answer.sh --text failed (exit $rc) reading $2 on $1 in $REC" ;;
  esac
}

# step_text <step-id>: the step's recorded text, verbatim: from the line after the heading's blank line to the
# first column-1 annotation or step-end marker, trailing blank lines dropped, the body escape reversed.
step_text() {
  local open
  open="$(rec_step_open_line "$REC" "$1")" || return 1
  if rec_is_escaped_format "$REC"; then
    awk -v start="$open" -v ap="$REC_ANSWER_MARKER_PREFIX" -v se="$REC_STEP_END_PREFIX" '
      NR < start + 3 { next }
      index($0, ap) == 1 || index($0, se) == 1 { exit }
      $0 == "" { blank++; next }
      { while (blank > 0) { print ""; blank-- } print }
    ' "$REC" | rec_unescape_body
  else
    awk -v start="$open" -v ap="$REC_ANSWER_MARKER_PREFIX" -v se="$REC_STEP_END_PREFIX" '
      NR < start + 3 { next }
      index($0, ap) == 1 || index($0, se) == 1 { exit }
      $0 == "" { blank++; next }
      { while (blank > 0) { print ""; blank-- } print }
    ' "$REC"
  fi
}

STEP_IDS="$(rec_step_ids "$REC")"

has_line() { printf '%s\n' "$1" | grep -Fxq -- "$2"; }
is_type() { local t; for t in $TYPES; do [ "$t" = "$1" ] && return 0; done; return 1; }

# ---- validate every --answer BEFORE anything is written ----------------------------------------------------------
if [ -n "$ANSWERS" ]; then
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    a_id="${a%%=*}"; a_type="${a#*=}"
    has_line "$STEP_IDS" "$a_id" || die 2 "--answer names $a_id, which is not a step in $BASE; nothing was written"
    is_type "$a_type" || die 2 "--answer $a_id=$a_type: the type must be one of: $TYPES; nothing was written"
    if ann_value "$a_id" deviation && [ "$ANN" = "out-of-process" ]; then
      die 2 "--answer names $a_id, which is excluded (deviation: out-of-process) and is never emitted, so it takes no type; nothing was written"
    fi
    if ann_value "$a_id" step-type; then
      die 2 "$a_id already carries the step-type annotation \"$ANN\", which is used verbatim; change it deliberately with record-answer.sh --replace. Nothing was written."
    fi
  done <<EOF
$ANSWERS
EOF
fi

# answer_for <step-id>: sets ANN to the --answer type for that step; returns 1 if none.
answer_for() {
  local a
  ANN=""
  [ -n "$ANSWERS" ] || return 1
  while IFS= read -r a; do
    [ "${a%%=*}" = "$1" ] || continue
    ANN="${a#*=}"; return 0
  done <<EOF
$ANSWERS
EOF
  return 1
}

# ---- pass 1: exclusion, then type (persisting any answer given) --------------------------------------------------
INC_IDS=""      # newline-separated included step ids, in recording order
INC_TYPES=""    # the matching types, same order
MISSING=""
for sid in $STEP_IDS; do
  if ann_value "$sid" deviation && [ "$ANN" = "out-of-process" ]; then
    continue
  fi
  if ann_value "$sid" step-type; then
    stype="$ANN"
  elif answer_for "$sid"; then
    stype="$ANN"
    if ! bash "$ANSWER_SCRIPT" "$REC" "$sid" step-type "$stype" >/dev/null; then
      die 7 "record-answer.sh could not persist step-type $stype on $sid; emission stopped before anything was emitted"
    fi
  else
    first="$(step_text "$sid" | sed -n '1p')"
    MISSING="${MISSING}${sid}	${first}
"
    continue
  fi
  is_type "$stype" || die 5 "$sid carries the step-type \"$stype\", which is not one of: $TYPES"
  INC_IDS="${INC_IDS}${sid}
"
  INC_TYPES="${INC_TYPES}${stype}
"
done

if [ -n "$MISSING" ]; then
  printf '%s' "$MISSING"
  {
    printf '%s: the step(s) above have no step-type annotation. Judge what each one WAS in the process (%s),\n' "$SELF" "$TYPES"
    printf '%s: then re-run with --answer <step-id>=<type> for each; the answer is written into the recording first.\n' "$SELF"
  } >&2
  exit 9
fi

# ---- pass 2: build the steps -------------------------------------------------------------------------------------
STEPS_JSONL=""
UNFILLED=""
n=0
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  n=$(( n + 1 ))
  stype="$(printf '%s' "$INC_TYPES" | sed -n "${n}p")"

  text="$(step_text "$sid")"
  text="${text#"${text%%[![:space:]]*}"}"
  w1=""; rest=""
  if [ -n "$text" ]; then
    first_line="$(printf '%s\n' "$text" | sed -n '1p')"
    w1="${first_line%%[[:space:]]*}"
    rest="${text#"$w1"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
  fi

  desc="$text"
  if ann_value "$sid" relevance && ann_text "$sid" relevance && [ -n "$ANN" ]; then
    desc="$ANN"
  fi

  wf_step_id="$(printf '%s' "$sid" | tr '-' '_')"
  printf '%s\n' "$wf_step_id" | grep -Eq "$STEP_ID_PATTERN" || \
    die 5 "$sid maps to the step id \"$wf_step_id\", which does not match the schema's step id pattern $STEP_ID_PATTERN"

  obj=""
  case "$stype" in
    skill)
      name="${w1#/}"
      case "$name" in j-*) name="j.${name#j-}" ;; esac
      if printf '%s\n' "$name" | grep -Eq '^(j\.[a-z0-9]+(-[a-z0-9]+)*|jenga|jenga-config|jenga-permission-level)$'; then
        obj="$(jq -cn --arg id "$wf_step_id" --arg skill "$name" --arg input "$rest" --arg d "$desc" \
          '{id: $id, type: "skill", skill: $skill} + (if $input == "" then {} else {args: {input: $input}} end) + {description: $d}')"
      else
        UNFILLED="${UNFILLED}$sid: judged skill, but its text does not start with a skill name (\"$w1\")
"
      fi ;;
    playbook)
      pname="${w1#/}"
      case "$pname" in j-*) pname="j.${pname#j-}" ;; esac
      pid="${rest%%[[:space:]]*}"
      if [ "$pname" = "j.playbook" ] && printf '%s\n' "$pid" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
        obj="$(jq -cn --arg id "$wf_step_id" --arg p "$pid" --arg d "$desc" \
          '{id: $id, type: "playbook", playbook: $p, description: $d}')"
      else
        UNFILLED="${UNFILLED}$sid: judged playbook, but its text is not 'j.playbook <id>' (\"$w1 $pid\")
"
      fi ;;
    confirm)
      obj="$(jq -cn --arg id "$wf_step_id" --arg prompt "$text" --arg d "$desc" \
        '{id: $id, type: "confirm", prompt: $prompt, options: ["Yes", "No"], description: $d}')" ;;
    compute)
      case "/$w1/" in
        */../*|"//"*) w1="" ;;
      esac
      case "$w1" in
        */*) ;;
        *) w1="" ;;
      esac
      if [ -n "$w1" ] && printf '%s\n' "$w1" | grep -Eq '^[A-Za-z0-9._@+/-]+$'; then
        obj="$(jq -cn --arg id "$wf_step_id" --arg c "$w1" --arg rest "$rest" --arg d "$desc" \
          '{id: $id, type: "compute", command: $c}
           + (([$rest | scan("\\S+")]) as $a | if ($a | length) == 0 then {} else {args: $a} end)
           + {description: $d}')"
      else
        UNFILLED="${UNFILLED}$sid: judged compute, but its text does not start with a relative script path
"
      fi ;;
    render)
      case "/$w1/" in
        */../*|"//"*) w1="" ;;
      esac
      case "$w1" in
        *.json|*.md) ;;
        *) w1="" ;;
      esac
      if [ -n "$w1" ] && printf '%s\n' "$w1" | grep -Eq '^[A-Za-z0-9._@+/-]+$'; then
        obj="$(jq -cn --arg id "$wf_step_id" --arg t "$w1" --arg d "$desc" \
          '{id: $id, type: "render", template: $t, description: $d}')"
      else
        UNFILLED="${UNFILLED}$sid: judged render, but its text does not start with a relative .json or .md template path
"
      fi ;;
  esac
  [ -z "$obj" ] || STEPS_JSONL="${STEPS_JSONL}${obj}
"
done <<EOF
$INC_IDS
EOF

if [ -n "$UNFILLED" ]; then
  {
    printf '%s: nothing was emitted; these steps carry a type their text cannot fill (a required field would have to be invented):\n' "$SELF"
    printf '%s' "$UNFILLED" | sed 's/^/  /'
    printf '%s: change the judgment on purpose with record-answer.sh <path> <step-id> step-type <type> --replace, then re-run.\n' "$SELF"
  } >&2
  exit 10
fi

NAME="$(awk -v anchor="$REC_STEPS_ANCHOR" '
  index($0, anchor) == 1 { exit }
  index($0, "# Recording: ") == 1 { print substr($0, 14); exit }
' "$REC")"
[ -n "$NAME" ] || NAME="$WF_ID"

NSTEPS="$(printf '%s' "$STEPS_JSONL" | grep -c '^')"
UNIT="steps"
[ "$NSTEPS" -eq 1 ] && UNIT="step"
DESCRIPTION="Replay of the recorded process \"$NAME\" ($NSTEPS $UNIT), emitted from $BASE."

JSON="$(printf '%s' "$STEPS_JSONL" | jq -s . | jq \
  --arg id "$WF_ID" --arg name "$NAME" --arg desc "$DESCRIPTION" --arg src "$BASE" \
  '{id: $id, name: $name, description: $desc, source_recording: $src, steps: .}')" || \
  die 7 "could not assemble the definition with jq; nothing was written"

# ---- the candidate, the existing validator, and only then the destination ----------------------------------------
if [ ! -d "$DEST_DIR" ]; then
  mkdir -p "$DEST_DIR" 2>/dev/null || die 7 "could not create $DEST_DIR; nothing was written"
  MADE_DIR="$DEST_DIR"
fi
CANDIDATE="$DEST_DIR/.emit-$WF_ID.$$.candidate"
printf '%s\n' "$JSON" > "$CANDIDATE" || die 7 "could not write the candidate $CANDIDATE; nothing was written"

if ! verr="$(bash "$VALIDATOR" "$CANDIDATE" 2>&1)"; then
  err "the emitted definition failed validation; nothing was written to $DEST. The validator said:"
  printf '%s\n' "$verr" >&2
  exit 8
fi

# The recording's side of the cross-link is prepared before the definition moves, so a failure here cannot leave a
# definition in place that its recording does not name.
REC_TMP="$(dirname "$REC")/.tmp-$BASE.emit.$$"
if ! awk -v key="$LINK_KEY" -v id="$WF_ID" '
  NR == 1 { print; infm = 1; next }
  infm == 1 && $0 == "---" {
    if (done != 1) { print key ": " id }
    print; infm = 0; next
  }
  infm == 1 && index($0, key ":") == 1 && done != 1 { print key ": " id; done = 1; next }
  { print }
' "$REC" > "$REC_TMP"; then
  die 7 "could not write the recording's cross-link; nothing was emitted"
fi
[ "$(rec_frontmatter_value "$REC_TMP" "$LINK_KEY")" = "$WF_ID" ] || \
  die 7 "the recording's rewritten frontmatter does not name $WF_ID; $REC is unchanged and nothing was emitted"

PRE_EXISTED=0
[ -e "$DEST" ] && PRE_EXISTED=1
mv "$CANDIDATE" "$DEST" 2>/dev/null || die 7 "could not move the validated candidate to $DEST; nothing was written"
CANDIDATE=""
if ! mv "$REC_TMP" "$REC" 2>/dev/null; then
  [ "$PRE_EXISTED" -eq 1 ] || rm -f "$DEST"
  die 7 "could not update $REC with the cross-link; the new definition was taken back out"
fi
REC_TMP=""
MADE_DIR=""

printf '%s\n' "$DEST"
exit 0
