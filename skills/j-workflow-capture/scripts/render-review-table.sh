#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/render-review-table.sh - the review table (epic E103, task E103_S01_T04)
#
# Turns a CANDIDATE-STEPS FILE into the table j.workflow-capture shows the user before anything is written to a
# recording's annotations, and answers the two questions the review flow asks of it: which rows are uncertain, and
# what does one row say in full. Read-only: it writes nothing, resolves no roots, and never reads or writes the
# recorder's active-recording pointer.
#
# DETERMINISTIC: the output depends only on the file's content. Rows are ordered by `n`, nothing time-dependent is
# printed, and every transformation is a pure jq expression, so the same file always renders the same bytes.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   render-review-table.sh <candidates-file>               the Markdown table plus one summary line
#   render-review-table.sh --uncertain <candidates-file>   the uncertain row numbers, one per line, ascending
#   render-review-table.sh --row <n> <candidates-file>     one row in full, for the per-step prompt
#   render-review-table.sh --check <candidates-file>       validate only; prints nothing on success
#   render-review-table.sh -h | --help | help              this usage on stdout, exit 0
#
# ---------------------------------------------------------------------------
# THE CANDIDATE-STEPS FILE (the contract; E103_S02_T02's extractor writes it, the review agent fills proposals)
# ---------------------------------------------------------------------------
#   {
#     "candidate_steps_version": 1,
#     "steps": [
#       {
#         "n": 1,                                   integer, REQUIRED; the steps run 1..N in this order
#         "text": "the user's prompt, verbatim",    non-empty string, REQUIRED; becomes the recording step's text
#         "proposal": "include" | "exclude",        optional; absent or null = no proposal yet
#         "step_type": "skill" | "playbook" | "confirm" | "compute" | "render",   optional
#         "parameters": [                           optional; [] means "no parameters proposed"
#           {"name": "project_dir", "value": "/opt/acme/app"},      name ^[a-z][a-z0-9_]*$, unique in the row
#           {"name": "api_key", "secret": true}                     secret: NEVER carries a value
#         ],
#         "uncertain": true | false,                optional; the proposer's own doubt
#         "reason": "why it is uncertain",          optional string
#         "evidence": ["tool call or assistant text", ...]          optional; context only, never a step
#         "secret_flags": [                         optional; written by scan-secrets.sh (E103_S03_T02), never a value
#           {"kind": "literal" | "phrasing", "pattern": "assignment", "name": "stripe_secret_key", "cleared": true}
#         ]                                         shown by --row as "secret flags: ..."
#       }
#     ]
#   }
#
# Row n is recording step `step-%03d` of n: the capture writer appends the candidates in this order, so the
# review's answers (record-review.sh) land on the step the row shows. A secret parameter that carries a `value` is
# refused (exit 4) rather than rendered: a credential must never reach the table, a recording or a definition.
#
# ---------------------------------------------------------------------------
# WHEN A ROW IS UNCERTAIN (one rule, applied here and nowhere else)
# ---------------------------------------------------------------------------
#   a row is uncertain when  "uncertain" is true,
#                       or   it has no proposal,
#                       or   it proposes include without a step_type.
# So an extractor's bare output, with no proposals at all, is walked step by step in full, and a row is only
# accepted in a batch when every decision emission needs has been proposed and nobody doubted it.
#
# ---------------------------------------------------------------------------
# THE TABLE
# ---------------------------------------------------------------------------
#   | # | Step | Proposed | Type | Parameters | Uncertain |
#   Step        the text with whitespace runs collapsed to one space, cut to 72 characters ("..." when cut)
#   Proposed    include | exclude | ?            Type        the step type, or ? (include without one), or -
#   Parameters  name=value, ... (value cut to 40), "name (secret)" for a secret, - for none (and for an excluded
#               row without proposals, which emits nothing), ? when not proposed
#   Uncertain   "yes", or "yes: <reason>"; empty for a certain row
# A `|` in any cell is written as `\|`. The table is followed by one line:
#   "<N> candidate steps; uncertain: <n>, <n>" or "<N> candidate steps; none uncertain".
# An empty step list prints only "No candidate steps to review." (and --uncertain prints nothing).
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success
#   2   usage error (unknown option, missing file, bad --row number)
#   3   the file does not exist or is not readable
#   4   the file is not a valid candidate-steps file; the problems are on stderr, nothing on stdout
#   5   --row: no row with that number
#   6   jq is not available
#
# Compatible with macOS bash 3.2 and safe under `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'USAGE'
usage:
  render-review-table.sh <candidates-file>
  render-review-table.sh --uncertain <candidates-file>
  render-review-table.sh --row <n> <candidates-file>
  render-review-table.sh --check <candidates-file>
  render-review-table.sh -h | --help | help

Renders a candidate-steps file as the review table j.workflow-capture shows first (step number, excerpt, proposed
include or exclude, proposed step type, proposed parameters, uncertain flag), lists the uncertain rows, or prints
one row in full. Read-only and deterministic. The file format and the uncertain rule: this script's header.
USAGE
}

MODE="table"
ROW=""
FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    --uncertain) MODE="uncertain"; shift ;;
    --check) MODE="check"; shift ;;
    --row)
      [ "$#" -ge 2 ] || { usage >&2; die 2 "--row needs a row number"; }
      MODE="row"; ROW="$2"; shift 2 ;;
    --row=*) MODE="row"; ROW="${1#--row=}"; shift ;;
    --) shift; [ "$#" -ge 1 ] && { FILE="$1"; shift; } ;;
    -*) usage >&2; die 2 "unknown option: $1" ;;
    *)
      [ -z "$FILE" ] || { usage >&2; die 2 "only one candidates file, got \"$FILE\" and \"$1\""; }
      FILE="$1"; shift ;;
  esac
done

[ -n "$FILE" ] || { usage >&2; die 2 "needs a candidates file"; }
if [ "$MODE" = "row" ]; then
  case "$ROW" in
    ''|*[!0-9]*|0*) die 2 "--row wants a positive row number, got \"$ROW\"" ;;
  esac
fi
command -v jq >/dev/null 2>&1 || die 6 "jq is required and was not found on PATH"
[ -f "$FILE" ] || die 3 "no such candidates file: $FILE"
[ -r "$FILE" ] || die 3 "candidates file is not readable: $FILE"

# ---- validation: every problem, one per line; empty output means valid ------------------------------------------
JQ_PROBLEMS='
  def types: ["skill","playbook","confirm","compute","render"];
  def isint: type == "number" and . == floor;
  if type != "object" then "the file is not a JSON object"
  elif .candidate_steps_version != 1 then "candidate_steps_version must be 1"
  elif (.steps | type) != "array" then "steps must be an array"
  else
    .steps | to_entries[] | .key as $i | .value as $s | ($i + 1) as $want |
    if ($s | type) != "object" then "steps[\($i)] is not an object"
    else
      (if ($s.n | isint | not) or $s.n != $want then "steps[\($i)]: n must be \($want) (rows run 1..N in order)" else empty end),
      (if ($s.text | type) != "string" or ($s.text | test("\\S") | not) then "step \($want): text must be a non-empty string" else empty end),
      (if $s.proposal != null and ($s.proposal | IN("include","exclude") | not) then "step \($want): proposal must be include or exclude" else empty end),
      (if $s.step_type != null and ($s.step_type | IN(types[]) | not) then "step \($want): step_type must be one of \(types | join(", "))" else empty end),
      (if $s.uncertain != null and ($s.uncertain | type) != "boolean" then "step \($want): uncertain must be true or false" else empty end),
      (if $s.reason != null and ($s.reason | type) != "string" then "step \($want): reason must be a string" else empty end),
      (if $s.evidence != null and ($s.evidence | type) != "array" then "step \($want): evidence must be an array" else empty end),
      (if $s.secret_flags == null then empty
       elif ($s.secret_flags | type) != "array" then "step \($want): secret_flags must be an array"
       else ($s.secret_flags[] | select((type != "object") or ((.kind | IN("literal","phrasing")) | not)
                                         or ((.name | type) != "string") or ((.name | test("^[a-z][a-z0-9_]*$")) | not))
             | "step \($want): a secret flag needs kind literal or phrasing and a name matching ^[a-z][a-z0-9_]*$")
       end),
      (if $s.parameters == null then empty
       elif ($s.parameters | type) != "array" then "step \($want): parameters must be an array"
       else
         ($s.parameters | to_entries[] | .value as $p |
           if ($p | type) != "object" then "step \($want): a parameter is not an object"
           elif ($p.name | type) != "string" or ($p.name | test("^[a-z][a-z0-9_]*$") | not) then "step \($want): parameter name \($p.name | tojson) must match ^[a-z][a-z0-9_]*$"
           elif $p.secret != null and ($p.secret | type) != "boolean" then "step \($want): parameter \($p.name): secret must be true or false"
           elif $p.secret == true and $p.value != null then "step \($want): parameter \($p.name) is secret and must not carry a value"
           elif $p.secret != true and (($p.value | type) != "string" or $p.value == "") then "step \($want): parameter \($p.name) needs a non-empty string value"
           else empty end),
         (if ([$s.parameters[] | .name?] | length) != ([$s.parameters[] | .name?] | unique | length) then "step \($want): a parameter name is used twice" else empty end)
       end)
    end
  end
'

if ! problems="$(jq -r "$JQ_PROBLEMS" "$FILE" 2>/dev/null)"; then
  die 4 "$FILE is not valid JSON"
fi
if [ -n "$problems" ]; then
  err "$FILE is not a valid candidate-steps file:"
  printf '%s\n' "$problems" | sed 's/^/  - /' >&2
  exit 4
fi

[ "$MODE" = "check" ] && exit 0

# ---- shared jq definitions: the uncertain rule and the cell renderers --------------------------------------------
JQ_DEFS='
  def squash: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
  def cut($k): if length > $k then .[0:$k] + "..." else . end;
  def cell: gsub("\\|"; "\\|");
  def why:
    if .uncertain == true then (.reason // "")
    elif .proposal == null then "no proposal yet"
    elif .proposal == "include" and .step_type == null then "no step type proposed"
    else null end;
  def is_uncertain: why != null;
  def flag: why as $w | if $w == null then "" elif $w == "" then "yes" else "yes: " + ($w | squash) end;
  def proposed: .proposal // "?";
  def typecell: if .step_type != null then .step_type elif .proposal == "exclude" then "-" else "?" end;
  def param: if .secret == true then .name + " (secret)" else .name + "=" + (.value | squash | cut(40)) end;
  def params: if .parameters == null then (if .proposal == "exclude" then "-" else "?" end) elif (.parameters | length) == 0 then "-" else [.parameters[] | param] | join(", ") end;
'

case "$MODE" in
  uncertain)
    jq -r "$JQ_DEFS"' .steps | sort_by(.n)[] | select(is_uncertain) | .n' "$FILE"
    ;;
  row)
    out="$(jq -r --argjson n "$ROW" "$JQ_DEFS"'
      [.steps[] | select(.n == $n)] | if length == 0 then empty else .[0] |
        "step: \(.n)",
        "recording step: step-\(.n | tostring | if length < 3 then ("00" + .)[-3:] else . end)",
        "proposed: \(proposed)",
        "type: \(typecell)",
        "parameters: \(params)",
        "uncertain: \(flag | if . == "" then "no" else . end)",
        (if (.secret_flags // []) | length > 0 then
           "secret flags: " + ([.secret_flags[] | "\(.name) (\(.kind): \(.pattern // "?")\(if .cleared == true then ", cleared" else "" end))"] | join(", "))
         else empty end),
        "text:",
        .text,
        "evidence: \((.evidence // []) | length) item(s)",
        ((.evidence // [])[] | "  - " + (if type == "string" then . else tojson end | squash | cut(160)))
      end' "$FILE")"
    [ -n "$out" ] || die 5 "no row $ROW in $FILE"
    printf '%s\n' "$out"
    ;;
  table)
    jq -r "$JQ_DEFS"'
      (.steps | sort_by(.n)) as $rows |
      if ($rows | length) == 0 then "No candidate steps to review."
      else
        "| # | Step | Proposed | Type | Parameters | Uncertain |",
        "|---|---|---|---|---|---|",
        ($rows[] | "| \(.n) | \(.text | squash | cut(72) | cell) | \(proposed) | \(typecell) | \(params | cell) | \(flag | cell) |"),
        "",
        ([$rows[] | select(is_uncertain) | .n | tostring]) as $u |
        "\($rows | length) candidate step\(if ($rows | length) == 1 then "" else "s" end); " +
          (if ($u | length) == 0 then "none uncertain" else "uncertain: " + ($u | join(", ")) end)
      end' "$FILE"
    ;;
esac
