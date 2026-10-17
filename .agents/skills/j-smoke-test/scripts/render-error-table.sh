#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-smoke-test/scripts/render-error-table.sh
#
# Renders smoke-test-skills.sh's critical findings as the Feature | Error |
# Consequences table (E64_S01_T02). Deterministic: identical input produces
# byte-identical output. No clock, no network, no model.
#
# The rows are the registered Jenga type `error_table` (templates/playbook-types.json):
# one `Feature | Error | Consequences` line per critical finding, three non-empty
# fields separated by " | ", no outer pipes. Everything else on screen (the
# heading, the table header, the separator) comes from the template asset
# templates/CRITICAL_ERROR_TABLE_TEMPLATE.md, not from this script.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   render-error-table.sh [--rows-only] [--template <path>] [<findings.jsonl>]
#
#   <findings.jsonl>  JSON lines as printed by smoke-test-skills.sh (any
#                     severity; only severity "critical" is rendered). Reads
#                     stdin when omitted or "-".
#   --rows-only       Print just the rows: the `error_table` value, ready for
#                     scripts/validate-typed-object.sh error_table or a
#                     playbook forward_from step. No heading, no header.
#   --template <path> Template to render. Default: templates/
#                     CRITICAL_ERROR_TABLE_TEMPLATE.md, found three levels above
#                     this script (correct in this repo and in
#                     node_modules/@jenga-ai/agent).
#
# ---------------------------------------------------------------------------
# THE TEMPLATE
# ---------------------------------------------------------------------------
# Single-line HTML comments are dropped. `{{COUNT}}` is replaced by the number of
# rows. The line that is exactly `{{ROWS}}` is replaced by the rows. A template
# with no `{{ROWS}}` line is an error rather than a silently row-less table.
#
# ---------------------------------------------------------------------------
# NO CRITICAL FINDINGS, NO TABLE
# ---------------------------------------------------------------------------
# When the input holds no critical finding (empty input included) nothing at all
# is printed and the exit code is 0: never an empty table, never a header with
# no rows. The caller treats empty output as "nothing to report".
#
# ---------------------------------------------------------------------------
# ROW SANITISING
# ---------------------------------------------------------------------------
# A field is flattened to one line (newlines and tabs become a space), trimmed,
# and every "|" in it becomes the broken bar "¦" (U+00A6) so that it cannot be
# read as a column separator. An empty field becomes "unspecified" so that the
# row still has three non-empty fields.
#
# Exit codes: 0 success (including "no critical findings"); 2 usage error,
# missing jq/template, a template with no {{ROWS}} line, or input that is not
# JSON lines.
# ---------------------------------------------------------------------------

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SELF_DIR/../../../templates/CRITICAL_ERROR_TABLE_TEMPLATE.md"
ROWS_ONLY=0
INPUT="-"

usage() {
  echo "Usage: $(basename "$0") [--rows-only] [--template <path>] [<findings.jsonl>]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --rows-only) ROWS_ONLY=1; shift ;;
    --template)
      if [ $# -lt 2 ]; then usage; exit 2; fi
      TEMPLATE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -) INPUT="-"; shift ;;
    -*) echo "render-error-table: unknown argument: $1" >&2; usage; exit 2 ;;
    *) INPUT="$1"; shift ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "render-error-table: jq is required but was not found" >&2
  exit 2
fi
if [ "$INPUT" != "-" ] && [ ! -f "$INPUT" ]; then
  echo "render-error-table: findings file not found: $INPUT" >&2
  exit 2
fi

ROWS="$(mktemp)"
trap 'rm -f "$ROWS"' EXIT

# One row per critical finding, in input order.
JQ_PROGRAM='select(.severity == "critical")
  | [.feature, .error, .consequences]
  | map((. // "") | tostring | gsub("[\r\n\t]+"; " ") | gsub("\\|"; "¦") | gsub("^ +| +$"; "")
        | if . == "" then "unspecified" else . end)
  | join(" | ")'

if [ "$INPUT" = "-" ]; then
  jq -r "$JQ_PROGRAM" > "$ROWS"
else
  jq -r "$JQ_PROGRAM" "$INPUT" > "$ROWS"
fi
JQ_RC=$?
if [ "$JQ_RC" -ne 0 ]; then
  echo "render-error-table: input is not valid JSON lines" >&2
  exit 2
fi

COUNT="$(grep -c '' "$ROWS")"
[ "$COUNT" -gt 0 ] || exit 0

if [ "$ROWS_ONLY" -eq 1 ]; then
  cat "$ROWS"
  exit 0
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "render-error-table: template not found: $TEMPLATE" >&2
  exit 2
fi
if ! grep -qx '{{ROWS}}' "$TEMPLATE"; then
  echo "render-error-table: template has no {{ROWS}} line: $TEMPLATE" >&2
  exit 2
fi

awk -v count="$COUNT" -v rows_file="$ROWS" '
  /^<!--.*-->[ \t]*$/ { next }
  $0 == "{{ROWS}}" { while ((getline row < rows_file) > 0) print row; close(rows_file); next }
  { gsub(/\{\{COUNT\}\}/, count); print }
' "$TEMPLATE"
