#!/usr/bin/env bash
# mixed-width-board.sh - generate a synthetic mixed-width board project (epic E86, task E86_S06_T01).
#
# Usage:
#   bash tests/helpers/mixed-width-board.sh <dir> [--two-digit]
#   bash tests/helpers/mixed-width-board.sh -h | --help
#
# Writes a complete throwaway project into <dir> (which must not exist or must be empty) and nothing anywhere else:
# a board in the real layout (<dir>/project/board/{epics,stories,tasks}), project/todo.md, plan and summary files,
# queue and handoff samples, a rapport, an event log, and a git repository whose history has epic(...), story(...)
# and task(...) commits for the board items. It is called from bats (bash) and from Node tests (child_process).
#
# Default (wide) variant, a superset of the two-digit one:
#   E01   S01 (T01 T02)                        full E01_S01_T01 chain
#   E10   S01 (T01), S10 (T10), S1 (T1)        prefix-collision neighbours: E10 vs E100/E1001, S1 vs S10
#   E11   S01 (T01)
#   E99   S99 (T99)
#   E100  S10 (T10), S100 (T99 T100)
#   E101  S01 (T01)
#   E1001 S01 (T01), S100 (T100)
# --two-digit writes only E01, E10, E11, E99 and their S01, S10, S99, T01, T02, T10, T99 items: every ID in the tree,
# in file names, file bodies and commit subjects, has at most two digits per segment.
#
# Determinism: the same arguments give byte-identical files and identical commit SHAs on every run and machine.
# Every date, author and committer is pinned through GIT_* environment variables, the git environment is isolated
# (no user or system config, no hooks, no signing), and nothing in the output depends on the path of <dir>.
#
# Safety: no network, no write outside <dir>, no read of the host's real project/ tree. Files are created under
# umask 022 (mode 644; this script itself is committed mode 644 and invoked with bash). Compatible with bash 3.2
# (no associative arrays, no mapfile, no here-documents, no empty-array expansion).
#
# Exit codes: 0 generated; 2 usage error; 3 <dir> exists and is not an empty directory; any other non-zero value
# is a failure of mkdir, printf or git while writing.

set -eu
umask 022

SELF="mixed-width-board.sh"

usage() {
  printf 'Usage: bash %s <dir> [--two-digit]\n' "$SELF"
  printf '  <dir>        directory to create the fixture project in (must not exist, or be empty)\n'
  printf '  --two-digit  emit only IDs of at most two digits per segment (E01, E10, E11, E99 families)\n'
}

DIR=""
WIDE=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --two-digit) WIDE=0 ;;
    -*) printf '%s: unknown option: %s\n' "$SELF" "$1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$DIR" ]; then
        printf '%s: more than one directory given: %s and %s\n' "$SELF" "$DIR" "$1" >&2; usage >&2; exit 2
      fi
      DIR="$1"
      ;;
  esac
  shift
done
if [ -z "$DIR" ]; then
  printf '%s: a target directory is required\n' "$SELF" >&2; usage >&2; exit 2
fi

if [ -e "$DIR" ] || [ -L "$DIR" ]; then
  if [ ! -d "$DIR" ]; then
    printf '%s: %s exists and is not a directory\n' "$SELF" "$DIR" >&2; exit 3
  fi
  if [ -n "$(ls -A "$DIR")" ]; then
    printf '%s: %s is not empty; refusing to write into it\n' "$SELF" "$DIR" >&2; exit 3
  fi
fi
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd -P)"

# ---------------------------------------------------------------------------
# Writers. Every path handed to these is relative to $DIR; nothing else is ever written.
# ---------------------------------------------------------------------------

# put <relpath> <printf-format> [args...]  - write one file (creating its directory).
put() {
  local rel="$1"
  shift
  mkdir -p "$DIR/$(dirname "$rel")"
  printf -- "$@" > "$DIR/$rel"
}

# yaml_list <key> <id...>  - a block list, or "key:" followed by nothing when the list is empty.
yaml_list() {
  local key="$1" item
  shift
  printf '%s:\n' "$key"
  for item in "$@"; do
    printf '  - %s\n' "$item"
  done
}

# date_lines <status>  - date_started and date_completed lines that agree with the status.
date_lines() {
  case "$1" in
    Passed) printf 'date_started: 2026-01-02\ndate_completed: 2026-01-03\n' ;;
    "In Progress") printf 'date_started: 2026-01-02\ndate_completed:\n' ;;
    *) printf 'date_started:\ndate_completed:\n' ;;
  esac
}

COMMITS=""   # newline-separated "subject|path path ..." entries, committed in order once every file exists

queue_commit() {
  COMMITS="$COMMITS$1|$2
"
}

# emit_epic <id> <status> <story-id...>
emit_epic() {
  local id="$1" status="$2" rel
  shift 2
  rel="project/board/epics/${id}_fixture-epic.md"
  mkdir -p "$DIR/project/board/epics"
  {
    printf -- '---\nid: %s\ntitle: "Fixture epic %s"\nstatus: %s\ndate_created: 2026-01-01\n' "$id" "$id" "$status"
    date_lines "$status"
    printf 'dates_previously_completed:\nreopened_on:\nreopened_reason:\n'
    yaml_list stories "$@"
    printf -- '---\n\n# Epic: Fixture epic %s\n\nSynthetic epic written by tests/helpers/mixed-width-board.sh.\n' "$id"
  } > "$DIR/$rel"
  queue_commit "epic($id): add fixture epic" "$rel"
}

# emit_story <id> <status> <task-id...>
emit_story() {
  local id="$1" status="$2" epic rel sum
  shift 2
  epic="${id%%_*}"
  rel="project/board/stories/${id}_fixture-story.md"
  sum="project/documentation/summaries/${id}-summary.md"
  mkdir -p "$DIR/project/board/stories"
  {
    printf -- '---\nid: %s\nepic_id: %s\ntitle: "Fixture story %s"\nstatus: %s\ndate_created: 2026-01-01\n' \
      "$id" "$epic" "$id" "$status"
    date_lines "$status"
    printf 'dates_previously_completed:\nreopened_on:\nreopened_reason:\npriority: P1\n'
    yaml_list tasks "$@"
    printf -- '---\n\n# Story: Fixture story %s\n\nSynthetic story under epic %s.\n' "$id" "$epic"
  } > "$DIR/$rel"
  put "$sum" '# Execution Summary: Fixture story %s\n\n**Story ID:** %s\n**Epic ID:** %s\n\nSynthetic story summary.\n' \
    "$id" "$id" "$epic"
  queue_commit "story($id): add fixture story" "$rel $sum"
}

# emit_task <id> <status> [<depends-on-task-id>]
emit_task() {
  local id="$1" status="$2" dep="${3:-}" story epic rel plan sum
  story="${id%_T*}"
  epic="${id%%_*}"
  rel="project/board/tasks/${id}_fixture-task.md"
  plan="project/documentation/plans/${id}-plan.md"
  sum="project/documentation/summaries/${id}-summary.md"
  mkdir -p "$DIR/project/board/tasks"
  {
    printf -- '---\nid: %s\nstory_id: %s\nepic_id: %s\ntitle: "Fixture task %s"\nstatus: %s\ndate_created: 2026-01-01\n' \
      "$id" "$story" "$epic" "$id" "$status"
    date_lines "$status"
    printf 'dates_previously_completed:\nreopened_on:\nreopened_reason:\nassigned_to: developer\n'
    if [ -n "$dep" ]; then
      yaml_list depends_on "$dep"
    fi
    printf -- '---\n\n# Task: Fixture task %s\n\nSynthetic task under story %s.\n' "$id" "$story"
  } > "$DIR/$rel"
  put "$plan" '# Execution Plan: Fixture task %s\n\n**Task ID:** %s\n**Story ID:** %s\n**Epic ID:** %s\n\nSynthetic plan.\n' \
    "$id" "$id" "$story" "$epic"
  put "$sum" '# Execution Summary: Fixture task %s\n\n**Task ID:** %s\n**Story ID:** %s\n**Epic ID:** %s\n\nSynthetic summary.\n' \
    "$id" "$id" "$story" "$epic"
  queue_commit "task($id): add fixture task" "$rel $plan $sum"
}

# ---------------------------------------------------------------------------
# Phase A: the board, in the real layout. Commits are queued in this order.
# ---------------------------------------------------------------------------

E10_STORIES="E10_S01 E10_S10"
if [ "$WIDE" = 1 ]; then
  E10_STORIES="$E10_STORIES E10_S1"
fi

# shellcheck disable=SC2086  # the story lists are deliberately word-split into separate arguments
emit_epic E01 Passed E01_S01
emit_story E01_S01 Passed E01_S01_T01 E01_S01_T02
emit_task E01_S01_T01 Passed
emit_task E01_S01_T02 Passed E01_S01_T01

emit_epic E10 "In Progress" $E10_STORIES
emit_story E10_S01 Passed E10_S01_T01
emit_task E10_S01_T01 Passed
emit_story E10_S10 "In Progress" E10_S10_T10
emit_task E10_S10_T10 Pending
if [ "$WIDE" = 1 ]; then
  emit_story E10_S1 Passed E10_S1_T1
  emit_task E10_S1_T1 Passed
fi

emit_epic E11 Pending E11_S01
emit_story E11_S01 Pending E11_S01_T01
emit_task E11_S01_T01 Pending

emit_epic E99 Passed E99_S99
emit_story E99_S99 Passed E99_S99_T99
emit_task E99_S99_T99 Passed

if [ "$WIDE" = 1 ]; then
  emit_epic E100 "In Progress" E100_S10 E100_S100
  emit_story E100_S10 "In Progress" E100_S10_T10
  emit_task E100_S10_T10 Pending
  emit_story E100_S100 Passed E100_S100_T99 E100_S100_T100
  emit_task E100_S100_T99 Passed
  emit_task E100_S100_T100 Passed E100_S100_T99

  emit_epic E101 Pending E101_S01
  emit_story E101_S01 Pending E101_S01_T01
  emit_task E101_S01_T01 Pending

  emit_epic E1001 Pending E1001_S01 E1001_S100
  emit_story E1001_S01 Pending E1001_S01_T01
  emit_task E1001_S01_T01 Pending
  emit_story E1001_S100 Passed E1001_S100_T100
  emit_task E1001_S100_T100 Passed
fi

# Names that the supporting files (queue, rapport, todo, log, merge commit) refer to, per variant.
if [ "$WIDE" = 1 ]; then
  BATCH_STORY=E100_S100; BATCH_EPIC=E100; BATCH_T1=E100_S100_T99; BATCH_T2=E100_S100_T100
  TOP_EPIC=E1001; TOP_STORY=E1001_S100; TOP_TASK=E1001_S100_T100
  TODO_IDS="E01_S01 E10_S10_T10 E99_S99_T99 E100_S100_T100 E101_S01_T01 E1001_S100_T100"
else
  BATCH_STORY=E01_S01; BATCH_EPIC=E01; BATCH_T1=E01_S01_T01; BATCH_T2=E01_S01_T02
  TOP_EPIC=E99; TOP_STORY=E99_S99; TOP_TASK=E99_S99_T99
  TODO_IDS="E01_S01 E10_S10_T10 E11_S01_T01 E99_S99_T99"
fi

put project/PROJECT_SUMMARY.md '# Fixture Project\n\nSynthetic mixed-width board project written by tests/helpers/mixed-width-board.sh.\n'
put project/configs/workflow.json '{\n  "paths": {\n    "board": "project/board",\n    "epics": "project/board/epics",\n    "stories": "project/board/stories",\n    "tasks": "project/board/tasks",\n    "rapports_problems": "project/rapports/problems",\n    "queue": "project/queue",\n    "scrum_triggers": "project/queue/scrum_triggers.jsonl",\n    "session_handoff": "project/queue/handoffs/",\n    "logs": "project/logs",\n    "documentation": "project/documentation",\n    "documentation_plans": "project/documentation/plans",\n    "documentation_summaries": "project/documentation/summaries"\n  }\n}\n'

# ---------------------------------------------------------------------------
# Phase B: the throwaway git history. The environment is pinned so the SHAs reproduce.
# ---------------------------------------------------------------------------

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
unset GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_TEMPLATE_DIR GIT_PREFIX GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_DATE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Fixture Author" GIT_AUTHOR_EMAIL="fixture@example.invalid"
export GIT_COMMITTER_NAME="Fixture Author" GIT_COMMITTER_EMAIL="fixture@example.invalid"

fgit() {
  git -C "$DIR" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false \
    -c core.autocrlf=false -c core.safecrlf=false -c core.fileMode=true "$@"
}

COMMIT_N=0
# fixture_commit <subject> [<path>...]  - stage exactly these paths (none: an empty commit) and commit with a pinned date.
fixture_commit() {
  local subject="$1" p stamp
  shift
  stamp="$(printf '2026-01-04T%02d:%02d:00+0000' $((COMMIT_N / 60)) $((COMMIT_N % 60)))"
  COMMIT_N=$((COMMIT_N + 1))
  export GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp"
  if [ "$#" -gt 0 ]; then
    for p in "$@"; do
      fgit add -- "$p"
    done
    fgit commit -q -m "$subject"
  else
    fgit commit -q --allow-empty -m "$subject"
  fi
}

fgit -c init.defaultBranch=main init -q
fgit symbolic-ref HEAD refs/heads/main
fixture_commit "chore: scaffold fixture project" project/PROJECT_SUMMARY.md project/configs/workflow.json

ANCHOR=""
LINES="$COMMITS"
while [ -n "$LINES" ]; do
  entry="${LINES%%
*}"
  LINES="${LINES#*
}"
  subject="${entry%%|*}"
  paths="${entry#*|}"
  # shellcheck disable=SC2086  # paths are repo-relative and contain no spaces; split on purpose
  fixture_commit "$subject" $paths
  case "$subject" in
    "story($BATCH_STORY):"*) ANCHOR="$(fgit rev-parse HEAD)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Phase C: supporting files (rapport, todo, queue, handoffs, event log), then their commits.
# ---------------------------------------------------------------------------

RAPPORT="project/rapports/problems/${TOP_TASK}-fixture-sample-problem.md"
put "$RAPPORT" '# Rapport: Fixture sample problem\n\n**Date:** 2026-01-03 (UTC)\n**Agent:** Tester\n**Related Epic:** %s\n**Related Story:** %s\n**Related Task:** %s\n**Type:** `analysis`\n\nSynthetic rapport for the mixed-width fixture.\n' \
  "$TOP_EPIC" "$TOP_STORY" "$TOP_TASK"
fixture_commit "chore($TOP_TASK): add rapport - fixture sample problem" "$RAPPORT"

fixture_commit "merge: land $BATCH_T2-fixture-task into main (Passed)"

{
  printf '# Todo\n\n<!-- Format: <mission title>: <E##_S##> (epic/story ref optional) -->\n\n'
  for id in $TODO_IDS; do
    printf 'Fixture mission for %s: %s\n' "$id" "$id"
  done
  printf '\n<!-- RECONCILED: Fixture mission already done: %s -->\n' "$BATCH_T1"
} > "$DIR/project/todo.md"

mkdir -p "$DIR/project/queue/handoffs" "$DIR/project/logs"
for tid in $BATCH_T1 $BATCH_T2; do
  put "project/queue/handoffs/developer-fixture-session-${tid}.json" \
    '{\n  "agent": "developer",\n  "session_id": "fixture-session",\n  "status": "implementation_complete",\n  "task_id": "%s",\n  "story_id": "%s",\n  "epic_id": "%s",\n  "worktree": "/fixture/worktrees/%s",\n  "paths": ["%s"],\n  "date": "2026-01-03T00:00:00Z"\n}\n' \
    "$tid" "$BATCH_STORY" "$BATCH_EPIC" "$tid" "$ANCHOR"
done
put "project/queue/bundle-${BATCH_STORY}.json" \
  '{\n  "story_id": "%s",\n  "anchor_sha": "%s",\n  "started_at": "2026-01-02T00:00:00Z",\n  "tasks": ["%s", "%s"],\n  "task_changed_files": {\n    "%s": ["project/board/tasks/%s_fixture-task.md"]\n  },\n  "conflict_reports": [],\n  "cross_bundle_conflicts": {}\n}\n' \
  "$BATCH_STORY" "$ANCHOR" "$BATCH_T1" "$BATCH_T2" "$BATCH_T2" "$BATCH_T2"
put project/queue/scrum_triggers.jsonl \
  '{"type":"story_rollup","story_id":"%s","epic_id":"%s","date":"2026-01-03T00:00:00Z","sender":{"agent":"tester","session_id":"fixture-session","task_id":"%s","story_id":"%s","epic_id":"%s","date":"2026-01-03","paths":["%s"],"worktree":"/fixture/worktrees/%s"},"message":"Synthetic story rollup for the mixed-width fixture."}\n{"type":"status_review","task_id":"%s","story_id":"%s","epic_id":"%s","date":"2026-01-03T00:05:00Z"}\n' \
  "$BATCH_STORY" "$BATCH_EPIC" "$BATCH_T2" "$BATCH_STORY" "$BATCH_EPIC" "$ANCHOR" "$BATCH_T2" \
  "$TOP_TASK" "$TOP_STORY" "$TOP_EPIC"
put project/logs/events.json \
  '{"event":"session_start","agent":"developer","session_id":"fixture-session","date":"2026-01-02T00:00:00Z"}\n{"event":"task_passed","agent":"tester","session_id":"fixture-session","task_id":"%s","story_id":"%s","epic_id":"%s","date":"2026-01-03T00:00:00Z"}\n' \
  "$TOP_TASK" "$TOP_STORY" "$TOP_EPIC"

fixture_commit "chore: add fixture todo, queue and event log samples" \
  project/todo.md project/queue project/logs

if [ "$WIDE" = 1 ]; then
  VARIANT="wide"
else
  VARIANT="two-digit"
fi
printf 'Generated %s mixed-width board fixture in %s\n' "$VARIANT" "$DIR"
