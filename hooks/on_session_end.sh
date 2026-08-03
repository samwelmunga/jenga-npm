#!/bin/bash
# .claude/hooks/on_session_end.sh
# Triggered on SessionEnd by all agents (scrum-master, developer, tester).
#
# Responsibilities:
#   1. Log a sender event to events.json
#   2. Detect new problem rapports using a manifest (not a timestamp)
#      and write trigger payloads to the scrum master queue
#   3. Write a status-review trigger to the scrum master queue
#   4. Read .session_handoff.json (if present) and route the assignment
#      to the correct next agent queue, then delete the handoff file
#
# Pipeline routing (section 4):
#   scrum-master  planning_complete       → developer_triggers.jsonl
#   developer     implementation_complete → tester_triggers.jsonl
#   tester        passed / passed_with_remarks → scrum_triggers.jsonl (story_rollup)
#   tester        failed / error          → developer_triggers.jsonl (rework) +
#                                           scrum_triggers.jsonl (status_review)
#
# NOTE: Claude Code hooks cannot spawn a named agent session directly.
# Instead, we write structured trigger payloads to the appropriate queue
# files. Each agent reads its own queue at the start of its next session.

# shellcheck source=lib/resolve-project-dir.sh
source "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"

PROJECT_DIR="$JENGA_PROJECT_DIR"
RAPPORT_DIR="$PROJECT_DIR/project/rapports/problems"
MANIFEST="$PROJECT_DIR/.claude/hooks/.rapport_manifest.json"
QUEUE_DIR="$PROJECT_DIR/project/queue"
QUEUE_FILE="$QUEUE_DIR/scrum_triggers.jsonl"
DEV_QUEUE="$QUEUE_DIR/developer_triggers.jsonl"
TESTER_QUEUE="$QUEUE_DIR/tester_triggers.jsonl"
HANDOFF_FILE="$QUEUE_DIR/.session_handoff.json"
EVENTS_LOG="$PROJECT_DIR/project/logs/events.json"
AGENT="${JENGA_AGENT_TYPE:-unknown}"
SESSION_ID="${JENGA_SESSION_ID:-}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$PROJECT_DIR/project/logs" "$QUEUE_DIR"

# --- 1. Log sender object ---

SENDER=$(jq -n \
  --arg agent "$AGENT" \
  --arg session_id "$SESSION_ID" \
  --arg date "$TIMESTAMP" \
  '{
    sender: {
      agent: $agent,
      session_id: $session_id,
      task_id: "",
      story_id: "",
      epic_id: "",
      date: $date,
      paths: [],
      worktree: ""
    }
  }')

if [ -f "$EVENTS_LOG" ]; then
  jq --argjson entry "$SENDER" '. += [$entry]' "$EVENTS_LOG" > /tmp/events_tmp.json \
    && mv /tmp/events_tmp.json "$EVENTS_LOG"
else
  echo "[$SENDER]" > "$EVENTS_LOG"
fi

# --- 2. Manifest-based rapport detection ---
# Use a JSON array of known filenames instead of a mtime sentinel file.
# This prevents silently missing rapports written before the session ends
# but after the sentinel was last touched.

if [ ! -f "$MANIFEST" ]; then
  echo "[]" > "$MANIFEST"
fi

if [ -d "$RAPPORT_DIR" ]; then
  # Collect current rapport files (exclude .IGNORE.md files — already resolved)
  # Results are stored in a bash array to avoid word-splitting on paths.
  mapfile -t CURRENT_FILES < <(find "$RAPPORT_DIR" -name "*.md" ! -name "*.IGNORE.md" 2>/dev/null | sort)

  # Identify new files not present in the manifest
  NEW_FILES=()
  for file in "${CURRENT_FILES[@]}"; do
    known=$(jq --arg f "$file" 'index($f) != null' "$MANIFEST" 2>/dev/null)
    if [ "$known" != "true" ]; then
      NEW_FILES+=("$file")
    fi
  done

  if [ "${#NEW_FILES[@]}" -gt 0 ]; then
    echo "New rapport(s) detected: ${#NEW_FILES[@]} file(s). Writing trigger to queue."

    # Build a safe JSON array of file paths — never interpolate paths into strings
    FILES_JSON=$(printf '%s\n' "${NEW_FILES[@]}" | jq -R . | jq -s .)

    TRIGGER=$(jq -n \
      --arg type "rapport_review" \
      --arg agent "$AGENT" \
      --arg session_id "$SESSION_ID" \
      --arg date "$TIMESTAMP" \
      --argjson files "$FILES_JSON" \
      '{
        type: $type,
        sender: { agent: $agent, session_id: $session_id, date: $date },
        rapport_files: $files,
        message: "New problem rapport(s) detected. Review each file and either create a backlog item or set the affected task/story/epic status to Failed with a rapport reference. Report back to the user with a summary."
      }')

    echo "$TRIGGER" >> "$QUEUE_FILE"

    # Update the manifest to include all current files
    printf '%s\n' "${CURRENT_FILES[@]}" | jq -R . | jq -s . > "$MANIFEST"
  fi
fi

# --- 3. Status-review trigger ---

TRIGGER=$(jq -n \
  --arg type "status_review" \
  --arg agent "$AGENT" \
  --arg session_id "$SESSION_ID" \
  --arg date "$TIMESTAMP" \
  '{
    type: $type,
    sender: { agent: $agent, session_id: $session_id, date: $date },
    message: "A session has just ended. Review the scrum board and update the status of any tasks, stories, or epics where status may have changed based on recent activity. Check story and epic rollup. Report back to the user with a summary of what changed."
  }')

echo "$TRIGGER" >> "$QUEUE_FILE"

# --- 4. Session handoff routing ---
# Each agent writes .session_handoff.json before its session ends.
# This section reads that file and routes the work to the correct next
# agent queue so the pipeline continues automatically.

if [ -f "$HANDOFF_FILE" ]; then
  HANDOFF_AGENT=$(jq -r '.agent // empty' "$HANDOFF_FILE" 2>/dev/null)
  HANDOFF_STATUS=$(jq -r '.status // empty' "$HANDOFF_FILE" 2>/dev/null)

  case "$HANDOFF_AGENT" in

    scrum-master)
      # Planning phase complete — forward tasks to developer queue
      if [ "$HANDOFF_STATUS" = "planning_complete" ]; then
        TRIGGER=$(jq -n \
          --slurpfile h "$HANDOFF_FILE" \
          --arg type "implementation_assignment" \
          --arg date "$TIMESTAMP" \
          '{
            type: $type,
            date: $date,
            sender: { agent: "scrum-master", session_id: $h[0].session_id, date: $date },
            task_ids: ($h[0].task_ids // []),
            story_id: ($h[0].story_id // ""),
            epic_id:  ($h[0].epic_id  // ""),
            message:  "Scrum master planning complete. Implement the assigned tasks."
          }')
        echo "$TRIGGER" >> "$DEV_QUEUE"
        echo "[on_session_end] scrum-master → developer queue: implementation_assignment"
      fi
      ;;

    developer)
      # Implementation complete — forward to tester queue
      if [ "$HANDOFF_STATUS" = "implementation_complete" ]; then
        TRIGGER=$(jq -n \
          --slurpfile h "$HANDOFF_FILE" \
          --arg type "test_assignment" \
          --arg date "$TIMESTAMP" \
          '{
            type: $type,
            date: $date,
            sender: { agent: "developer", session_id: $h[0].session_id, date: $date },
            task_id:  ($h[0].task_id  // ""),
            story_id: ($h[0].story_id // ""),
            epic_id:  ($h[0].epic_id  // ""),
            worktree: ($h[0].worktree // ""),
            paths:    ($h[0].paths    // []),
            message:  "Developer session complete. Test the implementation in the assigned worktree."
          }')
        echo "$TRIGGER" >> "$TESTER_QUEUE"
        echo "[on_session_end] developer → tester queue: test_assignment"
      fi
      ;;

    tester)
      # Tester session complete — always write story_rollup to scrum-master
      ROLLUP=$(jq -n \
        --slurpfile h "$HANDOFF_FILE" \
        --arg type "story_rollup" \
        --arg date "$TIMESTAMP" \
        '{
          type: $type,
          date: $date,
          sender: { agent: "tester", session_id: $h[0].session_id, date: $date },
          task_id:     ($h[0].task_id     // ""),
          story_id:    ($h[0].story_id    // ""),
          epic_id:     ($h[0].epic_id     // ""),
          test_status: ($h[0].status      // "unknown"),
          rapport_file: ($h[0].rapport_file // ""),
          message: ("Tester session complete with status: " + ($h[0].status // "unknown") + ". Check rollup and update board accordingly.")
        }')
      echo "$ROLLUP" >> "$QUEUE_FILE"
      echo "[on_session_end] tester → scrum-master queue: story_rollup (status=$HANDOFF_STATUS)"

      # Tests failed — also route back to developer for rework
      if [ "$HANDOFF_STATUS" = "failed" ] || [ "$HANDOFF_STATUS" = "error" ]; then
        REWORK=$(jq -n \
          --slurpfile h "$HANDOFF_FILE" \
          --arg type "rework_assignment" \
          --arg date "$TIMESTAMP" \
          '{
            type: $type,
            date: $date,
            sender: { agent: "tester", session_id: $h[0].session_id, date: $date },
            task_id:      ($h[0].task_id      // ""),
            story_id:     ($h[0].story_id     // ""),
            epic_id:      ($h[0].epic_id      // ""),
            worktree:     ($h[0].worktree     // ""),
            rapport_file: ($h[0].rapport_file // ""),
            message: "Tests failed. Address the findings in the rapport and re-implement before calling the tester again."
          }')
        echo "$REWORK" >> "$DEV_QUEUE"
        echo "[on_session_end] tester (failed) → developer queue: rework_assignment"
      fi
      ;;

  esac

  # Consume the handoff file — it is single-use
  rm -f "$HANDOFF_FILE"
fi

# --- 5. Todo cleanup ---
# Remove project/todo.md if it is effectively empty (only blanks, # Todo, and HTML comments).
# Runs unconditionally on every session end regardless of agent type.
bash "$PROJECT_DIR/scripts/todo_cleanup.sh"