#!/usr/bin/env bash
################################################################################
# run-progress.sh - resolve a run's scope and print its progress lines (epic E92, E92_S02_T04; Node drawing E92_S08_T07)
#
# The one script /jenga, /do and /dooo call after a finished task or wave. It decides WHICH tasks the lines are about and
# nothing else: the counts come only from scripts/board-progress.sh and the drawing only from a renderer. This file holds
# no status names and does no counting.
#
# THE AFTER-TASK CALL IS `--scope story` (E92_S06_T22). After a finished task, or a finished wave, the callers run
# `--scope story --task <finished task id>[,<id>...]` and the line always shows the STORY the finished task belongs to,
# never the epic and never the whole run. `--resolve-scope` and `--scope run` are kept for compatibility (nothing in
# skills/ calls them any more); they are not part of the after-task contract and always draw with the legacy renderer.
#
# THE DRAWING (E92_S08_T07). In story scope the lines are drawn by the Node renderer by default:
#   after-task lines   node lib/progress/cli.js [--charset C] [--cols N] [--color M] after-task --story <S1,S2,...>
#                      (ONE call for every distinct story, in first-seen order: each call pays the label-table cost)
#   after-story lines  story-finished.sh (next to this script), which draws with `cli.js after-story` the same way
# `--legacy`, or JENGA_PROGRESS_RENDERER=legacy in the environment, draws with the old bash renderers instead,
# scripts/render-progress-bar.sh and scripts/render-story-bar.sh, byte for byte as before E92_S08_T07. Any other value of
# JENGA_PROGRESS_RENDERER (empty, `node`, anything else) means the Node default; an environment value is never a usage
# error. cli.js is looked up with the same dual path as the other helpers (<root>/lib/progress/cli.js, then
# node_modules/@jenga-ai/agent/lib/progress/cli.js).
#
# The Node output is captured (so a failure can fall back), therefore Node sees a pipe: under the default colour mode
# `auto` it draws no colour, and colour needs `--color always` in a real terminal. When stdout is a terminal and neither
# --cols nor COLUMNS is given, the terminal width is passed to Node as --cols.
#
# Usage:
#   run-progress.sh --scope story --task <task id>[,<task id>...] [--after-story] [--legacy] [render options]
#   run-progress.sh --scope run   --ids <id>[,<id>...]            [render options]   (compatibility, legacy drawing)
#   run-progress.sh --resolve-scope --ids <id>[,<id>...]                             (compatibility)
#
#   --scope story    the parent story of each --task (its own `story_id`). --task takes one id or a comma separated
#                    list. ONE line is printed per DISTINCT parent story, in the order each story is first seen in the
#                    list (a /jenga wave can finish tasks of several stories; two tasks of one story print one line).
#   --after-story    (--scope story only; E92_S06_T23) once the after-task lines are printed, also print the AFTER-STORY
#                    line for every distinct story that has just finished (all its tasks in a terminal state, failures
#                    included). The decision, the once-per-completion ledger and the drawing live in story-finished.sh
#                    (next to this script); this script only hands over the stories it resolved. The after-task lines
#                    always come first. A repeat call in the same finished state prints no story line.
#   --legacy         (story scope) draw with the old bash renderers, as before E92_S08_T07. Also passed on to
#                    story-finished.sh. The environment form is JENGA_PROGRESS_RENDERER=legacy.
#   --resolve-scope  prints `run` or `story` once. DOCUMENTED DEFAULT: `run` when the ids expand to at least 2 tasks,
#                    otherwise `story` (a one-task run would only ever show 0/1 and then 1/1). The orchestrator calls
#                    this ONCE at run start and keeps the answer; the choice is never re-made per print.
#   --scope run      the run's own scope. Each id is expanded to tasks (a task is itself; a story or an epic goes
#                    through `board-progress.sh --story/--epic <id> --items`), unioned with the task ids this session's
#                    execution ledger records (so a later /jenga wave that adds items is counted), de-duplicated, and
#                    handed to `board-progress.sh --ids`. The ledger is read by skills/j-break/scripts/lib/ledger_reader.py,
#                    the same reader render-execution-status.sh uses, under the same session key.
#   --cols, --color  forwarded to the renderer unchanged (Node and legacy).
#   --charset utf8|ascii   forwarded to the Node renderer only, and only when given, so its own precedence holds (flag,
#                    then JENGA_PROGRESS_CHARSET, then config progress_charset, then utf8). The legacy renderers pick
#                    their glyphs from the locale and never see it. A value other than utf8 or ascii is a usage error.
#   --level          forwarded to the legacy renderer only (the Node after-task line is always the task level).
#   --session KEY    session key for the ledger (default: scripts/checklist-marker.sh session-key; with none, the
#                    ledger union is skipped).
#   --root DIR       project root (exported as JENGA_PROJECT_ROOT, as board-progress.sh's own --root does).
#
# Output: one newline-terminated line per printed bar on stdout (story scope: one per distinct story, then the
# after-story lines; run scope: one). The legacy renderers inherit this script's stdout, so their TTY, colour and width
# detection see the real terminal.
#
# A PROGRESS PROBLEM NEVER FAILS A RUN. An unknown id, an empty scope, a missing script, a malformed ledger line or a
# renderer failure prints one `run-progress.sh: warning: ...` line on stderr, prints nothing on stdout and exits 0. An
# empty answer from --resolve-scope therefore means "show no bar". With a list of tasks every id is resolved to its story
# BEFORE anything is drawn, so an unknown id or a task naming no story prints nothing at all; a legacy renderer failure
# part-way stops at the first failing bar, warning once. When the NODE drawing is not possible (node not on PATH, cli.js
# not found, cli.js exits non-zero or prints nothing) one `run-progress.sh: warning: ... (legacy drawing used, run
# unaffected)` line is written and the legacy renderers draw every line of the call instead (story-finished.sh is then
# told --legacy, so the after-story line adds no second warning). Only a usage error (missing, conflicting or unknown
# arguments, a bad --charset) exits 2.
#
# Exit codes: 0 printed, or a progress problem was warned about; 2 usage error.
################################################################################

set -o nounset

SCRIPT_NAME="run-progress.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Package root (scripts/, templates/, lib/): resolved by the shared helper so it also works from a consumer's .claude/skills mirror.
# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
REPO_ROOT="$(jenga_package_root "$SCRIPT_DIR")" || true

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

USAGE="usage: $SCRIPT_NAME --scope story --task <id>[,<id>...] [--after-story] [--legacy] [opts] | --scope run --ids <ids> [opts] | --resolve-scope --ids <ids>"

case "${1:-}" in -h|--help|help) printf '%s\n' "$USAGE"; exit 0 ;; esac

RESOLVE=0; SCOPE=""; IDS=""; TASK=""; SESSION_KEY=""; ROOT=""; AFTER_STORY=0; LEGACY=0
FWD_LEVEL=""; FWD_COLS=""; FWD_COLOR=""; FWD_CHARSET=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve-scope) RESOLVE=1; shift ;;
    --after-story) AFTER_STORY=1; shift ;;
    --legacy)  LEGACY=1; shift ;;
    --scope)   [ "$#" -ge 2 ] || usage_err "--scope needs a value"; SCOPE="$2"; shift 2 ;;
    --ids)     [ "$#" -ge 2 ] || usage_err "--ids needs a value"; IDS="${IDS:+$IDS,}$2"; shift 2 ;;
    --task)    [ "$#" -ge 2 ] || usage_err "--task needs a value"; TASK="$2"; shift 2 ;;
    --session) [ "$#" -ge 2 ] || usage_err "--session needs a value"; SESSION_KEY="$2"; shift 2 ;;
    --root)    [ "$#" -ge 2 ] || usage_err "--root needs a value"; ROOT="$2"; shift 2 ;;
    --level)   [ "$#" -ge 2 ] || usage_err "--level needs a value"; FWD_LEVEL="$2"; shift 2 ;;
    --cols)    [ "$#" -ge 2 ] || usage_err "--cols needs a value"; FWD_COLS="$2"; shift 2 ;;
    --color)   [ "$#" -ge 2 ] || usage_err "--color needs a value"; FWD_COLOR="$2"; shift 2 ;;
    --charset) [ "$#" -ge 2 ] || usage_err "--charset needs a value"; FWD_CHARSET="$2"; shift 2 ;;
    *) usage_err "unknown argument: $1" ;;
  esac
done

if [ "$RESOLVE" -eq 1 ]; then
  [ -z "$SCOPE" ] || usage_err "--resolve-scope and --scope cannot be combined"
  [ -z "$TASK" ] || usage_err "--resolve-scope takes --ids, not --task"
  [ -n "$IDS" ] || usage_err "--resolve-scope needs --ids"
  [ "$AFTER_STORY" -eq 0 ] || usage_err "--after-story needs --scope story"
else
  case "$SCOPE" in
    run)   [ -n "$IDS" ] || usage_err "--scope run needs --ids"
           [ -z "$TASK" ] || usage_err "--scope run takes --ids, not --task" ;;
    story) [ -n "$TASK" ] || usage_err "--scope story needs --task"
           [ -z "$IDS" ] || usage_err "--scope story takes --task, not --ids" ;;
    "")    usage_err "$USAGE" ;;
    *)     usage_err "--scope must be run or story, got: $SCOPE" ;;
  esac
  [ "$AFTER_STORY" -eq 0 ] || [ "$SCOPE" = "story" ] || usage_err "--after-story needs --scope story"
fi

case "$FWD_CHARSET" in ""|utf8|ascii) ;; *) usage_err "--charset must be utf8 or ascii, got: $FWD_CHARSET" ;; esac
# The environment form of --legacy. Any other value is the Node default.
[ "${JENGA_PROGRESS_RENDERER:-}" != "legacy" ] || LEGACY=1

[ -z "$ROOT" ] || export JENGA_PROJECT_ROOT="$ROOT"

# The terminal width, for the Node renderer only: its output is captured, so it cannot see the terminal itself. Read only
# when stdout is a terminal and neither --cols nor COLUMNS is given (the legacy renderers detect it on their own).
TTY_COLS=""
if [ -z "$FWD_COLS" ] && [ -z "${COLUMNS:-}" ] && [ -t 1 ]; then
  exec 3>&1
  TTY_COLS="$(stty size <&3 2>/dev/null | awk '{print $2}')"
  exec 3>&-
  case "$TTY_COLS" in ''|*[!0-9]*) TTY_COLS="" ;; esac
fi

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

# The legacy bar renderer. The Node path of story scope needs it only when it falls back, so it is looked up there.
RENDER=""
if [ "$SCOPE" = "run" ] || [ "$LEGACY" -eq 1 ]; then
  RENDER="$(resolve_helper scripts/render-progress-bar.sh)" || warn "could not locate scripts/render-progress-bar.sh"
fi

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
  # Every id of the list is resolved to its parent story first (so a bad id prints nothing), then the distinct stories are
  # drawn in first-seen order. The dedup lives here, not in the callers.
  RESOLVE_ROOT="$(resolve_helper scripts/resolve-root.sh)" || warn "could not locate scripts/resolve-root.sh"
  TASKS_DIR="$(bash "$RESOLVE_ROOT" get tasks 2>"$ERR_FILE")" || warn "could not resolve the tasks directory: $(first_line "$ERR_FILE")"
  STORIES_FILE="$TMP_DIR/stories"
  : >"$STORIES_FILE"
  rest="$TASK,"
  while [ -n "$rest" ]; do
    el="${rest%%,*}"; rest="${rest#*,}"
    el="${el#"${el%%[![:space:]]*}"}"; el="${el%"${el##*[![:space:]]}"}"
    [ -n "$el" ] || continue
    printf '%s' "$el" | grep -Eq '^E[0-9]+_S[0-9]+_T[0-9]+$' || warn "unknown task id: $el"
    STORY=""
    for f in "$TASKS_DIR/${el}"_*.md "$TASKS_DIR/${el}.md"; do
      [ -f "$f" ] || continue
      STORY="$(awk 'NR==1 && !/^---[ \t]*$/ {exit} NR>1 && /^---[ \t]*$/ {exit} /^story_id:/ {sub(/^story_id:[ \t]*/, ""); gsub(/["\047\r \t]/, ""); print; exit}' "$f")"
      break
    done
    [ -n "$STORY" ] || warn "unknown task id, or it names no story: $el"
    printf '%s\n' "$STORY" >>"$STORIES_FILE"
  done
  STORIES="$(dedupe <"$STORIES_FILE")"
  [ -n "$STORIES" ] || warn "--task names no task: $TASK"
fi

# Counts for one scope, then the bar. The renderer writes straight to this script's stdout (so it sees the real TTY); it
# prints nothing when it fails.
print_bar() { # <board-progress.sh arguments...>
  local json_file="$TMP_DIR/progress.json"
  bash "$BOARD_PROGRESS" "$@" >"$json_file" 2>"$ERR_FILE" \
    || warn "board-progress.sh failed: $(first_line "$ERR_FILE")"
  [ -s "$json_file" ] || warn "board-progress.sh printed nothing"

  local -a render_args=(--file "$json_file")
  [ -z "$FWD_LEVEL" ] || render_args+=(--level "$FWD_LEVEL")
  [ -z "$FWD_COLS" ]  || render_args+=(--cols "$FWD_COLS")
  [ -z "$FWD_COLOR" ] || render_args+=(--color "$FWD_COLOR")

  bash "$RENDER" "${render_args[@]}" 2>"$ERR_FILE" || warn "render-progress-bar.sh failed: $(first_line "$ERR_FILE")"
}

# The Node drawing of the after-task lines: ONE call for every distinct story (comma list), output captured so that a
# failure can fall back. Prints the lines and returns 0, or writes ONE warning and returns 1 with nothing printed.
fallback_note() { printf '%s: warning: %s (legacy drawing used, run unaffected)\n' "$SCRIPT_NAME" "$1" >&2; }
last_line() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | tr -d '\r'; }
draw_node_after_task() { # <comma list of story ids>
  local cli out="$TMP_DIR/node.out" err="$TMP_DIR/node.err" cols="${FWD_COLS:-$TTY_COLS}" why
  command -v node >/dev/null 2>&1 || { fallback_note "node is not on PATH"; return 1; }
  cli="$(resolve_helper lib/progress/cli.js)" || { fallback_note "could not locate lib/progress/cli.js"; return 1; }
  local -a node_args=()
  [ -z "$FWD_CHARSET" ] || node_args+=(--charset "$FWD_CHARSET")
  [ -z "$cols" ]        || node_args+=(--cols "$cols")
  [ -z "$FWD_COLOR" ]   || node_args+=(--color "$FWD_COLOR")
  if node "$cli" ${node_args[@]+"${node_args[@]}"} after-task --story "$1" >"$out" 2>"$err" && [ -s "$out" ]; then
    cat "$out"
    return 0
  fi
  why="$(last_line "$err")"
  fallback_note "the Node renderer failed: ${why:-it printed nothing}"
  return 1
}

if [ "$SCOPE" = "run" ]; then
  print_bar --ids "$TASKS"
else
  DRAWN_BY_NODE=0
  if [ "$LEGACY" -eq 0 ] && draw_node_after_task "$(printf '%s\n' "$STORIES" | paste -s -d, -)"; then
    DRAWN_BY_NODE=1
  fi
  if [ "$DRAWN_BY_NODE" -eq 0 ]; then
    [ -n "$RENDER" ] || RENDER="$(resolve_helper scripts/render-progress-bar.sh)" || warn "could not locate scripts/render-progress-bar.sh"
    while IFS= read -r STORY; do
      print_bar --story "$STORY"
    done <<<"$STORIES"
  fi
  if [ "$AFTER_STORY" -eq 1 ]; then
    # After-story lines come after every after-task line. The trigger script owns the decision, the ledger and the
    # drawing; any problem it has is its own warning and exit 0. It draws with the legacy renderer whenever this call did
    # (by choice or after a Node failure, which has already been warned about once).
    TRIGGER="$SCRIPT_DIR/story-finished.sh"
    [ -f "$TRIGGER" ] || warn "could not locate $TRIGGER"
    trigger_args=(--story "$(printf '%s\n' "$STORIES" | paste -s -d, -)")
    [ -z "$FWD_COLS" ]    || trigger_args+=(--cols "$FWD_COLS")
    [ -z "$FWD_COLOR" ]   || trigger_args+=(--color "$FWD_COLOR")
    [ -z "$FWD_CHARSET" ] || trigger_args+=(--charset "$FWD_CHARSET")
    [ "$DRAWN_BY_NODE" -eq 1 ] || trigger_args+=(--legacy)
    bash "$TRIGGER" "${trigger_args[@]}" 2>"$ERR_FILE" || warn "story-finished.sh failed: $(first_line "$ERR_FILE")"
    # Its own warnings are on stderr and it printed nothing else: pass them on.
    [ ! -s "$ERR_FILE" ] || cat "$ERR_FILE" >&2
  fi
fi
exit 0
