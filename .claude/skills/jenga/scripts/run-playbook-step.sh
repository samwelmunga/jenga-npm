#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/run-playbook-step.sh
#
# Deterministic step-SEQUENCING state tracker for a confirmed playbook chain (E53_S02_T03). This
# script does NOT execute a skill step itself — invoking a skill's `SKILL.md` instructions (and,
# where applicable, loading `agents/<prefered_agent>.md`) is inherently the calling agent's job
# and cannot live in a shell script. What belongs in a script, per `CLAUDE.md`'s Skill
# Implementation Principle, is the deterministic bookkeeping around that: which step is current,
# which have completed, which have failed, and enforcing that a failure halts the sequence
# permanently with no silent skip-ahead — exactly the story's acceptance criterion for mid-chain
# failure handling.
#
# `/jenga`'s natural-language branch (wired in E53_S02_T04) uses this script as follows, after
# `render-playbook-confirmation.sh` (E53_S02_T03) returns a `confirmed` result:
#
#   1. `init` with the confirmed, ordered step list -> get the first step to invoke.
#   2. Invoke that step (as `/route`'s Step 6 already does for a single matched skill).
#   3. `advance <state_file> passed` (step succeeded) or `advance <state_file> failed [note]`
#      (step failed) -> get the next step, a "complete" signal, or (on failure) a halt report.
#   4. Repeat 2-3 until "complete" or a halt report is returned.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   run-playbook-step.sh init "<playbook_id>" "<name>" "<comma-separated confirmed step names>"
#       Starts a new run. Creates a state file tracking the ordered step list, a current-step
#       pointer (starts at the first step), and empty completed/failed lists. Emits the first
#       step's info as JSON on stdout and a `STATE_FILE:` path on stderr.
#
#   run-playbook-step.sh advance <state_file> passed
#       Records the CURRENT step as completed and advances the pointer. If more steps remain,
#       emits the next step's info as JSON (same shape as `init`'s stdout). If that was the last
#       step, emits a completion report instead (see OUTPUT SCHEMA) and removes the state file.
#
#   run-playbook-step.sh advance <state_file> failed ["<note>"]
#       Records the CURRENT step as failed (optionally with a free-text note) and halts the
#       sequence PERMANENTLY — the state file is marked `halted: true` rather than removed, so a
#       further `advance` call against it is rejected (see EXIT CODES). Emits a halt report (see
#       OUTPUT SCHEMA) listing completed / failed / never-run steps.
#
# ---------------------------------------------------------------------------
# OUTPUT SCHEMA
# ---------------------------------------------------------------------------
# `init` and a `passed` `advance` call that has more steps remaining both emit, on stdout:
#
#   {"status": "step_ready", "step": "<skill name>", "step_index": 2, "total_steps": 5}
#
# A `passed` `advance` call on the FINAL step emits, on stdout (state file removed):
#
#   {"status": "complete", "playbook_id": "...", "name": "...",
#    "completed": ["<step1>", "<step2>", ...]}
#
# A `failed` `advance` call emits, on stdout (state file retained, marked halted):
#
#   {"status": "halted", "playbook_id": "...", "name": "...",
#    "completed": ["<step1>", ...], "failed_step": "<stepN>", "failed_note": "<note or null>",
#    "never_run": ["<stepN+1>", ...]}
#
# Nothing else is ever written to stdout — errors/warnings go to stderr only.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   `init` succeeded; OR `advance passed` succeeded (whether it returned the next step or a
#       "complete" report); OR `advance failed` succeeded in recording the halt (a "halted" report
#       IS the expected, successful outcome of this call — exit 0, not an error)
#   2   usage error (missing/malformed arguments, unrecognized outcome word), or a real setup
#       problem (python3 unavailable, state file missing/corrupt)
#   3   `advance` called against a state file already marked `halted: true` from a prior `failed`
#       call — rejected outright rather than silently resuming; this is the "no skip-ahead, no
#       silent resumption after a halt" guard the story's acceptance criteria require
#
# ---------------------------------------------------------------------------

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by run-playbook-step.sh" >&2
  exit 2
fi

if [ $# -lt 1 ]; then
  echo "Usage:" >&2
  echo "  run-playbook-step.sh init \"<playbook_id>\" \"<name>\" \"<comma-separated confirmed step names>\"" >&2
  echo "  run-playbook-step.sh advance <state_file> passed" >&2
  echo "  run-playbook-step.sh advance <state_file> failed [\"<note>\"]" >&2
  exit 2
fi

SUBCOMMAND="$1"
shift

if [ "$SUBCOMMAND" = "init" ]; then
  if [ $# -ne 3 ]; then
    echo 'Usage: run-playbook-step.sh init "<playbook_id>" "<name>" "<comma-separated steps>"' >&2
    exit 2
  fi
  PLAYBOOK_ID="$1"
  PLAYBOOK_NAME="$2"
  RAW_STEPS="$3"

  if [ -z "${RAW_STEPS// /}" ]; then
    echo "Error: no steps given to run-playbook-step.sh init" >&2
    exit 2
  fi

  STATE_FILE="$(mktemp -t jenga-playbook-run-XXXXXX.json)"

  PY_SCRIPT="$(mktemp -t run-playbook-step-init-XXXXXX.py)"
  trap 'rm -f "$PY_SCRIPT"' EXIT

  cat > "$PY_SCRIPT" <<'PY'
import json
import sys
from datetime import datetime, timezone

state_file_path = sys.argv[1]
playbook_id = sys.argv[2]
playbook_name = sys.argv[3]
raw_steps = sys.argv[4]

steps = [s.strip() for s in raw_steps.split(",") if s.strip() != ""]
if not steps:
    print("Error: no valid step names parsed from the given list", file=sys.stderr)
    sys.exit(2)

state = {
    "version": 1,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "playbook_id": playbook_id,
    "playbook_name": playbook_name,
    "steps": steps,
    "current_index": 0,
    "completed": [],
    "halted": False,
    "failed_step": None,
    "failed_note": None,
}

with open(state_file_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")

print(json.dumps({
    "status": "step_ready",
    "step": steps[0],
    "step_index": 1,
    "total_steps": len(steps),
}))
print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
PY

  python3 "$PY_SCRIPT" "$STATE_FILE" "$PLAYBOOK_ID" "$PLAYBOOK_NAME" "$RAW_STEPS"
  exit 0

elif [ "$SUBCOMMAND" = "advance" ]; then
  if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo 'Usage: run-playbook-step.sh advance <state_file> passed|failed ["<note>"]' >&2
    exit 2
  fi
  STATE_FILE="$1"
  OUTCOME="$2"
  NOTE="${3:-}"

  if [ "$OUTCOME" != "passed" ] && [ "$OUTCOME" != "failed" ]; then
    echo "Error: outcome must be 'passed' or 'failed', got '$OUTCOME'" >&2
    exit 2
  fi

  if [ ! -f "$STATE_FILE" ]; then
    echo "Error: state file not found at $STATE_FILE" >&2
    echo "The playbook run may have expired (e.g. temp dir was cleared), or already completed." >&2
    exit 2
  fi

  PY_SCRIPT="$(mktemp -t run-playbook-step-advance-XXXXXX.py)"
  trap 'rm -f "$PY_SCRIPT"' EXIT

  cat > "$PY_SCRIPT" <<'PY'
import json
import os
import sys

state_file_path = sys.argv[1]
outcome = sys.argv[2]
note = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != "" else None

try:
    with open(state_file_path, encoding="utf-8") as f:
        state = json.load(f)
except Exception as e:
    print(f"Error: could not read/parse state file at {state_file_path}: {e}", file=sys.stderr)
    sys.exit(2)

if state.get("halted"):
    print(
        f"Error: this playbook run already halted on step '{state.get('failed_step')}'. "
        "A further advance() call is rejected -- no silent resumption after a halt. "
        "Start a new run with run-playbook-step.sh init if you want to retry.",
        file=sys.stderr,
    )
    sys.exit(3)

steps = state["steps"]
idx = state["current_index"]

if idx >= len(steps):
    print(f"Error: state file at {state_file_path} has no current step (already complete).", file=sys.stderr)
    sys.exit(2)

current_step = steps[idx]

if outcome == "failed":
    state["halted"] = True
    state["failed_step"] = current_step
    state["failed_note"] = note
    never_run = steps[idx + 1:]

    with open(state_file_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
        f.write("\n")

    print(json.dumps({
        "status": "halted",
        "playbook_id": state["playbook_id"],
        "name": state["playbook_name"],
        "completed": state["completed"],
        "failed_step": current_step,
        "failed_note": note,
        "never_run": never_run,
    }))
    sys.exit(0)

# outcome == "passed"
state["completed"].append(current_step)
state["current_index"] = idx + 1

if state["current_index"] >= len(steps):
    result = {
        "status": "complete",
        "playbook_id": state["playbook_id"],
        "name": state["playbook_name"],
        "completed": state["completed"],
    }
    try:
        os.remove(state_file_path)
    except OSError:
        pass
    print(json.dumps(result))
    sys.exit(0)

with open(state_file_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")

next_step = steps[state["current_index"]]
print(json.dumps({
    "status": "step_ready",
    "step": next_step,
    "step_index": state["current_index"] + 1,
    "total_steps": len(steps),
}))
print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
PY

  python3 "$PY_SCRIPT" "$STATE_FILE" "$OUTCOME" "$NOTE"
  exit $?

else
  echo "Error: unrecognized subcommand '$SUBCOMMAND' (expected 'init' or 'advance')" >&2
  exit 2
fi
