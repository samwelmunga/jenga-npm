#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/uncharted/scripts/elicitation-state.sh
#
# Deterministic persistence + turn-cap counting for `/uncharted`'s
# conversational convergence loop (E20_S08_T03) — the "propose understanding,
# confirm/correct" cycle that runs during `onboard`'s default (non-`--legacy`)
# flow and `segment --mode investigate`.
#
# Two problems this script exists to solve mechanically rather than leave to
# agent memory across a long, possibly multi-session conversation:
#
#   1. HARD TURN CAP (solution-assessment-uncharted-interactive-elicitation.md,
#      Problem 10). A convergence loop with no termination bound can run
#      forever on a genuinely hard case. `turn` increments a per-node
#      counter and exits 3 — not 0 — the instant the cap is reached, so the
#      caller gets an unmissable, mechanical stop signal instead of having to
#      remember to compare numbers itself.
#
#   2. MULTI-SESSION PERSISTENCE (same document, Problem 11). A whole-
#      codebase onboard conversation can span many sessions. `init` /
#      `checkpoint` / `pause` / `complete` / `list-paused` give the
#      conversation a durable, resumable state file, checkpointed after each
#      converged node (per that problem's RECOMMENDED solution) rather than
#      only at the very end.
#
# This script performs NO judgement — it does not decide what to ask, what
# counts as high-impact, or when understanding has actually converged. It
# only counts turns, tracks status, and persists whatever the agent asks it
# to persist. All of that judgement lives in skills/uncharted/SKILL.md's
# Convergence Loop subsection.
#
# ---------------------------------------------------------------------------
# STATE FILE
# ---------------------------------------------------------------------------
# project/queue/elicitation-state/<id>.json — one file per elicitation run
# (a whole `onboard` pass, or a single `segment --mode investigate` target).
# This directory is git-ignored (mirrors project/queue/handoffs/ — see
# templates/SCRUM_BOARD_SCHEMA.md): it is session-scratch resumability data,
# never a durable artifact. The durable output of a converged elicitation is
# the graph write (project/knowledge-graph/graph.json, per the stub schema at
# project/knowledge-graph/STUB_SCHEMA.md) and the `[ARCH]`-tagged board item —
# both written by the agent driving the flow, never by this script.
#
# Shape:
#   {
#     "id": "<id>",
#     "target": "<free text, e.g. the investigated path or description>",
#     "cap": <int>,               // hard turn cap, default 5
#     "status": "in_progress" | "paused" | "complete",
#     "created_at": "<ISO 8601 UTC>",
#     "updated_at": "<ISO 8601 UTC>",
#     "nodes": {
#       "<node-id>": { "turns": <int>, "status": "pending"|"converged"|"flagged", "note": "<text>" }
#     },
#     "checkpoint": { ...arbitrary, agent-defined fields, e.g. directory-triage results... }
#   }
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
# ---------------------------------------------------------------------------
#   init --id ID [--target TEXT] [--cap N]
#       Create the state file if it does not already exist (default cap 5,
#       per the solution assessment's "3-5 rounds" recommendation). Idempotent
#       — calling init again on an existing id returns the existing state
#       unchanged rather than resetting it, so a resumed session can call
#       init unconditionally without wiping progress.
#
#   turn --id ID --node NODE
#       Increment NODE's turn counter by one. Prints
#       {"turns": N, "cap": C, "cap_reached": true|false}. EXITS 3 (not 0)
#       when the increment reaches the cap — the node's status is also set to
#       "flagged" in the state file at that point, so the cap event is
#       durable, not just a transient exit code the caller might not act on.
#
#   converge --id ID --node NODE [--note TEXT]
#       Mark NODE's status "converged", independent of whether the cap was
#       ever hit (a node can converge on turn 1). Optional TEXT is stored as
#       the node's note (e.g. a one-line summary of what was confirmed).
#
#   checkpoint --id ID --json FILE
#       Shallow-merge the JSON object in FILE (or stdin when FILE is "-")
#       into the state's top-level "checkpoint" field. New keys are added;
#       existing keys are overwritten by the new value. This is the generic
#       "save progress" primitive — directory-triage results, draft node
#       content, anything else the flow wants durable before it might pause.
#
#   pause --id ID
#       Set status "paused" and update "updated_at". The caller (the agent
#       driving `/uncharted`) is responsible for also writing a scrum-master
#       SessionEnd handoff with status "elicitation_paused" and this state
#       file's path, per skills/uncharted/SKILL.md's Multi-Session
#       Persistence subsection — this script only updates the state file
#       itself, it does not write handoffs.
#
#   complete --id ID
#       Set status "complete" and update "updated_at". A completed
#       elicitation's state file is left on disk (not deleted) as an audit
#       trail of what was asked and confirmed; nothing currently prunes it.
#
#   status --id ID
#       Read-only. Prints the current state file, pretty-printed.
#
#   list-paused
#       Read-only. Prints a JSON array of every state file currently
#       "status": "paused" — {"id", "state_file", "target", "updated_at"} per
#       entry — for a resuming session (or on_session_end.sh's routing logic)
#       to discover what is waiting to be picked back up.
#
# ---------------------------------------------------------------------------
# CONCURRENCY
# ---------------------------------------------------------------------------
# Every mutating subcommand (init/turn/converge/checkpoint/pause/complete)
# wraps its read-modify-write in scripts/with-lock.sh, keyed to the target
# state file — the same atomic mkdir-based lock already used for board files
# and events.json (see hooks/on_session_end.sh and
# templates/SCRUM_BOARD_SCHEMA.md's File Locking section), not a new
# concurrency mechanism. The write itself is atomic (temp file in the same
# directory, then `mv`), matching the pattern in hooks/on_session_end.sh's
# own events.json append.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0 — success
#   1 — usage error: unknown subcommand/flag, missing required argument
#   2 — input error: state file missing for a subcommand that requires it
#       (everything except init/list-paused), or --json input unreadable/
#       not a JSON object
#   3 — turn cap reached (ONLY for `turn`; the increment still happened and
#       was persisted — this is a signal to stop looping, not a failure)
#   4 — write failure: could not acquire the lock, or the atomic write failed
#
# Examples:
#   elicitation-state.sh init --id onboard-2026-09-01 --target . --cap 5
#   elicitation-state.sh turn --id onboard-2026-09-01 --node billing-worker
#   elicitation-state.sh converge --id onboard-2026-09-01 --node billing-worker --note "confirmed: reconciles ledger entries"
#   echo '{"directory_triage": {...}}' | elicitation-state.sh checkpoint --id onboard-2026-09-01 --json -
#   elicitation-state.sh pause --id onboard-2026-09-01
#   elicitation-state.sh list-paused
#
# Requires: bash, python3, git (to resolve the repo root).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)

if [ -z "$REPO_ROOT" ]; then
  echo "elicitation-state.sh: could not resolve repository root from $SCRIPT_DIR (not inside a git work tree?)" >&2
  exit 2
fi

WITH_LOCK="$REPO_ROOT/scripts/with-lock.sh"
STATE_DIR="$REPO_ROOT/project/queue/elicitation-state"
DEFAULT_CAP=5

mkdir -p "$STATE_DIR"

usage() {
  cat <<'EOF'
Usage: elicitation-state.sh <subcommand> [options]

Subcommands:
  init --id ID [--target TEXT] [--cap N]
  turn --id ID --node NODE
  converge --id ID --node NODE [--note TEXT]
  checkpoint --id ID --json FILE|-
  pause --id ID
  complete --id ID
  status --id ID
  list-paused

See this script's own header comment for full semantics of each subcommand.

Exit codes: 0 success, 1 usage error, 2 input error, 3 turn cap reached
(only for `turn`), 4 write failure.
EOF
}

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi

SUBCOMMAND="$1"
shift

if [ "$SUBCOMMAND" = "-h" ] || [ "$SUBCOMMAND" = "--help" ]; then
  usage
  exit 0
fi

ID=""
NODE=""
TARGET=""
CAP="$DEFAULT_CAP"
NOTE=""
JSON_ARG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --id)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      ID="$2"; shift 2 ;;
    --node)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      NODE="$2"; shift 2 ;;
    --target)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      TARGET="$2"; shift 2 ;;
    --cap)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      CAP="$2"; shift 2 ;;
    --note)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      NOTE="$2"; shift 2 ;;
    --json)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      JSON_ARG="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "elicitation-state.sh: unknown argument '$1'" >&2
      exit 1 ;;
  esac
done

case "$SUBCOMMAND" in
  init|turn|converge|checkpoint|pause|complete|status)
    if [ -z "$ID" ]; then
      echo "elicitation-state.sh: --id is required for '$SUBCOMMAND'" >&2
      exit 1
    fi
    ;;
  list-paused)
    ;;
  *)
    echo "elicitation-state.sh: unknown subcommand '$SUBCOMMAND'" >&2
    exit 1
    ;;
esac

if [ "$SUBCOMMAND" = "turn" ] || [ "$SUBCOMMAND" = "converge" ]; then
  if [ -z "$NODE" ]; then
    echo "elicitation-state.sh: --node is required for '$SUBCOMMAND'" >&2
    exit 1
  fi
fi

if [ "$SUBCOMMAND" = "checkpoint" ] && [ -z "$JSON_ARG" ]; then
  echo "elicitation-state.sh: --json is required for 'checkpoint'" >&2
  exit 1
fi

if [ -n "$ID" ]; then
  STATE_FILE="$STATE_DIR/${ID}.json"
fi

# ---------------------------------------------------------------------------
# Read-only subcommands — no lock needed, nothing is mutated.
# ---------------------------------------------------------------------------

if [ "$SUBCOMMAND" = "status" ]; then
  if [ ! -f "$STATE_FILE" ]; then
    echo "elicitation-state.sh: no state file for id '$ID' ($STATE_FILE)" >&2
    exit 2
  fi
  python3 -m json.tool "$STATE_FILE"
  exit 0
fi

if [ "$SUBCOMMAND" = "list-paused" ]; then
  python3 -c '
import json, glob, os, sys

state_dir = sys.argv[1]
paused = []
for path in sorted(glob.glob(os.path.join(state_dir, "*.json"))):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        continue
    if data.get("status") == "paused":
        paused.append({
            "id": data.get("id", os.path.splitext(os.path.basename(path))[0]),
            "state_file": path,
            "target": data.get("target", ""),
            "updated_at": data.get("updated_at", ""),
        })
print(json.dumps(paused, indent=2))
' "$STATE_DIR"
  exit 0
fi

# ---------------------------------------------------------------------------
# Mutating subcommands — everything below goes through with-lock.sh.
# ---------------------------------------------------------------------------

if [ ! -f "$WITH_LOCK" ]; then
  echo "elicitation-state.sh: scripts/with-lock.sh not found at $WITH_LOCK" >&2
  exit 4
fi

if [ "$SUBCOMMAND" != "init" ] && [ ! -f "$STATE_FILE" ]; then
  echo "elicitation-state.sh: no state file for id '$ID' ($STATE_FILE) — run 'init' first" >&2
  exit 2
fi

# checkpoint's JSON payload is read here (outside the lock) so a bad/missing
# file fails fast with exit 2 before ever touching the lock.
CHECKPOINT_JSON="{}"
if [ "$SUBCOMMAND" = "checkpoint" ]; then
  if [ "$JSON_ARG" = "-" ]; then
    CHECKPOINT_JSON=$(cat)
  else
    if [ ! -f "$JSON_ARG" ]; then
      echo "elicitation-state.sh: --json file '$JSON_ARG' does not exist" >&2
      exit 2
    fi
    CHECKPOINT_JSON=$(cat "$JSON_ARG")
  fi
  if ! echo "$CHECKPOINT_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, dict)' 2>/dev/null; then
    echo "elicitation-state.sh: --json payload is not a JSON object" >&2
    exit 2
  fi
fi

# The update logic is captured as a standalone python3 script and run via
# `python3 -c` with every value passed as a positional argv entry (never
# interpolated into the script text), mirroring the same avoid-fragile-
# quoting convention hooks/on_session_end.sh already uses for its own
# events.json read-modify-write.
UPDATE_SCRIPT=$(cat <<'PYEOF'
import json, os, sys, tempfile, datetime

state_file, subcommand, elicitation_id, target, cap_s, node, note, checkpoint_json = sys.argv[1:9]

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def load():
    with open(state_file) as f:
        return json.load(f)

def atomic_write(data):
    dir_name = os.path.dirname(state_file)
    fd, tmp_path = tempfile.mkstemp(prefix=".elicitation_tmp.", dir=dir_name)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, state_file)
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise

result = {}
exit_code = 0

if subcommand == "init":
    if os.path.exists(state_file):
        state = load()
        result = {"created": False, "state": state}
    else:
        cap = int(cap_s)
        state = {
            "id": elicitation_id,
            "target": target,
            "cap": cap,
            "status": "in_progress",
            "created_at": now,
            "updated_at": now,
            "nodes": {},
            "checkpoint": {},
        }
        atomic_write(state)
        result = {"created": True, "state": state}

elif subcommand == "turn":
    state = load()
    nodes = state.setdefault("nodes", {})
    entry = nodes.setdefault(node, {"turns": 0, "status": "pending", "note": ""})
    entry["turns"] = entry.get("turns", 0) + 1
    cap = state.get("cap", int(cap_s))
    cap_reached = entry["turns"] >= cap
    if cap_reached:
        entry["status"] = "flagged"
    state["updated_at"] = now
    atomic_write(state)
    result = {"turns": entry["turns"], "cap": cap, "cap_reached": cap_reached}
    if cap_reached:
        exit_code = 3

elif subcommand == "converge":
    state = load()
    nodes = state.setdefault("nodes", {})
    entry = nodes.setdefault(node, {"turns": 0, "status": "pending", "note": ""})
    entry["status"] = "converged"
    if note:
        entry["note"] = note
    state["updated_at"] = now
    atomic_write(state)
    result = {"node": node, "status": "converged", "turns": entry.get("turns", 0)}

elif subcommand == "checkpoint":
    state = load()
    payload = json.loads(checkpoint_json)
    cp = state.setdefault("checkpoint", {})
    cp.update(payload)
    state["updated_at"] = now
    atomic_write(state)
    result = {"checkpoint_keys": list(payload.keys())}

elif subcommand == "pause":
    state = load()
    state["status"] = "paused"
    state["updated_at"] = now
    atomic_write(state)
    result = {"status": "paused"}

elif subcommand == "complete":
    state = load()
    state["status"] = "complete"
    state["updated_at"] = now
    atomic_write(state)
    result = {"status": "complete"}

else:
    sys.stderr.write("elicitation-state.sh: internal error — unhandled subcommand '%s'\n" % subcommand)
    sys.exit(1)

print(json.dumps(result, indent=2))
sys.exit(exit_code)
PYEOF
)

set +e
# NOTE: unlike `bash -c`, `python3 -c CODE arg1 arg2...` sets sys.argv[0] to
# the literal string "-c" (not the first following argument) — there is no
# python3 equivalent of bash's "$0 placeholder" convention. sys.argv[1:9]
# below therefore lines up directly with the positional arguments given here,
# with no placeholder needed.
"$WITH_LOCK" "$STATE_FILE" -- python3 -c "$UPDATE_SCRIPT" \
  "$STATE_FILE" "$SUBCOMMAND" "$ID" "$TARGET" "$CAP" "$NODE" "$NOTE" "$CHECKPOINT_JSON"
STATUS=$?
set -e

if [ "$STATUS" -eq 2 ]; then
  # with-lock.sh's own "could not acquire the lock" exit code — remap to
  # this script's write-failure code so callers have one code (4), not two,
  # to check for "the mutation did not happen".
  exit 4
fi

exit "$STATUS"
