#!/bin/bash
# .claude/hooks/on_session_end.sh
# Triggered on SessionEnd by all agents (scrum-master, developer, tester).
#
# Responsibilities:
#   1. Log a sender event to events.json
#   2. Detect new problem rapports using a manifest (not a timestamp)
#      and write trigger payloads to the scrum master queue
#   3. Write a status-review trigger to the scrum master queue
#   4. Process every pending file under project/queue/handoffs/ (if any),
#      routing each one's assignment to the correct next agent queue, then
#      deleting that individual file immediately after it is routed — so a
#      problem with one file never blocks or loses any of the others
#   4b. Remove this session's perceived-branch state file (E78_S01_T03), keyed
#      by the harness session id (env, then stdin payload), never SESSION_ID
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
# NOTE: this manifest lives under project/ (not .claude/) because .claude/
# and .agents/ are generated build outputs, clobbered on every /distribute
# or /self-sync run — see CLAUDE.md. Canonical, committed state must not
# live inside a distribution target. Seed generated via, and kept in sync
# by, scripts/generate-rapport-manifest.sh (see section 2 below).
MANIFEST="$PROJECT_DIR/project/data/rapport_manifest.json"
QUEUE_DIR="$PROJECT_DIR/project/queue"
QUEUE_FILE="$QUEUE_DIR/scrum_triggers.jsonl"
DEV_QUEUE="$QUEUE_DIR/developer_triggers.jsonl"
TESTER_QUEUE="$QUEUE_DIR/tester_triggers.jsonl"
# Per-session handoff files (E37_S01_T01) replace the old single-slot
# .session_handoff.json. Every file under this directory is processed in
# section 4 below; see templates/SCRUM_BOARD_SCHEMA.md's handoffs/ section
# for the write-side filename convention.
HANDOFF_DIR="$QUEUE_DIR/handoffs"
EVENTS_LOG="$PROJECT_DIR/project/logs/events.json"
AGENT="${JENGA_AGENT_TYPE:-unknown}"
SESSION_ID="${JENGA_SESSION_ID:-}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Key of the perceived-branch state file this session may have written
# (E78_S01_T03; section 4b below removes it). Deliberately NOT derived from
# SESSION_ID above: at SessionEnd lib/resolve-project-dir.sh invents a fresh
# uuid for JENGA_SESSION_ID, so that value never matches the key the state
# file was written under (project/documentation/perceived-branch-session-id.md).
# The key comes from the harness instead: the environment first, then the
# stdin payload's session_id. Resolved here, early and once, so nothing below
# can consume the payload first (the hook reads no other stdin). Empty means
# "no key could be determined" and section 4b then skips silently.
PERCEIVED_KEY="${JENGA_CHECKLIST_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -z "$PERCEIVED_KEY" ] && [ ! -t 0 ]; then
  # The 1-second timeout keeps an idle, never-closed pipe from blocking the
  # hook (read -t with an integer works on stock macOS bash 3.2); a timeout
  # leaves whatever was read in the variable, which the jq below rejects if
  # it is not a complete JSON object.
  HOOK_STDIN=""
  IFS= read -r -t 1 -d '' HOOK_STDIN 2>/dev/null || true
  if [ -n "$HOOK_STDIN" ]; then
    PERCEIVED_KEY=$(printf '%s' "$HOOK_STDIN" \
      | jq -r 'if (.session_id | type) == "string" then .session_id else empty end' 2>/dev/null) || PERCEIVED_KEY=""
  fi
  unset HOOK_STDIN
fi

mkdir -p "$PROJECT_DIR/project/logs" "$QUEUE_DIR" "$HANDOFF_DIR"

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

# events.json is JSONL (one record per line; project/documentation/event-log-merge-strategy.md).
# The sender event is appended through the shared helper scripts/events-append.sh (E75_S01),
# which validates the record, appends ONE compact line under scripts/with-lock.sh and refuses a
# legacy array-shaped file. Nothing already in the file is read back or rewritten.
EVENTS_APPEND=""
for _c in "$PROJECT_DIR/scripts/events-append.sh" "$PROJECT_DIR/node_modules/@jenga-ai/agent/scripts/events-append.sh"; do
  [ -f "$_c" ] && { EVENTS_APPEND="$_c"; break; }
done
if [ -n "$EVENTS_APPEND" ]; then
  bash "$EVENTS_APPEND" --file "$EVENTS_LOG" "$SENDER"
else
  echo "on_session_end.sh: scripts/events-append.sh not found; sender event not logged" >&2
fi

# --- 2. Manifest-based rapport detection ---
# Use a JSON array of known filenames instead of a mtime sentinel file.
# This prevents silently missing rapports written before the session ends
# but after the sentinel was last touched.
#
# The manifest itself is committed to the repo (seeded and kept in sync via
# scripts/generate-rapport-manifest.sh), so on a normal checkout it already
# exists and reflects the rapports present at commit time. The bootstrap
# below is a non-destructive fallback for the genuinely unexpected case
# where the file is missing (e.g. project/data/ was pruned) — it does not
# run on a fresh clone with the manifest intact.

mkdir -p "$(dirname "$MANIFEST")"
if [ ! -f "$MANIFEST" ]; then
  echo "[]" > "$MANIFEST"
fi

if [ -d "$RAPPORT_DIR" ]; then
  # Collect current rapport files (exclude .IGNORE.md files — already resolved)
  # Results are stored in a bash array to avoid word-splitting on paths.
  # Uses a portable `while read` loop rather than mapfile/readarray: macOS
  # ships bash 3.2 (no mapfile support), and this hook must run there —
  # matches the convention already established in scripts/smoke-harness.sh,
  # skills/j-publish/scripts/generate_release_notes.sh, and
  # skills/j-publish/scripts/finalize_changelog.sh. Fixed incidentally here
  # because this task's acceptance criteria require the hook to actually
  # execute end-to-end (mapfile silently failed on stock macOS bash,
  # leaving CURRENT_FILES empty and masking real detection results).
  CURRENT_FILES=()
  while IFS= read -r line; do
    [ -n "$line" ] && CURRENT_FILES+=("$line")
  done < <(find "$RAPPORT_DIR" -name "*.md" ! -name "*.IGNORE.md" 2>/dev/null | sort)

  # Identify new files not present in the manifest. The manifest stores
  # paths relative to $PROJECT_DIR (portable across clones/worktrees), so
  # each absolute CURRENT_FILES entry is relativized before the lookup.
  # NEW_FILES itself stays absolute — it feeds rapport_files in the
  # trigger below, which the scrum master reads directly.
  NEW_FILES=()
  for file in "${CURRENT_FILES[@]}"; do
    rel="${file#"$PROJECT_DIR"/}"
    known=$(jq --arg f "$rel" 'index($f) != null' "$MANIFEST" 2>/dev/null)
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

    # Update the manifest to include all current files. Delegates to the
    # shared generator script (rather than re-inlining the same jq
    # pipeline) so the runtime update and the committed seed can never
    # drift in how they compute "current rapport files".
    bash "$PROJECT_DIR/scripts/generate-rapport-manifest.sh" "$MANIFEST" >/dev/null
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

# --- Helper: has this handoff's referenced task already reached a
# terminal board status? ---------------------------------------------------
# Guards against resurrecting a stale handoff file (e.g. one that was
# accidentally committed to git alongside unrelated work, or one left over
# from before this directory was ever consumed) as a fresh routing signal
# for work that has already been fully verified. Terminal here means "no
# further routing action should occur": Passed / Passed with remarks /
# Rejected / Done are all end states, and Blocked is included because a
# blocked task must not be silently re-touched by any agent per
# agents/developer.md's Blocked-halt contract (only a human may clear it).
# Deliberately fails open (returns 1 / "not terminal") when the task file
# can't be found or has no readable status, so a lookup miss falls back to
# today's behavior (route it) rather than silently dropping a handoff whose
# task genuinely can't be identified.
is_task_terminal() {
  local task_id="$1" task_file task_status
  task_file=$(find "$PROJECT_DIR/project/board/tasks" -maxdepth 1 -iname "${task_id}_*.md" 2>/dev/null | head -1)
  [ -z "$task_file" ] && return 1
  task_status=$(awk -F': ' '/^status:/ {print $2; exit}' "$task_file" 2>/dev/null)
  case "$task_status" in
    Passed|"Passed with remarks"|Rejected|Done|Blocked) return 0 ;;
    *) return 1 ;;
  esac
}

# --- 4. Session handoff routing ---
# Each agent writes a per-session handoff file under project/queue/handoffs/
# before its session ends (see E37_S01_T01). This section processes every
# file currently present in that directory — not just one fixed path — so
# concurrent sessions ending close together each get routed instead of the
# last writer silently clobbering the others. Every file is routed through
# the same per-agent logic below, then deleted individually right after
# routing, so a problem with one file can't block or lose any of the rest.
#
# The glob is intentionally generic (*.json, not a pattern anchored to the
# <agent>-<session_id>-<task_id> convention) so it also picks up older
# ad-hoc-named files written before that convention existed — routing below
# only ever reads the .agent/.status fields from file contents, never the
# filename, so this is safe.
#
# Before routing, a developer/tester handoff whose referenced task is
# already terminal on the board is treated as stale (deleted, not routed)
# rather than as a live signal — see is_task_terminal() above. This closes
# a real regression found during E37_S01_T02 testing: this directory can
# accumulate committed leftover files for already-shipped work (nothing
# consumed them before this task existed), and a bare generic glob would
# otherwise resurrect all of them as fresh test_assignment/story_rollup
# triggers the moment this hook first runs against such a directory.
for HANDOFF_FILE in "$HANDOFF_DIR"/*.json; do
  # Guard against the glob matching nothing (no nullglob dependency, so
  # this stays portable to stock macOS bash 3.2 — same rationale as the
  # portable `while read` loop in section 2 above).
  [ -e "$HANDOFF_FILE" ] || continue

  # Atomic per-file claim (E37_S01_T04) — closes the TOCTOU window between
  # this per-process glob snapshot and the eventual delete at the bottom of
  # the loop. `mv` between two paths on the same filesystem is a rename(2)
  # syscall: the kernel guarantees that when multiple concurrent processes
  # race to rename the same source path, exactly one succeeds and every
  # other attempt fails because the source no longer exists. No GNU-only
  # flags are involved, so this is portable to macOS/BSD as well as Linux.
  # Without this claim, concurrent invocations could each see the same
  # not-yet-deleted file, read it, and route it before either deleted it —
  # confirmed in project/rapports/problems/E37_S01-concurrent-session-end-race-verification-gap.md
  # as duplicate (2x/2x/4x observed) trigger entries for the same handoff.
  # If the rename fails, another concurrent process already claimed this
  # exact file — skip it without reading, routing, or deleting anything;
  # that other process now owns it.
  CLAIMED_HANDOFF_FILE="${HANDOFF_FILE}.claimed.$$"
  if ! mv "$HANDOFF_FILE" "$CLAIMED_HANDOFF_FILE" 2>/dev/null; then
    echo "[on_session_end] handoff already claimed by a concurrent invocation — skipping $(basename "$HANDOFF_FILE")"
    continue
  fi
  HANDOFF_FILE="$CLAIMED_HANDOFF_FILE"

  HANDOFF_AGENT=$(jq -r '.agent // empty' "$HANDOFF_FILE" 2>/dev/null)
  HANDOFF_STATUS=$(jq -r '.status // empty' "$HANDOFF_FILE" 2>/dev/null)

  # Staleness check — only meaningful for developer/tester handoffs, which
  # each reference exactly one task_id. scrum-master's planning_complete
  # handoff carries a task_ids array of just-created tasks that can't
  # already be terminal in practice, so it is not checked here.
  if [ "$HANDOFF_AGENT" = "developer" ] || [ "$HANDOFF_AGENT" = "tester" ]; then
    CHECK_TASK_ID=$(jq -r '.task_id // empty' "$HANDOFF_FILE" 2>/dev/null)
    if [ -n "$CHECK_TASK_ID" ] && is_task_terminal "$CHECK_TASK_ID"; then
      echo "[on_session_end] stale handoff for already-terminal task $CHECK_TASK_ID — skipping routing, deleting $(basename "$HANDOFF_FILE")"
      rm -f "$HANDOFF_FILE"
      continue
    fi
  fi

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

      # A conversational architecture elicitation session (/uncharted
      # onboard's default flow, or segment --mode investigate — E20_S08_T03)
      # ended mid-run without converging. The session driving it is
      # responsible for calling skills/j-uncharted/scripts/elicitation-state.sh
      # pause and then writing this handoff with status "elicitation_paused"
      # as its last action (see skills/j-uncharted/SKILL.md's Multi-Session
      # Persistence subsection). This routes that pause into a resume
      # signal for the next scrum-master session, per the existing
      # SessionEnd/queue pattern rather than a new persistence mechanism
      # (solution-assessment-uncharted-interactive-elicitation.md, Problem 11).
      if [ "$HANDOFF_STATUS" = "elicitation_paused" ]; then
        TRIGGER=$(jq -n \
          --slurpfile h "$HANDOFF_FILE" \
          --arg type "elicitation_resume" \
          --arg date "$TIMESTAMP" \
          '{
            type: $type,
            date: $date,
            sender: { agent: "scrum-master", session_id: $h[0].session_id, date: $date },
            elicitation_id: ($h[0].elicitation_id // ""),
            state_file:     ($h[0].state_file     // ""),
            message: "A conversational architecture elicitation session paused mid-run. Resume it from the persisted state file."
          }')
        echo "$TRIGGER" >> "$QUEUE_FILE"
        echo "[on_session_end] scrum-master (elicitation_paused) → scrum-master queue: elicitation_resume"
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

  # Consume this handoff file — it is single-use. Deleted immediately after
  # routing (not batched after the loop) so a later file's failure can never
  # cause an earlier, already-routed file to be left unconsumed or vice versa.
  rm -f "$HANDOFF_FILE"
done

# --- 4b. Perceived-branch state cleanup (E78_S01_T03) ---
# Remove this session's perceived-branch state file (epic E78, decision 3) so a
# stale file can never leak into a later session. All path and filename logic
# stays in scripts/perceived-branch.sh; this hook only hands it the explicit key
# resolved near the top (PERCEIVED_KEY), so the script's own env probe never
# runs inside this hook's polluted environment. Removal is by exact key, so
# another session's state file is never touched. Best-effort like the rest of
# the hook: no key means skip silently, and a missing or failing script is
# ignored. It sits before section 5 (which has no early exit either) so the
# hook's final command, and therefore its exit status, is the same as before.
# The subshell cd makes the script resolve the same project the hook uses.
if [ -n "$PERCEIVED_KEY" ] && [ -f "$PROJECT_DIR/scripts/perceived-branch.sh" ]; then
  ( cd "$PROJECT_DIR" && bash scripts/perceived-branch.sh clear --session "$PERCEIVED_KEY" ) >/dev/null 2>&1 || true
fi

# --- 5. Todo cleanup ---
# Remove project/todo.md if it is effectively empty (only blanks, # Todo, and HTML comments).
# Runs unconditionally on every session end regardless of agent type.
bash "$PROJECT_DIR/scripts/todo_cleanup.sh"

# --- 6. Stale resolved_context digest sweep (E49_S01_T02) ---
# Backstop cleanup for project/queue/context/ digest files. The primary
# cleanup path is scripts/consume-context-digest.sh, called by the receiving
# subagent once it has read its digest — this sweep only catches a digest
# whose intended receiver never consumed it (abandoned dispatch, or a
# receiver that read the raw file directly and forgot to delete it). Age-based
# rather than routed-and-deleted-immediately like section 4 above, because a
# digest's consumer is a later session that may not have started yet when
# THIS session ends — see scripts/sweep-stale-context-digests.sh's header for
# the full rationale. Runs unconditionally, same as todo cleanup above.
bash "$PROJECT_DIR/scripts/sweep-stale-context-digests.sh"
