#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow/scripts/workflow-cli.sh - the deterministic half of `j.workflow` (epic E80, task E80_S05_T01)
#
# Everything the skill would otherwise render or resolve itself lives here, so SKILL.md carries no inline
# listing, status or number-to-id logic. Modelled on skills/j-playbook/scripts/playbook-list.sh: a render
# command and a resolve command read the SAME rows in the SAME order, so a number the user picks from a listing
# resolves to the id on that line by construction. Nothing is sorted here; the order is the upstream order.
#
# Strictly read-only. It calls only the read commands of the upstream scripts (the loader, `run-state.sh list`
# and `run-state.sh status`); it never writes run state and never calls a command that does.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   workflow-cli.sh list-render
#       Definitions from the loader, one numbered line each:  <n>. <id> - <name> (<builtin|project>)
#       Then, after a blank line (only when there are valid lines too), one line per definition that failed
#       validation:  invalid: <file> - <reason>
#       An empty catalog with nothing invalid prints nothing and exits 0.
#   workflow-cli.sh runs-render
#       Runs from `run-state.sh list`, one numbered line each:  <n>. <run_id> - <workflow_id> - <lifecycle>
#       Runs that are paused or awaiting confirmation are also named after a blank line, as
#       `paused: <run_id>, ...` and `awaiting_confirmation: <run_id>, ...`. No runs prints nothing, exit 0.
#   workflow-cli.sh status-render [run_id]
#       With a run id: run, workflow, lifecycle, updated time, last checkpoint, the numbered steps with their
#       status (a checkpoint step is marked [checkpoint]) and the registered outputs as <step>.<name>: <value>,
#       from `run-state.sh status <run_id>`. Without a run id: the same output as runs-render.
#   workflow-cli.sh resumable
#       The runs-render format restricted to runs whose lifecycle is paused, awaiting_confirmation or failed
#       (the states `resume` accepts), numbered from 1 within that restricted list.
#   workflow-cli.sh resolve-definition <n>
#       The id of the n-th line of list-render.
#   workflow-cli.sh resolve-run <n> [--resumable]
#       The run id of the n-th line of runs-render, or of resumable with --resumable.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success
#   1   a resolve number is not a positive integer or is outside the listing (the valid range is on stderr), or
#       status-render names a run that does not exist
#   2   usage error, jq missing, an upstream script missing or failed (its stderr is surfaced, never an empty
#       list), or any other run-state failure (invalid run id, corrupt state, lock timeout)
#
# ---------------------------------------------------------------------------
# ENVIRONMENT
# ---------------------------------------------------------------------------
#   JENGA_WORKFLOW_LOADER   path of the definition loader to use instead of scripts/workflow/load-workflows.sh
#   JENGA_RUN_STATE         path of the run-state script to use instead of scripts/workflow/run-state.sh
#   Both are test hooks (a fixture that prints what the real script prints). The defaults resolve with the
#   consumer-install fallback: scripts/workflow/<name> when it exists, else
#   node_modules/@jenga-ai/agent/scripts/workflow/<name>, else the copy beside this skill's own tree.
#
# ---------------------------------------------------------------------------
# WHERE THIS DIFFERS FROM THE TASK TEXT (the real upstream files win)
# ---------------------------------------------------------------------------
#   - The loader prints ONLY valid definitions (a JSON array sorted by id, each with "source" and "file"). It has
#     no channel for invalid ones: it drops them and reports them on stderr. The `invalid:` lines are therefore
#     parsed from that stderr, from its two documented shapes (a "dropped invalid <source> workflow <file>:" block
#     with indented reason lines, and a one-line "dropped <source> workflow <file>: <reason>"). The reason text is
#     the loader's own; the lines of a multi-line reason are joined with "; ". The first column is the file path
#     as the loader printed it. Every other loader warning (for example an id collision) is forwarded to stderr
#     unchanged.
#   - run-state names the lifecycle key `status`; this script prints it under the word "lifecycle".
#   - `run-state.sh list` is tab separated (run_id, workflow_id, status, updated_at) and exits 4 AFTER a complete
#     listing when it skipped a corrupt state file (warning on stderr). That is not treated as a failure here:
#     the listing is rendered and the warning is forwarded.
#   - Step outputs live per step under steps[].outputs; they are shown as <step_id>.<output_name>.
#
# Needs jq. macOS bash 3.2 compatible.
# ---------------------------------------------------------------------------

set -euo pipefail
export LC_ALL=C

SELF="workflow-cli.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'USAGE'
Usage: workflow-cli.sh list-render
       workflow-cli.sh runs-render
       workflow-cli.sh status-render [run_id]
       workflow-cli.sh resumable
       workflow-cli.sh resolve-definition <n>
       workflow-cli.sh resolve-run <n> [--resumable]
USAGE
  exit 2
}

fail() {
  echo "$SELF: $*" >&2
  exit 2
}

# default_script <name>: the consumer-install fallback idiom, then the copy beside this tree.
default_script() {
  local name="$1" p
  p="$([ -f "scripts/workflow/$name" ] && echo "scripts/workflow/$name" || echo "node_modules/@jenga-ai/agent/scripts/workflow/$name")"
  if [ ! -f "$p" ] && [ -f "$SCRIPT_DIR/../../../scripts/workflow/$name" ]; then
    p="$SCRIPT_DIR/../../../scripts/workflow/$name"
  fi
  echo "$p"
}

LOADER="${JENGA_WORKFLOW_LOADER:-$(default_script load-workflows.sh)}"
RUNSTATE="${JENGA_RUN_STATE:-$(default_script run-state.sh)}"

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ $# -ge 1 ] || usage

ERRF=""
cleanup() { [ -z "$ERRF" ] || rm -f "$ERRF"; }
trap cleanup EXIT

# --- definitions -------------------------------------------------------------------------------------------

CATALOG=""   # the loader's JSON array
INVALID=""   # "invalid: ..." lines parsed from the loader's stderr

load_catalog() {
  local rc=0 parsed
  [ -f "$LOADER" ] || fail "the workflow loader was not found: $LOADER"
  ERRF="$(mktemp)"
  CATALOG="$(bash "$LOADER" 2>"$ERRF")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$ERRF" >&2
    fail "the workflow loader failed (exit $rc)"
  fi
  if ! printf '%s' "$CATALOG" | jq -e 'type == "array"' >/dev/null 2>&1; then
    cat "$ERRF" >&2
    fail "the workflow loader did not print a JSON array"
  fi
  # I<TAB>file<TAB>reason for a dropped definition, W<TAB>line for any other warning line.
  parsed="$(awk '
    function flush() {
      if (inblock) {
        if (reason == "") reason = "no reason reported"
        printf "I\t%s\t%s\n", file, reason
        inblock = 0
      }
    }
    /^load-workflows\.sh: warning: dropped invalid (builtin|project) workflow .*:$/ {
      flush()
      line = $0
      sub(/^load-workflows\.sh: warning: dropped invalid (builtin|project) workflow /, "", line)
      sub(/:$/, "", line)
      file = line; reason = ""; inblock = 1
      next
    }
    inblock && /^  / {
      r = substr($0, 3)
      reason = (reason == "" ? r : reason "; " r)
      next
    }
    /^load-workflows\.sh: warning: dropped (builtin|project) workflow / {
      flush()
      line = $0
      sub(/^load-workflows\.sh: warning: dropped (builtin|project) workflow /, "", line)
      i = index(line, ": ")
      if (i > 0) { file = substr(line, 1, i - 1); reason = substr(line, i + 2) }
      else { file = line; reason = "" }
      if (reason == "") reason = "no reason reported"
      printf "I\t%s\t%s\n", file, reason
      next
    }
    { flush(); printf "W\t%s\n", $0 }
    END { flush() }
  ' "$ERRF")"
  INVALID=""
  local kind a b
  while IFS="$(printf '\t')" read -r kind a b || [ -n "$kind" ]; do
    case "$kind" in
      I) INVALID="${INVALID}invalid: ${a} - ${b}
" ;;
      W) printf '%s\n' "$a" >&2 ;;
    esac
  done <<EOF2
$parsed
EOF2
}

definition_lines() {
  printf '%s' "$CATALOG" | jq -r 'to_entries[] | "\(.key + 1). \(.value.id) - \(.value.name) (\(.value.source))"'
}

# --- runs --------------------------------------------------------------------------------------------------

ROWS=""   # tab separated run rows: run_id, workflow_id, status, updated_at

# load_rows [resumable]
load_rows() {
  local only="${1:-}" out rc=0
  [ -f "$RUNSTATE" ] || fail "the run-state script was not found: $RUNSTATE"
  out="$(bash "$RUNSTATE" list)" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ]; then
    fail "run-state.sh list failed (exit $rc)"
  fi
  if [ "$only" = "resumable" ]; then
    ROWS="$(printf '%s\n' "$out" | awk -F'\t' 'NF >= 3 && ($3 == "paused" || $3 == "awaiting_confirmation" || $3 == "failed")')"
  else
    ROWS="$(printf '%s\n' "$out" | awk -F'\t' 'NF >= 3')"
  fi
}

render_rows() {
  printf '%s\n' "$ROWS" | awk -F'\t' '
    NF >= 3 {
      n++
      printf "%d. %s - %s - %s\n", n, $1, $2, $3
      if ($3 == "paused") p = p (p == "" ? "" : ", ") $1
      else if ($3 == "awaiting_confirmation") a = a (a == "" ? "" : ", ") $1
    }
    END {
      if (p != "" || a != "") {
        print ""
        if (p != "") print "paused: " p
        if (a != "") print "awaiting_confirmation: " a
      }
    }'
}

row_count() {
  printf '%s\n' "$ROWS" | awk -F'\t' 'NF >= 3 { n++ } END { print n + 0 }'
}

# --- resolve helpers ---------------------------------------------------------------------------------------

# check_number <n> <count> <what>: exit 1 naming the valid range unless 1 <= n <= count.
check_number() {
  local n="$1" count="$2" what="$3"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "$count" ]; then
    if [ "$count" -eq 0 ]; then
      echo "$SELF: '$n' is not a valid $what number; the list is empty" >&2
    else
      echo "$SELF: '$n' is not a valid $what number; the valid range is 1-$count" >&2
    fi
    exit 1
  fi
}

# --- commands ----------------------------------------------------------------------------------------------

case "$1" in
  list-render)
    [ $# -eq 1 ] || usage
    load_catalog
    lines="$(definition_lines)"
    [ -z "$lines" ] || printf '%s\n' "$lines"
    if [ -n "$INVALID" ]; then
      [ -z "$lines" ] || echo
      printf '%s' "$INVALID"
    fi
    ;;
  runs-render)
    [ $# -eq 1 ] || usage
    load_rows
    render_rows
    ;;
  resumable)
    [ $# -eq 1 ] || usage
    load_rows resumable
    render_rows
    ;;
  status-render)
    [ $# -le 2 ] || usage
    if [ $# -eq 1 ]; then
      load_rows
      render_rows
    else
      [ -f "$RUNSTATE" ] || fail "the run-state script was not found: $RUNSTATE"
      rc=0
      state="$(bash "$RUNSTATE" status "$2")" || rc=$?
      if [ "$rc" -ne 0 ]; then
        [ "$rc" -eq 3 ] && exit 1
        fail "run-state.sh status failed (exit $rc)"
      fi
      printf '%s' "$state" | jq -r '
        "run: \(.run_id)",
        "workflow: \(.workflow_id)",
        "lifecycle: \(.status)",
        "updated: \(.updated_at)",
        "last checkpoint: \(.last_checkpoint // "none" | tostring)",
        "",
        "steps:",
        (.steps | to_entries[]
          | "  \(.key + 1). \(.value.id) (\(.value.type)) - \(.value.status)\(if .value.checkpoint == true then " [checkpoint]" else "" end)"),
        "",
        "outputs:",
        ( [ .steps[] | .id as $s | (.outputs // {}) | to_entries[]
            | "  \($s).\(.key): \(.value | if type == "string" then . else tojson end)" ]
          | if length == 0 then ["  none"] else . end | .[] )'
    fi
    ;;
  resolve-definition)
    [ $# -eq 2 ] || usage
    load_catalog
    count="$(printf '%s' "$CATALOG" | jq 'length')"
    check_number "$2" "$count" "workflow"
    printf '%s' "$CATALOG" | jq -r --argjson i "$(($2 - 1))" '.[$i].id'
    ;;
  resolve-run)
    [ $# -ge 2 ] && [ $# -le 3 ] || usage
    only=""
    if [ $# -eq 3 ]; then
      [ "$3" = "--resumable" ] || usage
      only="resumable"
    fi
    load_rows "$only"
    check_number "$2" "$(row_count)" "run"
    printf '%s\n' "$ROWS" | awk -F'\t' -v i="$2" 'NF >= 3 { n++; if (n == i + 0) { print $1; exit } }'
    ;;
  *)
    usage
    ;;
esac
