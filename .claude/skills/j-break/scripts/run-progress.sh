#!/usr/bin/env bash
################################################################################
# run-progress.sh - resolve a run's scope and print its one-line progress bar (epic E92, E92_S02_T04)
#
# The one script /jenga, /do and /dooo call after a finished task or wave. It decides WHICH tasks the bar is about and
# nothing else: the counts come only from scripts/board-progress.sh and the drawing only from
# scripts/render-progress-bar.sh. This file holds no status names and does no counting.
#
# Usage:
#   run-progress.sh --resolve-scope --ids <id>[,<id>...]
#   run-progress.sh --scope run   --ids <id>[,<id>...] [render options]
#   run-progress.sh --scope story --task <task id>     [render options]
#
#   --resolve-scope  prints `run` or `story` once. DOCUMENTED DEFAULT: `run` when the ids expand to at least 2 tasks,
#                    otherwise `story` (a one-task run would only ever show 0/1 and then 1/1). The orchestrator calls
#                    this ONCE at run start and keeps the answer; the choice is never re-made per print.
#   --scope run      the run's own scope. Each id is expanded to tasks (a task is itself; a story or an epic goes
#                    through `board-progress.sh --story/--epic <id> --items`), unioned with the task ids this session's
#                    execution ledger records (so a later /jenga wave that adds items is counted), de-duplicated, and
#                    handed to `board-progress.sh --ids`. The ledger is read by skills/j-break/scripts/lib/ledger_reader.py,
#                    the same reader render-execution-status.sh uses, under the same session key.
#   --scope story    the parent story of --task (its own `story_id`), via `board-progress.sh --story`.
#   --level, --cols, --color   forwarded to the renderer unchanged.
#   --session KEY    session key for the ledger (default: scripts/checklist-marker.sh session-key; with none, the
#                    ledger union is skipped).
#   --root DIR       project root (exported as JENGA_PROJECT_ROOT, as board-progress.sh's own --root does).
#
# Output: a newline-terminated single line on stdout, from the renderer. The renderer inherits this script's stdout, so
# its TTY, colour and width detection see the real terminal.
#
# A PROGRESS PROBLEM NEVER FAILS A RUN. An unknown id, an empty scope, a missing script, a malformed ledger line or a
# renderer failure prints one `run-progress.sh: warning: ...` line on stderr, prints nothing on stdout and exits 0. An
# empty answer from --resolve-scope therefore means "show no bar". Only a usage error (missing, conflicting or unknown
# arguments) exits 2.
#
# Exit codes: 0 printed, or a progress problem was warned about; 2 usage error.
################################################################################

set -o nounset

SCRIPT_NAME="run-progress.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

TMP_DIR=""
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

usage_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2; }
warn() { printf '%s: warning: %s (no progress line printed, run unaffected)\n' "$SCRIPT_NAME" "$1" >&2; exit 0; }

resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

USAGE="usage: $SCRIPT_NAME --resolve-scope --ids <ids> | --scope run --ids <ids> [opts] | --scope story --task <id> [opts]"

case "${1:-}" in -h|--help|help) printf '%s\n' "$USAGE"; exit 0 ;; esac

RESOLVE=0; SCOPE=""; IDS=""; TASK=""; SESSION_KEY=""; ROOT=""
FWD_LEVEL=""; FWD_COLS=""; FWD_COLOR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve-scope) RESOLVE=1; shift ;;
    --scope)   [ "$#" -ge 2 ] || usage_err "--scope needs a value"; SCOPE="$2"; shift 2 ;;
    --ids)     [ "$#" -ge 2 ] || usage_err "--ids needs a value"; IDS="${IDS:+$IDS,}$2"; shift 2 ;;
    --task)    [ "$#" -ge 2 ] || usage_err "--task needs a value"; TASK="$2"; shift 2 ;;
    --session) [ "$#" -ge 2 ] || usage_err "--session needs a value"; SESSION_KEY="$2"; shift 2 ;;
    --root)    [ "$#" -ge 2 ] || usage_err "--root needs a value"; ROOT="$2"; shift 2 ;;
    --level)   [ "$#" -ge 2 ] || usage_err "--level needs a value"; FWD_LEVEL="$2"; shift 2 ;;
    --cols)    [ "$#" -ge 2 ] || usage_err "--cols needs a value"; FWD_COLS="$2"; shift 2 ;;
    --color)   [ "$#" -ge 2 ] || usage_err "--color needs a value"; FWD_COLOR="$2"; shift 2 ;;
    *) usage_err "unknown argument: $1" ;;
  esac
done

if [ "$RESOLVE" -eq 1 ]; then
  [ -z "$SCOPE" ] || usage_err "--resolve-scope and --scope cannot be combined"
  [ -z "$TASK" ] || usage_err "--resolve-scope takes --ids, not --task"
  [ -n "$IDS" ] || usage_err "--resolve-scope needs --ids"
else
  case "$SCOPE" in
    run)   [ -n "$IDS" ] || usage_err "--scope run needs --ids"
           [ -z "$TASK" ] || usage_err "--scope run takes --ids, not --task" ;;
    story) [ -n "$TASK" ] || usage_err "--scope story needs --task"
           [ -z "$IDS" ] || usage_err "--scope story takes --task, not --ids" ;;
    "")    usage_err "$USAGE" ;;
    *)     usage_err "--scope must be run or story, got: $SCOPE" ;;
  esac
fi

[ -z "$ROOT" ] || export JENGA_PROJECT_ROOT="$ROOT"

# ---- from here on every failure is a warning, never a failed run --------------------------------------------------
command -v python3 >/dev/null 2>&1 || warn "python3 is not available"
BOARD_PROGRESS="$(resolve_helper scripts/board-progress.sh)" || warn "could not locate scripts/board-progress.sh"
TMP_DIR="$(mktemp -d 2>/dev/null)" || warn "could not create a temporary directory"
ERR_FILE="$TMP_DIR/err"
EXPANDED_FILE="$TMP_DIR/expanded"
: >"$EXPANDED_FILE"

first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

# These helpers run in the main shell, never inside $( ), so a warn exits the whole script. They append to $EXPANDED_FILE.
# Task ids of a story or an epic: board-progress.sh --story/--epic <id> --items, ids only.
task_ids_of() { # <flag> <id>
  local json
  json="$(bash "$BOARD_PROGRESS" "$1" "$2" --items 2>"$ERR_FILE")" \
    || warn "cannot expand $2: $(first_line "$ERR_FILE")"
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    for item in json.load(sys.stdin)["levels"]["tasks"]["items"]:
        print(item["id"])
except Exception as exc:
    sys.stderr.write("unreadable board-progress output: %s\n" % exc)
    sys.exit(1)' >>"$EXPANDED_FILE" 2>"$ERR_FILE" || warn "$(first_line "$ERR_FILE")"
}

# Every id of the comma separated list, expanded to task ids and appended to $EXPANDED_FILE, one per line.
expand_ids() { # <comma list>
  local rest="$1," el
  while [ -n "$rest" ]; do
    el="${rest%%,*}"; rest="${rest#*,}"
    el="${el#"${el%%[![:space:]]*}"}"; el="${el%"${el##*[![:space:]]}"}"
    [ -n "$el" ] || continue
    if printf '%s' "$el" | grep -Eq '^E[0-9]+_S[0-9]+_T[0-9]+$'; then printf '%s\n' "$el" >>"$EXPANDED_FILE"
    elif printf '%s' "$el" | grep -Eq '^E[0-9]+_S[0-9]+$'; then task_ids_of --story "$el"
    elif printf '%s' "$el" | grep -Eq '^E[0-9]+$'; then task_ids_of --epic "$el"
    else warn "unknown id: $el"
    fi
  done
}

dedupe() { awk 'NF && !seen[$0]++'; }

# ---- --resolve-scope ------------------------------------------------------------------------------------------------
if [ "$RESOLVE" -eq 1 ]; then
  expand_ids "$IDS"
  # Distinct task ids in order; whether there is a first and a second one is all the rule needs (no tallying here).
  DISTINCT="$(dedupe <"$EXPANDED_FILE")"
  [ -n "$DISTINCT" ] || warn "empty scope: $IDS expands to no tasks"
  if [ -n "$(printf '%s\n' "$DISTINCT" | sed -n 2p)" ]; then echo run; else echo story; fi
  exit 0
fi

RENDER="$(resolve_helper scripts/render-progress-bar.sh)" || warn "could not locate scripts/render-progress-bar.sh"

if [ "$SCOPE" = "run" ]; then
  expand_ids "$IDS"
  # The ledger union: task ids this session finished, so a later wave that adds items is counted. No session key means
  # no union, not an error (nothing could match the ledger either way).
  RESOLVE_ROOT="$(resolve_helper scripts/resolve-root.sh)" || warn "could not locate scripts/resolve-root.sh"
  if [ -z "$SESSION_KEY" ]; then
    if MARKER="$(resolve_helper scripts/checklist-marker.sh)"; then
      SESSION_KEY="$(bash "$MARKER" session-key 2>/dev/null)" || SESSION_KEY=""
    fi
  fi
  LEDGER_IDS=""
  if [ -n "$SESSION_KEY" ]; then
    LEDGER_PY="$SCRIPT_DIR/lib/ledger_reader.py"
    [ -f "$LEDGER_PY" ] || warn "could not locate $LEDGER_PY"
    QUEUE_DIR="$(bash "$RESOLVE_ROOT" get queue 2>"$ERR_FILE")" || warn "could not resolve the queue directory: $(first_line "$ERR_FILE")"
    [ -n "$QUEUE_DIR" ] || warn "the queue directory resolved to an empty path"
    LEDGER_IDS="$(python3 "$LEDGER_PY" --queue "$QUEUE_DIR" --session "$SESSION_KEY" 2>"$ERR_FILE")" \
      || warn "bad ledger: $(first_line "$ERR_FILE")"
    LEDGER_IDS="$(printf '%s\n' "$LEDGER_IDS" | grep -E '^E[0-9]+_S[0-9]+_T[0-9]+$' || true)"
  fi
  TASKS="$( { cat "$EXPANDED_FILE"; printf '%s\n' "$LEDGER_IDS"; } | dedupe | paste -s -d, -)"
  [ -n "$TASKS" ] || warn "empty scope: $IDS expands to no tasks"
  PROGRESS_ARGS=(--ids "$TASKS")
else
  printf '%s' "$TASK" | grep -Eq '^E[0-9]+_S[0-9]+_T[0-9]+$' || warn "unknown task id: $TASK"
  RESOLVE_ROOT="$(resolve_helper scripts/resolve-root.sh)" || warn "could not locate scripts/resolve-root.sh"
  TASKS_DIR="$(bash "$RESOLVE_ROOT" get tasks 2>"$ERR_FILE")" || warn "could not resolve the tasks directory: $(first_line "$ERR_FILE")"
  STORY=""
  for f in "$TASKS_DIR/${TASK}"_*.md "$TASKS_DIR/${TASK}.md"; do
    [ -f "$f" ] || continue
    STORY="$(awk 'NR==1 && !/^---[ \t]*$/ {exit} NR>1 && /^---[ \t]*$/ {exit} /^story_id:/ {sub(/^story_id:[ \t]*/, ""); gsub(/["\047\r \t]/, ""); print; exit}' "$f")"
    break
  done
  [ -n "$STORY" ] || warn "unknown task id, or it names no story: $TASK"
  PROGRESS_ARGS=(--story "$STORY")
fi

JSON_FILE="$TMP_DIR/progress.json"
bash "$BOARD_PROGRESS" "${PROGRESS_ARGS[@]}" >"$JSON_FILE" 2>"$ERR_FILE" \
  || warn "board-progress.sh failed: $(first_line "$ERR_FILE")"
[ -s "$JSON_FILE" ] || warn "board-progress.sh printed nothing"

RENDER_ARGS=(--file "$JSON_FILE")
[ -z "$FWD_LEVEL" ] || RENDER_ARGS+=(--level "$FWD_LEVEL")
[ -z "$FWD_COLS" ]  || RENDER_ARGS+=(--cols "$FWD_COLS")
[ -z "$FWD_COLOR" ] || RENDER_ARGS+=(--color "$FWD_COLOR")

# The renderer writes straight to this script's stdout (so it sees the real TTY); it prints nothing when it fails.
bash "$RENDER" "${RENDER_ARGS[@]}" 2>"$ERR_FILE" || warn "render-progress-bar.sh failed: $(first_line "$ERR_FILE")"
exit 0
