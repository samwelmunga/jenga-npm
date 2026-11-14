#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-status/scripts/render-status-overview.sh - the default `j.status` overview (E92_S06_T24)
#
# Prints a short board overview instead of the per-epic and per-story list:
#   1. a total line (epics, done/total tasks, percent), a bar and the counts;
#   2. only epics that are NOT complete, in groups with a heading each, in this order: Needs attention (has failed
#      tasks), In progress, Started, Not started. Inside a group sorted by percent (highest first), ties by id.
#      One row per epic: id, bar, done/total, percent, a failed or in-progress marker and the title cut to the width;
#   3. complete epics collapse to ONE line ("Complete (N)" and their task total), epics with only rejected tasks or no
#      tasks to ONE more line;
#   4. a footer hint: `j.status <id>` for one epic, `j.status --all` for every row.
#
# This script does no counting and no status classification. It reads the board ONCE with
# `scripts/board-progress.sh --graph --counts-only` and only lays out the totals objects that JSON states (each epic's
# tasks.totals); the percent is round(done * 100 / denominator) of those totals. Every word comes from
# scripts/lib/progress-labels.sh (JENGA_PROGRESS_LANG=sv for Swedish). Layout helpers (glyph sets, width, colour,
# truncation, bar drawing) are in lib/status-render-common.sh.
#
# USAGE
#   render-status-overview.sh [--all] [--cols N] [--color auto|always|never] [--root <dir>]
#   render-status-overview.sh -h | --help       print this usage on stdout, exit 0
#
#   --all    accepted, then this script prints NOTHING and exits 0: the full legacy list is produced by the j.status
#            SKILL.md wiring (E92_S06_T26), which runs the legacy renderers for --all. The flag exists only so that the
#            caller may pass it through unchanged.
#   --cols   terminal width (default: COLUMNS, else `stty size` on a TTY, else 80). Under 50 the bars are dropped. No
#            line is ever wider than the width: a longer line is cut and ends in the "more" glyph.
#   --color  auto (default: colour only when stdout is a TTY and NO_COLOR is empty), always, never.
#   --root   project root, forwarded to board-progress.sh.
#
# Glyphs: UTF-8 locale: ━ filled and ╌ empty bar cells, ◉ in progress, ✕ failed, ○ pending, ⚑ goal, ★ complete, ⊘
# rejected, · separator. Any other locale (first non-empty of LC_ALL, LC_CTYPE, LANG) gives ASCII only (# - ~ ! o > *
# / and "..."; titles and Swedish letters are transliterated or become ?).
#
# SIBLING FILES, first match wins
#   env JENGA_BOARD_PROGRESS / JENGA_PROGRESS_LABELS (test seam: a stub that prints a board-progress JSON fixture),
#   then <this dir>/../../../scripts/<name> and scripts/lib/progress-labels.sh, then node_modules/@jenga-ai/agent/scripts/.
#
# A PROBLEM NEVER FAILS j.status
#   Empty board, missing board-progress.sh or labels, board-progress.sh failing, malformed JSON, jq missing: ONE stderr
#   warning, nothing on stdout, exit 0. Only a usage error (unknown or valueless argument) exits 2. Read-only.
#
# EXIT CODES: 0 overview printed, --all deferred, or a problem warned about; 2 usage error.
# Requires: bash 3.2+, jq.
# ---------------------------------------------------------------------------
set -u

SR_NAME="render-status-overview.sh"
SR_WHAT="status overview"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '/^# USAGE/,/^# Glyphs:/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
usage_err() { printf '%s: %s\n' "$SR_NAME" "$1" >&2; exit 2; }

cols=""; color="auto"; root=""; all=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --all)     all=1; shift ;;
    --cols)    [ "$#" -ge 2 ] || usage_err "--cols needs a value"; cols="$2"; shift 2 ;;
    --cols=*)  cols="${1#--cols=}"; shift ;;
    --color)   [ "$#" -ge 2 ] || usage_err "--color needs a value"; color="$2"; shift 2 ;;
    --color=*) color="${1#--color=}"; shift ;;
    --root)    [ "$#" -ge 2 ] || usage_err "--root needs a value"; root="$2"; shift 2 ;;
    --root=*)  root="${1#--root=}"; shift ;;
    *) usage_err "unknown argument: $1 (see --help)" ;;
  esac
done
case "$color" in auto|always|never) ;; *) usage_err "--color must be auto, always or never" ;; esac
if [ -n "$cols" ]; then
  case "$cols" in *[!0-9]*) usage_err "--cols needs a positive integer" ;; esac
  [ "$cols" -ge 1 ] || usage_err "--cols needs a positive integer"
fi

# --all: the full list is the wiring's job (E92_S06_T26); print nothing and defer.
[ "$all" -eq 0 ] || exit 0

COMMON="$SCRIPT_DIR/lib/status-render-common.sh"
if [ ! -f "$COMMON" ]; then
  printf '%s: warning: %s (%s skipped)\n' "$SR_NAME" "lib/status-render-common.sh not found" "$SR_WHAT" >&2
  exit 0
fi
# shellcheck source=lib/status-render-common.sh
. "$COMMON"

BOARD_PROGRESS="$(sr_find_file "${JENGA_BOARD_PROGRESS:-}" board-progress.sh "$SCRIPT_DIR")"
LABELS="$(sr_find_file "${JENGA_PROGRESS_LABELS:-}" lib/progress-labels.sh "$SCRIPT_DIR")"
[ -n "$BOARD_PROGRESS" ] || sr_warn "board-progress.sh not found"
[ -n "$LABELS" ] || sr_warn "progress-labels.sh not found"
command -v jq >/dev/null 2>&1 || sr_warn "jq not found"

# shellcheck disable=SC1090
. "$LABELS" 2>/dev/null || sr_warn "progress-labels.sh could not be loaded"
lab() { progress_label "$1" 2>/dev/null || true; }
l_board="$(lab ov_board)";       l_epics="$(lab ov_epics)";       l_tasks="$(lab ov_tasks)"
l_pending="$(lab ov_pending)";   l_prog="$(lab in_progress)";     l_red="$(lab failed)"
l_rejnote="$(lab rejected_note)"
l_g_att="$(lab ov_group_attention)"; l_g_prog="$(lab ov_group_progress)"
l_g_start="$(lab ov_group_started)"; l_g_not="$(lab ov_group_notstarted)"
l_complete="$(lab ov_complete)"; l_hidden="$(lab ov_hidden)"; l_rejempty="$(lab ov_rejected_empty)"
l_f_scope="$(lab ov_footer_scope)"; l_f_all="$(lab ov_footer_all)"
for v in "$l_board" "$l_epics" "$l_tasks" "$l_pending" "$l_prog" "$l_red" "$l_rejnote" "$l_g_att" "$l_g_prog" \
         "$l_g_start" "$l_g_not" "$l_complete" "$l_hidden" "$l_rejempty" "$l_f_scope" "$l_f_all"; do
  [ -n "$v" ] || sr_warn "progress labels missing"
done

sr_detect_utf
sr_resolve_color "$color"
sr_resolve_cols "$cols"

bp_args=(--graph --counts-only)
[ -z "$root" ] || bp_args=("${bp_args[@]}" --root "$root")
json="$(bash "$BOARD_PROGRESS" "${bp_args[@]}" 2>/dev/null)" || sr_warn "board-progress.sh --graph --counts-only failed"
[ -n "$json" ] || sr_warn "board-progress.sh --graph printed nothing"

# shellcheck disable=SC2016  # jq program
PROGRAM='
def T: (.tasks.totals // {}) | {done: (.done // 0), in_progress: (.in_progress // 0), failed: (.failed // 0),
                                 pending: (.pending // 0), rejected: (.rejected // 0), denominator: (.denominator // 0)};
def idnum: [(.id | tostring | scan("[0-9]+") | tonumber)];
def pct_of($t): $t | pct;
def bar_of($t; $w): $t | bar($w);
def marker($t): if $t.failed > 0 then [g.fail + ($t.failed | tostring), "31"]
  elif $t.in_progress > 0 then [g.prog + ($t.in_progress | tostring), "33"]
  else ["", ""] end;
def rowline($e; $idw; $cntw; $pctw; $barw; $mkw):
  ($e.t) as $t
  | marker($t) as $mk
  | ( [["  ", ""], [($e.id | txt | pad($idw)), "36"], [" ", ""]]
      + (if $cols >= 50 then bar_of($t; $barw) + [[" ", ""]] else [] end)
      + [[(($t.done | tostring) + "/" + ($t.denominator | tostring) | lpad($cntw)), ""], [" ", ""],
         [((pct_of($t) | tostring) + " %" | lpad($pctw)), ""]] ) as $base
  | ($cols - ($base | segs_len) - 2 - $mkw - 2) as $room
  | if $room >= 4 then
      $base + [["  ", ""], [($mk[0] | pad($mkw)), $mk[1]], ["  ", ""], [($e.title | txt | clip($room)), "2"]]
    elif $mk[0] != "" then $base + [["  ", ""], $mk]
    else $base end;
# wrap: pack parts (each a one-segment line) into lines no wider than $cols, two spaces between, indent two
def wrap:
  reduce .[] as $p ([[["  ", ""]]];
    (.[-1]) as $cur
    | if ($cur | length) == 1 then (.[-1] = $cur + $p)
      elif (($cur + [["  ", ""]] + $p) | segs_len) <= $cols then (.[-1] = $cur + [["  ", ""]] + $p)
      else . + [[["  ", ""]] + $p] end);
def group($name; $color; $list):
  if ($list | length) == 0 then empty
  else
    ([$list[] | .id | txt | length] | max) as $idw0
    | ([$list[] | ((.t.done | tostring) + "/" + (.t.denominator | tostring) | length)] | max) as $cntw
    | ([$list[] | ((.t | pct | tostring) + " %" | length)] | max) as $pctw
    | ([$list[] | (marker(.t)[0] | length)] | max) as $mkw
    | (if $cols >= 80 then 14 elif $cols >= 60 then 10 else 6 end) as $barw
    | ([[($name + " (" + ($list | length | tostring) + ")"), $color]] | emit),
      ($list[] | rowline(.; ([$idw0, 3] | max); $cntw; $pctw; $barw; $mkw) | emit),
      ""
  end;

. as $d
| [($d.epics // [])[] | . + {t: T}] as $epics
| if ($epics | length) == 0 then error("no epics") else . end
| ($epics | map(select(.t.denominator > 0 and .t.done == .t.denominator))) as $complete
| ($epics | map(select(.t.denominator == 0))) as $empty
| ($epics | map(select(.t.denominator > 0 and .t.done < .t.denominator))) as $open
| ($open | map(select(.t.failed > 0))) as $att
| ($open | map(select(.t.failed == 0 and .t.in_progress > 0))) as $prog
| ($open | map(select(.t.failed == 0 and .t.in_progress == 0 and .t.done > 0))) as $start
| ($open | map(select(.t.failed == 0 and .t.in_progress == 0 and .t.done == 0))) as $not
| (reduce $epics[] as $e ({done: 0, in_progress: 0, failed: 0, pending: 0, rejected: 0, denominator: 0};
     reduce ("done", "in_progress", "failed", "pending", "rejected", "denominator") as $k (.; .[$k] += $e.t[$k]))) as $tot
| def srt: sort_by([-(.t | pct)] + idnum);
  # 1. total
  ( ( $l_board + " " + g.sep + " " + ($epics | length | tostring) + " " + $l_epics + " " + g.sep + " "
      + ($tot.done | tostring) + "/" + ($tot.denominator | tostring) + " " + $l_tasks + " " + g.sep + " "
      + ($tot | pct | tostring) + " %" ) as $full
    | ( $l_board + " " + ($epics | length | tostring) + " " + g.sep + " "
      + ($tot.done | tostring) + "/" + ($tot.denominator | tostring) + " " + g.sep + " " + ($tot | pct | tostring) + " %" ) as $short
    | [[(if ($full | txt | length) <= $cols then $full else $short end), "1"]] | emit ),
  ( if $cols >= 50 and $tot.denominator > 0 then
      [["  ", ""]] + ($tot | bar([[$cols - 4, 40] | min, 10] | max)) + [[(if $tot.done == $tot.denominator then g.star else g.goal end), "2"]] | emit
    else empty end ),
  ( [ (if $tot.in_progress > 0 then [[g.prog + " " + ($tot.in_progress | tostring) + " " + $l_prog, "33"]] else empty end),
       (if $tot.failed > 0 then [[g.fail + " " + ($tot.failed | tostring) + " " + $l_red, "31"]] else empty end),
       (if $tot.pending > 0 then [[g.pend + " " + ($tot.pending | tostring) + " " + $l_pending, "90"]] else empty end),
       (if $tot.rejected > 0 then [[($l_rejnote | gsub("⊘"; g.rej) | sub("%d"; ($tot.rejected | tostring))), "2"]] else empty end) ]
    | wrap | .[] | emit ),
  "",
  # 2. open epics
  ( group($l_g_att; "1;31"; $att | srt),
    group($l_g_prog; "1;33"; $prog | srt),
    group($l_g_start; "1;33"; $start | srt),
    group($l_g_not; "1;90"; $not | srt) ),
  # 3. collapsed
  ( if ($complete | length) > 0 then
      [[g.star + " " + $l_complete + " (" + ($complete | length | tostring) + ")", "1;32"],
       ["  " + ($complete | map(.t.done) | add | tostring) + " " + $l_tasks + " " + g.sep + " " + $l_hidden, "2"]] | emit
    else empty end ),
  ( if ($empty | length) > 0 then
      [[g.rej + " " + $l_rejempty + " (" + ($empty | length | tostring) + "): " + ($empty | map(.id | txt) | join(", ")), "90"]] | emit
    else empty end ),
  "",
  # 4. footer
  ( ( [[$l_f_scope + "  " + g.sep + "  " + $l_f_all, "2"]] ) as $one
    | if ($one | map([(.[0] | txt), .[1]]) | segs_len) <= $cols then ($one | emit)
      else ([[$l_f_scope, "2"]] | emit), ([[$l_f_all, "2"]] | emit) end )
'

out="$(printf '%s\n' "$json" | sr_jq "$PROGRAM" \
  --arg l_board "$l_board" --arg l_epics "$l_epics" --arg l_tasks "$l_tasks" --arg l_pending "$l_pending" \
  --arg l_prog "$l_prog" --arg l_red "$l_red" --arg l_rejnote "$l_rejnote" --arg l_g_att "$l_g_att" \
  --arg l_g_prog "$l_g_prog" --arg l_g_start "$l_g_start" --arg l_g_not "$l_g_not" --arg l_complete "$l_complete" \
  --arg l_hidden "$l_hidden" --arg l_rejempty "$l_rejempty" --arg l_f_scope "$l_f_scope" --arg l_f_all "$l_f_all" \
  2>/dev/null)" || sr_warn "board-progress.sh output could not be rendered (empty board or malformed JSON)"
[ -n "$out" ] || sr_warn "nothing to render"
printf '%s\n' "$out"
exit 0
