#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-close-task/scripts/close-task-context.sh - the deterministic half of /j-close-task
#
# USAGE
#   close-task-context.sh context <task_id> [--session <id>]
#   close-task-context.sh report  <task_id>
#
#   <task_id>   E##_S##_T##. The story and epic ids are derived from it.
#   --session   the caller's session id, used verbatim in the sender object; a fresh one is minted without it.
#
# context  Resolves the board files, the task's status class and its commits, and prints one JSON object:
#            {task_id, story_id, epic_id, task_file, story_file, epic_file, task_status, status_class,
#             commits[], other_branch_commits[], sender{...}}
#          status_class is completed | ladder | incomplete | unknown (completed-statuses.sh, so the script-set
#          statuses after Passed count as done). commits are the task's commits reachable from HEAD, the
#          only ones the Tester can verify in the main checkout. other_branch_commits are the task's commits
#          that exist only on other branches (an unmerged branch, or a rewritten copy such as a cherry-pick);
#          they are informational. sender is ready to hand to the Tester: its paths are `commits` and its
#          worktree is the main checkout.
# report   Re-reads the board after the Tester and the rollup have run and prints one JSON object:
#            {task{id,status,class}, story{id,status,class,open_tasks[]}, epic{id,status,class,open_stories[]},
#             queue{total, types[]} | null}
#          open_* lists the siblings that are not completed-or-beyond; queue is null when the trigger queue
#          cannot be parsed. Read-only.
#
# Neither mode writes anything.
#
# EXIT CODES
#   0 ok   1 the task, story or epic file is missing or ambiguous, or a helper script is unavailable   2 usage
# ---------------------------------------------------------------------------
set -u

die() { printf 'close-task-context.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

[ "$#" -ge 2 ] || die "usage: close-task-context.sh context|report <task_id> [--session <id>]" 2
mode="$1"; task_id="$2"; shift 2
session=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "$#" -ge 2 ] || die "--session needs a value" 2; session="$2"; shift 2 ;;
    *) die "unknown argument '$1'" 2 ;;
  esac
done
case "$mode" in context|report) ;; *) die "unknown mode '$mode' (expected context or report)" 2 ;; esac
printf '%s' "$task_id" | grep -Eq '^E[0-9]+_S[0-9]+_T[0-9]+$' || die "invalid task id '$task_id' (expected E##_S##_T##)" 2
command -v jq >/dev/null 2>&1 || die "jq is required"

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$PROJECT_ROOT" ] || die "could not locate the project root from $SCRIPT_DIR"

# The package root holds scripts/ and templates/: this checkout, or the installed package for a consumer.
if [ -f "$PROJECT_ROOT/scripts/commits-for-item.sh" ]; then PKG_ROOT="$PROJECT_ROOT"
else PKG_ROOT="$PROJECT_ROOT/node_modules/@jenga-ai/agent"; fi
COMMITS="$PKG_ROOT/scripts/commits-for-item.sh"
STATUSES="$PKG_ROOT/skills/j-reconcile/scripts/completed-statuses.sh"
SCHEMA="$PKG_ROOT/templates/SCRUM_BOARD_SCHEMA.md"
[ -f "$COMMITS" ] || die "missing helper: $COMMITS"
[ -f "$STATUSES" ] || die "missing helper: $STATUSES"

story_id="${task_id%_T*}"
epic_id="${story_id%_S*}"

cfg="$PROJECT_ROOT/project/configs/workflow.json"
cfg_path() { # <key> <default>
  local v=""
  [ -f "$cfg" ] && v="$(jq -r --arg k "$1" '.paths[$k] // empty' "$cfg" 2>/dev/null)"
  printf '%s' "${v:-$2}"
}
TASKS_DIR="$PROJECT_ROOT/$(cfg_path tasks project/board/tasks)"
STORIES_DIR="$PROJECT_ROOT/$(cfg_path stories project/board/stories)"
EPICS_DIR="$PROJECT_ROOT/$(cfg_path epics project/board/epics)"

find_item() { # <dir> <id> -> the one board file for the id
  local matches count
  matches="$(ls -1 "$1/$2.md" "$1/$2"_*.md 2>/dev/null)"
  count="$(printf '%s' "$matches" | grep -c . || true)"
  [ "$count" -eq 1 ] || die "expected exactly one board file for $2 in $1, found $count"
  printf '%s' "$matches"
}

fm_get() { # <file> <key> -> value of the key in the first frontmatter block
  awk -v k="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, k ":") == 1 { sub("^" k ":[ ]*", ""); gsub(/^"|"$/, ""); print; exit }
  ' "$1"
}

[ -f "$SCHEMA" ] || die "missing schema: $SCHEMA"
STATUS_JSON="$(bash "$STATUSES" --schema "$SCHEMA" 2>/dev/null)" || die "completed-statuses.sh failed"
class_of() { # <status>
  printf '%s' "$STATUS_JSON" | jq -r --arg s "$1" '
    if (.completed | index($s)) then "completed"
    elif (.ladder | index($s)) then "ladder"
    elif (.incomplete | index($s)) then "incomplete"
    else "unknown" end'
}

task_file="$(find_item "$TASKS_DIR" "$task_id")" || exit 1
story_file="$(find_item "$STORIES_DIR" "$story_id")" || exit 1
epic_file="$(find_item "$EPICS_DIR" "$epic_id")" || exit 1
rel() { printf '%s' "${1#"$PROJECT_ROOT"/}"; }

if [ "$mode" = "context" ]; then
  task_status="$(fm_get "$task_file" status)"
  all_commits="$(bash "$COMMITS" "$task_id" --repo "$PROJECT_ROOT" 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  commits="[]"; other="[]"
  for sha in $(printf '%s' "$all_commits" | jq -r '.[]'); do
    if git -C "$PROJECT_ROOT" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      commits="$(printf '%s' "$commits" | jq -c --arg s "$sha" '. + [$s]')"
    else
      other="$(printf '%s' "$other" | jq -c --arg s "$sha" '. + [$s]')"
    fi
  done
  [ -n "$session" ] || session="close-task-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  jq -n -c \
    --arg task "$task_id" --arg story "$story_id" --arg epic "$epic_id" \
    --arg tf "$(rel "$task_file")" --arg sf "$(rel "$story_file")" --arg ef "$(rel "$epic_file")" \
    --arg status "$task_status" --arg class "$(class_of "$task_status")" \
    --argjson commits "$commits" --argjson other "$other" \
    --arg session "$session" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg wt "$PROJECT_ROOT" '
    {task_id: $task, story_id: $story, epic_id: $epic,
     task_file: $tf, story_file: $sf, epic_file: $ef,
     task_status: $status, status_class: $class,
     commits: $commits, other_branch_commits: $other,
     sender: {agent: "orchestrator", session_id: $session, task_id: $task, story_id: $story,
              epic_id: $epic, date: $date, paths: $commits, worktree: $wt}}'
  exit 0
fi

# report
done_class() { case "$(class_of "$1")" in completed|ladder) return 0 ;; *) return 1 ;; esac; }

open_siblings() { # <dir> <prefix> -> JSON array of {id,status} for siblings that are not done
  local f id st out="[]"
  for f in "$1"/"$2"*.md; do
    [ -f "$f" ] || continue
    id="$(fm_get "$f" id)"; [ -n "$id" ] || id="$(basename "$f" .md)"
    st="$(fm_get "$f" status)"
    done_class "$st" || out="$(printf '%s' "$out" | jq -c --arg i "$id" --arg s "$st" '. + [{id: $i, status: $s}]')"
  done
  printf '%s' "$out"
}

task_status="$(fm_get "$task_file" status)"
story_status="$(fm_get "$story_file" status)"
epic_status="$(fm_get "$epic_file" status)"
open_tasks="$(open_siblings "$TASKS_DIR" "${story_id}_T")"
open_stories="$(open_siblings "$STORIES_DIR" "${epic_id}_S")"

queue="null"
qfile="$PROJECT_ROOT/project/queue/scrum_triggers.jsonl"
if [ ! -s "$qfile" ]; then
  queue='{"total":0,"types":[]}'
else
  queue="$(jq -s -c '{total: length, types: (map(.type // "unknown") | group_by(.) | map({type: .[0], count: length}))}' "$qfile" 2>/dev/null || echo null)"
  [ -n "$queue" ] || queue="null"
fi

jq -n -c \
  --arg task "$task_id" --arg ts "$task_status" --arg tc "$(class_of "$task_status")" \
  --arg story "$story_id" --arg ss "$story_status" --arg sc "$(class_of "$story_status")" --argjson ot "$open_tasks" \
  --arg epic "$epic_id" --arg es "$epic_status" --arg ec "$(class_of "$epic_status")" --argjson os "$open_stories" \
  --argjson queue "$queue" '
  {task: {id: $task, status: $ts, class: $tc},
   story: {id: $story, status: $ss, class: $sc, open_tasks: $ot},
   epic: {id: $epic, status: $es, class: $ec, open_stories: $os},
   queue: $queue}'
