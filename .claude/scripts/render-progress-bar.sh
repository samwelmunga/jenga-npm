#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/render-progress-bar.sh - render one terminal progress line from board-progress JSON (E92_S02_T02, E92_S02_T03)
#
# Reads ONE JSON document in the E92_S01 contract (project/documentation/progress-visualisation.md, section 3) and
# prints ONE line on stdout, for example (language sv, 10 cells):
#
#   [████████░░] 8/10 · 1 pågår · 1 röd · ⊘ 2 avvisade (ej räknade)
#
# The renderer does no counting. It picks one levels.<level>.totals block and only allocates bar cells. It holds no
# status names: statuses were already bucketed by scripts/board-progress.sh. It reads nothing but its input and the
# label library and writes nothing.
#
# USAGE
#   render-progress-bar.sh [--level tasks|stories|epics] [--cells N] [--cols N] [--color auto|always|never] [--file <path>]
#   render-progress-bar.sh --each epics|stories|array [--cells N] [--cols N] [--color auto|always|never] [--file <path>]
#   ... | render-progress-bar.sh [options]
#   render-progress-bar.sh -h | --help       print this usage on stdout, exit 0
#
#   --level   which levels.<level>.totals block to render. Default: tasks, and when the caller did not name a level
#             and tasks is absent, the first present of tasks, stories, epics. A level that was named with --level
#             and is absent is an error.
#   --cells   maximum bar width in cells, 1..500, default 10. The bar shrinks below this to fit the terminal width.
#   --cols    terminal width in columns, 1..10000. Overrides COLUMNS and the terminal; see WIDTH below.
#   --color   auto (default), always, never. Colour is OFF when NO_COLOR is set and non-empty, when stdout is not a
#             TTY, or with --color never; --color always forces it, even over NO_COLOR.
#   --each    batch mode (see BATCH MODE): render one line per array element instead of one line for a levels block.
#   --file    read the JSON from this path instead of stdin. Without --file and with a terminal on stdin the script
#             refuses to wait for input and exits 2.
#
# LINE FORMAT
#   [bar] <done>/<denominator>[ · <n> <in progress label>][ · <n> <failed label>][ · <n> <unknown label>][ · <rejected note>]
#   Each optional segment appears only when its number is greater than 0. The text carries every number, so the line
#   is complete without colour. Denominator 0 prints an all-grey bar and "0/0 · <nothing label>"; there is no division
#   by zero. Labels come from scripts/lib/progress-labels.sh (default language en; JENGA_PROGRESS_LANG=sv for Swedish).
#
# BAR
#   Cells are drawn in order: done as a filled cell (green), then in_progress (yellow), failed (red) and pending (grey),
#   each of those three as an empty cell (the example line above shows 8 filled and 2 empty cells for 8 done, 1 in
#   progress and 1 failed). Cell counts use largest-remainder rounding over done, in_progress, failed and pending ONLY, so the cells always sum
#   to the bar width and the rejected bucket is never drawn as filled or as remaining. A non-zero bucket never rounds to zero
#   cells while another bucket has more than one, and the bar is full (every cell filled) only when pending,
#   in_progress and failed are all zero, also at one cell.
#
# COLOUR
#   ANSI 32 green, 33 yellow, 31 red, 90 grey, each run closed with ESC[0m. Without colour only done is distinguishable
#   from the rest in the bar (filled versus empty cell); the text carries the in_progress and failed numbers.
#
# GLYPH FALLBACK
#   When the locale is not UTF-8 (the first non-empty of LC_ALL, LC_CTYPE, LANG does not name UTF-8, or all are empty)
#   the output uses '#' (filled) and '-' (empty) for cells, '(x)' for the rejected symbol and '-' for the separator '·'.
#
# WIDTH (E92_S02_T03)
#   The width W is taken from the first of: --cols N; the COLUMNS environment variable (when a positive integer, else
#   ignored); `stty size` (its column count) when stdout is a TTY (when it prints a positive integer); otherwise 80. The visible width of
#   the line never exceeds W. Visible width counts every glyph as ONE cell (including the ASCII fallback '(x)', which is
#   three cells) and counts characters, not bytes, whatever the locale; ANSI colour escapes are not counted. The output
#   is always exactly one line.
#
#   MIN_BAR_CELLS=4
#   (the same constant is defined as a variable below; tests read it from here)
#
#   Rules, applied in this order:
#     1. The bar is at most --cells (default 10) cells and shrinks so that "[bar] text" fits in W. A --cells value that
#        is itself below MIN_BAR_CELLS and already fits is kept; the minimum only governs shrinking.
#     2. If the room left for the bar is below MIN_BAR_CELLS, the bar and its brackets are dropped and the text-only line
#        is printed, for example "8/10 · 1 pågår · 1 röd".
#     3. If even the text-only line is wider than W, segments are dropped from the lowest priority upward, in this order:
#        unknown, then the rejected note, then in_progress. done/denominator and failed are never dropped.
#     4. If done/denominator plus failed still does not fit, the text is hard-truncated to W-1 characters (a dangling
#        separator is trimmed) and a single "…" is appended ("~" in the non-UTF-8 ASCII fallback).
#
# BATCH MODE (E92_S05_T03)
#   --each <key> renders MANY bars in one process and one jq call, with no fork per line (starting the script once per
#   bar would re-pay the start-up cost every time).
#   The input is a JSON array of {"id": "<id>", "totals": {done, in_progress, failed, pending, rejected, unknown,
#   denominator}} elements, or an object holding such an array under <key>: the `epics` or `stories` array of a
#   `board-progress.sh --by-parent` document (its extra `level` field per element is ignored). <key> is epics, stories or
#   array; with a top-level array as input the array itself is used whatever the key. Output is one line per element, in
#   input order: <id><TAB><rendered line>, where the rendered line is exactly what single mode prints for those totals
#   (one code path; width, colour, glyph fallback and label rules unchanged and applied per line, the width resolved once).
#   One jq call checks the whole input; an element that is not {id, totals} with non-negative integer totals, or an id with
#   a control character, exits 2 before anything is printed. An empty array prints nothing and exits 0. --level is not
#   allowed with --each (exit 2).
#
# EXIT CODES
#   0 success; 2 usage error, jq missing, or unreadable/invalid input (message on stderr, nothing on stdout).
#
# Requires: bash 3.2+, jq. Compatible with macOS bash 3.2.
# ---------------------------------------------------------------------------
set -u

# Minimum bar width in cells (documented in the header, WIDTH section). Below it the bar is dropped.
MIN_BAR_CELLS=4

_err() { printf 'render-progress-bar: %s\n' "$*" >&2; }
_die() { _err "$*"; exit 2; }

usage() {
  sed -n '/^# USAGE/,/^# LINE FORMAT/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

level=""
level_explicit=0
cells=10
cols=""
cols_set=0
color_mode="auto"
file=""
each=""
each_set=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --level)   [ "$#" -ge 2 ] || _die "--level needs a value"; level="$2"; level_explicit=1; shift 2 ;;
    --level=*) level="${1#--level=}"; level_explicit=1; shift ;;
    --cells)   [ "$#" -ge 2 ] || _die "--cells needs a value"; cells="$2"; shift 2 ;;
    --cells=*) cells="${1#--cells=}"; shift ;;
    --cols)    [ "$#" -ge 2 ] || _die "--cols needs a value"; cols="$2"; cols_set=1; shift 2 ;;
    --cols=*)  cols="${1#--cols=}"; cols_set=1; shift ;;
    --color)   [ "$#" -ge 2 ] || _die "--color needs a value"; color_mode="$2"; shift 2 ;;
    --color=*) color_mode="${1#--color=}"; shift ;;
    --each)    [ "$#" -ge 2 ] || _die "--each needs a value"; each="$2"; each_set=1; shift 2 ;;
    --each=*)  each="${1#--each=}"; each_set=1; shift ;;
    --file)    [ "$#" -ge 2 ] || _die "--file needs a value"; file="$2"; shift 2 ;;
    --file=*)  file="${1#--file=}"; shift ;;
    *) _die "unknown argument: $1 (see --help)" ;;
  esac
done

if [ "$each_set" -eq 1 ]; then
  case "$each" in epics|stories|array) ;; *) _die "--each must be epics, stories or array (got: $each)" ;; esac
  [ "$level_explicit" -eq 0 ] || _die "--level cannot be combined with --each"
fi
case "$color_mode" in auto|always|never) ;; *) _die "--color must be auto, always or never (got: $color_mode)" ;; esac
if [ "$level_explicit" -eq 1 ]; then
  case "$level" in tasks|stories|epics) ;; *) _die "--level must be tasks, stories or epics (got: $level)" ;; esac
fi
case "$cells" in
  ''|*[!0-9]*) _die "--cells must be a positive integer (got: $cells)" ;;
esac
cells=$((10#$cells))
{ [ "$cells" -ge 1 ] && [ "$cells" -le 500 ]; } || _die "--cells must be between 1 and 500 (got: $cells)"

if [ "$cols_set" -eq 1 ]; then
  case "$cols" in
    ''|*[!0-9]*) _die "--cols must be a positive integer (got: $cols)" ;;
  esac
  cols=$((10#$cols))
  { [ "$cols" -ge 1 ] && [ "$cols" -le 10000 ]; } || _die "--cols must be between 1 and 10000 (got: $cols)"
fi

command -v jq >/dev/null 2>&1 || _die "jq is required but was not found on PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || _die "cannot resolve the script directory"
LABELS="$SCRIPT_DIR/lib/progress-labels.sh"
[ -r "$LABELS" ] || _die "label library not found: $LABELS"
# shellcheck source=lib/progress-labels.sh
. "$LABELS"

# ---- input -----------------------------------------------------------------
if [ -n "$file" ]; then
  [ -r "$file" ] && [ -f "$file" ] || _die "cannot read input file: $file"
  doc="$(cat "$file")" || _die "cannot read input file: $file"
else
  if [ -t 0 ]; then _die "no input: pipe board-progress JSON on stdin or pass --file <path>"; fi
  doc="$(cat)" || _die "cannot read stdin"
fi

if [ -n "$each" ]; then
  # Batch mode: ONE jq call checks every element and emits one TSV row per element (id, then the seven totals). A malformed
  # element makes the whole run fail before anything is printed. Control characters are banned in ids so a tab or newline
  # can never forge a row; the \001 marker below can therefore not be an id.
  rows="$(printf '%s' "$doc" | jq -r --arg k "$each" '
    (if type == "array" then . elif type == "object" then .[$k] else null end) as $a
    | if ($a | type) != "array" then "\u0001input has no array to render (--each " + $k + ")"
      else
        [ $a | to_entries[] | .key as $i | .value as $v
          | if ($v | type) == "object" and ($v.id | type) == "string" and ($v.id | length) > 0
               and ($v.id | test("[[:cntrl:]]") | not) and ($v.totals | type) == "object"
               and ([$v.totals | .done, .in_progress, .failed, .pending, .rejected, .unknown, .denominator]
                    | all(type == "number" and . >= 0 and . == floor))
            then {ok: true, row: ([$v.id] + ([$v.totals | .done, .in_progress, .failed, .pending, .rejected, .unknown, .denominator] | map(tostring)) | join("\t"))}
            else {ok: false, i: $i} end ] as $r
        | if any($r[]; .ok | not)
          then "\u0001element " + (first($r[] | select(.ok | not) | .i) | tostring) + " is not {id, totals} with non-negative integer totals"
          else $r[] | .row end
      end' 2>/dev/null)" || _die "input is not valid JSON"
  case "$rows" in
    $'\001'*) _die "${rows#$'\001'}" ;;
  esac
else
  printf '%s' "$doc" | jq -e 'type == "object" and (.levels | type == "object")' >/dev/null 2>&1 \
    || _die "input is not a JSON object with a levels object (expected the board-progress contract)"

  if [ "$level_explicit" -eq 0 ]; then
    for _cand in tasks stories epics; do
      if printf '%s' "$doc" | jq -e --arg l "$_cand" '.levels | has($l)' >/dev/null 2>&1; then level="$_cand"; break; fi
    done
    [ -n "$level" ] || _die "input has no tasks, stories or epics level"
  fi

  nums="$(printf '%s' "$doc" | jq -r --arg l "$level" '
    if (.levels | has($l)) and (.levels[$l].totals | type == "object") then
      .levels[$l].totals
      | [.done, .in_progress, .failed, .pending, .rejected, .unknown, .denominator]
      | map(if type == "number" and . >= 0 and . == floor then (. | tostring) else "x" end)
      | join(" ")
    else "missing" end' 2>/dev/null)" || _die "input is not valid JSON"
  [ "$nums" != "missing" ] || _die "level '$level' (or its totals) is not present in the input"
  # shellcheck disable=SC2086
  set -- $nums
  [ "$#" -eq 7 ] || _die "totals of level '$level' are malformed"
  for _n in "$@"; do
    case "$_n" in ''|*[!0-9]*) _die "totals of level '$level' must be non-negative integers" ;; esac
  done
  n_done=$1; n_prog=$2; n_fail=$3; n_pend=$4; n_rej=$5; n_unk=$6; n_den=$7
fi

# ---- glyphs and colour -----------------------------------------------------
_loc="${LC_ALL:-}"
[ -n "$_loc" ] || _loc="${LC_CTYPE:-}"
[ -n "$_loc" ] || _loc="${LANG:-}"
case "$_loc" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) G_FULL='█'; G_EMPTY='░'; G_SEP='·'; G_REJ='⊘'; G_ELL='…' ;;
  *) G_FULL='#'; G_EMPTY='-'; G_SEP='-'; G_REJ='(x)'; G_ELL='~' ;;
esac

use_color=0
case "$color_mode" in
  always) use_color=1 ;;
  never)  use_color=0 ;;
  auto)   if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then use_color=1; fi ;;
esac
ESC=$'\033'

# ---- labels, resolved once (the batch mode renders hundreds of lines; nothing below forks per line) -------------------
lang="$(progress_lang)"
L_prog="$(progress_label in_progress "$lang")"
L_fail="$(progress_label failed "$lang")"
L_unk="$(progress_label unknown "$lang")"
L_nothing="$(progress_label nothing "$lang")"
L_rejfmt="$(progress_label rejected_note "$lang")"

# Width source: --cols, COLUMNS, stty size on a TTY, else 80. Resolved once, so every line of a batch uses the same width.
width=""
if [ "$cols_set" -eq 1 ]; then
  width=$cols
else
  case "${COLUMNS-}" in
    ''|*[!0-9]*) ;;
    *) if [ "${#COLUMNS}" -le 6 ] && [ "$((10#$COLUMNS))" -ge 1 ]; then width=$((10#$COLUMNS)); fi ;;
  esac
  if [ -z "$width" ] && [ -t 1 ] && command -v stty >/dev/null 2>&1; then
    # `stty size` prints "<rows> <cols>" for the terminal on its stdin. It is used instead of `tput cols` because tput
    # sizes from its STDOUT, which inside $(...) is a pipe, so it answered 80 whatever the terminal (E92_S05_T03). The
    # terminal is handed over explicitly: our own stderr when that is a terminal, otherwise /dev/tty. Without a usable
    # terminal the result is empty or not a number and the 80 default applies.
    _tc=""
    if [ -t 2 ]; then _tc="$(stty size <&2 2>/dev/null)" || _tc=""; fi
    if [ -z "$_tc" ]; then _tc="$({ stty size </dev/tty; } 2>/dev/null)" || _tc=""; fi
    _tc="${_tc##* }"
    case "$_tc" in
      ''|*[!0-9]*) ;;
      *) if [ "${#_tc}" -le 6 ] && [ "$((10#$_tc))" -ge 1 ]; then width=$((10#$_tc)); fi ;;
    esac
  fi
  [ -n "$width" ] || width=80
fi

# _vlen <string>: sets VLEN to the number of characters (every glyph one cell), independent of the locale and of the
# bash version: with LC_ALL=C the UTF-8 continuation bytes (0x80-0xBF) are removed and the rest counted.
_vlen() {
  local LC_ALL=C _s="$1" _t
  _t="${_s//[$'\200'-$'\277']/}"
  VLEN=${#_t}
}

# _trunc <string> <n>: sets TRUNC to the first n characters of the string (whole UTF-8 sequences, locale independent).
_trunc() {
  local LC_ALL=C _s="$1" _n="$2" _i=0 _c=0 _len _b
  _len=${#_s}
  while [ "$_i" -lt "$_len" ]; do
    _b="${_s:_i:1}"
    case "$_b" in
      [$'\200'-$'\277']) ;;
      *) _c=$((_c + 1)); if [ "$_c" -gt "$_n" ]; then break; fi ;;
    esac
    _i=$((_i + 1))
  done
  TRUNC="${_s:0:_i}"
}

_build_text() {
  TEXT="$seg_base"
  if [ "$keep_prog" -eq 1 ]; then TEXT="$TEXT$seg_prog"; fi
  TEXT="$TEXT$seg_fail"
  if [ "$keep_unk" -eq 1 ]; then TEXT="$TEXT$seg_unk"; fi
  if [ "$keep_rej" -eq 1 ]; then TEXT="$TEXT$seg_rej"; fi
}

_rep() { # <glyph> <count>: sets REP to the glyph repeated count times
  local i=0
  REP=""
  while [ "$i" -lt "$2" ]; do REP="$REP$1"; i=$((i + 1)); done
}
_seg() { # <ansi code> <glyph> <count>: appends one coloured (or plain) run of cells to BAR
  [ "$3" -gt 0 ] || return 0
  _rep "$2" "$3"
  if [ "$use_color" -eq 1 ]; then
    BAR="$BAR$ESC[$1m$REP$ESC[0m"
  else
    BAR="$BAR$REP"
  fi
}

# _render_line: renders the line for n_done n_prog n_fail n_pend n_rej n_unk n_den into LINE (no trailing newline).
# This is the only place a line is built, so single mode and --each mode cannot disagree.
_render_line() {
  local bar_cells=$cells _room _drop _p k j best bestr left donor dmax total sumf
  seg_prog=""; seg_fail=""; seg_unk=""; seg_rej=""
  if [ "$n_prog" -gt 0 ]; then seg_prog=" $G_SEP $n_prog $L_prog"; fi
  if [ "$n_fail" -gt 0 ]; then seg_fail=" $G_SEP $n_fail $L_fail"; fi
  if [ "$n_unk" -gt 0 ]; then seg_unk=" $G_SEP $n_unk $L_unk"; fi
  if [ "$n_rej" -gt 0 ]; then
    # shellcheck disable=SC2059  # the label is a printf format string by contract
    printf -v _note "$L_rejfmt" "$n_rej"
    _note="${_note//⊘/$G_REJ}"
    seg_rej=" $G_SEP $_note"
  fi
  seg_base="$n_done/$n_den"
  if [ "$n_den" -eq 0 ]; then
    seg_base="$seg_base $G_SEP $L_nothing"
  fi

  keep_prog=1; keep_unk=1; keep_rej=1
  show_bar=1
  _build_text; _vlen "$TEXT"; text_len=$VLEN
  # "[" + bar + "] " is cells + 3 visible cells.
  if [ $((bar_cells + 3 + text_len)) -gt "$width" ]; then
    _room=$((width - 3 - text_len))
    if [ "$_room" -ge "$MIN_BAR_CELLS" ]; then
      bar_cells=$_room
    else
      show_bar=0
    fi
  fi
  if [ "$show_bar" -eq 0 ]; then
    # Drop order, lowest priority first: unknown, rejected note, in_progress. done/denominator and failed stay.
    for _drop in unk rej prog; do
      [ "$text_len" -gt "$width" ] || break
      case "$_drop" in unk) keep_unk=0 ;; rej) keep_rej=0 ;; prog) keep_prog=0 ;; esac
      _build_text; _vlen "$TEXT"; text_len=$VLEN
    done
    if [ "$text_len" -gt "$width" ]; then
      _trunc "$TEXT" $((width - 1))
      TEXT="$TRUNC"
      while :; do # trim a dangling separator and spaces before the ellipsis
        case "$TEXT" in
          *" ") TEXT="${TEXT% }" ;;
          *" $G_SEP") TEXT="${TEXT% "$G_SEP"}" ;;
          *) break ;;
        esac
      done
      TEXT="$TEXT$G_ELL"
    fi
    LINE="$TEXT"
    return 0
  fi

  # ---- cell allocation (the only arithmetic) --------------------------------
  # Buckets in display order: 0 done, 1 in_progress, 2 failed, 3 pending.
  B=("$n_done" "$n_prog" "$n_fail" "$n_pend")
  C=(0 0 0 0)
  total=$((n_done + n_prog + n_fail + n_pend))
  if [ "$total" -eq 0 ]; then
    C[3]=$bar_cells
  else
    F=(0 0 0 0); R=(0 0 0 0); sumf=0
    for k in 0 1 2 3; do
      _p=$((B[k] * bar_cells))
      F[k]=$((_p / total)); R[k]=$((_p % total)); sumf=$((sumf + F[k]))
    done
    C=("${F[0]}" "${F[1]}" "${F[2]}" "${F[3]}")
    left=$((bar_cells - sumf))
    # Largest remainder; a tie goes to the bucket that understates progress (failed, in_progress, pending, then done).
    while [ "$left" -gt 0 ]; do
      best=-1; bestr=-1
      for k in 2 1 3 0; do
        if [ "${R[k]}" -gt "$bestr" ]; then best=$k; bestr=${R[k]}; fi
      done
      [ "$best" -ge 0 ] || break
      C[best]=$((C[best] + 1)); R[best]=-1; left=$((left - 1))
    done
    # A non-zero bucket never rounds to zero cells while another bucket has more than one.
    for k in 2 1 3 0; do
      if [ "${B[k]}" -gt 0 ] && [ "${C[k]}" -eq 0 ]; then
        donor=-1; dmax=1
        for j in 0 1 2 3; do
          if [ "${C[j]}" -gt "$dmax" ]; then donor=$j; dmax=${C[j]}; fi
        done
        if [ "$donor" -ge 0 ]; then C[donor]=$((C[donor] - 1)); C[k]=$((C[k] + 1)); fi
      fi
    done
    # Never a full bar while work is open (only reachable with one cell, where the minimum rule has no donor).
    if [ "${C[0]}" -eq "$bar_cells" ] && [ $((n_prog + n_fail + n_pend)) -gt 0 ]; then
      for k in 2 1 3; do
        if [ "${B[k]}" -gt 0 ]; then C[0]=$((C[0] - 1)); C[k]=$((C[k] + 1)); break; fi
      done
    fi
  fi

  BAR=""
  _seg 32 "$G_FULL" "${C[0]}"
  _seg 33 "$G_EMPTY" "${C[1]}"
  _seg 31 "$G_EMPTY" "${C[2]}"
  _seg 90 "$G_EMPTY" "${C[3]}"
  LINE="[$BAR] $TEXT"
}

if [ -n "$each" ]; then
  # One line per element: <id><TAB><rendered line>, in input order. An empty array prints nothing and exits 0.
  while IFS=$'\t' read -r _id n_done n_prog n_fail n_pend n_rej n_unk n_den; do
    [ -n "$_id" ] || continue
    _render_line
    printf '%s\t%s\n' "$_id" "$LINE"
  done <<< "$rows"
else
  _render_line
  printf '%s\n' "$LINE"
fi
