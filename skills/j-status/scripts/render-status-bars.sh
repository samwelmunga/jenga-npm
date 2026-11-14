#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-status/scripts/render-status-bars.sh - one progress bar per epic and per story, for j.status (E92_S05_T04)
#
# Prints, for every epic and then every story on the board, one line
#
#     <id><TAB><bar line>
#
# for example (language en, NO_COLOR):  E92<TAB>[██████░░░░] 6/10 · 1 in progress
#
# This script adds no counting and no drawing of its own. It reads the board ONCE with
# `scripts/board-progress.sh --by-parent` and pipes that one JSON document twice into
# `scripts/render-progress-bar.sh --each epics` and `--each stories`, in that order (epics first, each group in the
# numeric id order board-progress.sh produced). Every number comes from board-progress.sh and every glyph from the
# renderer, so a line here is byte-identical to what the single-bar renderer prints for the same totals.
#
# USAGE
#   render-status-bars.sh [--cols N] [--color auto|always|never] [--root <dir>]
#   render-status-bars.sh -h | --help       print this usage on stdout, exit 0
#
#   --cols   terminal width in columns, forwarded to the renderer unchanged (its width rules apply per line).
#   --color  forwarded to the renderer. The renderer's own `auto` looks at ITS stdout, which here is always a pipe
#            (output is buffered, see below), so `auto` is resolved against THIS script's stdout first: a TTY and no
#            non-empty NO_COLOR gives `always`, anything else is passed on as `auto` (which resolves to no colour).
#            `always` and `never` are passed through untouched, so `always` still forces colour over NO_COLOR.
#   --root   project root, forwarded to board-progress.sh as `--root <dir>` (it reads that board instead of the one
#            in the current directory). Used by tests and by callers running from outside the project.
#
# SIBLING SCRIPTS
#   board-progress.sh and render-progress-bar.sh are looked up, first match wins:
#     1. JENGA_BOARD_PROGRESS / JENGA_RENDER_PROGRESS_BAR (environment; a path to the script; the test seam)
#     2. <this script's directory>/../../../scripts/<name>   (the repository, the .claude/.agents mirrors and the
#        node_modules/@jenga-ai/agent package all keep skills/ and scripts/ side by side)
#     3. scripts/<name>, then node_modules/@jenga-ai/agent/scripts/<name>   (relative to the current directory)
#
# A BAR PROBLEM NEVER FAILS j.status
#   Output is buffered and printed only when both renderings succeeded. If either shared script is missing, exits
#   non-zero (board with no epic file, jq missing, malformed JSON ...) this script prints ONE warning line on stderr,
#   prints NOTHING on stdout and exits 0, so j.status can still print its tables without bars. A board with epics but
#   no stories prints the epic lines only. Only a usage error (unknown or valueless argument) exits 2.
#
# EXIT CODES
#   0 lines printed, or a bar problem was warned about (empty stdout); 2 usage error.
#
# Requires: bash 3.2+ (macOS bash is fine) and what the two shared scripts require (jq).
# ---------------------------------------------------------------------------
set -u

SCRIPT_NAME="render-status-bars.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '/^# USAGE/,/^# SIBLING SCRIPTS/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}
usage_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2; }
warn() { printf '%s: warning: %s (status bars skipped)\n' "$SCRIPT_NAME" "$1" >&2; exit 0; }

cols=""
color="auto"
root=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cols)    [ "$#" -ge 2 ] || usage_err "--cols needs a value"; cols="$2"; shift 2 ;;
    --cols=*)  cols="${1#--cols=}"; shift ;;
    --color)   [ "$#" -ge 2 ] || usage_err "--color needs a value"; color="$2"; shift 2 ;;
    --color=*) color="${1#--color=}"; shift ;;
    --root)    [ "$#" -ge 2 ] || usage_err "--root needs a value"; root="$2"; shift 2 ;;
    --root=*)  root="${1#--root=}"; shift ;;
    *) usage_err "unknown argument: $1 (see --help)" ;;
  esac
done

# find_script <env override> <file name>: prints the path of the script, or nothing.
find_script() {
  local override="$1" name="$2" cand
  if [ -n "$override" ]; then
    [ -f "$override" ] && printf '%s' "$override"
    return 0
  fi
  for cand in "$SCRIPT_DIR/../../../scripts/$name" "scripts/$name" "node_modules/@jenga-ai/agent/scripts/$name"; do
    if [ -f "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  return 0
}

BOARD_PROGRESS="$(find_script "${JENGA_BOARD_PROGRESS:-}" board-progress.sh)"
RENDERER="$(find_script "${JENGA_RENDER_PROGRESS_BAR:-}" render-progress-bar.sh)"
[ -n "$BOARD_PROGRESS" ] || warn "board-progress.sh not found"
[ -n "$RENDERER" ] || warn "render-progress-bar.sh not found"

# Colour: the renderer's `auto` would see a pipe (we buffer), so decide it here from our own stdout.
if [ "$color" = "auto" ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  color="always"
fi

render_args=(--color "$color")
if [ -n "$cols" ]; then render_args=(--cols "$cols" "${render_args[@]}"); fi

bp_args=(--by-parent)
if [ -n "$root" ]; then bp_args=("${bp_args[@]}" --root "$root"); fi

json="$(bash "$BOARD_PROGRESS" "${bp_args[@]}" 2>/dev/null)" || warn "board-progress.sh --by-parent failed"
[ -n "$json" ] || warn "board-progress.sh --by-parent printed nothing"

epic_lines="$(printf '%s\n' "$json" | bash "$RENDERER" --each epics "${render_args[@]}" 2>/dev/null)" \
  || warn "render-progress-bar.sh --each epics failed"
story_lines="$(printf '%s\n' "$json" | bash "$RENDERER" --each stories "${render_args[@]}" 2>/dev/null)" \
  || warn "render-progress-bar.sh --each stories failed"

# Both succeeded: print. ($(...) removed the trailing newline of each block, so add exactly one back.)
if [ -n "$epic_lines" ]; then printf '%s\n' "$epic_lines"; fi
if [ -n "$story_lines" ]; then printf '%s\n' "$story_lines"; fi
exit 0
