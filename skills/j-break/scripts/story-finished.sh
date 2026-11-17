#!/usr/bin/env bash
################################################################################
# story-finished.sh - print the after-story progress line once per finished story (epic E92, E92_S06_T23; Node E92_S08_T07)
#
# The trigger behind "a story just completed all its tasks". It decides WHETHER a story's line is printed and nothing else:
# the counts come only from scripts/board-progress.sh (--story) and the drawing only from a renderer. It is normally
# reached through `run-progress.sh --scope story --task <ids> --after-story`, which prints the after-task lines first and
# then calls this script with the distinct stories it resolved. It can also be run on its own.
#
# Usage:
#   story-finished.sh --story <story id>[,<story id>...] [--cols N] [--color auto|always|never] [--charset utf8|ascii]
#                     [--legacy] [--root DIR]
#
# THE DRAWING (E92_S08_T07). By default the line is drawn by the Node renderer, `node lib/progress/cli.js [--charset C]
# [--cols N] [--color M] after-story --story <id>` (cli.js found like the other helpers: <root>/lib/progress/cli.js, then
# node_modules/@jenga-ai/agent/lib/progress/cli.js), with its output captured. `--legacy`, or JENGA_PROGRESS_RENDERER=legacy
# in the environment, draws with scripts/render-story-bar.sh exactly as before. --charset goes to Node only, and only when
# given. When the Node drawing is not possible (node not on PATH, cli.js not found, a non-zero exit or no output) ONE
# `story-finished.sh: warning: ... (legacy drawing used, run unaffected)` line is written and render-story-bar.sh draws
# that story and every later one of the call. Because the Node output is captured, colour under `auto` is off; colour
# needs `--color always`. When stdout is a terminal and neither --cols nor COLUMNS is given, the terminal width is passed
# to Node as --cols.
#
# FINISHED: the story has at least one counted task (denominator above 0), none pending, none in progress and none of
# unknown status. Failed and Rejected tasks are terminal: a story with Failed tasks is finished, and is announced.
#
# ONCE PER COMPLETION: a ledger in the queue directory (resolved by scripts/resolve-root.sh get queue), file
# story-finished-ledger.tsv, holds one record per announced story: `<story id> TAB <signature>`, where the signature is
# the final bucket counts (done:in_progress:failed:pending:rejected:unknown:denominator). A call that finds the same
# signature prints nothing. A different signature (for example a Failed task re-run and Passed) prints again and replaces
# the record; so does a story that stopped being finished and finished again with other counts. The ledger is
# machine-local transient state and is gitignored.
#
# A PROGRESS PROBLEM NEVER FAILS A RUN: an unknown story, a failing board-progress.sh, a missing helper or renderer, an
# unreadable or unwritable ledger or a missing jq prints one `story-finished.sh: warning: ...` line on stderr for that
# story, prints nothing for it and exits 0. When the ledger cannot be read nothing is printed (it could not be known
# whether the line was already shown). Only a usage error exits 2.
#
# Exit codes: 0 done (printed or not, warnings included); 2 usage error.
################################################################################

set -o nounset

SCRIPT_NAME="story-finished.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Package root (scripts/, templates/, lib/): resolved by the shared helper so it also works from a consumer's .claude/skills mirror.
# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
REPO_ROOT="$(jenga_package_root "$SCRIPT_DIR")" || true

TMP_DIR=""; LOCK_DIR=""
cleanup() {
  [ -z "$LOCK_DIR" ] || rmdir "$LOCK_DIR" 2>/dev/null
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2; }
note() { printf '%s: warning: %s (no story line printed, run unaffected)\n' "$SCRIPT_NAME" "$1" >&2; }
end_ok() { exit 0; }

resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

USAGE="usage: $SCRIPT_NAME --story <id>[,<id>...] [--cols N] [--color auto|always|never] [--charset utf8|ascii] [--legacy] [--root DIR]"
case "${1:-}" in -h|--help|help) printf '%s\n' "$USAGE"; exit 0 ;; esac

STORIES=""; FWD_COLS=""; FWD_COLOR=""; FWD_CHARSET=""; ROOT=""; LEGACY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --story) [ "$#" -ge 2 ] || usage_err "--story needs a value"; STORIES="${STORIES:+$STORIES,}$2"; shift 2 ;;
    --cols)  [ "$#" -ge 2 ] || usage_err "--cols needs a value"; FWD_COLS="$2"; shift 2 ;;
    --color) [ "$#" -ge 2 ] || usage_err "--color needs a value"; FWD_COLOR="$2"; shift 2 ;;
    --charset) [ "$#" -ge 2 ] || usage_err "--charset needs a value"; FWD_CHARSET="$2"; shift 2 ;;
    --legacy) LEGACY=1; shift ;;
    --root)  [ "$#" -ge 2 ] || usage_err "--root needs a value"; ROOT="$2"; shift 2 ;;
    *) usage_err "unknown argument: $1" ;;
  esac
done
[ -n "$STORIES" ] || usage_err "--story needs at least one story id"
case "$FWD_CHARSET" in ""|utf8|ascii) ;; *) usage_err "--charset must be utf8 or ascii, got: $FWD_CHARSET" ;; esac
# The environment form of --legacy. Any other value is the Node default.
[ "${JENGA_PROGRESS_RENDERER:-}" != "legacy" ] || LEGACY=1
[ -z "$ROOT" ] || export JENGA_PROJECT_ROOT="$ROOT"

# The terminal width, for the Node renderer only (its output is captured, so it cannot see the terminal itself).
TTY_COLS=""
if [ "$LEGACY" -eq 0 ] && [ -z "$FWD_COLS" ] && [ -z "${COLUMNS:-}" ] && [ -t 1 ]; then
  exec 3>&1
  TTY_COLS="$(stty size <&3 2>/dev/null | awk '{print $2}')"
  exec 3>&-
  case "$TTY_COLS" in ''|*[!0-9]*) TTY_COLS="" ;; esac
fi

# ---- from here on every failure is a warning, never a failed run --------------------------------------------------
command -v jq >/dev/null 2>&1 || { note "jq is not available"; end_ok; }
BOARD_PROGRESS="$(resolve_helper scripts/board-progress.sh)" || { note "could not locate scripts/board-progress.sh"; end_ok; }
# The legacy renderer is needed up front only in legacy mode; the Node path looks it up when it falls back.
RENDER=""
if [ "$LEGACY" -eq 1 ]; then
  RENDER="$(resolve_helper scripts/render-story-bar.sh)" || { note "could not locate scripts/render-story-bar.sh"; end_ok; }
fi
RESOLVE_ROOT="$(resolve_helper scripts/resolve-root.sh)" || { note "could not locate scripts/resolve-root.sh"; end_ok; }
TMP_DIR="$(mktemp -d 2>/dev/null)" || { note "could not create a temporary directory"; end_ok; }
ERR_FILE="$TMP_DIR/err"; JSON_FILE="$TMP_DIR/progress.json"; NODE_OUT="$TMP_DIR/node.out"; NODE_CLI=""

first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }
last_line() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | tr -d '\r'; }
fallback_note() { printf '%s: warning: %s (legacy drawing used, run unaffected)\n' "$SCRIPT_NAME" "$1" >&2; }

# draw_node <story id>: the Node after-story line, output captured. Prints it and returns 0, or writes ONE warning and
# returns 1 with nothing printed.
draw_node() {
  local why
  command -v node >/dev/null 2>&1 || { fallback_note "node is not on PATH"; return 1; }
  [ -n "$NODE_CLI" ] || NODE_CLI="$(resolve_helper lib/progress/cli.js)" || { fallback_note "could not locate lib/progress/cli.js"; return 1; }
  local cols="${FWD_COLS:-$TTY_COLS}"
  local -a node_args=()
  [ -z "$FWD_CHARSET" ] || node_args+=(--charset "$FWD_CHARSET")
  [ -z "$cols" ]        || node_args+=(--cols "$cols")
  [ -z "$FWD_COLOR" ]   || node_args+=(--color "$FWD_COLOR")
  if node "$NODE_CLI" ${node_args[@]+"${node_args[@]}"} after-story --story "$1" >"$NODE_OUT" 2>"$ERR_FILE" && [ -s "$NODE_OUT" ]; then
    cat "$NODE_OUT"
    return 0
  fi
  why="$(last_line "$ERR_FILE")"
  fallback_note "the Node renderer failed for $1: ${why:-it printed nothing}"
  return 1
}

QUEUE_DIR="$(bash "$RESOLVE_ROOT" get queue 2>"$ERR_FILE")" || { note "could not resolve the queue directory: $(first_line "$ERR_FILE")"; end_ok; }
[ -n "$QUEUE_DIR" ] || { note "the queue directory resolved to an empty path"; end_ok; }
LEDGER="$QUEUE_DIR/story-finished-ledger.tsv"

# The ledger must be readable (or absent) before anything is decided; an unreadable one means "cannot know".
if [ -e "$LEDGER" ] && { [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ]; }; then
  note "the ledger $LEDGER is not a readable file"
  end_ok
fi

# A short best-effort lock around the read-decide-record step, so two waves finishing the same story do not both announce it.
# Never fatal: after the retries the step runs unlocked.
if mkdir -p "$QUEUE_DIR" 2>/dev/null; then
  _try=0
  while [ "$_try" -lt 30 ]; do
    if mkdir "$LEDGER.lock" 2>/dev/null; then LOCK_DIR="$LEDGER.lock"; break; fi
    # a lock older than a minute is stale
    if [ -n "$(find "$LEDGER.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$LEDGER.lock" 2>/dev/null; fi
    _try=$((_try + 1)); sleep 0.1
  done
fi

# recorded_signature <story id>: the signature last announced for the story, or empty.
recorded_signature() {
  [ -f "$LEDGER" ] || return 0
  awk -F '\t' -v id="$1" '$1 == id { sig = $2 } END { if (sig != "") print sig }' "$LEDGER" 2>/dev/null
}

# record <story id> <signature>: replace the story's record, or add one (temp file in the queue directory, then mv).
record() {
  local tmp
  tmp="$(mktemp "$QUEUE_DIR/.story-finished-ledger.XXXXXX" 2>/dev/null)" || { note "cannot write the ledger in $QUEUE_DIR"; return 1; }
  { if [ -f "$LEDGER" ]; then awk -F '\t' -v id="$1" '$1 != id && NF >= 2' "$LEDGER"; fi
    printf '%s\t%s\n' "$1" "$2"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp"; note "cannot write the ledger in $QUEUE_DIR"; return 1; }
  mv -f "$tmp" "$LEDGER" 2>/dev/null || { rm -f "$tmp"; note "cannot update the ledger $LEDGER"; return 1; }
}

process_story() { # <story id>
  local story="$1" row signature done_n prog_n fail_n pend_n rej_n unk_n den_n
  printf '%s' "$story" | grep -Eq '^E[0-9]+_S[0-9]+$' || { note "unknown story id: $story"; return 0; }
  bash "$BOARD_PROGRESS" --story "$story" >"$JSON_FILE" 2>"$ERR_FILE" \
    || { note "board-progress.sh failed for $story: $(first_line "$ERR_FILE")"; return 0; }
  [ -s "$JSON_FILE" ] || { note "board-progress.sh printed nothing for $story"; return 0; }
  row="$(jq -r '
    if (.levels.tasks.totals | type) == "object" then
      .levels.tasks.totals | [.done, .in_progress, .failed, .pending, .rejected, .unknown, .denominator]
      | map(if type == "number" and . >= 0 and . == floor then tostring else "x" end) | join(" ")
    else "x" end' "$JSON_FILE" 2>/dev/null)" || row="x"
  # shellcheck disable=SC2086
  set -- $row
  [ "$#" -eq 7 ] || { note "unreadable board-progress output for $story"; return 0; }
  done_n=$1; prog_n=$2; fail_n=$3; pend_n=$4; rej_n=$5; unk_n=$6; den_n=$7
  case "$row" in *x*) note "unreadable board-progress output for $story"; return 0 ;; esac

  # Finished: something counted, nothing pending, nothing in progress, nothing of unknown status.
  [ "$den_n" -gt 0 ] && [ "$pend_n" -eq 0 ] && [ "$prog_n" -eq 0 ] && [ "$unk_n" -eq 0 ] || return 0

  signature="$done_n:$prog_n:$fail_n:$pend_n:$rej_n:$unk_n:$den_n"
  [ "$(recorded_signature "$story")" != "$signature" ] || return 0

  # The Node line first (default). A failure is warned about once, and the legacy renderer draws this story and every
  # later one of the call.
  if [ "$LEGACY" -eq 0 ]; then
    if draw_node "$story"; then
      record "$story" "$signature" || true
      return 0
    fi
    LEGACY=1
  fi
  if [ -z "$RENDER" ]; then
    RENDER="$(resolve_helper scripts/render-story-bar.sh)" || { note "could not locate scripts/render-story-bar.sh"; return 0; }
  fi
  local -a render_args=(--file "$JSON_FILE")
  [ -z "$FWD_COLS" ]  || render_args+=(--cols "$FWD_COLS")
  [ -z "$FWD_COLOR" ] || render_args+=(--color "$FWD_COLOR")
  # The renderer writes straight to this script's stdout (so it sees the real TTY). Record only after it succeeded.
  if bash "$RENDER" "${render_args[@]}" 2>"$ERR_FILE"; then
    record "$story" "$signature" || true
  else
    note "render-story-bar.sh failed for $story: $(first_line "$ERR_FILE")"
  fi
  return 0
}

rest="$STORIES,"
SEEN=" "
while [ -n "$rest" ]; do
  el="${rest%%,*}"; rest="${rest#*,}"
  el="${el#"${el%%[![:space:]]*}"}"; el="${el%"${el##*[![:space:]]}"}"
  [ -n "$el" ] || continue
  case "$SEEN" in *" $el "*) continue ;; esac
  SEEN="$SEEN$el "
  process_story "$el"
done
exit 0
