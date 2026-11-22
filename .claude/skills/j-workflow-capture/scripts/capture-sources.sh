#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/capture-sources.sh - the source catalog of j.workflow-capture (E103_S01_T02)
#
# j.workflow-capture builds a workflow from a process that is already finished. Where that process comes from is
# its source. This script owns the list of sources, the wording of the numbered picker, and the rule that decides
# whether a source can be used yet, so that SKILL.md never re-derives any of them.
#
# USAGE
#   capture-sources.sh menu                print the five-option numbered source picker, free text last
#   capture-sources.sh list                print the catalog as TSV, one line per entry (columns below)
#   capture-sources.sh check <n|key>       is this source usable now? exit 0 yes, 3 not yet (message on stdout)
#   capture-sources.sh -h | --help         print this usage, exit 0
#
#   --stories-dir <dir>   the board's stories directory. Default: JENGA_CAPTURE_STORIES_DIR, else
#                         "resolve-root.sh get stories". A directory that cannot be resolved is treated as a board
#                         that does not carry the implementing stories (see AVAILABILITY).
#
# THE CATALOG (one entry per line below the CATALOG marker; fields separated by "|")
#   n | key | label | implementing stories (comma-separated, "-" for none) | shipped | follow-up question
#   Entries numbered 1-5 are the picker, in order. Entries numbered "-" (export, import) are sub-commands that
#   are checkable but never shown in the picker.
#
# AVAILABILITY
#   A source with no implementing story is always available. Otherwise, for each implementing story:
#     - when the board carries its story file (<stories-dir>/<ID>_*.md), the story has landed only when its
#       status is "Passed" or "Passed with remarks";
#     - when the board does not carry it (a consumer project has no E103 board files), the entry's shipped flag
#       decides. THE STORY THAT IMPLEMENTS A SOURCE FLIPS THAT ENTRY'S SHIPPED FLAG TO "yes" WHEN IT LANDS.
#   The source is available only when every implementing story has landed.
#
# list OUTPUT COLUMNS (TAB-separated)
#   n  key  label  state  stories  waiting-on  follow-up
#   state is "available" or "not-yet-available"; waiting-on is "<ID>:<status>" per story not landed, comma-joined
#   ("<ID>:not-shipped" when the board does not carry it), or "-".
#
# EXIT CODES
#   0 ok (check: available)   2 usage error or unknown source   3 check: not yet available
#
# Reads the board read-only. Creates and writes nothing, and never touches the active-recording pointer.
# bash 3.2 compatible, safe under set -u.
# ---------------------------------------------------------------------------
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '3,/^# ----*$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die_usage() { printf 'capture-sources.sh: %s\n' "$1" >&2; exit 2; }

catalog() {
  sed -n '/^# CATALOG-BEGIN$/,/^# CATALOG-END$/p' "${BASH_SOURCE[0]}" | sed -e '1d' -e '$d' -e 's/^# //'
}
# CATALOG-BEGIN
# 1|current-session|The current session (what we just did)|E103_S02|yes|-
# 2|other-session|Another session|E103_S02|yes|Which session? Give a local session UUID, a transcript .jsonl path, or paste the text or a file path.
# 3|external|External instructions (a link or pasted text)|E103_S03,E103_S04|no|Give the link, or paste the instructions.
# 4|live|Start a live recording instead (hands off to j.workflow-recorder)|-|yes|-
# 5|other|Other (describe below)|-|yes|-
# -|export|Export a workflow as a portable package|E103_S05|no|-
# -|import|Import a workflow package|E103_S05|no|-
# CATALOG-END

STORIES_DIR=""
STORIES_DIR_SET=0

resolve_stories_dir() {
  [ "$STORIES_DIR_SET" -eq 1 ] && return 0
  STORIES_DIR_SET=1
  if [ -n "${JENGA_CAPTURE_STORIES_DIR:-}" ]; then STORIES_DIR="$JENGA_CAPTURE_STORIES_DIR"; return 0; fi
  # shellcheck source=/dev/null
  if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
  local resolver
  resolver="$(jenga_package_root "$SCRIPT_DIR" 2>/dev/null)/scripts/resolve-root.sh"
  [ -f "$resolver" ] && STORIES_DIR="$(bash "$resolver" get stories 2>/dev/null)" || STORIES_DIR=""
  return 0
}

# Prints the status of story $1 from the board, or nothing when the board does not carry it.
story_status() {
  resolve_stories_dir
  [ -n "$STORIES_DIR" ] && [ -d "$STORIES_DIR" ] || return 0
  local f
  for f in "$STORIES_DIR/$1"_*.md; do
    [ -f "$f" ] || continue
    awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} /^status:/ {sub(/^status:[[:space:]]*/, ""); gsub(/["'\''[:space:]]+$/, ""); gsub(/^["'\'']/, ""); print; exit}' "$f"
    return 0
  done
}

# For one catalog entry ($1 stories, $2 shipped flag), prints the waiting-on field ("-" when available).
waiting_on() {
  local stories="$1" shipped="$2" out="" id st old_ifs
  [ "$stories" = "-" ] && { printf -- '-'; return 0; }
  old_ifs="$IFS"; IFS=','
  for id in $stories; do
    IFS="$old_ifs"
    st="$(story_status "$id")"
    if [ -n "$st" ]; then
      case "$st" in "Passed"|"Passed with remarks") continue ;; esac
      out="${out:+$out,}$id:$st"
    elif [ "$shipped" != "yes" ]; then
      out="${out:+$out,}$id:not-shipped"
    fi
    IFS=','
  done
  IFS="$old_ifs"
  printf '%s' "${out:--}"
}

cmd_list() {
  local n key label stories shipped follow w state
  catalog | while IFS='|' read -r n key label stories shipped follow; do
    w="$(waiting_on "$stories" "$shipped")"
    if [ "$w" = "-" ]; then state="available"; else state="not-yet-available"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$key" "$label" "$state" "$stories" "$w" "$follow"
  done
}

# Human wording for a waiting-on field: "E103_S02 (status: Pending)" or "E103_S02 (not in this release yet)".
describe_waiting() {
  local w="$1" out="" item id st old_ifs="$IFS"
  IFS=','
  for item in $w; do
    id="${item%%:*}"; st="${item#*:}"
    if [ "$st" = "not-shipped" ]; then item="$id (not in this release yet)"; else item="$id (status: $st)"; fi
    out="${out:+$out and }$item"
  done
  IFS="$old_ifs"
  printf '%s' "$out"
}

cmd_menu() {
  printf 'Where should the workflow be captured from?\n'
  cmd_list | while IFS="$(printf '\t')" read -r n key label state stories w follow; do
    [ "$n" = "-" ] && continue
    if [ "$state" = "available" ]; then
      printf '%s. %s\n' "$n" "$label"
    else
      printf '%s. %s - not yet available, waits on %s\n' "$n" "$label" "$(describe_waiting "$w")"
    fi
  done
}

cmd_check() {
  local want="$1" line n key label state stories w follow
  line="$(cmd_list | awk -F '\t' -v w="$want" '$1 == w || $2 == w {print; exit}')"
  [ "$want" != "-" ] && [ -n "$line" ] || die_usage "unknown source: $want (expected 1-5 or one of: $(catalog | cut -d'|' -f2 | tr '\n' ' '))"
  IFS="$(printf '\t')" read -r n key label state stories w follow <<EOF
$line
EOF
  if [ "$state" = "available" ]; then
    printf 'available\t%s\t%s\n' "$key" "$follow"
    return 0
  fi
  printf 'not-yet-available\t%s\t"%s" is not available yet: it is implemented by %s.\n' \
    "$key" "$label" "$(describe_waiting "$w")"
  return 3
}

CMD=""
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    --stories-dir)  [ $# -ge 2 ] || die_usage "--stories-dir needs a directory"
                    STORIES_DIR="$2"; STORIES_DIR_SET=1; shift 2 ;;
    menu|list)      [ -z "$CMD" ] || die_usage "one command at a time"; CMD="$1"; shift ;;
    check)          [ -z "$CMD" ] || die_usage "one command at a time"
                    [ $# -ge 2 ] || die_usage "check needs a source number or key"
                    CMD="check"; ARG="$2"; shift 2 ;;
    *)              die_usage "unknown argument: $1 (try --help)" ;;
  esac
done

case "${CMD:-menu}" in
  menu)  cmd_menu ;;
  list)  cmd_list ;;
  check) cmd_check "$ARG"; exit $? ;;
esac
