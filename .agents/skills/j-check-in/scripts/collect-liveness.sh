#!/bin/bash

################################################################################
# collect-liveness.sh
#
# Gathers liveness evidence from 6 on-disk sources plus piped ListAgents input,
# joins them deterministically, and emits a single JSON object with findings
# and visibility metadata.
#
# This script is the DETERMINISTIC half of j.check-in. It renders nothing and
# decides nothing: skills/j-check-in/SKILL.md owns presentation and judgment.
#
# ---------------------------------------------------------------------------
# CRITICAL: This script exits 0 always (unless the script itself fails with an
# internal error). This is a DELIBERATE DIVERGENCE from scripts/check-worktree-liveness.sh,
# which exits 1 when it finds live processes. The reason: this script's job is to
# REPORT findings, not to signal them via exit code. The JSON output carries all
# signal; the exit code is reserved for internal script failures only.
# DO NOT "fix" this to exit non-zero on findings.
# ---------------------------------------------------------------------------
#
# WHY THE HOST SESSION MUST BE THE COLLECTOR. Input is a JSON array on stdin,
# transcribed by the host session from ListAgents' output — that output is a
# human-readable listing, not JSON, so this is a transcription and not a raw
# pipe (see SKILL.md step 2 for the shape and the state-value rules).
# A bash script cannot invoke ListAgents directly — that is a harness
# tool. It also cannot be collected by a delegated subagent: called from inside
# a delegated scrum-master subagent, ListAgents returned only that subagent
# itself plus seven unrelated interactive peer sessions, and the parent's
# sibling developer/tester subagents were INVISIBLE. A delegated agent is
# structurally blind to exactly the agents it would be asked to check on. The
# host session therefore produces the input and pipes it in.
#
# Use --no-agents to skip ListAgents input and run on-disk evidence only
# (the automatic path in E44_S07).
#
# Output: Exactly one JSON object on stdout, with keys:
#         - generated_at (ISO 8601 timestamp)
#         - session_id (from environment or derived)
#         - visibility (object with in_session, cross_session, agents_input, notes)
#         - findings (array of finding objects)
#         - residue (object with counts and oldest timestamp)
#         - counts (object with error, warn, info counts)
#
# Finding codes:
#   F1  agent `running` but idle past the stall threshold
#   F2  agent `completed` but its worktree still has live processes
#   F3  slot holder past TTL in THIS session
#   F4  slot holder past TTL in ANOTHER session (always actionable: false —
#       both slot scripts' headers state they never read or write another
#       session's counter file, so there is nothing this session may do)
#   F5  board says `In Progress` but nothing is alive
#   F6  board says `In Progress` but no worktree exists
#   F13 liveness undeterminable (never rendered as "clear")
#
# `severity` is error|warn|info. `actionable` is a SEPARATE boolean, because a
# consumer offers options only for actionable findings. `escalation.next_rung`
# is observe|taskstop. `escalation.break_available` is COMPUTED (E44_S10) and is
# true ONLY for a finding about a healthy-but-long orchestration with queued
# work left to dispatch, where halting new dispatch is a meaningful action:
#   1. the agent is `running` and its name is a dispatcher: a story id
#      (a bundle agent) or any id inside an epic with a live epic lock
#   2. it is NOT stalled: idle past the warn threshold, under the stall one
#      (this is the F1 info finding; a stalled F1 can never qualify)
#   3. queued work remains: a live bundle manifest with a non-terminal task, or
#      a live un-commented project/todo.md entry for the epic
#   4. skills/j-break/scripts/check-break.sh exists (no consumption point, no rung)
#   5. no break is already pending, read ONLY via `check-break.sh --peek`
#      (exit 10 = pending). This script never reads the flag file itself.
# Every other finding (stalled agents, F2, F3, F4, F5, F6, F13) is always false,
# as is every finding under --no-agents. `escalation.break_reason` is a single
# sentence present exactly when break_available is true. /break halts the
# DISPATCHER at a task boundary; it cannot reach a wedged agent mid-task, which
# is why a stalled agent never qualifies. Any unreadable input fails closed to
# false and is disclosed in visibility.notes.
#
# ZERO WRITES. This script creates, modifies and removes nothing — no temp
# files, no redirection to any path, no lock. Every join happens in jq or in
# shell variables. tests/checkin-liveness.bats asserts this both statically
# (grepping this source for write constructs) and behaviourally.
#
# Exit codes:
#   0 = success (findings signal via JSON, not exit code)
#   1 = script internal error (rare; JSON may be incomplete or absent)
#
# Future config keys (currently hardcoded thresholds):
#   checkin_idle_warn_minutes   (currently 20)
#   checkin_idle_stall_minutes  (currently 45)
#
# DO NOT LOWER THE STALL THRESHOLD. Real data from this repository: session
# `tester-E69_S06-bundle` logged session_start at 22:58:05Z and then nothing
# until three advisory_checkpoint entries at 23:20:17Z — 22 minutes of total
# silence from a perfectly healthy tester running test suites. Any threshold
# near or below that produces constant false positives. 45 also deliberately
# matches the existing slot_ttl_minutes.
#
# Test seams (never set in normal operation):
#   JENGA_PROJECT_ROOT        project root to read evidence from
#   JENGA_LIVENESS_SCRIPT     path to check-worktree-liveness.sh (lets a test
#                             simulate its exit 4 "cannot determine" path)
#   JENGA_CHECKIN_NOW_EPOCH   fixed "now" in epoch seconds, for deterministic
#                             idle/TTL arithmetic
#   JENGA_CHECKIN_BREAK_SCRIPT path to check-break.sh (lets a test stub the
#                             pending/absent/errored break states)
#
################################################################################

set -o errexit

# ============================================================================
# CONFIGURATION & CONSTANTS
# ============================================================================

IDLE_WARN_MINUTES=20
STALL_MINUTES=45

PROJECT_ROOT="${JENGA_PROJECT_ROOT:-.}"
EVENTS_FILE="$PROJECT_ROOT/project/logs/events.json"
BOARD_DIR="$PROJECT_ROOT/project/board"
QUEUE_DIR="$PROJECT_ROOT/project/queue"
WORKTREE_DIR="$PROJECT_ROOT/.claude/worktrees"
RAPPORT_DIR="$PROJECT_ROOT/project/rapports/problems"
# Sibling-script resolution. JENGA_PROJECT_ROOT names the tree we READ EVIDENCE
# from, which under test is a synthetic fixture that contains no scripts/ at
# all. The helper scripts we EXECUTE therefore have to be resolved
# independently: project root first (so a consuming project's own copy wins),
# then this script's own repo, then the installed package. Resolving them under
# the evidence root alone would silently make every probe "undeterminable" in
# every fixture — a blind collector that still looked like a working one.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

resolve_helper() {
  local rel="$1" candidate
  for candidate in \
    "$PROJECT_ROOT/$rel" \
    "$REPO_ROOT/$rel" \
    "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"
  do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 0
}

LIVENESS_SCRIPT="${JENGA_LIVENESS_SCRIPT:-$(resolve_helper scripts/check-worktree-liveness.sh)}"
MARKER_SCRIPT="$(resolve_helper scripts/checklist-marker.sh)"

NO_AGENTS=false
LISTAGENTS_INPUT=""

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-agents)
      NO_AGENTS=true
      shift
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$NO_AGENTS" == false ]]; then
  LISTAGENTS_INPUT="$(cat)" || LISTAGENTS_INPUT=""
fi

GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
NOW_EPOCH="${JENGA_CHECKIN_NOW_EPOCH:-$(date -u +%s)}"

if [[ -n "${SESSION_ID:-}" ]]; then
  CURRENT_SESSION="$SESSION_ID"
elif [[ -n "${HARNESS_SESSION_ID:-}" ]]; then
  CURRENT_SESSION="$HARNESS_SESSION_ID"
else
  CURRENT_SESSION="session-$(hostname)-$$"
fi

EXTRA_NOTES=""

add_note() {
  # Accumulate a visibility note. Notes are tab-separated here and converted
  # to a JSON array at the end; a note is never dropped silently.
  EXTRA_NOTES="${EXTRA_NOTES}${1}"$'\t'
}

# ============================================================================
# SOURCE 1 — ListAgents input (per-subagent lifecycle state)
# ============================================================================
#
# Normalised to [{name, state, session_id}]. `name` is the join key to the
# board: per E44_S05_T03, j.do names every background subagent after the board
# id of the unit it is executing (task id, or story id for a bundle), so no
# board-side scope resolution is needed here.

AGENTS_JSON="[]"
if [[ "$NO_AGENTS" == false ]] && [[ -n "$LISTAGENTS_INPUT" ]]; then
  AGENTS_JSON="$(printf '%s' "$LISTAGENTS_INPUT" | jq -c '
    (if type == "array" then .
     elif type == "object" and ((.agents? | type) == "array") then .agents
     else [] end)
    | map(select(type == "object"))
    | map({
        name: (.name // .id // null),
        state: (((.state // .status // "unknown") | tostring) | ascii_downcase),
        session_id: (.session_id // .sessionId // null)
      })
    | map(select(.name != null))
  ' 2>/dev/null || printf '[]')"
  [[ -n "$AGENTS_JSON" ]] || AGENTS_JSON="[]"
fi

# ============================================================================
# SOURCE 2 — events.json (last activity per session_id)
# ============================================================================
#
# RULE: derive last activity using ONLY max(date) grouped by session_id. Do NOT
# branch on event names. project/logs/events.json has severe event-name drift —
# test_run_complete (30) / test_run_completed (26) / test_run (19) /
# test_result (16); sender_received (359) / sender_object_received (28) /
# incoming_sender (14) — plus 132 entries with no `event` key at all. Any logic
# keyed on event names will be wrong. Reading only `date` sidesteps it entirely.
#
# TOLERANT PARSE, DELIBERATELY. This repository's real events.json is not valid
# JSON: it opens as an array, is never closed, carries a stray `}` and bare `,`
# separator lines where agents appended to it, and has entries with no comma
# between them. A strict `jq -s` parse fails outright on it. Degrading to "no
# activity data" would make every F1 unreachable while still printing a
# clean-looking report — the exact false "all clear" this feature exists to
# prevent. So we recover every well-formed object we can and DISCLOSE the
# shortfall in visibility.notes.

EVENTS_RAW="[]"
EVENTS_BAD=0
if [[ -f "$EVENTS_FILE" ]]; then
  EVENTS_PARSED=""
  if command -v python3 >/dev/null 2>&1; then
    EVENTS_PARSED="$(python3 - "$EVENTS_FILE" <<'PY' || printf ''
import json, sys

decoder = json.JSONDecoder()
try:
    raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    print(json.dumps({"events": [], "bad": 0}))
    sys.exit(0)

events = []
bad = 0
i = 0
n = len(raw)
while i < n:
    if raw[i] in " \t\r\n,[]":
        i += 1
        continue
    try:
        obj, j = decoder.raw_decode(raw, i)
    except ValueError:
        bad += 1
        nl = raw.find("\n", i)
        if nl == -1:
            break
        i = nl + 1
        continue
    i = j
    if isinstance(obj, dict):
        events.append(obj)
    elif isinstance(obj, list):
        events.extend(x for x in obj if isinstance(x, dict))
print(json.dumps({"events": events, "bad": bad}))
PY
)"
  fi

  if [[ -n "$EVENTS_PARSED" ]]; then
    EVENTS_RAW="$(printf '%s' "$EVENTS_PARSED" | jq -c '.events' 2>/dev/null || printf '[]')"
    EVENTS_BAD="$(printf '%s' "$EVENTS_PARSED" | jq -r '.bad' 2>/dev/null || printf '0')"
  else
    # No python3: fall back to a strict parse that handles a well-formed array
    # or well-formed JSONL, and nothing else.
    EVENTS_RAW="$(jq -s -c '
      (if (length == 1 and ((.[0] | type) == "array")) then .[0] else . end)
      | map(select(type == "object"))
    ' "$EVENTS_FILE" 2>/dev/null || printf '[]')"
    if [[ "$EVENTS_RAW" == "[]" ]]; then
      add_note "events.json could not be parsed and python3 is unavailable; idle times are unknown"
    fi
  fi
  [[ -n "$EVENTS_RAW" ]] || EVENTS_RAW="[]"
  case "$EVENTS_BAD" in ''|*[!0-9]*) EVENTS_BAD=0 ;; esac
  if [[ "$EVENTS_BAD" -gt 0 ]]; then
    add_note "events.json is not valid JSON: $EVENTS_BAD unparseable region(s) skipped, so some idle times may be understated"
  fi
else
  add_note "events.json is absent; idle times are unknown"
fi

ACTIVITY_JSON="$(printf '%s' "$EVENTS_RAW" | jq -c '
  {
    by_session: (
      map(select(((.session_id | type) == "string") and ((.date | type) == "string")))
      | group_by(.session_id)
      | map({key: .[0].session_id, value: (map(.date) | max)})
      | from_entries
    ),
    by_task: (
      map(select(((.task_id | type) == "string") and ((.date | type) == "string")))
      | group_by(.task_id)
      | map({key: .[0].task_id, value: (map(.date) | max)})
      | from_entries
    )
  }
' 2>/dev/null || printf '{"by_session":{},"by_task":{}}')"
[[ -n "$ACTIVITY_JSON" ]] || ACTIVITY_JSON='{"by_session":{},"by_task":{}}'

# ============================================================================
# SOURCE 3 — the board (declared In Progress items)
# ============================================================================

# SHORTLIST FIRST, THEN PARSE. This repository carries ~1500 board files, and
# spawning a per-file frontmatter pipeline over all of them cost 27s of pure
# subprocess churn. One grep -l narrows it to the handful actually declared
# In Progress, and only those get parsed.
BOARD_ROWS=""
if [[ -d "$BOARD_DIR" ]]; then
  for board_kind in tasks stories; do
    [[ -d "$BOARD_DIR/$board_kind" ]] || continue
    board_matches="$(grep -l -- '^status:[[:space:]]*In Progress' "$BOARD_DIR/$board_kind"/*.md 2>/dev/null || true)"
    [[ -n "$board_matches" ]] || continue
    while IFS= read -r board_file; do
      [[ -n "$board_file" ]] && [[ -f "$board_file" ]] || continue
      bf_head="$(sed -n '1,40p' "$board_file" 2>/dev/null || true)"
      bf_status="$(printf '%s\n' "$bf_head" | grep -m1 '^status:' | sed 's/^status:[[:space:]]*//' | tr -d '\r' || true)"
      [[ "$bf_status" == "In Progress" ]] || continue
      bf_id="$(printf '%s\n' "$bf_head" | grep -m1 '^id:' | sed 's/^id:[[:space:]]*//' | tr -d '\r' || true)"
      [[ -n "$bf_id" ]] || continue
      bf_scope="$(printf '%s\n' "$bf_head" | grep -m1 '^execution_scope:' | sed 's/^execution_scope:[[:space:]]*//' | tr -d '\r' || true)"
      [[ -n "$bf_scope" ]] || bf_scope="task"
      BOARD_ROWS="${BOARD_ROWS}${bf_id}"$'\t'"${bf_scope}"$'\t'"${board_kind}"$'\n'
    done <<< "$board_matches"
  done
fi

BOARD_JSON="$(printf '%s' "$BOARD_ROWS" | jq -R -s -c '
  split("\n") | map(select(length > 0)) | map(split("\t"))
  | map({id: .[0], scope: (.[1] // "task"), kind: (.[2] // "tasks")})
' 2>/dev/null || printf '[]')"
[[ -n "$BOARD_JSON" ]] || BOARD_JSON="[]"

# ============================================================================
# SOURCE 4 — worktrees on disk
# ============================================================================

# Basenames via parameter expansion, not basename(1): this directory holds ~60
# worktrees and each is visited again by match_worktree, so a subprocess per
# entry is a measurable cost for no benefit.
WORKTREE_ROWS=""
WORKTREE_NAMES=()
if [[ -d "$WORKTREE_DIR" ]]; then
  for wt_path in "$WORKTREE_DIR"/*/; do
    [[ -d "$wt_path" ]] || continue
    wt_base="${wt_path%/}"
    wt_base="${wt_base##*/}"
    WORKTREE_NAMES+=("$wt_base")
    WORKTREE_ROWS="${WORKTREE_ROWS}${wt_base}"$'\n'
  done
fi

WORKTREES_JSON="$(printf '%s' "$WORKTREE_ROWS" | jq -R -s -c '
  split("\n") | map(select(length > 0))
' 2>/dev/null || printf '[]')"
[[ -n "$WORKTREES_JSON" ]] || WORKTREES_JSON="[]"

match_worktree() {
  # Echo the basename of the worktree belonging to board id $1, or nothing.
  # j.do names worktrees <id>-<slug>, and story bundles bundle-<id>.
  #
  # A task inside a story bundle has NO worktree of its own — the whole
  # bundle shares the story's one. So a task that matches nothing falls back
  # to its parent story's bundle worktree before being called worktree-less,
  # otherwise every task in every bundle reads as F6.
  local id="$1" base parent
  [[ -n "$id" ]] || return 0
  [[ "${#WORKTREE_NAMES[@]}" -gt 0 ]] || return 0
  for base in "${WORKTREE_NAMES[@]}"; do
    if [[ "$base" == "$id" || "$base" == "$id-"* || "$base" == "bundle-$id" ]]; then
      printf '%s' "$base"
      return 0
    fi
  done
  if [[ "$id" =~ ^(E[0-9]+_S[0-9]+)_T[0-9]+$ ]]; then
    parent="${BASH_REMATCH[1]}"
    for base in "${WORKTREE_NAMES[@]}"; do
      if [[ "$base" == "bundle-$parent" ]]; then
        printf '%s' "$base"
        return 0
      fi
    done
  fi
  return 0
}

# Story ids currently being executed as a bundle. j.do writes
# project/queue/bundle-<E##_S##>.json for the life of a bundle run and
# deletes it when the bundle concludes.
#
# WHY THIS GATES F5/F6 FOR STORIES. A story is normally "In Progress" simply
# because its tasks are, and it never gets a worktree of its own — only a
# bundle run does. Without this gate every In Progress story is reported as
# F6, which on this repository's real board was 8 findings out of 8, all
# false. A story's liveness is its tasks' liveness unless it is genuinely
# running as one unit.
BUNDLE_ROWS=""
if [[ -d "$QUEUE_DIR" ]]; then
  for bundle_file in "$QUEUE_DIR"/bundle-*.json; do
    [[ -f "$bundle_file" ]] || continue
    bundle_id="${bundle_file##*/}"
    bundle_id="${bundle_id#bundle-}"
    bundle_id="${bundle_id%.json}"
    BUNDLE_ROWS="${BUNDLE_ROWS}${bundle_id}"$'\n'
  done
fi

BUNDLES_JSON="$(printf '%s' "$BUNDLE_ROWS" | jq -R -s -c '
  split("\n") | map(select(length > 0))
' 2>/dev/null || printf '[]')"
[[ -n "$BUNDLES_JSON" ]] || BUNDLES_JSON="[]"

# ============================================================================
# SOURCE 5 — OS process liveness, via scripts/check-worktree-liveness.sh
# ============================================================================
#
# Probed ONLY for worktrees that a finding could actually be about: a completed
# agent's worktree (F2) and a declared-In-Progress item's worktree (F5). This
# repository carries ~60 worktrees and each probe is an lsof call, so probing
# all of them would make the collector unusably slow for no added signal.

PROBE_IDS=""
collect_probe_id() {
  local id="$1"
  [[ -n "$id" ]] || return 0
  case "$PROBE_IDS" in
    *"	$id	"*) return 0 ;;
  esac
  PROBE_IDS="${PROBE_IDS}	${id}	"
  return 0
}

while IFS= read -r agent_name; do
  [[ -n "$agent_name" ]] || continue
  collect_probe_id "$agent_name"
done <<< "$(printf '%s' "$AGENTS_JSON" | jq -r '.[] | select(.state == "completed") | .name' 2>/dev/null || true)"

while IFS= read -r board_id; do
  [[ -n "$board_id" ]] || continue
  collect_probe_id "$board_id"
done <<< "$(printf '%s' "$BOARD_JSON" | jq -r '.[].id' 2>/dev/null || true)"

PROBE_ROWS=""
ANY_UNDETERMINABLE=false
for probe_id in $(printf '%s' "$PROBE_IDS" | tr '\t' '\n' | sed '/^$/d'); do
  probe_wt="$(match_worktree "$probe_id")"
  if [[ -z "$probe_wt" ]]; then
    PROBE_ROWS="${PROBE_ROWS}${probe_id}"$'\t'$'\t'"absent"$'\t'"0"$'\n'
    continue
  fi
  probe_result="undeterminable"
  probe_count=0
  if [[ -x "$LIVENESS_SCRIPT" ]] || [[ -f "$LIVENESS_SCRIPT" ]]; then
    probe_out=""
    probe_rc=0
    probe_out="$(bash "$LIVENESS_SCRIPT" "$WORKTREE_DIR/$probe_wt" 2>/dev/null)" || probe_rc=$?
    case "$probe_rc" in
      0)
        probe_result="clear"
        probe_count=0
        ;;
      1)
        probe_result="live"
        # check-worktree-liveness.sh prints exactly one line per deduplicated
        # PID. printf needs the trailing newline or wc -l undercounts by one.
        probe_count="$(printf '%s\n' "$probe_out" | sed '/^$/d' | wc -l | tr -d ' ')"
        case "$probe_count" in ''|*[!0-9]*) probe_count=1 ;; esac
        [[ "$probe_count" -gt 0 ]] || probe_count=1
        ;;
      3)
        probe_result="absent"
        probe_count=0
        ;;
      *)
        # Exit 4 (neither lsof nor /proc available) and any other unexpected
        # code mean we DO NOT KNOW. That is deliberately not the same as clear.
        probe_result="undeterminable"
        probe_count=0
        ;;
    esac
  else
    add_note "check-worktree-liveness.sh not found at $LIVENESS_SCRIPT; OS process liveness is unknown"
  fi
  if [[ "$probe_result" == "undeterminable" ]]; then
    ANY_UNDETERMINABLE=true
  fi
  PROBE_ROWS="${PROBE_ROWS}${probe_id}"$'\t'"${probe_wt}"$'\t'"${probe_result}"$'\t'"${probe_count}"$'\n'
done

PROBES_JSON="$(printf '%s' "$PROBE_ROWS" | jq -R -s -c '
  split("\n") | map(select(length > 0)) | map(split("\t"))
  | map({
      id: .[0],
      worktree: (if (.[1] // "") == "" then null else .[1] end),
      result: (.[2] // "undeterminable"),
      count: ((.[3] // "0") | tonumber? // 0)
    })
' 2>/dev/null || printf '[]')"
[[ -n "$PROBES_JSON" ]] || PROBES_JSON="[]"

# ============================================================================
# SOURCE 6 — concurrency slot holders past TTL
# ============================================================================
#
# Slot file shape (scripts/acquire-concurrency-slot.sh header):
#   {"developer": {"cap": <int>, "holders": {"<holder-id>": "<ISO ts>"}}, ...}

SLOT_ROWS=""
SLOT_FILES_OTHER=0
if [[ -d "$QUEUE_DIR" ]]; then
  for slot_file in "$QUEUE_DIR"/concurrency-slots-*.json; do
    [[ -f "$slot_file" ]] || continue
    file_session="$(basename "$slot_file" | sed -e 's/^concurrency-slots-//' -e 's/\.json$//')"
    if [[ "$file_session" != "$CURRENT_SESSION" ]]; then
      SLOT_FILES_OTHER=$((SLOT_FILES_OTHER + 1))
    fi
    slot_holders="$(jq -r '
      to_entries[]
      | .key as $role
      | ((.value.holders // {}) | to_entries[] | "\($role)\t\(.key)\t\(.value)")
    ' "$slot_file" 2>/dev/null || true)"
    [[ -n "$slot_holders" ]] || continue
    while IFS= read -r holder_line; do
      [[ -n "$holder_line" ]] || continue
      SLOT_ROWS="${SLOT_ROWS}${file_session}"$'\t'"${holder_line}"$'\n'
    done <<< "$slot_holders"
  done
fi

SLOTS_JSON="$(printf '%s' "$SLOT_ROWS" | jq -R -s -c \
  --argjson now "$NOW_EPOCH" \
  --argjson ttl "$STALL_MINUTES" \
  --arg current "$CURRENT_SESSION" '
  split("\n") | map(select(length > 0)) | map(split("\t"))
  | map({session: .[0], role: .[1], holder: .[2], acquired_at: (.[3] // null)})
  | map(. + {
      age_minutes: (
        if ((.acquired_at | type) == "string")
        then (try (((($now - (.acquired_at | fromdateiso8601)) / 60) | floor)) catch null)
        else null end
      ),
      is_current: (.session == $current)
    })
  | map(select((.age_minutes != null) and (.age_minutes >= $ttl)))
' 2>/dev/null || printf '[]')"
[[ -n "$SLOTS_JSON" ]] || SLOTS_JSON="[]"

# ============================================================================
# SOURCE 7 — open lifecycle-phase frames (context only, never a finding)
# ============================================================================
#
# checklist-marker.sh read is scoped to THIS session by design and never fails
# the caller: no marker means no output and exit 0.

MARKER_PHASE=""
if [[ -f "$MARKER_SCRIPT" ]]; then
  MARKER_PHASE="$(bash "$MARKER_SCRIPT" read --field situation 2>/dev/null || true)"
  MARKER_PHASE="$(printf '%s' "$MARKER_PHASE" | tr -d '\r' | sed '/^$/d' | head -1 || true)"
fi
if [[ -n "$MARKER_PHASE" ]]; then
  add_note "a '$MARKER_PHASE' lifecycle phase is open in this session"
fi

# ============================================================================
# RESIDUE (counted, never touched)
# ============================================================================

UNDRAINED_TRIGGERS=0
if [[ -f "$QUEUE_DIR/scrum_triggers.jsonl" ]]; then
  UNDRAINED_TRIGGERS="$(wc -l < "$QUEUE_DIR/scrum_triggers.jsonl" 2>/dev/null | tr -d ' ' || printf '0')"
  case "$UNDRAINED_TRIGGERS" in ''|*[!0-9]*) UNDRAINED_TRIGGERS=0 ;; esac
fi

OPEN_RAPPORTS=0
if [[ -d "$RAPPORT_DIR" ]]; then
  OPEN_RAPPORTS="$(find "$RAPPORT_DIR" -type f -name "*.md" ! -name "*.IGNORE.md" 2>/dev/null | wc -l | tr -d ' ' || printf '0')"
  case "$OPEN_RAPPORTS" in ''|*[!0-9]*) OPEN_RAPPORTS=0 ;; esac
fi

STALE_WORKTREES=0
if [[ -d "$WORKTREE_DIR" ]]; then
  STALE_WORKTREES="$(find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +30 2>/dev/null | wc -l | tr -d ' ' || printf '0')"
  case "$STALE_WORKTREES" in ''|*[!0-9]*) STALE_WORKTREES=0 ;; esac
fi

OLDEST_RESIDUE="null"
if [[ -f "$QUEUE_DIR/scrum_triggers.jsonl" ]] && [[ -s "$QUEUE_DIR/scrum_triggers.jsonl" ]]; then
  oldest_trigger="$(jq -r -s 'map(select(type == "object") | .date // empty) | sort | first // empty' "$QUEUE_DIR/scrum_triggers.jsonl" 2>/dev/null || true)"
  if [[ -n "$oldest_trigger" ]]; then
    OLDEST_RESIDUE="$(printf '%s' "$oldest_trigger" | jq -R -s -c '.[0:-1] // .' 2>/dev/null || printf 'null')"
    [[ -n "$OLDEST_RESIDUE" ]] || OLDEST_RESIDUE="null"
  fi
fi

# ============================================================================
# BREAK ELIGIBILITY (E44_S10) — read-only; fails closed
# ============================================================================
#
# Produces BREAK_ELIGIBLE_JSON: {"<agent name>": "<one-sentence reason>"} for
# every running agent that is a dispatcher with queued work left. The jq in
# BUILD FINDINGS additionally requires idle in [warn, stall) because only the
# F1 info finding consults this map. Anything unreadable leaves the map empty
# (break_available false) and says so in visibility.notes rather than guessing.

BREAK_ELIGIBLE_JSON="{}"
BREAK_CANDIDATES=""
if [[ "$NO_AGENTS" == false ]]; then
  BREAK_CANDIDATES="$(printf '%s' "$AGENTS_JSON" | jq -r '.[] | select(.state == "running") | .name | select(test("^E[0-9]+(_S[0-9]+)?(_T[0-9]+)?$"))' 2>/dev/null || true)"
fi

break_item_status() {
  # Echo the board status of item $1, or nothing when no board file matches.
  local id="$1" f st
  for f in "$BOARD_DIR"/tasks/"$id"_*.md "$BOARD_DIR"/stories/"$id"_*.md "$BOARD_DIR"/epics/"$id"_*.md; do
    [[ -f "$f" ]] || continue
    st="$(sed -n '1,40p' "$f" 2>/dev/null | grep -m1 '^status:' | sed 's/^status:[[:space:]]*//' | tr -d '\r' || true)"
    printf '%s' "$st"
    return 0
  done
  return 0
}

break_is_terminal() {
  case "$1" in
    Passed|"Passed with remarks"|Merged|Done|"Deployed to Stage"|"Deployed to Prod"|Publicized|Failed|Rejected) return 0 ;;
  esac
  return 1
}

break_age_minutes() {
  # Echo whole minutes since ISO timestamp $1, or nothing when unparseable.
  jq -n -r --argjson now "$NOW_EPOCH" --arg s "$1" \
    'try ((($now - ($s | fromdateiso8601)) / 60) | floor) catch empty' 2>/dev/null || true
}

if [[ -n "$BREAK_CANDIDATES" ]]; then
  BREAK_SCRIPT="${JENGA_CHECKIN_BREAK_SCRIPT:-$(resolve_helper skills/j-break/scripts/check-break.sh)}"
  BREAK_TTL=""
  if [[ -f "$PROJECT_ROOT/project/configs/scope-thresholds.json" ]]; then
    BREAK_TTL="$(jq -r '.bundle_lock_ttl_minutes // empty' "$PROJECT_ROOT/project/configs/scope-thresholds.json" 2>/dev/null || true)"
  fi
  case "$BREAK_TTL" in ''|*[!0-9]*) BREAK_TTL="" ;; esac

  if [[ -z "$BREAK_SCRIPT" ]] || [[ ! -f "$BREAK_SCRIPT" ]]; then
    : # no consumption point, so no /break rung; a normal state, not a defect
  elif [[ -z "$BREAK_TTL" ]]; then
    add_note "bundle_lock_ttl_minutes unreadable, so /break eligibility could not be judged; the /break rung is withheld"
  else
    break_rc=0
    bash "$BREAK_SCRIPT" --peek >/dev/null 2>&1 || break_rc=$?
    if [[ "$break_rc" -eq 10 ]]; then
      : # a break is already pending, so offering one is moot
    elif [[ "$break_rc" -ne 0 ]]; then
      add_note "check-break.sh --peek failed (exit $break_rc), so /break eligibility could not be judged; the /break rung is withheld"
    else
      # Live epic locks, one "<epic_id>\t<bundle_story_id>" row per unexpired lock.
      LIVE_LOCKS=""
      for lock_file in "$QUEUE_DIR"/epic-lock-*.json; do
        [[ -f "$lock_file" ]] || continue
        lock_row="$(jq -r '[(.epic_id // ""), (.bundle_story_id // ""), (.started_at // "")] | @tsv' "$lock_file" 2>/dev/null || true)"
        if [[ -z "$lock_row" ]]; then
          add_note "epic lock ${lock_file##*/} is unreadable; /break eligibility for its epic could not be judged"
          continue
        fi
        IFS=$'\t' read -r lk_epic lk_story lk_started <<< "$lock_row"
        lk_age="$(break_age_minutes "$lk_started")"
        if [[ -n "$lk_age" ]] && [[ "$lk_age" -lt "$BREAK_TTL" ]]; then
          LIVE_LOCKS="${LIVE_LOCKS}${lk_epic}"$'\t'"${lk_story}"$'\n'
        fi
      done

      BREAK_ROWS=""
      while IFS= read -r cand; do
        [[ -n "$cand" ]] || continue
        cand_epic="${cand%%_*}"
        # The name must be backed by a live bundle manifest or a live epic lock.
        live_why=""
        manifest="$QUEUE_DIR/bundle-$cand.json"
        remaining=0
        if [[ -f "$manifest" ]]; then
          m_started="$(jq -r '.started_at // empty' "$manifest" 2>/dev/null || true)"
          m_age="$(break_age_minutes "$m_started")"
          if [[ -z "$m_age" ]]; then
            add_note "bundle manifest for $cand is unreadable or has no usable started_at; /break eligibility could not be judged"
          fi
          m_locked=false
          if printf '%s' "$LIVE_LOCKS" | cut -f2 | grep -qx -- "$cand"; then m_locked=true; fi
          if [[ "$m_locked" == true ]] || { [[ -n "$m_age" ]] && [[ "$m_age" -lt "$BREAK_TTL" ]]; }; then
            live_why="a live bundle for $cand"
            while IFS= read -r mt; do
              [[ -n "$mt" ]] || continue
              mt_status="$(break_item_status "$mt")"
              if ! break_is_terminal "$mt_status"; then remaining=$((remaining + 1)); fi
            done <<< "$(jq -r '.tasks[]? // empty' "$manifest" 2>/dev/null || true)"
          fi
        fi
        if [[ -z "$live_why" ]] && printf '%s' "$LIVE_LOCKS" | cut -f1 | grep -qx -- "$cand_epic"; then
          live_why="a live epic lock on $cand_epic"
        fi
        [[ -n "$live_why" ]] || continue

        # Queued work: unfinished manifest tasks, else live todo.md entries in this epic.
        if [[ "$remaining" -eq 0 ]] && [[ -f "$PROJECT_ROOT/project/todo.md" ]]; then
          in_comment=false
          while IFS= read -r tl || [[ -n "$tl" ]]; do
            tl="${tl#"${tl%%[![:space:]]*}"}"
            if [[ "$in_comment" == true ]]; then
              if [[ "$tl" == *"-->"* ]]; then in_comment=false; fi
              continue
            fi
            if [[ "$tl" == *"<!--"* ]]; then
              if [[ "$tl" != *"-->"* ]]; then in_comment=true; fi
              continue
            fi
            if [[ -z "$tl" ]] || [[ "$tl" == "#"* ]]; then continue; fi
            if [[ "$tl" =~ :[[:space:]]*(E[0-9]+(_S[0-9]+)?(_T[0-9]+)?)[[:space:]]*$ ]]; then
              td_id="${BASH_REMATCH[1]}"
              if [[ "${td_id%%_*}" != "$cand_epic" ]] || [[ "$td_id" == "$cand" ]]; then continue; fi
              td_status="$(break_item_status "$td_id")"
              if [[ -z "$td_status" ]] || break_is_terminal "$td_status"; then continue; fi
              remaining=$((remaining + 1))
            fi
          done < "$PROJECT_ROOT/project/todo.md"
        fi
        [[ "$remaining" -gt 0 ]] || continue
        BREAK_ROWS="${BREAK_ROWS}${cand}"$'\t'"${live_why} is running and $remaining item(s) are still queued; /break would stop new dispatch at the next task boundary and would not touch the running agent"$'\n'
      done <<< "$BREAK_CANDIDATES"

      BREAK_ELIGIBLE_JSON="$(printf '%s' "$BREAK_ROWS" | jq -R -s -c '
        split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries
      ' 2>/dev/null || printf '{}')"
      [[ -n "$BREAK_ELIGIBLE_JSON" ]] || BREAK_ELIGIBLE_JSON="{}"
    fi
  fi
fi

# ============================================================================
# BUILD FINDINGS
# ============================================================================

FINDINGS_JSON="$(jq -n -c \
  --argjson agents "$AGENTS_JSON" \
  --argjson activity "$ACTIVITY_JSON" \
  --argjson board "$BOARD_JSON" \
  --argjson worktrees "$WORKTREES_JSON" \
  --argjson probes "$PROBES_JSON" \
  --argjson slots "$SLOTS_JSON" \
  --argjson bundles "$BUNDLES_JSON" \
  --argjson break_ok "$BREAK_ELIGIBLE_JSON" \
  --argjson now "$NOW_EPOCH" \
  --argjson idle_warn "$IDLE_WARN_MINUTES" \
  --argjson stall "$STALL_MINUTES" '

  def esc($rung): {
    break_available: false,
    break_issued_at: null,
    grace_minutes: null,
    next_rung: $rung
  };

  # Only the healthy-but-long F1 info finding can be offered /break, and only
  # when the shell side proved the agent is a dispatcher with queued work.
  def esc_break($rung; $name):
    if ($break_ok[$name] // null) != null
    then esc($rung) + {break_available: true, break_reason: $break_ok[$name]}
    else esc($rung) end;

  def idle_of($iso):
    if ($iso | type) == "string"
    then (try (((($now - ($iso | fromdateiso8601)) / 60) | floor)) catch null)
    else null end;

  def probe_for($id): ($probes | map(select(.id == $id)) | first) // null;

  def seen_for($a):
    (if (($a.session_id | type) == "string")
     then ($activity.by_session[$a.session_id] // null)
     else null end)
    // ($activity.by_task[$a.name] // null);

  # ---- F1 / F2 / F13, per agent reported by ListAgents --------------------
  ([ $agents[]
     | . as $a
     | (seen_for($a)) as $seen
     | (idle_of($seen)) as $idle
     | (probe_for($a.name)) as $p
     | if $a.state == "running" then
         (if $idle == null then
            {
              code: "F13", severity: "warn", actionable: false,
              subject: {agent: $a.name, session_id: $a.session_id, task_id: $a.name},
              evidence: {
                listagents_state: "running",
                last_event_at: null,
                idle_minutes: null,
                stall_threshold_minutes: $stall,
                reason: "no dated event matched this agent by session_id or task_id"
              },
              escalation: esc("observe"),
              owning_skill: null
            }
          elif $idle >= $stall then
            {
              code: "F1", severity: "warn", actionable: true,
              subject: {agent: $a.name, session_id: $a.session_id, task_id: $a.name},
              evidence: {
                listagents_state: "running",
                last_event_at: $seen,
                idle_minutes: $idle,
                stall_threshold_minutes: $stall,
                worktree: ($p.worktree // null),
                worktree_live_processes: ($p.count // null)
              },
              escalation: esc("taskstop"),
              owning_skill: null
            }
          elif $idle >= $idle_warn then
            {
              code: "F1", severity: "info", actionable: false,
              subject: {agent: $a.name, session_id: $a.session_id, task_id: $a.name},
              evidence: {
                listagents_state: "running",
                last_event_at: $seen,
                idle_minutes: $idle,
                idle_warn_threshold_minutes: $idle_warn,
                stall_threshold_minutes: $stall,
                worktree: ($p.worktree // null),
                worktree_live_processes: ($p.count // null)
              },
              escalation: esc_break("observe"; $a.name),
              owning_skill: null
            }
          else empty end)
       elif $a.state == "completed" then
         (if ($p != null and $p.result == "live") then
            {
              code: "F2", severity: "warn", actionable: true,
              subject: {agent: $a.name, session_id: $a.session_id, task_id: $a.name},
              evidence: {
                listagents_state: "completed",
                last_event_at: $seen,
                worktree: $p.worktree,
                worktree_live_processes: $p.count
              },
              escalation: esc("observe"),
              owning_skill: null
            }
          else empty end)
       else empty end
   ])

  # ---- F5 / F6, per declared In Progress board item ----------------------
  + ([ $board[]
       | . as $b
       # A story is In Progress because its tasks are. Only a bundle run
       # makes the story itself the executing unit, so only then can its own
       # liveness be judged.
       | select($b.kind != "stories" or ($bundles | index($b.id) != null))
       | ($agents | map(select(.name == $b.id and .state == "running")) | length) as $live_agents
       | (probe_for($b.id)) as $p
       | (if ($p != null and $p.worktree != null) then 1 else 0 end) as $wt_count
       | if $live_agents > 0 then empty
         elif $wt_count == 0 then
           # A light/inline-scope item legitimately has no worktree — j.do
           # implements those against the current checkout. Flagging them
           # would make F6 pure noise on any board that uses those scopes.
           (if ($b.scope == "light" or $b.scope == "inline") then empty
            else
              {
                code: "F6", severity: "warn", actionable: true,
                subject: {agent: null, session_id: null, task_id: $b.id},
                evidence: {
                  board_status: "In Progress",
                  execution_scope: $b.scope,
                  worktree: null,
                  reason: "no worktree exists for a board item declared In Progress"
                },
                escalation: esc("observe"),
                owning_skill: "j.reconcile"
              }
            end)
         elif ($p != null and $p.result == "undeterminable") then empty
         elif ($p != null and $p.result == "live") then empty
         else
           {
             code: "F5", severity: "warn", actionable: true,
             subject: {agent: null, session_id: null, task_id: $b.id},
             evidence: {
               board_status: "In Progress",
               execution_scope: $b.scope,
               worktree: ($p.worktree // null),
               worktree_live_processes: ($p.count // 0),
               listagents_running_matches: 0,
               reason: "board declares In Progress but no agent is running and no process is rooted in its worktree"
             },
             escalation: esc("observe"),
             owning_skill: "j.reconcile"
           }
         end
     ])

  # ---- F3 / F4, per slot holder past TTL ---------------------------------
  + ([ $slots[]
       | . as $s
       | if $s.is_current then
           {
             code: "F3", severity: "info", actionable: false,
             subject: {agent: $s.role, session_id: $s.session, task_id: $s.holder},
             evidence: {
               role: $s.role,
               holder: $s.holder,
               acquired_at: $s.acquired_at,
               age_minutes: $s.age_minutes,
               ttl_minutes: $stall,
               reason: "acquire-concurrency-slot.sh already drops stale holders atomically before its cap check, so there is nothing to do by hand"
             },
             escalation: esc("observe"),
             owning_skill: null
           }
         else
           {
             code: "F4", severity: "info", actionable: false,
             subject: {agent: $s.role, session_id: $s.session, task_id: $s.holder},
             evidence: {
               role: $s.role,
               holder: $s.holder,
               acquired_at: $s.acquired_at,
               age_minutes: $s.age_minutes,
               ttl_minutes: $stall,
               reason: "another session owns this counter file; both slot scripts state they never read or write a counter file for any session other than their own"
             },
             escalation: esc("observe"),
             owning_skill: null
           }
         end
     ])

  # ---- F13, per probe that could not determine liveness ------------------
  + ([ $probes[]
       | select(.result == "undeterminable")
       | {
           code: "F13", severity: "warn", actionable: false,
           subject: {agent: null, session_id: null, task_id: .id},
           evidence: {
             worktree: .worktree,
             reason: "check-worktree-liveness.sh could not determine liveness (neither lsof nor /proc available); this is NOT the same as clear"
           },
           escalation: esc("observe"),
           owning_skill: null
         }
     ])
' 2>/dev/null || printf '[]')"
[[ -n "$FINDINGS_JSON" ]] || FINDINGS_JSON="[]"

# ============================================================================
# BUILD VISIBILITY
# ============================================================================

IN_SESSION="true"
AGENTS_INPUT="listagents"
BASE_NOTES='["lsof or /proc may be unavailable", "peer sessions unattributable without harness bridge"]'

if [[ "$NO_AGENTS" == "true" ]]; then
  IN_SESSION="false"
  AGENTS_INPUT="absent"
  BASE_NOTES='["harness agent list unavailable (--no-agents mode)", "on-disk evidence only"]'
fi

# cross_session: "none" the moment any probe could not determine liveness —
# a blind run must never read as a clean one.
CROSS_SESSION="partial"
if [[ "$ANY_UNDETERMINABLE" == "true" ]]; then
  CROSS_SESSION="none"
elif [[ "$WORKTREES_JSON" == "[]" ]]; then
  CROSS_SESSION="full"
fi

VISIBILITY="$(jq -n -c \
  --arg in_session "$IN_SESSION" \
  --arg cross "$CROSS_SESSION" \
  --arg agents "$AGENTS_INPUT" \
  --argjson notes "$BASE_NOTES" \
  --arg extra "$EXTRA_NOTES" '
  {
    in_session: ($in_session == "true"),
    cross_session: $cross,
    agents_input: $agents,
    notes: ($notes + ($extra | split("\t") | map(select(length > 0))))
  }')"

# ============================================================================
# BUILD COUNTS (derived from findings, never tracked by hand)
# ============================================================================

COUNTS="$(printf '%s' "$FINDINGS_JSON" | jq -c '
  {
    error: (map(select(.severity == "error")) | length),
    warn:  (map(select(.severity == "warn"))  | length),
    info:  (map(select(.severity == "info"))  | length)
  }' 2>/dev/null || printf '{"error":0,"warn":0,"info":0}')"

# ============================================================================
# BUILD RESIDUE
# ============================================================================

RESIDUE="$(jq -n -c \
  --argjson undrained "$UNDRAINED_TRIGGERS" \
  --argjson rapports "$OPEN_RAPPORTS" \
  --argjson slots "$SLOT_FILES_OTHER" \
  --argjson stale "$STALE_WORKTREES" \
  --argjson oldest "$OLDEST_RESIDUE" '
  {
    undrained_triggers: $undrained,
    open_rapports: $rapports,
    slot_files_other_sessions: $slots,
    stale_worktrees: $stale,
    oldest_residue_at: $oldest
  }')"

# ============================================================================
# EMIT FINAL JSON OBJECT
# ============================================================================

RESULT="$(jq -n \
  --arg generated_at "$GENERATED_AT" \
  --arg session_id "$CURRENT_SESSION" \
  --argjson visibility "$VISIBILITY" \
  --argjson findings "$FINDINGS_JSON" \
  --argjson residue "$RESIDUE" \
  --argjson counts "$COUNTS" '
  {
    generated_at: $generated_at,
    session_id: $session_id,
    visibility: $visibility,
    findings: $findings,
    residue: $residue,
    counts: $counts
  }')"

echo "$RESULT"
exit 0
