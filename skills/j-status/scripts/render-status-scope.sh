#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-status/scripts/render-status-scope.sh - the extended block of `j.status <scope>` (E92_S06_T15)
#
# For one epic or one story prints (1) the dependency tree as indented text, stories as groups and tasks as nodes with
# their depends_on, (2) the "Ready to take" list and (3) one "X unlocked by Y" line per unlocked_by.
#
# This script does no counting and no readiness or dependency logic. It reads the board ONCE with
# `scripts/board-progress.sh --graph --within <id>` and only lays out what that JSON states (state, ready, unlocked_by,
# depends_on, complete, stop). Every word comes from scripts/lib/progress-labels.sh (JENGA_PROGRESS_LANG=sv for Swedish).
#
# USAGE
#   render-status-scope.sh <id> [--cols N] [--color auto|always|never] [--root <dir>]
#   render-status-scope.sh -h | --help       print this usage on stdout, exit 0
#
#   <id>     one epic or story id, any width (E3_S5 equals E03_S05). A task id, a missing or a malformed id is a usage error.
#   --cols   terminal width (default: COLUMNS, else 80). Under 50 the tree degrades to a flat list, one node per line.
#   --color  auto (default: colour only when stdout is a TTY and NO_COLOR is empty), always, never.
#   --root   project root, forwarded to board-progress.sh.
#
# Glyphs: UTF-8 locale: ● done, ◉ in progress or failed, ○ pending, locked or rejected, ⚑ goal, ★ complete, ━ and ╌
# connectors. Any other locale (first non-empty of LC_ALL, LC_CTYPE, LANG) gives ASCII only: [x] [~] [ ] > * = -.
#
# SIBLING FILES, first match wins
#   env JENGA_BOARD_PROGRESS / JENGA_PROGRESS_LABELS (test seam), then <this dir>/../../../scripts/<name> and
#   scripts/lib/progress-labels.sh, then node_modules/@jenga-ai/agent/scripts/<name>.
#
# A PROBLEM NEVER FAILS j.status
#   Missing script or labels, board-progress.sh failing, malformed JSON, jq missing: ONE stderr warning, nothing on
#   stdout, exit 0. Only a usage error exits 2. Read-only; writes nothing.
#
# EXIT CODES: 0 block printed or problem warned about; 2 usage error.
# Requires: bash 3.2+, jq.
# ---------------------------------------------------------------------------
set -u

SCRIPT_NAME="render-status-scope.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '/^# USAGE/,/^# SIBLING FILES/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
usage_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2; }
warn() { printf '%s: warning: %s (status scope block skipped)\n' "$SCRIPT_NAME" "$1" >&2; exit 0; }

id=""; cols=""; color="auto"; root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cols)    [ "$#" -ge 2 ] || usage_err "--cols needs a value"; cols="$2"; shift 2 ;;
    --cols=*)  cols="${1#--cols=}"; shift ;;
    --color)   [ "$#" -ge 2 ] || usage_err "--color needs a value"; color="$2"; shift 2 ;;
    --color=*) color="${1#--color=}"; shift ;;
    --root)    [ "$#" -ge 2 ] || usage_err "--root needs a value"; root="$2"; shift 2 ;;
    --root=*)  root="${1#--root=}"; shift ;;
    -*) usage_err "unknown argument: $1 (see --help)" ;;
    *)  [ -z "$id" ] || usage_err "only one id is allowed (got '$id' and '$1')"; id="$1"; shift ;;
  esac
done

[ -n "$id" ] || usage_err "an epic or story id is required (see --help)"
case "$id" in
  [Ee][0-9]*_[Ss][0-9]*_[Tt][0-9]*) usage_err "'$id' is a task id; give an epic or a story id" ;;
esac
printf '%s' "$id" | grep -Eq '^[Ee][0-9]+(_[Ss][0-9]+)?$' || usage_err "malformed id '$id' (expected E<digits> or E<digits>_S<digits>)"
case "$color" in auto|always|never) ;; *) usage_err "--color must be auto, always or never" ;; esac
if [ -n "$cols" ]; then printf '%s' "$cols" | grep -Eq '^[0-9]+$' || usage_err "--cols needs a positive integer"; fi
id="$(printf '%s' "$id" | tr 'es' 'ES')"

# find_file <env override> <path relative to scripts/>
find_file() {
  local override="$1" rel="$2" cand
  if [ -n "$override" ]; then [ -f "$override" ] && printf '%s' "$override"; return 0; fi
  for cand in "$SCRIPT_DIR/../../../scripts/$rel" "scripts/$rel" "node_modules/@jenga-ai/agent/scripts/$rel"; do
    if [ -f "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  return 0
}

BOARD_PROGRESS="$(find_file "${JENGA_BOARD_PROGRESS:-}" board-progress.sh)"
LABELS="$(find_file "${JENGA_PROGRESS_LABELS:-}" lib/progress-labels.sh)"
[ -n "$BOARD_PROGRESS" ] || warn "board-progress.sh not found"
[ -n "$LABELS" ] || warn "progress-labels.sh not found"
command -v jq >/dev/null 2>&1 || warn "jq not found"

# shellcheck disable=SC1090
. "$LABELS" 2>/dev/null || warn "progress-labels.sh could not be loaded"
l_title="$(progress_label tree_title)";   l_empty="$(progress_label tree_empty)"
l_ready="$(progress_label ready_to_take)"; l_none="$(progress_label nothing_ready)"
l_unl="$(progress_label unlocked_by)";    l_goal="$(progress_label goal)"
l_done="$(progress_label state_done)";    l_rdy="$(progress_label state_ready)"
l_lock="$(progress_label state_locked)";  l_fail="$(progress_label state_failed)"
l_rej="$(progress_label state_rejected)"; l_prog="$(progress_label in_progress)"
l_unk="$(progress_label unknown)"
[ -n "$l_title" ] && [ -n "$l_empty" ] && [ -n "$l_ready" ] && [ -n "$l_none" ] && [ -n "$l_unl" ] || warn "progress labels missing"

# Locale: UTF-8 glyphs or the ASCII stand-ins (same rule as render-progress-bar.sh).
loc="${LC_ALL:-}"; [ -n "$loc" ] || loc="${LC_CTYPE:-}"; [ -n "$loc" ] || loc="${LANG:-}"
case "$loc" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) utf=1 ;;
  *) utf=0 ;;
esac

if [ "$color" = "auto" ]; then
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then color="always"; else color="never"; fi
fi
[ -n "$cols" ] || cols="${COLUMNS:-80}"
case "$cols" in ''|*[!0-9]*) cols=80 ;; esac

bp_args=(--graph --within "$id")
[ -z "$root" ] || bp_args=("${bp_args[@]}" --root "$root")
json="$(bash "$BOARD_PROGRESS" "${bp_args[@]}" 2>/dev/null)" || warn "board-progress.sh --graph --within $id failed"
[ -n "$json" ] || warn "board-progress.sh --graph printed nothing"

out="$(printf '%s\n' "$json" | jq -r \
  --argjson utf "$utf" --argjson color "$([ "$color" = always ] && echo 1 || echo 0)" --argjson cols "$cols" \
  --arg id "$id" --arg t_title "$l_title" --arg t_empty "$l_empty" --arg t_ready "$l_ready" --arg t_none "$l_none" \
  --arg t_unl "$l_unl" --arg t_goal "$l_goal" --arg s_done "$l_done" --arg s_ready "$l_rdy" --arg s_locked "$l_lock" \
  --arg s_failed "$l_fail" --arg s_rej "$l_rej" --arg s_prog "$l_prog" --arg s_unk "$l_unk" '
  def clean: tostring | gsub("[\u0000-\u001f\u007f]"; "?");
  def g: if $utf == 1 then {done:"●", prog:"◉", pend:"○", goal:"⚑", star:"★", on:"━", off:"╌", sep:"·"}
         else {done:"[x]", prog:"[~]", pend:"[ ]", goal:">", star:"*", on:"=", off:"-", sep:"-"} end;
  def esc: [27] | implode;
  def paint(c; s): if $color == 1 then esc + "[" + c + "m" + s + esc + "[0m" else s end;
  def word: {done:$s_done, ready:$s_ready, locked:$s_locked, failed:$s_failed, rejected:$s_rej, in_progress:$s_prog}[.] // $s_unk;
  def sym: if . == "done" then {s: g.done, c: "32"}
           elif . == "in_progress" or . == "failed" then {s: g.prog, c: (if . == "failed" then "31" else "33" end)}
           else {s: g.pend, c: "2"} end;
  def stopsym: if . == "done" then "done" elif . == "failed" then "failed" elif . == "in_progress" then "in_progress" else "pending" end;
  def deps: (.depends_on // []) | map(clean) | join(", ");
  . as $d
  | ($d.tasks // []) as $tasks | ($d.stories // []) as $stories
  | (if ($d.scope.within // "") != "" then ($d.scope.within | clean) else $id end) as $scope
  | ( ($stories | length) > 0 and ($stories | all(.complete == true)) ) as $all_complete
  | ([$stories[] | select((.depends_on // []) | length > 0)] + [$tasks[] | select((.depends_on // []) | length > 0)] | length > 0) as $has_edges
  | ( (if $all_complete then g.star else g.goal end) + " " + $t_goal + ": " + $scope ) as $goal_line
  | [ paint("1"; $t_title + " (" + $scope + ")"),
      paint("36"; $goal_line),
      ( if $has_edges | not then "  " + $t_empty
        elif $cols < 50 then
          ( $tasks[] | (.state | sym) as $y | paint($y.c; $y.s) + " " + (.id | clean) + " " + (.state | word) )
        else
          ( $stories[] as $s
            | ($s.stop | stopsym | sym) as $y
            | ("  " + paint($y.c; $y.s) + " " + ($s.id | clean) + " " + ($s.title | clean)
               + (if ($s.depends_on // []) | length > 0 then " " + g.off + g.off + " " + ($s | deps) else "" end)),
              ( $tasks[] | select(.story_id == $s.id) | (.state | sym) as $t
                | ("      " + paint($t.c; $t.s) + " " + (.id | clean) + " " + (.state | word) + " " + g.sep + " " + (.title | clean)
                   + (if (.depends_on // []) | length > 0 then " " + (if .state == "locked" or .state == "failed" or .state == "rejected" then g.off + g.off else g.on + g.on end) + " " + deps else "" end)) ) )
        end ),
      "",
      paint("1"; $t_ready),
      ( if ($d.ready // []) | length == 0 then "  " + $t_none
        else ( $d.ready[] as $r | "  " + g.pend + " " + ($r | clean)
               + ( [$tasks[] | select(.id == $r) | .title | clean] | if length > 0 then " " + g.sep + " " + .[0] else "" end ) ) end ),
      ( [$tasks[] | select((.unlocked_by // null) != null)] as $u
        | if ($u | length) > 0 then "", ( $u[] | (.id | clean) as $a | (.unlocked_by | clean) as $b | "  " + ($t_unl | gsub("%s"; "@@") | sub("@@"; $a) | sub("@@"; $b)) ) else empty end )
    ] | .[]
' 2>/dev/null)" || warn "board-progress.sh output could not be rendered"
[ -n "$out" ] || warn "nothing to render"
printf '%s\n' "$out"
exit 0
