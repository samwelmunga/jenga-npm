#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/record-review.sh - the review mode's writer (epic E103, task E103_S01_T04)
#
# Persists every decision j.workflow-capture's review makes - include or exclude, step type, parameters - into the
# captured recording, and ONLY through skills/j-workflow-recorder/scripts/record-answer.sh. It adds no second writer
# and no second format: it maps a review row number to the recording step id and a review decision to an annotation
# kind, then calls record-answer.sh. Because every decision ends up as an annotation, emit-workflow.sh emits from the
# answers alone and re-emission stays deterministic (no judgment is ever re-made at emission time).
#
# It works on the recording path it is GIVEN. It never reads or writes the recorder's active-recording pointer, so a
# captured recording never becomes the session's active recording (epic E103, decision 6).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   record-review.sh decide <recording> <n> include [--note <text>] [--replace]
#   record-review.sh decide <recording> <n> exclude [--note <text>] [--replace]
#   record-review.sh decide <recording> <n> type <skill|playbook|confirm|compute|render> [--note <text>] [--replace]
#   record-review.sh decide <recording> <n> params none | <name>=<literal>|<name>... [--note <text>] [--replace]
#   record-review.sh accept <recording> <candidates-file> [<n>...]
#   record-review.sh pending <recording> <candidates-file>
#   record-review.sh -h | --help | help
#
# ROW TO STEP. Row n is recording step `step-%03d` of n (the capture writer appends the candidates in row order;
# render-review-table.sh's header owns that contract).
#
# DECISION TO ANNOTATION (record-answer.sh's header owns the kinds and their vocabularies):
#   include             deviation   in-process       (the step is emitted; identical to no deviation annotation)
#   exclude             deviation   out-of-process   (the step is not emitted)
#   type <t>            step-type   <t>              (used verbatim by emit-workflow.sh)
#   params none         parameters  none
#   params <p>...       parameters  confirmed        body: one <name>=<literal> or bare <name> per argument
#   --note carries the user's own words for a free-text answer. --replace supersedes an earlier decision of the same
#   kind (a correction); without it a second decision of the same kind is refused by record-answer.sh (exit 7).
#
# accept   persists the PROPOSALS in the candidates file for the named rows (default: every row that is not
#          uncertain, per render-review-table.sh's rule): its proposal as include/exclude, an included row's
#          step_type, and an included row's parameters ([] -> none; a secret parameter by name only). A decision
#          already recorded is KEPT, never overwritten, so a correction made before accept wins. A named row that is
#          uncertain is refused (exit 2): uncertain rows are decided one at a time, never in a batch. Everything is
#          checked before the first write, so a refused accept writes nothing. Prints one line per row and kind:
#          `<n><TAB><kind><TAB>written <value>` or `<n><TAB><kind><TAB>kept <value>`.
# pending  prints `<n><TAB><what is missing>` for every row that still lacks a decision emission needs: an
#          include/exclude decision, and a step type for a row that is not excluded. Exit 1 when any row is pending,
#          0 when none is.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success (pending: nothing pending)
#   1   pending: at least one row still needs a decision
#   2   usage error: unknown sub-command or decision, bad row number, accept on an uncertain row, a parameter literal
#       spanning more than one line, or a parameter literal that looks like a credential (detect-parameters.sh
#       secret-check; E103_S02_T04): a credential is confirmed by bare <name> only and never written down
#   3   the recording or the candidates file does not exist or is not readable
#   4   the candidates file is not valid (render-review-table.sh's message is on stderr)
#   5   the recording has no step for a row
#   6   a sibling script (record-answer.sh, recording-format.sh, render-review-table.sh) or jq is missing
#   other  record-answer.sh's own exit code, passed through unchanged (7: already decided, pass --replace)
#
# Compatible with macOS bash 3.2 and safe under `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDER_DIR="$SCRIPT_DIR/../../j-workflow-recorder/scripts"
ANSWER="$RECORDER_DIR/record-answer.sh"
FORMAT_LIB="$RECORDER_DIR/recording-format.sh"
RENDER="$SCRIPT_DIR/render-review-table.sh"
DETECT="$SCRIPT_DIR/detect-parameters.sh"

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'USAGE'
usage:
  record-review.sh decide <recording> <n> include|exclude [--note <text>] [--replace]
  record-review.sh decide <recording> <n> type <skill|playbook|confirm|compute|render> [--note <text>] [--replace]
  record-review.sh decide <recording> <n> params none | <name>=<literal>|<name>... [--note <text>] [--replace]
  record-review.sh accept <recording> <candidates-file> [<n>...]
  record-review.sh pending <recording> <candidates-file>
  record-review.sh -h | --help | help

Persists j.workflow-capture's review decisions into a captured recording through record-answer.sh: row n is step
step-<n, 3 digits>; include/exclude -> deviation, type -> step-type, params -> parameters. accept persists the
proposals of the rows that are not uncertain (never overwriting a decision already made); pending lists the rows
still missing a decision emission needs. Full contract: this script's header.
USAGE
}

for f in "$ANSWER" "$FORMAT_LIB" "$RENDER"; do
  [ -r "$f" ] || die 6 "cannot read the sibling script $f"
done
# shellcheck source=../../j-workflow-recorder/scripts/recording-format.sh
. "$FORMAT_LIB"

step_id() { printf 'step-%03d' "$1"; }

is_row_number() {
  case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac
  return 0
}

require_recording() {
  [ -f "$1" ] || die 3 "no such recording: $1"
  [ -r "$1" ] || die 3 "recording is not readable: $1"
}

# Exits 5 unless the recording has exactly one step for row $2. Uses the shared parse contract; no second parser.
require_row_step() {
  local id
  id="$(step_id "$2")"
  rec_step_open_line "$1" "$id" >/dev/null 2>&1 || die 5 "row $2 has no step \"$id\" in $1 (are the candidates appended to this recording in row order?)"
}

# Validates the candidates file through the renderer (the one owner of its contract).
require_candidates() {
  [ -f "$1" ] || die 3 "no such candidates file: $1"
  [ -r "$1" ] || die 3 "candidates file is not readable: $1"
  bash "$RENDER" --check "$1" || exit 4
}

# Prints the recorded value of <kind> on row <n>'s step, or nothing (exit 1) when there is none.
recorded() { bash "$ANSWER" --value "$1" "$(step_id "$2")" "$3" 2>/dev/null; }

# refuse_secret_literal <n> <name> <literal>: dies 2 when <literal> looks like a credential, so it is never written
# into the recording (E103_S02_T04). The way out is the bare <name>, an input whose value the run asks for.
refuse_secret_literal() {
  [ -f "$DETECT" ] || die 6 "cannot find $DETECT"
  if bash "$DETECT" secret-check "$3"; then
    die 2 "row $1: the value of parameter $2 looks like a credential and is never written down; confirm it by name only ($2). Nothing was written."
  fi
}

# ---- decide ------------------------------------------------------------------------------------------------------
cmd_decide() {
  [ "$#" -ge 3 ] || { usage >&2; die 2 "decide needs <recording> <n> <decision>"; }
  local rec="$1" n="$2" what="$3"; shift 3
  local kind="" value="" body="" passthru=() params=()
  is_row_number "$n" || die 2 "row number must be a positive integer, got \"$n\""
  case "$what" in
    include) kind="deviation"; value="in-process" ;;
    exclude) kind="deviation"; value="out-of-process" ;;
    type)
      [ "$#" -ge 1 ] || die 2 "type needs one of skill, playbook, confirm, compute, render"
      kind="step-type"; value="$1"; shift ;;
    params) kind="parameters" ;;
    *) die 2 "unknown decision \"$what\" (expected include, exclude, type or params)" ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --replace) passthru+=(--replace); shift ;;
      --note)
        [ "$#" -ge 2 ] || die 2 "--note needs a value"
        passthru+=(--note "$2"); shift 2 ;;
      --note=*) passthru+=(--note "${1#--note=}"); shift ;;
      -*) die 2 "unknown option: $1" ;;
      *)
        [ "$kind" = "parameters" ] || die 2 "unexpected argument \"$1\" for $what"
        params+=("$1"); shift ;;
    esac
  done
  require_recording "$rec"
  require_row_step "$rec" "$n"
  if [ "$kind" = "parameters" ]; then
    [ "${#params[@]}" -ge 1 ] || die 2 "params needs none, or one <name>=<literal> or <name> per parameter"
    local p
    for p in "${params[@]}"; do
      case "$p" in
        *=*) refuse_secret_literal "$n" "${p%%=*}" "${p#*=}" ;;
      esac
    done
    body="$(printf '%s\n' "${params[@]}")"
    printf '%s\n' "$body" | bash "$ANSWER" "$rec" "$(step_id "$n")" parameters - ${passthru[@]+"${passthru[@]}"}
    return $?
  fi
  bash "$ANSWER" "$rec" "$(step_id "$n")" "$kind" "$value" ${passthru[@]+"${passthru[@]}"}
}

# The answer body for one accepted decision: the token itself, except a confirmed parameters body, which is one
# <name>=<literal> (or a bare <name> for a secret, never its value) per proposed parameter.
body_of() {
  if [ "$3" = "parameters" ] && [ "$4" = "confirmed" ]; then
    jq -r --argjson n "$2" '.steps[] | select(.n == $n) | .parameters[] |
      if .secret == true then .name else .name + "=" + .value end' "$1"
  else
    printf '%s\n' "$4"
  fi
}

# ---- accept ------------------------------------------------------------------------------------------------------
cmd_accept() {
  [ "$#" -ge 2 ] || { usage >&2; die 2 "accept needs <recording> <candidates-file>"; }
  local rec="$1" cand="$2"; shift 2
  local rows="" uncertain n plan line kind val cur rc
  command -v jq >/dev/null 2>&1 || die 6 "jq is required and was not found on PATH"
  require_recording "$rec"
  require_candidates "$cand"
  uncertain="$(bash "$RENDER" --uncertain "$cand")" || exit 4
  if [ "$#" -gt 0 ]; then
    for n in "$@"; do
      is_row_number "$n" || die 2 "row number must be a positive integer, got \"$n\""
      jq -e --argjson n "$n" 'any(.steps[]; .n == $n)' "$cand" >/dev/null || die 2 "no row $n in $cand"
      if printf '%s\n' "$uncertain" | grep -qx "$n"; then
        die 2 "row $n is uncertain: decide it step by step (record-review.sh decide), never in a batch. Nothing was written."
      fi
      rows="${rows}${n}
"
    done
  else
    rows="$(jq -r --arg u "$uncertain" '
      ($u | split("\n") | map(select(. != "") | tonumber)) as $skip | .steps[].n | select(IN($skip[]) | not)
    ' "$cand")"
  fi

  # The plan: "<n>\t<kind>\t<value>" per decision to persist. The answer body is derived per write (body_of).
  plan="$(printf '%s\n' "$rows" | grep . | jq -R -r --slurpfile c "$cand" '
    tonumber as $n | ($c[0].steps[] | select(.n == $n)) as $s |
    (if $s.proposal == "include" then "\($n)\tdeviation\tin-process"
     else "\($n)\tdeviation\tout-of-process" end),
    (if $s.proposal == "include" then
       "\($n)\tstep-type\t\($s.step_type)",
       (if $s.parameters == null then empty
        elif ($s.parameters | length) == 0 then "\($n)\tparameters\tnone"
        elif any($s.parameters[]; (.value // "") | test("[\\n\\r]")) then "\($n)\tERROR\tmultiline"
        else "\($n)\tparameters\tconfirmed"
        end)
     else empty end)
  ')" || die 4 "could not read the proposals in $cand"

  # Check everything before the first write.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="${line%%	*}"
    case "$line" in *"	ERROR	"*) die 2 "row $n has a parameter literal spanning more than one line; decide its parameters with decide ... params. Nothing was written." ;; esac
    require_row_step "$rec" "$n"
    case "$line" in
      *"	parameters	confirmed")
        while IFS='	' read -r pname pval; do
          [ -n "$pname" ] || continue
          refuse_secret_literal "$n" "$pname" "$pval"
        done <<PEOF
$(jq -r --argjson n "$n" '.steps[] | select(.n == $n) | .parameters[] | select(.secret != true) | "\(.name)\t\(.value)"' "$cand")
PEOF
        ;;
    esac
  done <<EOF
$plan
EOF

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="$(printf '%s' "$line" | cut -f1)"
    kind="$(printf '%s' "$line" | cut -f2)"
    val="$(printf '%s' "$line" | cut -f3)"
    if cur="$(recorded "$rec" "$n" "$kind")"; then
      printf '%s\t%s\tkept %s\n' "$n" "$kind" "$cur"
      continue
    fi
    rc=0
    body_of "$cand" "$n" "$kind" "$val" | bash "$ANSWER" "$rec" "$(step_id "$n")" "$kind" - >/dev/null || rc=$?
    [ "$rc" -eq 0 ] || die "$rc" "record-answer.sh refused row $n $kind (exit $rc); rows before it were written"
    printf '%s\t%s\twritten %s\n' "$n" "$kind" "$val"
  done <<EOF
$plan
EOF
}

# ---- pending -----------------------------------------------------------------------------------------------------
cmd_pending() {
  [ "$#" -eq 2 ] || { usage >&2; die 2 "pending needs <recording> <candidates-file>"; }
  local rec="$1" cand="$2" n dev any=0
  command -v jq >/dev/null 2>&1 || die 6 "jq is required and was not found on PATH"
  require_recording "$rec"
  require_candidates "$cand"
  for n in $(jq -r '.steps[].n' "$cand"); do
    require_row_step "$rec" "$n"
    if ! dev="$(recorded "$rec" "$n" deviation)"; then
      printf '%s\tinclude or exclude\n' "$n"; any=1; continue
    fi
    if [ "$dev" != "out-of-process" ] && ! recorded "$rec" "$n" step-type >/dev/null; then
      printf '%s\tstep type\n' "$n"; any=1
    fi
  done
  return "$any"
}

[ "$#" -ge 1 ] || { usage >&2; die 2 "needs a sub-command"; }
sub="$1"; shift
case "$sub" in
  -h|--help|help) usage; exit 0 ;;
  decide) cmd_decide "$@" ;;
  accept) cmd_accept "$@" ;;
  pending) cmd_pending "$@" ;;
  *) usage >&2; die 2 "unknown sub-command: $sub" ;;
esac
