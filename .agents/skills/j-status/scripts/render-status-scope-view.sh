#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-status/scripts/render-status-scope-view.sh - the new `j.status <epic|story>` view (E92_S06_T25)
#
# For one epic or one story prints:
#   1. a header block: title and percent; for an epic a milestone track with one stop per story ending in the goal,
#      with a label under each stop; a one-line message ("Almost there - 2 stories left") and "Ready to take: ...";
#   2. complete stories hidden behind ONE line ("N complete stories hidden, --all shows them"); with --all they are
#      listed like the others;
#   3. for each remaining story: a symbol, id, truncated title, its own mini bar and done/total; then one row per task:
#      state symbol, short id (T01), the state in words, the title and a dependency column ("after T01 ✓" in green when
#      the dependency is done, "waits for T02" in grey when not; a dependency in another story uses the full id);
#   4. "Ready to take (N)" and "Unlocks after" - the latter lists ONLY locked tasks and what each waits for.
#
# This script does no counting and no readiness or dependency logic. It reads the board ONCE with
# `scripts/board-progress.sh --graph --within <id>` and only lays out what that JSON states (state, ready, blocked_by,
# depends_on, complete, stop, totals). Whether a dependency is done is looked up in the same JSON (task state, story
# complete, external bucket). Every word comes from scripts/lib/progress-labels.sh (JENGA_PROGRESS_LANG=sv for Swedish).
# Layout helpers (glyph sets, width, colour, truncation, bar drawing) are in lib/status-render-common.sh. It replaces
# render-status-scope.sh (the indented text tree), which stays untouched for `--legacy` (E92_S06_T26 does the wiring).
#
# USAGE
#   render-status-scope-view.sh <id> [--all] [--cols N] [--color auto|always|never] [--root <dir>]
#   render-status-scope-view.sh -h | --help       print this usage on stdout, exit 0
#
#   <id>     one epic or one story id, any width (E3_S5 equals E03_S05). A task id, a missing or a malformed id is a
#            usage error (exit 2). A story id renders that story's block without the milestone track.
#   --all    list the complete stories too (default: they are hidden behind one line).
#   --cols   terminal width (default: COLUMNS, else `stty size` on a TTY, else 80). Under 50 the view degrades to a flat
#            list, one node per line (no track, no dependency column). No line is ever wider than the width: a longer
#            line is cut and ends in the "more" glyph.
#   --color  auto (default: colour only when stdout is a TTY and NO_COLOR is empty), always, never.
#   --root   project root, forwarded to board-progress.sh.
#
# Glyphs: UTF-8 locale: ● done, ◉ in progress, ✕ failed, ○ pending or locked, + ready, ⊘ rejected, ⚑ goal, ★ complete,
# ━ and ╌ bar and track cells, ▸ track start, ✓ tick. Any other locale (first non-empty of LC_ALL, LC_CTYPE, LANG) gives
# ASCII only (x ~ ! o + / > * # - and "ok" for the tick; Swedish letters are transliterated or become ?).
#
# SIBLING FILES, first match wins
#   env JENGA_BOARD_PROGRESS / JENGA_PROGRESS_LABELS (test seam: a stub that prints a --graph --within JSON fixture),
#   then <package root>/scripts/<name> and scripts/lib/progress-labels.sh (the package root comes from
#   skills/index/scripts/package-root.sh, see lib/status-render-common.sh), then ./scripts/ and ./node_modules/@jenga-ai/agent/scripts/.
#
# A PROBLEM NEVER FAILS j.status
#   Missing script or labels, board-progress.sh failing (unknown id included), malformed JSON, jq missing: ONE stderr
#   warning, nothing on stdout, exit 0. Only a usage error exits 2. Read-only; writes nothing.
#
# EXIT CODES: 0 view printed or problem warned about; 2 usage error.
# Requires: bash 3.2+, jq.
# ---------------------------------------------------------------------------
set -u

SR_NAME="render-status-scope-view.sh"
SR_WHAT="status scope view"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '/^# USAGE/,/^# Glyphs:/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
usage_err() { printf '%s: %s\n' "$SR_NAME" "$1" >&2; exit 2; }

id=""; cols=""; color="auto"; root=""; all=0
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
    -*) usage_err "unknown argument: $1 (see --help)" ;;
    *)  [ -z "$id" ] || usage_err "only one id is allowed (got '$id' and '$1')"; id="$1"; shift ;;
  esac
done

[ -n "$id" ] || usage_err "an epic or story id is required (see --help)"
case "$id" in
  [Ee][0-9]*_[Ss][0-9]*_[Tt][0-9]*) usage_err "'$id' is a task id; give an epic or a story id" ;;
esac
# builtins only (no grep or tr), so that a missing jq is still reported as a warning with exit 0
[[ "$id" =~ ^[Ee][0-9]+(_[Ss][0-9]+)?$ ]] || usage_err "malformed id '$id' (expected E<digits> or E<digits>_S<digits>)"
case "$color" in auto|always|never) ;; *) usage_err "--color must be auto, always or never" ;; esac
if [ -n "$cols" ]; then
  case "$cols" in *[!0-9]*) usage_err "--cols needs a positive integer" ;; esac
  [ "$cols" -ge 1 ] || usage_err "--cols needs a positive integer"
fi
if [[ "$id" == *_* ]]; then pre="${id%%_*}"; id="E${pre#?}_S${id#*_?}"; else id="E${id#?}"; fi

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

# Every label the layout uses, bound in jq as $l_<key>. A missing label is a progress problem (warn once, exit 0).
LABEL_KEYS="goal ready_to_take nothing_ready nothing in_progress unknown state_done state_ready state_locked state_failed state_rejected sc_hidden sc_hidden_one sc_msg_done sc_msg_last sc_msg_almost sc_msg_half sc_msg_going sc_msg_start sc_after sc_waits sc_unlocks_after sc_no_stories"
label_args=()
for k in $LABEL_KEYS; do
  v="$(progress_label "$k" 2>/dev/null)" || v=""
  [ -n "$v" ] || sr_warn "progress labels missing"
  label_args+=(--arg "l_$k" "$v")
done
# E92_S09_T04: the "decomposed/stories" note beside an epic's percent; optional (an empty label drops the note).
label_args+=(--arg l_epic_decomposed "$(progress_label epic_decomposed 2>/dev/null || true)")
# E92_S10_T02: the goal line that names a failed story (goal_failed / goal_failed_more); optional (empty: no line).
label_args+=(--arg l_goal_failed "$(progress_label goal_failed 2>/dev/null || true)")
label_args+=(--arg l_goal_failed_more "$(progress_label goal_failed_more 2>/dev/null || true)")

sr_detect_utf
sr_resolve_color "$color"
sr_resolve_cols "$cols"

bp_args=(--graph --within "$id")
[ -z "$root" ] || bp_args=("${bp_args[@]}" --root "$root")
json="$(bash "$BOARD_PROGRESS" "${bp_args[@]}" 2>/dev/null)" || sr_warn "board-progress.sh --graph --within $id failed"
[ -n "$json" ] || sr_warn "board-progress.sh --graph printed nothing"

# shellcheck disable=SC2016  # jq program
PROGRAM='
def short($sid): if startswith($sid + "_") then .[($sid | length) + 1:] else . end;
def tshort($t): ($t.story_id // "") as $sid | ($t.id | txt) | short($sid);
def storyno: (tostring | capture("_(?<n>S[0-9]+)$").n) // tostring;
def lab1($key; $n): $key | sub("%d"; ($n | tostring));
def word($s): ({done: $l_state_done, ready: $l_state_ready, locked: $l_state_locked, failed: $l_state_failed,
                rejected: $l_state_rejected, in_progress: $l_in_progress}[$s] // $l_unknown) | ascii_downcase;
def symof($s): {done: [g.done, "32"], in_progress: [g.prog, "33"], failed: [g.fail, "31"], ready: [g.ready, "35"],
                locked: [g.pend, "90"], rejected: [g.rej, "2"]}[$s] // [g.pend, "90"];
def stopsym($s): if (($s.totals.denominator // 0) == 0) then [g.rej, "2"]
  else ({done: [g.done, "32"], in_progress: [g.prog, "33"], failed: [g.fail, "31"]}[$s.stop] // [g.pend, "90"]) end;
def iscomp: (.complete == true) and ((.totals.denominator // 0) > 0);

. as $d
| ($d.tasks // []) as $tasks
| ($d.stories // []) as $stories
| ($d.external // []) as $ext
| ($d.ready // []) as $ready
| (($d.scope.within // $id) | txt) as $scope
| ($scope | test("_S[0-9]+$")) as $is_story
# a dependency is done when the JSON says so (task state, story complete, external bucket); an id the JSON does not
# list falls back to blocked_by (only unsatisfied ids are in it)
| (reduce (($tasks[] | {k: .id, v: (.state == "done")}), ($stories[] | {k: .id, v: (.complete == true)}),
           ($ext[] | {k: .id, v: (.bucket == "done")})) as $e ({}; .[$e.k] = $e.v)) as $known
| def depdone($t; $x): if ($known | has($x)) then $known[$x] else ((($t.blocked_by // []) | index($x)) == null) end;
  def deptext($t):
    ($t.depends_on // []) as $ds
    | if ($ds | length) == 0 then null
      else ([$ds[] | depdone($t; .)] | all) as $open
        | [ (($open | if . then $l_sc_after else $l_sc_waits end) + " "
             + ([$ds[] | . as $x | (($x | txt | short($t.story_id)) + (if depdone($t; $x) then " " + g.check else "" end))] | join(", "))),
            (if $open then "32" else "90" end) ]
      end;
  ( if $is_story and ($stories | length) > 0 then $stories[0].totals
    elif (($d.epics // []) | length) > 0 then $d.epics[0].tasks.totals
    else (reduce $stories[] as $s ({done: 0, denominator: 0}; .done += ($s.totals.done // 0) | .denominator += ($s.totals.denominator // 0))) end
  ) as $T
| (if $is_story then ($stories[0].title // $scope) else (($d.epics // [])[0].title // $scope) end | txt) as $title
| (($d.epics // [])[0].epic_progress // {}) as $ep
# an epic shows the epic percent the script states (epic_progress, E92_S09_T04), never recomputed; a story its task percent
| (if $is_story then ($T | pct) else ([($ep.percent // 0), 100] | min) end) as $p
| ($stories | map(select(iscomp))) as $hidden
| (if $all == 1 then $stories else ($stories | map(select(iscomp | not))) end) as $shown
| (if $is_story then ($stories | map(select(((.totals.denominator // 0) > 0) and (.complete != true))) | length)
   else ([(($ep.stories // 0) - ($stories | map(select(.complete == true)) | length)), 0] | max) end) as $left
| (if $is_story then (($stories | length) > 0 and $left == 0 and (($T.denominator // 0) > 0))
   else ($ep.goal_reached == true) end) as $allcomplete
# E92_S10_T02: the script states the failed stories and caps the percent at 99 while there is one; at that cap the
# message names the first failed story (and how many more) where the done message would have been
| ([($ep.failed_stories // [])[] | select(type == "string" and . != "")]) as $failed
| (if ($is_story | not) and ($allcomplete | not) and ($failed | length) > 0 and $p >= 99 then
     (if ($failed | length) == 1 then $l_goal_failed else $l_goal_failed_more end)
     | if . == "" then null else (sub("%s"; $failed[0]) | sub("%d"; (($failed | length) - 1 | tostring))) end
   else null end) as $failedmsg
| ($shown | map(.id)) as $shown_ids
| ($tasks | map(select(.story_id as $sid | $shown_ids | index($sid) != null))) as $shown_tasks
| (([$shown_tasks[] | tshort(.) | length] | max // 3) | [., 3] | max) as $idw
| (([$shown_tasks[] | word(.state) | txt | length] | max // 0)) as $wordw
| (8 + $idw + $wordw) as $ll
| (([$shown_tasks[] | deptext(.) | select(. != null) | .[0] | txt | length] | max // 0)) as $depw0
| ([$depw0, 34, ((($cols - $ll - 2) * 45 / 100) | floor), ($cols - $ll - 2 - 16)] | min) as $depw1
| (if $depw1 < ([$depw0, 12] | min) or $depw1 < 1 then 0 else $depw1 end) as $depw
| def trow($t):
    ($t.state) as $s
    | symof($s) as $y
    | ([["    ", ""], [$y[0], $y[1]], [" ", ""], [(tshort($t) | pad($idw)), "36"], [" ", ""],
        [(word($s) | txt | pad($wordw)), $y[1]], [" ", ""]]) as $left
    | deptext($t) as $dep
    | ($t.title | txt) as $tt
    | (if ($s == "done" or $s == "locked") then "2" else "" end) as $tc
    | if $dep != null and $depw > 0 then
        ($cols - $ll - $depw - 2) as $tw
        | $left + [[($tt | clip($tw) | pad($tw)), $tc], ["  ", ""], [($dep[0] | txt | clip($depw)), $dep[1]]]
      else $left + [[($tt | clip([$cols - $ll, 0] | max)), $tc]] end;
  def srow($s):
    ($s.totals) as $t
    | stopsym($s) as $y
    | ($s.id | txt) as $sid
    | ([[$y[0], $y[1]], [" ", ""], [$sid, "1;36"], ["  ", ""]]) as $pre
    | ($s.title | txt) as $tt
    | if ($t.denominator // 0) > 0 then
        ([[" ", ""]] + ($t | bar(8)) + [[(" " + ($t.done | tostring) + "/" + ($t.denominator | tostring) | lpad(6)), ""]]) as $right
        | ($cols - ($pre | segs_len) - ($right | segs_len)) as $lw
        | if $lw >= 6 then $pre + [[($tt | clip($lw) | pad($lw)), "1"]] + $right
          else $pre + [[($tt | clip([$cols - ($pre | segs_len), 0] | max)), "1"]] end
      else
        ([["  ", ""], [$l_nothing, "2"]]) as $right
        | ($cols - ($pre | segs_len) - ($right | segs_len)) as $lw
        | if $lw >= 6 then $pre + [[($tt | clip($lw) | pad($lw)), "2"]] + $right
          else $pre + [[($tt | clip([$cols - ($pre | segs_len), 0] | max)), "2"]] end
      end;
  def flatstory($s): (stopsym($s)) as $y
    | [[$y[0], $y[1]], [" ", ""], [($s.id | txt), "1;36"], [" ", ""], [($s.title | txt), "1"]];
  def flattask($t): (symof($t.state)) as $y
    | [["  ", ""], [$y[0], $y[1]], [" ", ""], [tshort($t), "36"], [" ", ""], [(word($t.state) | txt), $y[1]]];
  # the milestone track: a start glyph, per story a segment ending in its stop, then the goal; labels under the stops
  def track:
    ($stories | length) as $n
    | ([$cols, 64] | min) as $width
    | ([[((((($width - 4) / ([$n, 1] | max)) | floor) - 1)), 10] | min, 1] | max) as $w
    | (4 + $n * ($w + 1)) as $tlen
    | if $n == 0 or $cols < 50 or $tlen > $cols then empty
      else
        $allcomplete as $alldone
        | ( [[g.start, "35"]]
            + ([ $stories[] | . as $s | ($s.totals) as $t
                 | (if ($t.denominator // 0) > 0 then (($t.done * $w / $t.denominator) | round) else 0 end) as $fill
                 | stopsym($s) as $y
                 | [[rep(g.fill; $fill), "32"], [rep(g.empty; $w - $fill), "90"], [$y[0], $y[1]]] ] | add | map(select(.[0] != "")))
            + [[rep((if $alldone then g.fill else g.empty end); 2), (if $alldone then "32" else "90" end)],
               [(if $alldone then g.star else g.goal end), (if $alldone then "1;32" else "1" end)]] ) as $tr
        | ( if $w + 1 >= 4 then
              (reduce range(0; $n) as $k (""; pad([length, (($k + 1) * ($w + 1) - 1)] | max) + ($stories[$k].id | storyno)))
            else
              (($stories[0].id | storyno) + " " + g.more + " " + ($stories[-1].id | storyno))
            end ) as $row
        | ($row | pad([length + 1, (1 + $n * ($w + 1) + 2 - 1)] | max) + ($l_goal | txt)) as $lbl
        | ($tr | emit), ([[$lbl, "35"]] | emit)
      end;
  def message:
    if $is_story then (if $allcomplete then $l_sc_msg_done else null end)
    elif ($stories | length) == 0 then null
    elif $allcomplete then $l_sc_msg_done
    elif $failedmsg != null then $failedmsg
    elif $left == 1 then $l_sc_msg_last
    elif $p >= 80 then lab1($l_sc_msg_almost; $left)
    elif $p >= 50 then lab1($l_sc_msg_half; $left)
    elif $p > 0 then lab1($l_sc_msg_going; $left)
    else $l_sc_msg_start end;
  def readynext:
    if ($ready | length) == 0 then null
    else ($l_ready_to_take + ": " + ($ready[:2] | map(txt) | join(", ")) + (if ($ready | length) > 2 then " (+" + (($ready | length) - 2 | tostring) + ")" else "" end)) end;
  # 1. header
  ( ($id | txt) as $hid
    | (if ($is_story | not) and (($ep.decomposed // 0) < ($ep.stories // 0)) and $l_epic_decomposed != "" then
         ($l_epic_decomposed | sub("%d"; (($ep.decomposed // 0) | tostring)) | sub("%d"; (($ep.stories // 0) | tostring))) + " " + g.sep + " "
       else "" end) as $note
    | $note + ($p | tostring) + " %" as $pc
    | ([$cols, 64] | min) as $width
    | ($scope + " " + g.sep + " " + $title | clip([$cols - ($pc | length) - 2, 1] | max)) as $head
    | [[$head, "1"], [rep(" "; [2, $width - ($head | length) - ($pc | length)] | max), ""], [$pc, "1"]] | emit ),
  ( if $is_story then empty else track end ),
  ( [ (message as $m | if $m != null then [$m, (if $allcomplete then "32" elif $m == $failedmsg then "31" else "33" end)] else empty end),
      (readynext as $r | if $r != null then [$r, "35"] else empty end) ] as $parts
    | if ($parts | length) == 0 then empty
      else ($parts | to_entries | map((if .key > 0 then [["  " + g.next + "  ", "90"]] else [] end) + [.value]) | add) | emit end ),
  "",
  # 2. hidden complete stories
  ( if ($hidden | length) > 0 and $all == 0 then
      ([[g.done + " " + (if ($hidden | length) == 1 then lab1($l_sc_hidden_one; 1) else lab1($l_sc_hidden; ($hidden | length)) end), "32"],
        [" (" + ($hidden[:6] | map(.id | storyno) | join(", ")) + (if ($hidden | length) > 6 then ", " + g.more else "" end) + ")", "90"]] | emit)
    else empty end ),
  # 3. the remaining stories with their tasks
  ( if ($stories | length) == 0 then ([["  " + $l_sc_no_stories, "2"]] | emit)
    else
      ( $shown[] as $s
        | (if $cols < 50 then flatstory($s) else srow($s) end | emit),
          ( $tasks[] | select(.story_id == $s.id) | (if $cols < 50 then flattask(.) else trow(.) end | emit) ) )
    end ),
  "",
  # 4. ready to take, unlocks after
  ( [[$l_ready_to_take + " (" + ($ready | length | tostring) + ")", "1"]] | emit ),
  ( if ($ready | length) == 0 then ([["  " + $l_nothing_ready, "2"]] | emit)
    else ( $ready[] as $r
           | ([$tasks[] | select(.id == $r) | .title] | .[0] // "") as $rt
           | ([["  ", ""], [g.ready, "35"], [" ", ""], [($r | txt), "36"]]) as $base
           | (if $cols < 50 then $base
              else ($cols - ($base | segs_len) - 2) as $room
                | if $room >= 4 then $base + [["  ", ""], [($rt | txt | clip($room)), "2"]] else $base end end) | emit ) end ),
  ( ($tasks | map(select(.state == "locked"))) as $lk
    | if ($lk | length) == 0 then empty
      else "",
           ([[$l_sc_unlocks_after, "1"]] | emit),
           ( $lk[] as $t
             | (if ($t.blocked_by // []) | length > 0 then $t.blocked_by else ($t.depends_on // []) end) as $w
             | [["  ", ""], [($t.id | txt), "36"], [" " + g.back + " ", "90"], [($w | map(txt) | join(", ")), ""]] | emit )
      end )
'

out="$(printf '%s\n' "$json" | sr_jq "$PROGRAM" --arg id "$id" --argjson all "$all" "${label_args[@]}" 2>/dev/null)" \
  || sr_warn "board-progress.sh output could not be rendered (malformed JSON)"
[ -n "$out" ] || sr_warn "nothing to render"
printf '%s\n' "$out"
exit 0
