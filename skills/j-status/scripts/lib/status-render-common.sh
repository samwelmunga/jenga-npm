# shellcheck shell=bash
# ---------------------------------------------------------------------------
# skills/j-status/scripts/lib/status-render-common.sh - helpers shared by the new j.status renderers (E92_S06_T24)
#
# Source this file; do not execute it. bash 3.2 compatible. Sourcing prints nothing, sets no shell option and runs no
# command. It is sourced by the NEW renderers only (render-status-overview.sh, and the scope renderer of E92_S06_T25).
# The legacy render-status-bars.sh and render-status-scope.sh are deliberately not refactored onto it.
#
# BASH SIDE (set once per run by the renderer, in this order)
#   sr_find_file <override> <path relative to scripts/> <renderer dir>
#                       print the first existing sibling file (env override, then <renderer dir>/../../../scripts/,
#                       then scripts/ and node_modules/@jenga-ai/agent/scripts/ from the current directory), or nothing.
#   sr_detect_utf       SR_UTF=1 when the first non-empty of LC_ALL, LC_CTYPE, LANG names UTF-8, else 0 (ASCII glyphs).
#   sr_resolve_color <auto|always|never>
#                       SR_COLOR=1 or 0. auto: colour only when stdout is a TTY and NO_COLOR is empty.
#   sr_resolve_cols <value or empty>
#                       SR_COLS: --cols value, else COLUMNS, else `stty size` when stdout is a TTY, else 80.
#   sr_warn <message>   one stderr warning, then exit 0 (a progress problem never fails j.status). Uses SR_NAME and
#                       SR_WHAT, which the renderer sets (script name; what is being skipped).
#   sr_jq <program> [jq options]
#                       run `jq -r` on stdin with the jq prelude below in front of <program> and --arg/--argjson
#                       utf, color and cols already bound.
#
# JQ SIDE (SR_JQ_PRELUDE, prepended by sr_jq). A "line" is an array of segments [text, ansi-code]; code "" is plain.
#   g                glyph table (UTF-8 set, or the ASCII stand-ins): done prog pend fail goal star fill empty rej sep more
#                    and, for the scope renderer (E92_S06_T25): start check ready next back
#   txt              control bytes become ?; in ASCII mode every non-ASCII character is transliterated or becomes ?
#   rep(s; n)        s repeated n times ("" for n <= 0)
#   pad(n), lpad(n), clip(n)   pad right, pad left, truncate to n characters with the "more" glyph
#   pct              round(done * 100 / denominator) of a totals object, 0 when the denominator is 0
#   alloc(cells)     [done, in_progress, failed, pending] cell counts of a totals object (largest remainder; a non-zero
#                    bucket never rounds to zero while another bucket has more than one cell; all zero => all pending)
#   bar(cells)       the bar of a totals object as segments: done green, in progress yellow, failed red (filled cells)
#                    and pending grey (empty cells). No brackets.
#   segs_len         visible width of a line
#   emit             clean + fit + paint a line to ONE output string: the visible width never exceeds $cols (a longer
#                    line is cut and ends in the "more" glyph), colour escapes only when $color is 1
#
# Glyph sets follow render-status-scope.sh (UTF-8: ◉ ○ ⚑ ★ ━ ╌ ·) and render-progress-bar.sh (ASCII bar # and -);
# any non-UTF-8 locale prints ASCII only. Every glyph counts as ONE column, as in the existing renderers.
# ---------------------------------------------------------------------------

sr_find_file() {
  local override="$1" rel="$2" dir="$3" cand
  if [ -n "$override" ]; then
    [ -f "$override" ] && printf '%s' "$override"
    return 0
  fi
  # The package root: the install root in the monorepo and in node_modules, but node_modules/@jenga-ai/agent in a
  # consumer project, where "$dir/../../.." is only the .claude/ mirror (skills/ and agents/, no scripts/).
  local pkg
  # shellcheck source=/dev/null
  if [ -f "$dir/../../index/scripts/package-root.sh" ]; then . "$dir/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
  pkg="$(jenga_package_root "$dir")" || true
  for cand in "$pkg/scripts/$rel" "scripts/$rel" "node_modules/@jenga-ai/agent/scripts/$rel"; do
    if [ -f "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  return 0
}

sr_detect_utf() {
  local loc="${LC_ALL:-}"
  [ -n "$loc" ] || loc="${LC_CTYPE:-}"
  [ -n "$loc" ] || loc="${LANG:-}"
  case "$loc" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) SR_UTF=1 ;;
    *) SR_UTF=0 ;;
  esac
}

sr_resolve_color() {
  SR_COLOR=0
  case "$1" in
    always) SR_COLOR=1 ;;
    never) SR_COLOR=0 ;;
    *) if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then SR_COLOR=1; fi ;;
  esac
}

sr_resolve_cols() {
  local c="${1:-}"
  if [ -z "$c" ]; then c="${COLUMNS:-}"; fi
  case "$c" in ''|*[!0-9]*) c="" ;; esac
  if [ -z "$c" ] && [ -t 1 ]; then
    c="$(stty size 2>/dev/null | awk '{print $2}')"
    case "$c" in ''|*[!0-9]*) c="" ;; esac
  fi
  if [ -z "$c" ] || [ "$c" -lt 1 ]; then c=80; fi
  SR_COLS="$c"
}

sr_warn() {
  printf '%s: warning: %s (%s skipped)\n' "${SR_NAME:-status renderer}" "$1" "${SR_WHAT:-status block}" >&2
  exit 0
}

# shellcheck disable=SC2016  # jq source, not shell
SR_JQ_PRELUDE='
def g: if $utf == 1
  then {done:"●", prog:"◉", pend:"○", fail:"✕", goal:"⚑", star:"★", fill:"━", empty:"╌", rej:"⊘", sep:"·", more:"…",
        start:"▸", check:"✓", ready:"+", next:"›", back:"←"}
  else {done:"x", prog:"~", pend:"o", fail:"!", goal:">", star:"*", fill:"#", empty:"-", rej:"/", sep:"-", more:"...",
        start:">", check:"ok", ready:"+", next:">", back:"<-"} end;
def txt: tostring | gsub("[\u0000-\u001f\u007f]"; "?")
  | if $utf == 1 then . else
      (gsub("[åä]"; "a") | gsub("[ÅÄ]"; "A") | gsub("ö"; "o") | gsub("Ö"; "O") | gsub("é"; "e") | gsub("[^\u0000-\u007f]"; "?"))
    end;
def rep($s; $n): if $n > 0 then ([range(0; $n)] | map($s) | join("")) else "" end;
def pad($n): . as $s | ($s | length) as $l | $s + rep(" "; $n - $l);
def lpad($n): tostring | . as $s | ($s | length) as $l | rep(" "; $n - $l) + $s;
def clip($n): . as $s
  | if ($s | length) <= $n then $s
    elif $n <= 0 then ""
    elif $n <= (g.more | length) then $s[:$n]
    else $s[:($n - (g.more | length))] + g.more end;
def pct: if (.denominator // 0) > 0 then ((.done * 100 / .denominator) | round) else 0 end;
def alloc($cells):
  . as $t
  | (["done", "in_progress", "failed", "pending"] | map($t[.] // 0)) as $v
  | ($v | add) as $den
  | if $den == 0 then [0, 0, 0, $cells]
    else
      ($v | map(. * $cells / $den)) as $raw
      | ($raw | map(floor)) as $fl
      | ($cells - ($fl | add)) as $left
      | ([range(0; 4)] | sort_by([-($raw[.] - $fl[.]), .]) | .[:$left]) as $bump
      | ([range(0; 4)] | map(. as $i | $fl[$i] + (if ($bump | index($i)) != null then 1 else 0 end))) as $out
      | reduce range(0; 4) as $i ($out;
          if $v[$i] > 0 and .[$i] == 0 then (index(max)) as $j
            | if .[$j] > 1 then (.[$j] -= 1 | .[$i] = 1) else . end
          else . end)
    end;
def bar($cells): alloc($cells) as $a
  | [[rep(g.fill; $a[0]), "32"], [rep(g.fill; $a[1]), "33"], [rep(g.fill; $a[2]), "31"], [rep(g.empty; $a[3]), "90"]]
  | map(select(.[0] != ""));
def segs_len: map(.[0] | length) | add // 0;
def fit($n):
  . as $line
  | if ($line | segs_len) <= $n then $line
    else
      ([$n - (g.more | length), 0] | max) as $keep
      | (reduce $line[] as $s ({out: [], left: $keep};
          if .left <= 0 then .
          else ($s[0] | length) as $l
            | if $l <= .left then (.out += [$s] | .left -= $l)
              else (.out += [[$s[0][:.left], $s[1]]] | .left = 0) end
          end)).out
      | . + [[(g.more | .[:([$n, (g.more | length)] | min)]), ""]]
    end;
def paint: if $color == 1
  then map(if .[1] != "" then ([27] | implode) + "[" + .[1] + "m" + .[0] + ([27] | implode) + "[0m" else .[0] end) | join("")
  else map(.[0]) | join("") end;
def emit: map([(.[0] | txt), .[1]]) | fit($cols) | paint;
'

# sr_jq <program> [jq options...]: stdin is the JSON document.
sr_jq() {
  local prog="$1"
  shift
  jq -r --argjson utf "${SR_UTF:-1}" --argjson color "${SR_COLOR:-0}" --argjson cols "${SR_COLS:-80}" \
    "$@" "$SR_JQ_PRELUDE
$prog"
}
