#!/usr/bin/env bash
# skills/j-todo/scripts/add_trivial_task.sh
#
# Creates a fully-formed task board file for a `/todo --trivial` mission,
# forced to execution_scope: inline unconditionally, and registers it both
# in its parent story's tasks: frontmatter list and in project/todo.md.
#
# This script performs only the MECHANICAL half of --trivial: templating the
# task file, assigning the next task number, and wiring it into the board.
# The JUDGMENT half — estimating file/line counts and deciding what
# execution_scope the normal heuristic in agents/scrum-master.md would have
# assigned (computed_tier) — happens in the calling agent's instructions
# (skills/j-todo/SKILL.md), per the Skill Implementation Principle: a step that
# requires reasoning about branching logic, new dependencies, etc. does not
# belong in a script. This script never reads project/configs/scope-thresholds.json
# or recomputes computed_tier itself — it only records what it was told.
#
# Usage:
#   add_trivial_task.sh --story <E##_S##> --title "<title>" \
#     --description "<description>" --criteria "<c1>|<c2>|..." \
#     --computed-tier <inline|task|story> --est-files <N> --est-lines <M> \
#     [--prerequisites "<text>"]
#
# Requires an ALREADY-EXISTING parent story file (--trivial does not create
# stories or epics — resolve/create those first via the normal /todo flow).
#
# On success, prints the new task ID (e.g. E32_S14_T05) to stdout and exits 0.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

TASKS_DIR="project/board/tasks"
STORIES_DIR="project/board/stories"
UPDATE_STORY_SCRIPT="skills/j-todo/scripts/update_story_tasks.py"

story_id=""
title=""
description=""
criteria=""
computed_tier=""
est_files=""
est_lines=""
prerequisites="None."

usage() {
  cat >&2 <<EOF
Usage: $0 --story <E##_S##> --title "<title>" --description "<description>" \\
       --criteria "<c1>|<c2>|..." --computed-tier <inline|task|story> \\
       --est-files <N> --est-lines <M> [--prerequisites "<text>"]
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --story) story_id="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --description) description="$2"; shift 2 ;;
    --criteria) criteria="$2"; shift 2 ;;
    --computed-tier) computed_tier="$2"; shift 2 ;;
    --est-files) est_files="$2"; shift 2 ;;
    --est-lines) est_lines="$2"; shift 2 ;;
    --prerequisites) prerequisites="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Error: unknown argument '$1'" >&2; usage ;;
  esac
done

for req_name in story_id title description criteria computed_tier est_files est_lines; do
  if [ -z "${!req_name}" ]; then
    echo "Error: --${req_name//_/-} is required" >&2
    exit 1
  fi
done

if ! [[ "$story_id" =~ ^E[0-9]+_S[0-9]+$ ]]; then
  echo "Error: --story must look like E##_S## (got '$story_id')" >&2
  exit 1
fi

case "$computed_tier" in
  inline|task|story) ;;
  *) echo "Error: --computed-tier must be one of: inline, task, story (got '$computed_tier')" >&2; exit 1 ;;
esac

case "$est_files" in
  ''|*[!0-9]*) echo "Error: --est-files must be a non-negative integer (got '$est_files')" >&2; exit 1 ;;
esac
case "$est_lines" in
  ''|*[!0-9]*) echo "Error: --est-lines must be a non-negative integer (got '$est_lines')" >&2; exit 1 ;;
esac

epic_id="${story_id%%_S*}"

# Locate the parent story file. --trivial requires it to already exist.
story_file=""
for f in "${STORIES_DIR}/${story_id}_"*.md; do
  if [ -f "$f" ]; then
    story_file="$f"
    break
  fi
done
if [ -z "$story_file" ]; then
  echo "Error: no story file found for $story_id under $STORIES_DIR/. --trivial requires an already-resolved story — create it via the normal /todo flow first." >&2
  exit 1
fi

if [ ! -f "$UPDATE_STORY_SCRIPT" ]; then
  echo "Error: $UPDATE_STORY_SCRIPT not found." >&2
  exit 1
fi

# Determine the next task number for this story by scanning existing task files.
max_num=0
shopt -s nullglob
for f in "${TASKS_DIR}/${story_id}_T"*.md; do
  base="$(basename "$f")"
  num="$(printf '%s' "$base" | sed -nE "s/^${story_id}_T([0-9]+)_.*/\1/p")"
  if [ -n "$num" ]; then
    num=$((10#$num))
    if [ "$num" -gt "$max_num" ]; then
      max_num=$num
    fi
  fi
done
shopt -u nullglob
next_num=$((max_num + 1))
next_num_padded="$(printf '%02d' "$next_num")"
task_id="${story_id}_T${next_num_padded}"

shopt -s nullglob
existing_matches=("${TASKS_DIR}/${task_id}_"*.md)
shopt -u nullglob
if [ "${#existing_matches[@]}" -gt 0 ]; then
  echo "Error: a task file for $task_id already exists (ID collision). Aborting." >&2
  exit 1
fi

# Slugify the title for the filename.
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
slug="${slug:0:60}"
slug="${slug%-}"
if [ -z "$slug" ]; then
  slug="trivial-task"
fi

today="$(date -u +%Y-%m-%d)"

scope_rationale="forced inline via --trivial; computed scope would have been '${computed_tier}' — estimated ${est_files} files, ~${est_lines} lines"
override_justification="/todo --trivial invoked by user on ${today}; execution_scope forced to 'inline', overriding the heuristic's computed '${computed_tier}' tier (see scope_rationale)."

# Build the Acceptance Criteria block from the pipe-separated --criteria value.
criteria_block=""
IFS='|' read -ra crit_arr <<< "$criteria"
for c in "${crit_arr[@]}"; do
  c_trimmed="$(printf '%s' "$c" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [ -n "$c_trimmed" ]; then
    criteria_block+="- [ ] ${c_trimmed}"$'\n'
  fi
done
if [ -z "$criteria_block" ]; then
  echo "Error: --criteria produced no usable acceptance criteria" >&2
  exit 1
fi

task_file="${TASKS_DIR}/${task_id}_${slug}.md"

cat > "$task_file" <<EOF
---
id: ${task_id}
story_id: ${story_id}
epic_id: ${epic_id}
title: ${title}
status: Pending
date_created: ${today}
date_started:
date_completed:
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: []
execution_scope: inline
needs_docs: false
scope_rationale: "${scope_rationale}"
jenga_assigned: false
override_justification: "${override_justification}"
---

# Task: ${title}

## Description
${description}

## Prerequisites
${prerequisites}

## Acceptance Criteria
${criteria_block}
EOF

echo "Wrote task file: ${task_file}"

# Register the new task under its parent story's tasks: frontmatter list.
if ! scripts/with-lock.sh "$story_file" -- python3 "$UPDATE_STORY_SCRIPT" "$story_file" "$task_id"; then
  echo "Error: failed to register ${task_id} in ${story_file}'s tasks: list (lock timeout or write failure)." >&2
  exit 1
fi

# Register the todo entry using the FULL task ID, so /do routes straight into
# its Inline Execution Path without a redundant breakdown pass.
bash scripts/todo_manager.sh add "${title}: ${task_id}"

echo "${task_id}"
