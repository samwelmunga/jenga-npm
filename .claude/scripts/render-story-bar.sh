#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/render-story-bar.sh - render the after-story progress line (epic E92, task E92_S06_T23)
#
# Reads ONE JSON document in the E92_S01 contract (scripts/board-progress.sh --story <id>) and prints the "story just
# finished" line of Proposal A in project/documentation/prototypes/E92_S06/bars-prototype.html:
#
#   E92_S01  ━━━━━━━━━━━━━━━━━━━━★ 4/4 · 100 %
#   E92_S03  ━━━━━━━━━━━━━━━━━━━━━━━━━━━╌╌╌★ 3/4 · 75 %  ✕ 1 failed
#
# i.e. scope id, two spaces, a bar, the goal symbol, ` done/denominator · percent %`, then optional counts.
#
# The renderer does no counting. It reads levels.tasks.totals, allocates cells and computes the percent for display. It
# holds no status names and no words: every word comes from scripts/lib/progress-labels.sh. It writes nothing but stdout.
#
# USAGE
#   render-story-bar.sh [--id <scope id>] [--ready N] [--cols N] [--color auto|always|never] [--file <path>]
#   ... | render-story-bar.sh [options]
#   render-story-bar.sh -h | --help       print this usage on stdout, exit 0
#
#   --id      the scope id to print. Default: scope.ids[0] of the input.
#   --ready   number of ready tasks to show as "+ N ready" (default 0 = not shown). The JSON has no such number, so the
#             caller supplies it; the after-story trigger never does (a finished story has no ready task).
#   --cols    terminal width in columns, 1..10000. Else COLUMNS (positive integer), else `stty size` on a TTY, else 80.
#   --color   auto (default), always, never. Colour is OFF when NO_COLOR is non-empty, when stdout is not a TTY, or with
#             --color never; --color always forces it.
#   --file    read the JSON from this path instead of stdin (stdin on a terminal exits 2).
#
# LAYOUT
#   * Bar width: clamp(width - everything else on the line, 8, 30) cells. Buckets in order: done (filled, green), in
#     progress (filled, yellow), failed (filled, red), pending (dashed, grey). Largest-remainder allocation; a non-zero
#     bucket never gets 0 cells while another has more than one; the bar is all green only when everything counted is done.
#   * Goal symbol: a star when the story is finished (denominator > 0, nothing pending, nothing in progress), green when
#     every task is done and RED when it contains failed tasks (the failed cells stay red, the bar is not fully green);
#     a flag otherwise (grey). Denominator 0 prints an all-dashed bar and a flag.
#   * Optional counts, in this order, each only when above 0: in progress, failed, ready, rejected. They stay on the line
#     when they fit; otherwise they WRAP to following lines, indented under the bar, and are never truncated.
#   * Under 40 columns, or when the bar form cannot fit the width, the output is text-only: `<id> done/den · pct %`.
#   * No line is ever wider than the width (every glyph counts as one cell, escapes are not counted).
#   * Not a UTF-8 locale (first non-empty of LC_ALL, LC_CTYPE, LANG does not name UTF-8): ASCII glyphs only.
#
# EXIT CODES
#   0 success; 2 usage error, jq missing, or unreadable/invalid input (message on stderr, nothing on stdout).
#
# Requires: bash 3.2+, jq.
# ---------------------------------------------------------------------------
set -u

MIN_BAR_CELLS=8
MAX_BAR_CELLS=30
TEXT_ONLY_BELOW=40

_err() { printf 'render-story-bar: %s\n' "$*" >&2; }
_die() { _err "$*"; exit 2; }

usage() { sed -n '/^# USAGE/,/^# LAYOUT/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

id=""; id_set=0; ready=0; cols=""; cols_set=0; color_mode="auto"; file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --id)      [ "$#" -ge 2 ] || _die "--id needs a value"; id="$2"; id_set=1; shift 2 ;;
    --id=*)    id="${1#--id=}"; id_set=1; shift ;;
    --ready)   [ "$#" -ge 2 ] || _die "--ready needs a value"; ready="$2"; shift 2 ;;
    --ready=*) ready="${1#--ready=}"; shift ;;
    --cols)    [ "$#" -ge 2 ] || _die "--cols needs a value"; cols="$2"; cols_set=1; shift 2 ;;
    --cols=*)  cols="${1#--cols=}"; cols_set=1; shift ;;
    --color)   [ "$#" -ge 2 ] || _die "--color needs a value"; color_mode="$2"; shift 2 ;;
    --color=*) color_mode="${1#--color=}"; shift ;;
    --file)    [ "$#" -ge 2 ] || _die "--file needs a value"; file="$2"; shift 2 ;;
    --file=*)  file="${1#--file=}"; shift ;;
    *) _die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$color_mode" in auto|always|never) ;; *) _die "--color must be auto, always or never (got: $color_mode)" ;; esac
case "$ready" in ''|*[!0-9]*) _die "--ready must be a non-negative integer (got: $ready)" ;; esac
ready=$((10#$ready))
if [ "$cols_set" -eq 1 ]; then
  case "$cols" in ''|*[!0-9]*) _die "--cols must be a positive integer (got: $cols)" ;; esac
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

row="$(printf '%s' "$doc" | jq -r '
  if (type == "object") and (.levels | type == "object") and (.levels.tasks.totals | type == "object") then
    .levels.tasks.totals as $t
    | [$t.done, $t.in_progress, $t.failed, $t.pending, $t.rejected, $t.unknown, $t.denominator, ((.scope.ids // [])[0] // "")]
    | map(if type == "number" and . >= 0 and . == floor then tostring elif type == "string" then . else "x" end)
    | join("\t")
  else "missing" end' 2>/dev/null)" || _die "input is not valid JSON"
[ "$row" != "missing" ] || _die "input has no levels.tasks.totals (expected the board-progress contract)"
# The id is the LAST field: an empty leading field would be collapsed by read, shifting every number.
IFS=$'\t' read -r n_done n_prog n_fail n_pend n_rej n_unk n_den j_id <<<"$row"
for _n in "$n_done" "$n_prog" "$n_fail" "$n_pend" "$n_rej" "$n_unk" "$n_den"; do
  case "$_n" in ''|*[!0-9]*) _die "totals must be non-negative integers" ;; esac
done
[ "$id_set" -eq 1 ] || id="$j_id"
[ -n "$id" ] || _die "no scope id: the input has no scope.ids[0] and --id was not given"
case "$id" in *[[:cntrl:]]*) _die "the scope id contains a control character" ;; esac

# ---- glyphs, colour, labels, width -------------------------------------------
_loc="${LC_ALL:-}"
[ -n "$_loc" ] || _loc="${LC_CTYPE:-}"
[ -n "$_loc" ] || _loc="${LANG:-}"
case "$_loc" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) G_FILL='━'; G_EMPTY='╌'; G_SEP='·'; G_REJ='⊘'; G_ELL='…'; G_FLAG='⚑'; G_STAR='★'; G_IP='◉'; G_FAIL='✕'; G_READY='+' ;;
  *) G_FILL='#'; G_EMPTY='-'; G_SEP='-'; G_REJ='/'; G_ELL='...'; G_FLAG='>'; G_STAR='*'; G_IP='~'; G_FAIL='!'; G_READY='+' ;;
esac

use_color=0
case "$color_mode" in
  always) use_color=1 ;;
  never)  use_color=0 ;;
  auto)   if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then use_color=1; fi ;;
esac
ESC=$'\033'

lang="$(progress_lang)"
L_ip="$(progress_label in_progress "$lang")"
L_fail1="$(progress_label sl_failed_one "$lang")"
L_failn="$(progress_label sl_failed_many "$lang")"
L_ready="$(progress_label sl_ready "$lang")"
L_rej="$(progress_label sl_rejected "$lang")"

width=""
if [ "$cols_set" -eq 1 ]; then
  width=$cols
else
  case "${COLUMNS-}" in
    ''|*[!0-9]*) ;;
    *) if [ "${#COLUMNS}" -le 6 ] && [ "$((10#$COLUMNS))" -ge 1 ]; then width=$((10#$COLUMNS)); fi ;;
  esac
  if [ -z "$width" ] && [ -t 1 ] && command -v stty >/dev/null 2>&1; then
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

# _vlen <string>: VLEN = characters (every glyph one cell), locale independent (UTF-8 continuation bytes are skipped).
_vlen() { local LC_ALL=C _s="$1" _t; _t="${_s//[$'\200'-$'\277']/}"; VLEN=${#_t}; }
# _trunc <string> <n>: TRUNC = the first n characters (whole UTF-8 sequences).
_trunc() {
  local LC_ALL=C _s="$1" _n="$2" _i=0 _c=0 _len _b
  _len=${#_s}
  while [ "$_i" -lt "$_len" ]; do
    _b="${_s:_i:1}"
    case "$_b" in [$'\200'-$'\277']) ;; *) _c=$((_c + 1)); if [ "$_c" -gt "$_n" ]; then break; fi ;; esac
    _i=$((_i + 1))
  done
  TRUNC="${_s:0:_i}"
}
# _paint <ansi code> <text>: PAINT = the text, wrapped in the colour when colour is on.
_paint() { if [ "$use_color" -eq 1 ] && [ -n "$1" ]; then PAINT="$ESC[$1m$2$ESC[0m"; else PAINT="$2"; fi; }
_vlen "$G_ELL"; ELL_LEN=$VLEN
_rep() { local i=0; REP=""; while [ "$i" -lt "$2" ]; do REP="$REP$1"; i=$((i + 1)); done; }

# ---- derived display values ---------------------------------------------------
pct=0
if [ "$n_den" -gt 0 ]; then pct=$(( (n_done * 100 + n_den / 2) / n_den )); fi
all=0; fin=0
if [ "$n_den" -gt 0 ] && [ "$n_done" -eq "$n_den" ]; then all=1; fi
if [ "$n_den" -gt 0 ] && [ "$n_pend" -eq 0 ] && [ "$n_prog" -eq 0 ]; then fin=1; fi

tail_plain=" $n_done/$n_den $G_SEP $pct %"   # the bar form; text-only drops the leading space
_vlen "$tail_plain"; tail_len=$VLEN

# Optional counts: parallel arrays of plain text and colour code, in display order.
X_TXT=(); X_COL=()
if [ "$n_prog" -gt 0 ]; then X_TXT+=("$G_IP $n_prog $L_ip"); X_COL+=(33); fi
if [ "$n_fail" -gt 0 ]; then
  _w="$L_failn"; [ "$n_fail" -eq 1 ] && _w="$L_fail1"
  X_TXT+=("$G_FAIL $n_fail $_w"); X_COL+=(31)
fi
if [ "$ready" -gt 0 ]; then X_TXT+=("$G_READY $ready $L_ready"); X_COL+=(90); fi
if [ "$n_rej" -gt 0 ]; then X_TXT+=("$G_REJ $n_rej $L_rej"); X_COL+=(2); fi
n_x=${#X_TXT[@]}
extras_len=0
k=0
while [ "$k" -lt "$n_x" ]; do
  _vlen "${X_TXT[$k]}"; extras_len=$((extras_len + VLEN))
  [ "$k" -eq 0 ] || extras_len=$((extras_len + 2))
  k=$((k + 1))
done

_vlen "$id"; id_len=$VLEN
head_len=$((id_len + 2))

text_only() {
  local plain="$id $n_done/$n_den $G_SEP $pct %" p
  _vlen "$plain"
  if [ "$VLEN" -gt "$width" ]; then
    _trunc "$plain" $((width - $ELL_LEN)); plain="$TRUNC$G_ELL"
    _vlen "$plain"; [ "$VLEN" -le "$width" ] || { _trunc "$plain" "$width"; plain="$TRUNC"; }
    printf '%s\n' "$plain"; return 0
  fi
  _paint 36 "$id"; p="$PAINT "
  _paint 1 "$n_done/$n_den"; p="$p$PAINT $G_SEP $pct %"
  printf '%s\n' "$p"
}

if [ "$width" -lt "$TEXT_ONLY_BELOW" ]; then text_only; exit 0; fi

# Bar width: leave room for the counts when they can share the line, then clamp to 8..30.
fixed=$((head_len + 1 + tail_len))
[ "$n_x" -eq 0 ] || fixed=$((fixed + 2 + extras_len))
cells=$((width - fixed))
[ "$cells" -ge "$MIN_BAR_CELLS" ] || cells=$MIN_BAR_CELLS
[ "$cells" -le "$MAX_BAR_CELLS" ] || cells=$MAX_BAR_CELLS
if [ $((head_len + cells + 1 + tail_len)) -gt "$width" ]; then text_only; exit 0; fi

# ---- cell allocation (largest remainder; the only arithmetic besides the percent) ----------------------------------
B=("$n_done" "$n_prog" "$n_fail" "$n_pend")
C=(0 0 0 0)
total=$((n_done + n_prog + n_fail + n_pend))
if [ "$total" -eq 0 ]; then
  C[3]=$cells
else
  F=(0 0 0 0); R=(0 0 0 0); sumf=0
  for k in 0 1 2 3; do
    _p=$((B[k] * cells)); F[k]=$((_p / total)); R[k]=$((_p % total)); sumf=$((sumf + F[k]))
  done
  C=("${F[0]}" "${F[1]}" "${F[2]}" "${F[3]}")
  left=$((cells - sumf))
  # A tie goes to the bucket that understates progress (failed, in progress, pending, then done).
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
fi

# ---- the first line ----------------------------------------------------------------------------------------------------
if [ "$all" -eq 1 ]; then star_code=32; mark="$G_STAR"
elif [ "$fin" -eq 1 ]; then star_code=31; mark="$G_STAR"
else star_code=90; mark="$G_FLAG"; fi

line=""
_paint 36 "$id"; line="$PAINT  "
_rep "$G_FILL" "${C[0]}";  [ "${C[0]}" -eq 0 ] || { _paint 32 "$REP"; line="$line$PAINT"; }
_rep "$G_FILL" "${C[1]}";  [ "${C[1]}" -eq 0 ] || { _paint 33 "$REP"; line="$line$PAINT"; }
_rep "$G_FILL" "${C[2]}";  [ "${C[2]}" -eq 0 ] || { _paint 31 "$REP"; line="$line$PAINT"; }
_rep "$G_EMPTY" "${C[3]}"; [ "${C[3]}" -eq 0 ] || { _paint 90 "$REP"; line="$line$PAINT"; }
_paint "$star_code" "$mark"; line="$line$PAINT "
_paint 1 "$n_done/$n_den"; line="$line$PAINT $G_SEP $pct %"

base_len=$((head_len + cells + 1 + tail_len))
if [ "$n_x" -eq 0 ]; then printf '%s\n' "$line"; exit 0; fi
if [ $((base_len + 2 + extras_len)) -le "$width" ]; then
  k=0
  while [ "$k" -lt "$n_x" ]; do
    _paint "${X_COL[$k]}" "${X_TXT[$k]}"; line="$line  $PAINT"; k=$((k + 1))
  done
  printf '%s\n' "$line"; exit 0
fi

# The counts do not fit beside the bar: wrap them onto following lines, indented under the bar, greedily, never truncated
# (a single count wider than the room is clipped with an ellipsis as a last resort so no line exceeds the width).
printf '%s\n' "$line"
indent="$(printf '%*s' "$head_len" '')"
room=$((width - head_len))
cur=""; cur_len=0
k=0
while [ "$k" -lt "$n_x" ]; do
  txt="${X_TXT[$k]}"; _vlen "$txt"; tl=$VLEN
  if [ "$tl" -gt "$room" ]; then
    _trunc "$txt" $((room - $ELL_LEN)); txt="$TRUNC$G_ELL"; tl=$((room))
  fi
  if [ -n "$cur" ] && [ $((cur_len + 2 + tl)) -gt "$room" ]; then
    printf '%s%s\n' "$indent" "$cur"; cur=""; cur_len=0
  fi
  _paint "${X_COL[$k]}" "$txt"
  if [ -n "$cur" ]; then cur="$cur  $PAINT"; cur_len=$((cur_len + 2 + tl)); else cur="$PAINT"; cur_len=$tl; fi
  k=$((k + 1))
done
[ -z "$cur" ] || printf '%s%s\n' "$indent" "$cur"
exit 0
