#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# persist-task-usage.sh - persist a story's per-task token usage and print the "Usage" block of the closing report
# (epic E76, task E76_S03_T01)
#
# USAGE
#   persist-task-usage.sh <story-id>
#
# Called by skills/j-close-story/SKILL.md Step 2. Run it from the project root, like the skill's other scripts.
#
# WHAT IT DOES
#   1. Looks for task-usage.sh at scripts/task-usage.sh, then node_modules/@jenga-ai/agent/scripts/task-usage.sh.
#      When it exists in neither place it prints NOTHING and exits 0 (public-mirror guard: the script is not shipped
#      there, and an absent measurement tool is not a failure to report).
#   2. Runs `task-usage.sh --persist --story <story-id>`. The arithmetic, the locking and every frontmatter write
#      stay in that script; this one writes nothing to the board.
#   3. Prints the "Usage:" block of the Step 5 report: per task of the story, the persisted totals read back from
#      the task's frontmatter, or "not measured: <reason>" (never a zero for an unmeasured task), a
#      usage_possibly_incomplete flag, and a WARNING line naming the task and the reason for anything that failed.
#
# NON-BLOCKING
#   A non-zero exit of task-usage.sh (layout drift 4-7, nothing measured 8, a task that failed to persist 9, no jq 3)
#   is reported in the block and never propagated: this script exits 0, so the close proceeds and no task status
#   is touched. The only non-zero exit is 2, for a missing or malformed <story-id> (a caller bug).
#
# Compatible with macOS bash 3.2. No jq on the failure paths.
# ---------------------------------------------------------------------------

set -u

STORY="${1:-}"
case "$STORY" in
  E[0-9]*_S[0-9]*) ;;
  *) printf 'Usage: %s <story-id>   (for example E76_S03)\n' "$(basename "$0")" >&2; exit 2 ;;
esac
case "$STORY" in
  *[!A-Za-z0-9_]*) printf 'persist-task-usage.sh: malformed story id: %s\n' "$STORY" >&2; exit 2 ;;
esac

TU="$([ -f scripts/task-usage.sh ] && echo scripts/task-usage.sh || echo node_modules/@jenga-ai/agent/scripts/task-usage.sh)"
[ -f "$TU" ] || exit 0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/persist-task-usage.XXXXXX")" || exit 0
trap 'rm -rf "$TMP"' EXIT

bash "$TU" --persist --story "$STORY" >"$TMP/out" 2>"$TMP/err" </dev/null
rc=$?

# The board's tasks directory, resolved by the same resolver task-usage.sh uses; the default layout otherwise.
TASKS_DIR="$(bash "$(dirname "$TU")/resolve-root.sh" get tasks 2>/dev/null || true)"
[ -n "$TASKS_DIR" ] && [ -d "$TASKS_DIR" ] || TASKS_DIR="project/board/tasks"

# fm_get <file> <key>: the value of a top-level frontmatter key (first --- block only), empty when absent.
fm_get() {
  awk -v k="$2:" '
    NR == 1 { if ($0 !~ /^---[ \t]*$/) exit; next }
    /^---[ \t]*$/ { exit }
    index($0, k) == 1 { v = substr($0, length(k) + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v; exit }
  ' "$1" | sed 's/^"\(.*\)"$/\1/'
}

# result_field <task-id> <status|message>: from the JSON summary on stdout (needs jq; empty without it or on no entry).
result_field() {
  [ -s "$TMP/out" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg id "$1" --arg f "$2" '[.results[]? | select(.id == $id)][0][$f] // empty' "$TMP/out" 2>/dev/null
}

first_err_line() { grep . "$TMP/err" 2>/dev/null | head -n 1; }

printf 'Usage (task-usage.sh --persist --story %s):\n' "$STORY"

if [ "$rc" -ne 0 ]; then
  printf '  WARNING: usage measurement exited %s; the close continues and no task status was changed.\n' "$rc"
  grep . "$TMP/err" 2>/dev/null | head -n 3 | sed 's/^/    /'
fi

any=0
for f in "$TASKS_DIR/$STORY"_T*_*.md; do
  [ -f "$f" ] || continue
  any=1
  id="$(basename "$f" | sed -E 's/^(E[0-9]+_S[0-9]+_T[0-9]+)_.*/\1/')"
  status="$(result_field "$id" status)"
  message="$(result_field "$id" message)"
  total="$(fm_get "$f" usage_total_tokens)"
  if [ -n "$total" ]; then
    line="  $id: total=$total tokens (input=$(fm_get "$f" usage_input_tokens), output=$(fm_get "$f" usage_output_tokens), cache_write=$(fm_get "$f" usage_cache_write_tokens), cache_read=$(fm_get "$f" usage_cache_read_tokens)), transcripts=$(fm_get "$f" usage_transcripts)"
    if [ "$(fm_get "$f" usage_possibly_incomplete)" = true ]; then
      line="$line [usage_possibly_incomplete: the transcripts looked partly pruned]"
    fi
    printf '%s\n' "$line"
    case "$status" in
      failed|skipped) printf '    WARNING: %s: %s\n' "$id" "${message:-persist did not complete}" ;;
      not-measured) printf '    note: %s\n' "${message:-re-measure found no transcripts; persisted values kept}" ;;
    esac
  else
    if [ -n "$message" ]; then
      reason="$message"
    elif [ "$rc" -ne 0 ]; then
      reason="usage measurement failed (exit $rc): $(first_err_line)"
    else
      reason="no usage measured"
    fi
    printf '  %s: not measured: %s\n' "$id" "$reason"
    [ "$status" = failed ] && printf '    WARNING: %s: %s\n' "$id" "$message"
  fi
done
[ "$any" = 1 ] || printf '  (no task files found for %s under %s)\n' "$STORY" "$TASKS_DIR"

exit 0
