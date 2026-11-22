#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/verification-running.sh - is a Tester still verifying this task? (E89_S06_T16)
#
# A board status is a snapshot, not a signal. A Tester writes a terminal status ("Passed with remarks"
# in particular means "judged, findings outstanding") and keeps working: re-verifying handed-back findings,
# running delta rounds. Merging on the status alone can land a branch before the Tester's last fix.
# What does distinguish "judged and finished" from "judged, still verifying" is the tester concurrency slot:
# it is acquired before the Tester is invoked and released only when the Tester's session ends
# (agents/developer.md "Tester Concurrency Cap"; skills/j-do/SKILL.md "4.4"). A fresh tester holder
# for the task therefore means verification is still running, whatever the status says.
#
# Usage:
#   verification-running.sh [--quiet] [<task-id> | <task-branch>]
#   verification-running.sh -h | --help
#
# With no argument: JENGA_MERGE_TASK_ID is used when set, otherwise every fresh tester holder counts
# (the broad form, used by the pre-reconcile checklist item, which does not know which branch is merged).
# A branch name is reduced to its leading E##_S##_T## id. A holder matches when its id is the task id or
# the task's story id (a story bundle holds the slot under the story id).
#
# A holder older than slot_ttl_minutes (project/configs/scope-thresholds.json, default 45) is ignored, the
# same staleness rule scripts/acquire-concurrency-slot.sh applies, so a crashed Tester's leaked slot cannot
# block merging for long. Counter files are read only, never written.
#
# Exit codes:
#   0  no fresh tester slot matches: verification is not running (or cannot be shown to be)
#   1  a fresh tester slot matches: verification is still running. One line per holder on stdout
#   2  usage error
#   5  environment error (jq missing)
# ---------------------------------------------------------------------------
set -u

QUIET=0
ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      sed -n '2,/^# ----*$/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -*)
      echo "verification-running: unknown option '$1'" >&2
      exit 2
      ;;
    *)
      [ -z "$ARG" ] || {
        echo "verification-running: only one task id or branch may be given" >&2
        exit 2
      }
      ARG="$1"
      shift
      ;;
  esac
done
command -v jq >/dev/null 2>&1 || {
  echo "verification-running: jq is required" >&2
  exit 5
}

[ -n "$ARG" ] || ARG="${JENGA_MERGE_TASK_ID:-}"
TASK=""
STORY=""
if [ -n "$ARG" ]; then
  TASK="$(printf '%s' "$ARG" | grep -oE '^E[0-9]+_S[0-9]+_T[0-9]+' | head -n 1)"
  if [ -z "$TASK" ]; then
    # Not task-shaped (a story id, or an unrelated branch): a story id still matches bundle holders.
    TASK="$(printf '%s' "$ARG" | grep -oE '^E[0-9]+_S[0-9]+' | head -n 1)"
    [ -n "$TASK" ] || exit 0
  fi
  STORY="$(printf '%s' "$TASK" | grep -oE '^E[0-9]+_S[0-9]+')"
fi

# Queue directories: the main working tree's (slot files live there) and the resolved project dir's.
MAIN_TREE="$(git worktree list --porcelain 2>/dev/null | awk 'NR == 1 { print substr($0, 10); exit }')"
DIRS="${MAIN_TREE:+$MAIN_TREE/project/queue}"
for d in "${JENGA_PROJECT_DIR:-}" "${CLAUDE_PROJECT_DIR:-}" "$(git rev-parse --show-toplevel 2>/dev/null)"; do
  if [ -n "$d" ]; then
    DIRS="$DIRS
$d/project/queue"
  fi
done

TTL=45
for cfg in "${MAIN_TREE:-.}/project/configs/scope-thresholds.json" "project/configs/scope-thresholds.json"; do
  if [ -f "$cfg" ]; then
    v="$(jq -r '.slot_ttl_minutes // empty' "$cfg" 2>/dev/null)"
    case "$v" in
      '' | *[!0-9]*) ;;
      *)
        TTL="$v"
        break
        ;;
    esac
  fi
done
NOW="$(date -u +%s)"
FOUND=0
SEEN=""
while IFS= read -r dir; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  for f in "$dir"/concurrency-slots-*.json; do
    [ -f "$f" ] || continue
    case "$SEEN" in *"|$f|"*) continue ;; esac
    SEEN="$SEEN|$f|"
    out="$(jq -r --arg task "$TASK" --arg story "$STORY" --argjson now "$NOW" --argjson ttl "$TTL" '
      (.tester.holders // {}) | to_entries[]
      | select($task == "" or .key == $task or .key == $story)
      | (.value | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0)) as $t
      | select(($now - $t) < ($ttl * 60))
      | "tester slot held for \(.key) since \(.value)"' "$f" 2>/dev/null)"
    if [ -n "$out" ]; then
      FOUND=1
      [ "$QUIET" -eq 1 ] || printf '%s (%s)\n' "$out" "$f"
    fi
  done
done <<EOF
$DIRS
EOF

if [ "$FOUND" -eq 1 ]; then
  [ "$QUIET" -eq 1 ] || echo "verification is still running: a terminal board status is not merge authorisation" >&2
  exit 1
fi
exit 0
