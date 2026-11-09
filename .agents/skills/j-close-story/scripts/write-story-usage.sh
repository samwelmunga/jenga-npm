#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# write-story-usage.sh - roll a story's task usage plus its allocated overhead up into the story record, and print the
# "Story usage" block of the closing report (epic E76, task E76_S03_T05)
#
# USAGE
#   write-story-usage.sh <story-id>
#
# Called by skills/j-close-story/SKILL.md Step 4. Run it from the project root, like the skill's other scripts. Call it
# after persist-task-usage.sh (Step 2): that step writes the per-task fields this one only reads (the
# usage_possibly_incomplete flag of the tasks).
#
# WHAT IT DOES
#   1. Looks for task-usage.sh at scripts/task-usage.sh, then node_modules/@jenga-ai/agent/scripts/task-usage.sh.
#      When it exists in neither place it prints NOTHING, writes nothing and exits 0 (public-mirror guard, E76 epic
#      decision 6: the script is not shipped there, and an absent measurement tool is not a failure to report).
#   2. Runs `task-usage.sh --report --stories <story-id>` (the overhead allocation of E76_S03_T03; the rule is in
#      project/documentation/task-usage.md, "Allocating overhead to stories"). Nothing is calculated here: the task
#      part, the allocated overhead part and the total are the numbers of that output, and the total is checked to be
#      exactly the task part plus the overhead part before anything is written.
#   3. Writes the thirteen story fields of templates/SCRUM_BOARD_SCHEMA.md ("Usage fields on stories") into the story's
#      board file, in one critical section (scripts/with-lock.sh), through update-task-frontmatter.sh applied to a
#      temporary copy that replaces the file only when every write succeeded. usage_possibly_incomplete (the literal
#      true) is written only when a task of the story carries it, and an existing one is never cleared.
#   4. Prints the report block: the task part, the overhead part and the total, the story's tasks that have no
#      measurement, and any unallocated overhead of the story's session(s).
#
# NEVER A GUESS
#   When the numbers cannot be produced (task-usage.sh failed, jq is missing, no task of the story has a transcript,
#   the total does not add up) NO story field is written and the block says "not measured: <reason>". A persisted task
#   part is never lowered: when a recomputation is below the stored task part (transcripts pruned since), the stored
#   values are kept and usage_possibly_incomplete is set. The overhead part may legitimately change between runs (the
#   split set changes), so only the task part is guarded.
#
# NON-BLOCKING
#   Every failure is reported in the block and never propagated: this script exits 0, so the close proceeds and no
#   status is touched. The only non-zero exit is 2, for a missing or malformed <story-id> (a caller bug).
#
# Internal mode (not for callers): write-story-usage.sh --apply <file> <update-task-frontmatter.sh> <key> <value>...
# is the critical section that runs under scripts/with-lock.sh.
#
# Compatible with macOS bash 3.2.
# ---------------------------------------------------------------------------

set -u

# --- internal: the writes, run under the lock ------------------------------------------------------------------------
if [ "${1:-}" = "--apply" ]; then
  [ $# -ge 4 ] || exit 1
  file="$2"; ufm="$3"; shift 3
  [ -f "$file" ] && [ -f "$ufm" ] || exit 1
  tmp="$(mktemp "${file}.story-usage.XXXXXX")" || exit 1
  trap 'rm -f "$tmp"' EXIT
  cp -p "$file" "$tmp" || exit 1
  while [ $# -ge 2 ]; do
    bash "$ufm" "$tmp" "$1" "$2" >/dev/null || exit 1
    shift 2
  done
  mode="$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null)"
  mv "$tmp" "$file" || exit 1
  trap - EXIT
  case "$mode" in ''|*[!0-7]*) ;; *) chmod "$mode" "$file" 2>/dev/null || true ;; esac
  exit 0
fi

STORY="${1:-}"
case "$STORY" in
  E[0-9]*_S[0-9]*) ;;
  *) printf 'Usage: %s <story-id>   (for example E76_S03)\n' "$(basename "$0")" >&2; exit 2 ;;
esac
case "$STORY" in
  *[!A-Za-z0-9_]*) printf 'write-story-usage.sh: malformed story id: %s\n' "$STORY" >&2; exit 2 ;;
esac

TU="$([ -f scripts/task-usage.sh ] && echo scripts/task-usage.sh || echo node_modules/@jenga-ai/agent/scripts/task-usage.sh)"
[ -f "$TU" ] || exit 0

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
UFM="$(dirname "$SELF")/update-task-frontmatter.sh"
TU_DIR="$(dirname "$TU")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/write-story-usage.XXXXXX")" || exit 0
trap 'rm -rf "$TMP"' EXIT

printf 'Story usage (task-usage.sh --report --stories %s):\n' "$STORY"

not_measured() { printf '  not measured: %s\n' "$1"; exit 0; }

command -v jq >/dev/null 2>&1 || not_measured "jq is not installed, so the usage report cannot be read"

bash "$TU" --report --stories "$STORY" >"$TMP/out" 2>"$TMP/err" </dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  not_measured "usage measurement failed (exit $rc): $(grep . "$TMP/err" 2>/dev/null | head -n 1)"
fi
jq -e --arg s "$STORY" '.stories[$s] | type == "object"' "$TMP/out" >/dev/null 2>&1 \
  || not_measured "the usage report has no entry for $STORY"
[ "$(jq -r --arg s "$STORY" '.stories[$s].measured' "$TMP/out")" = true ] \
  || not_measured "no task of the story has a transcript (nothing to measure, or the transcripts were pruned)"

# one tab-separated row: task part (four fields, total), overhead part (four fields, total), story total
tab="$(printf '\t')"
row="$(jq -r --arg s "$STORY" '.stories[$s] as $st
  | [$st.tasks.input, $st.tasks.output, $st.tasks.cache_write, $st.tasks.cache_read, $st.tasks.total_tokens,
     $st.allocated_overhead.input, $st.allocated_overhead.output, $st.allocated_overhead.cache_write,
     $st.allocated_overhead.cache_read, $st.allocated_overhead.total_tokens, $st.total.total_tokens] | @tsv' "$TMP/out" 2>/dev/null)"
IFS="$tab" read -r t_in t_out t_cw t_cr t_tot o_in o_out o_cw o_cr o_tot s_tot <<EOF
$row
EOF
for v in "$t_in" "$t_out" "$t_cw" "$t_cr" "$t_tot" "$o_in" "$o_out" "$o_cw" "$o_cr" "$o_tot" "$s_tot"; do
  case "$v" in ''|*[!0-9]*) not_measured "the usage report carries a missing or non-integer number for $STORY" ;; esac
done
[ "$((t_tot))" -eq "$((t_in + t_out + t_cw + t_cr))" ] && [ "$((o_tot))" -eq "$((o_in + o_out + o_cw + o_cr))" ] \
  || not_measured "the report's totals are not the sum of their four fields for $STORY; nothing written"
[ "$((s_tot))" -eq "$((t_tot + o_tot))" ] \
  || not_measured "the report's story total ($s_tot) is not the task part ($t_tot) plus the overhead part ($o_tot); nothing written"

unmeasured="$(jq -r --arg s "$STORY" '.stories[$s].unmeasured_tasks // [] | join(", ")' "$TMP/out" 2>/dev/null)"

# unallocated overhead of this story's session(s): the records whose session directory (the allocation rule's
# derivation: a subagent path minus its last two components, a session path minus .jsonl) is the session of one of
# the story's task transcripts. Sums, record count, distinct reasons.
urow="$(jq -r --arg s "$STORY" '
  def sess: if test("/subagents/[^/]+$") then sub("/subagents/[^/]+$"; "") else sub("\\.jsonl$"; "") end;
  ([.tasks | to_entries[] | select(.value.story_id == $s) | .value.transcripts[]? | sess] | unique) as $ss
  | [.unallocated_overhead[]? | select((.path | sess) as $p | $ss | any(. == $p))] as $u
  | [($u | map(.input) | add // 0), ($u | map(.output) | add // 0), ($u | map(.cache_write) | add // 0),
     ($u | map(.cache_read) | add // 0), ($u | length), ($u | map(.reason) | unique | join(", "))] | @tsv' "$TMP/out" 2>/dev/null)"
IFS="$tab" read -r u_in u_out u_cw u_cr u_n u_reason <<EOF
$urow
EOF
case "$u_n" in ''|*[!0-9]*) u_n=0; u_in=0; u_out=0; u_cw=0; u_cr=0; u_reason="" ;; esac

# the board
STORIES_DIR="$(bash "$TU_DIR/resolve-root.sh" get stories 2>/dev/null || true)"
[ -n "$STORIES_DIR" ] && [ -d "$STORIES_DIR" ] || STORIES_DIR="project/board/stories"
TASKS_DIR="$(bash "$TU_DIR/resolve-root.sh" get tasks 2>/dev/null || true)"
[ -n "$TASKS_DIR" ] && [ -d "$TASKS_DIR" ] || TASKS_DIR="project/board/tasks"

fm_get() {
  awk -v k="$2:" '
    NR == 1 { if ($0 !~ /^---[ \t]*$/) exit; next }
    /^---[ \t]*$/ { exit }
    index($0, k) == 1 { v = substr($0, length(k) + 1); sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v); print v; exit }
  ' "$1" | sed 's/^"\(.*\)"$/\1/'
}

# the story's board file: exactly one
sfile=""; nfiles=0
for f in "$STORIES_DIR/$STORY"_*.md; do
  [ -f "$f" ] || continue
  nfiles=$((nfiles + 1)); sfile="$f"
done
[ "$nfiles" -eq 1 ] || sfile=""

# a task of the story carries usage_possibly_incomplete: the story's numbers are a lower bound
incomplete=0
for f in "$TASKS_DIR/$STORY"_T*_*.md; do
  [ -f "$f" ] || continue
  [ "$(fm_get "$f" usage_possibly_incomplete)" = true ] && incomplete=1
done

# decide what to write
action="write"; reason=""
if [ -z "$sfile" ]; then
  action=skip
  if [ "$nfiles" -eq 0 ]; then reason="no board file found for $STORY under $STORIES_DIR"
  else reason="more than one board file matches $STORY under $STORIES_DIR"; fi
else
  stored="$(fm_get "$sfile" usage_tasks_total_tokens)"
  case "$stored" in
    ''|*[!0-9]*) ;;
    *) if [ "$((t_tot))" -lt "$((stored))" ]; then action=keep; fi ;;
  esac
fi

today="${TASK_USAGE_TODAY:-$(date -u +%Y-%m-%d)}"
recorded=""
if [ "$action" = write ]; then
  set -- usage_tasks_input_tokens "$t_in" usage_tasks_output_tokens "$t_out" usage_tasks_cache_write_tokens "$t_cw" \
    usage_tasks_cache_read_tokens "$t_cr" usage_tasks_total_tokens "$t_tot" \
    usage_overhead_input_tokens "$o_in" usage_overhead_output_tokens "$o_out" usage_overhead_cache_write_tokens "$o_cw" \
    usage_overhead_cache_read_tokens "$o_cr" usage_overhead_total_tokens "$o_tot" \
    usage_total_tokens "$s_tot" usage_measured_on "$today"
  [ "$incomplete" -eq 1 ] && set -- "$@" usage_possibly_incomplete true
elif [ "$action" = keep ]; then
  # the recomputed task part is below the persisted one: transcripts were pruned. Keep every stored number, flag it.
  set -- usage_possibly_incomplete true
fi

if [ "$action" != skip ]; then
  WL="$TU_DIR/with-lock.sh"
  if [ ! -f "$WL" ]; then
    action=skip; reason="the lock wrapper $WL is missing"
  else
    bash "$WL" "$sfile" -- bash "$SELF" --apply "$sfile" "$UFM" "$@" </dev/null >/dev/null 2>"$TMP/werr"
    wrc=$?
    if [ "$wrc" -eq 2 ]; then
      action=skip; reason="the lock on $sfile was not acquired; nothing written"
    elif [ "$wrc" -ne 0 ]; then
      action=skip; reason="writing $sfile failed (exit $wrc); the file is unchanged"
    else
      recorded="$sfile"
    fi
  fi
fi

fmt() { printf 'total=%s tokens (input=%s, output=%s, cache_write=%s, cache_read=%s)' "$1" "$2" "$3" "$4" "$5"; }

if [ "$action" = keep ] && [ -n "$recorded" ]; then
  printf '  kept: the recomputed task part (%s tokens) is below the persisted %s tokens (transcripts possibly pruned);\n' "$t_tot" "$stored"
  printf '        the persisted story usage fields are untouched and usage_possibly_incomplete: true was set\n'
  printf '  recomputed tasks:    %s\n' "$(fmt "$t_tot" "$t_in" "$t_out" "$t_cw" "$t_cr")"
  printf '  recomputed overhead: %s\n' "$(fmt "$o_tot" "$o_in" "$o_out" "$o_cw" "$o_cr")"
else
  printf '  tasks:    %s\n' "$(fmt "$t_tot" "$t_in" "$t_out" "$t_cw" "$t_cr")"
  printf '  overhead: %s\n' "$(fmt "$o_tot" "$o_in" "$o_out" "$o_cw" "$o_cr")"
  printf '  story:    total=%s tokens (tasks %s + overhead %s)\n' "$s_tot" "$t_tot" "$o_tot"
fi
if [ "$u_n" -gt 0 ]; then
  printf "  unallocated overhead in this story's session (charged to no story): %s, entries=%s (%s)\n" \
    "$(fmt "$((u_in + u_out + u_cw + u_cr))" "$u_in" "$u_out" "$u_cw" "$u_cr")" "$u_n" "$u_reason"
else
  printf "  unallocated overhead in this story's session: none\n"
fi
[ -z "$unmeasured" ] || printf '  note: tasks without a measurement: %s (the task part is a lower bound)\n' "$unmeasured"
[ "$incomplete" -eq 0 ] || printf '  note: a task of the story has usage_possibly_incomplete: true, so the story numbers are a lower bound\n'
if [ "$action" = skip ]; then
  printf '  WARNING: the story usage fields were not written: %s. The close continues.\n' "$reason"
elif [ -n "$recorded" ] && [ "$action" = write ]; then
  printf '  recorded in %s\n' "$recorded"
fi

exit 0
