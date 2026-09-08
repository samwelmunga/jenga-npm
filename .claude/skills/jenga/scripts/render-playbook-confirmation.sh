#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/render-playbook-confirmation.sh
#
# Turn-by-turn checkbox-list confirmation renderer for a matched PLAYBOOK's ordered `steps`
# (E53_S02_T03). Used by `/jenga`'s natural-language branch after `match-playbook.sh`
# (E53_S02_T02) reports a `playbook_match` — renders the proposed chain as an editable, numbered,
# checked-by-default list the user must confirm before any step executes, per this story's
# acceptance criteria and `CLAUDE.md`'s Interaction Pattern. This mirrors
# `render-confirmation.sh`'s (E45_S02_T02) exact UX idiom and two-invocation state-file mechanics,
# scoped down from a nested Epic/Story/Task tree to a flat ordered step list.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A TWO-INVOCATION, STATE-FILE SCRIPT
# ---------------------------------------------------------------------------
# Same constraint as `render-confirmation.sh`/`render-picker.sh`: the Bash tool runs a command to
# completion and returns — it cannot block mid-script waiting on the user's next chat message. So
# this confirmation screen is split across (at least) two invocations of this same script,
# coordinated by the calling agent (`/jenga`'s SKILL.md, wired in E53_S02_T04), never by this
# script itself. See `render-confirmation.sh`'s own header for the full rationale — it applies
# here verbatim; this comment does not re-derive it a second time.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   render-playbook-confirmation.sh "<playbook_id>" "<name>" "<comma-separated ordered step names>"
#       Start a new confirmation session. `<playbook_id>` and `<name>` come straight from
#       `match-playbook.sh`'s `playbook_match` output; `<comma-separated ordered step names>` is
#       that same output's `steps` array joined with commas, in original playbook order.
#
#   render-playbook-confirmation.sh <state_file> "<raw_reply>"
#       Continue an existing confirmation session. <state_file> is the path printed on STDERR by
#       the start-mode invocation (or by any prior continue-mode invocation). <raw_reply> is the
#       user's raw chat text for this turn.
#
# ---------------------------------------------------------------------------
# TOGGLE COMMAND GRAMMAR (identical to render-confirmation.sh — no cascade, since steps are flat)
# ---------------------------------------------------------------------------
#   cancel                  Abort the session. State file removed.
#   confirm                 Finalize with the CURRENT checked state.
#   check <numbers>         Set the listed displayed number(s) to checked.
#   uncheck <numbers>       Set the listed displayed number(s) to unchecked.
#   <numbers>               Bare numbers TOGGLE the current checked state of each listed number.
#
# <numbers> is a comma- and/or whitespace-separated list of positive integers. Validation is
# ALL-OR-NOTHING per turn: if a reply contains any non-numeric token or any number outside the
# valid 1..N range, the ENTIRE turn is rejected as an error turn (state left untouched) — no
# partial application of the valid numbers in a mixed-validity reply. There is no cascading
# behavior here (unlike render-confirmation.sh's Epic->Story->Task cascade) — a playbook's steps
# are a flat ordered list with no parent/child relationship.
#
# ---------------------------------------------------------------------------
# OUTPUT CONTRACT
# ---------------------------------------------------------------------------
#   - Start mode, and continue-mode TOGGLE / ERROR turns:
#       STDOUT = plain human-readable text (the numbered list + instructions, or an error message
#                + retry instructions) — relayed verbatim to the user.
#       STDERR = `STATE_FILE: <absolute path>` — for the calling AGENT only, never relayed.
#
#   - Continue mode, CONFIRMED (final) turn:
#       STDOUT = a single JSON object: {"status": "confirmed", "playbook_id": "...",
#                "name": "...", "steps": ["<checked step1>", ...]} — checked-only steps, in
#                ORIGINAL PLAYBOOK ORDER regardless of what order they were un/re-checked in.
#                NOT meant to be relayed to the user verbatim.
#       STDERR = empty (state file removed).
#
#   - Continue mode, CANCELLED (`cancel` reply, case-insensitive):
#       STDOUT = plain human-readable cancellation acknowledgement — behaviorally identical to
#                render-confirmation.sh's and render-picker.sh's own cancellation handling: same
#                "nothing will run" framing, same exit code (3).
#       STDERR = empty (state file removed).
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   start mode rendered successfully; OR continue mode applied a toggle/check/uncheck command
#       and re-rendered the list; OR continue mode fully confirmed (final JSON emitted)
#   1   continue mode: at least one invalid/out-of-range number, or no numbers found, in the
#       reply — an error turn was emitted, retry with the same state file
#   2   usage error, or a real setup problem (python3 unavailable, state file missing/corrupt)
#   3   continue mode: user replied "cancel" — session aborted, state file removed
#
# ---------------------------------------------------------------------------

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by render-playbook-confirmation.sh" >&2
  exit 2
fi

if [ $# -eq 3 ]; then
  MODE="start"
  PLAYBOOK_ID="$1"
  PLAYBOOK_NAME="$2"
  RAW_STEPS="$3"
elif [ $# -eq 2 ]; then
  MODE="continue"
  STATE_FILE="$1"
  RAW_REPLY="$2"
else
  echo "Usage:" >&2
  echo "  render-playbook-confirmation.sh \"<playbook_id>\" \"<name>\" \"<comma-separated ordered step names>\"   # start" >&2
  echo "  render-playbook-confirmation.sh <state_file> \"<raw_reply>\"                                            # continue" >&2
  exit 2
fi

if [ "$MODE" = "start" ]; then
  if [ -z "${RAW_STEPS// /}" ]; then
    echo "Error: no steps given to render-playbook-confirmation.sh" >&2
    exit 2
  fi

  STATE_FILE="$(mktemp -t jenga-playbook-confirm-XXXXXX.json)"

  PY_SCRIPT="$(mktemp -t render-playbook-confirmation-start-XXXXXX.py)"
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

numbering = {}
for i, step in enumerate(steps, start=1):
    numbering[str(i)] = {"step": step, "checked": True}

total = len(numbering)

state = {
    "version": 1,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "playbook_id": playbook_id,
    "playbook_name": playbook_name,
    "total_steps": total,
    "order": [str(i) for i in range(1, total + 1)],
    "numbering": numbering,
}

with open(state_file_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")


def render_body():
    lines = []
    for n in state["order"]:
        rec = numbering[n]
        box = "[x]" if rec["checked"] else "[ ]"
        lines.append(f"  {box} {n}. {rec['step']}")
    return lines


def render_footer():
    checked = sum(1 for rec in numbering.values() if rec["checked"])
    unchecked = total - checked
    line = f"Currently checked: {checked} of {total} step(s)."
    if unchecked:
        line += f" {unchecked} step(s) unchecked and will be skipped."
    return line


header = [
    "=" * 68,
    f" /jenga -- Proposed Playbook: {playbook_name} ({playbook_id})",
    "=" * 68,
    "This looks like a multi-step workflow. Here is the proposed chain, in order.",
    "Everything below is checked [x] by default. Uncheck steps you do NOT want",
    "to run, or re-check steps you previously unchecked, by number.",
    "",
    "Commands:",
    '  check <numbers>    -- check the listed step(s), e.g. "check 3,5"',
    '  uncheck <numbers>  -- uncheck the listed step(s), e.g. "uncheck 2"',
    '  <numbers>          -- bare numbers toggle their current state',
    '  confirm            -- proceed with the currently checked steps, in order',
    '  cancel             -- abort, nothing will run',
    "-" * 68,
    "",
]

body = render_body()

footer = [
    "",
    "-" * 68,
    render_footer(),
    "",
    'Reply with a command ("check N,N", "uncheck N,N", bare numbers to toggle, "confirm", or "cancel").',
]

print("\n".join(header + body + footer))
print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
PY

  python3 "$PY_SCRIPT" "$STATE_FILE" "$PLAYBOOK_ID" "$PLAYBOOK_NAME" "$RAW_STEPS"
  exit 0
fi

# --------------------------------------------------------------------------
# continue mode
# --------------------------------------------------------------------------

if [ ! -f "$STATE_FILE" ]; then
  echo "Error: state file not found at $STATE_FILE" >&2
  echo "The confirmation session may have expired (e.g. temp dir was cleared)." >&2
  echo "Start a new confirmation session with: render-playbook-confirmation.sh \"<playbook_id>\" \"<name>\" \"<steps>\"" >&2
  exit 2
fi

PY_SCRIPT="$(mktemp -t render-playbook-confirmation-continue-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PY'
import json
import os
import re
import sys

state_file_path = sys.argv[1]
raw_reply = sys.argv[2]

try:
    with open(state_file_path, encoding="utf-8") as f:
        state = json.load(f)
except Exception as e:
    print(f"Error: could not read/parse state file at {state_file_path}: {e}", file=sys.stderr)
    sys.exit(2)

numbering = state["numbering"]
order = state["order"]
total = state["total_steps"]
playbook_id = state["playbook_id"]
playbook_name = state["playbook_name"]


def render_body():
    lines = []
    for n in order:
        rec = numbering[n]
        box = "[x]" if rec["checked"] else "[ ]"
        lines.append(f"  {box} {n}. {rec['step']}")
    return lines


def render_footer():
    checked = sum(1 for rec in numbering.values() if rec["checked"])
    unchecked = total - checked
    line = f"Currently checked: {checked} of {total} step(s)."
    if unchecked:
        line += f" {unchecked} step(s) unchecked and will be skipped."
    return line


stripped = raw_reply.strip()
lowered = stripped.lower()

if lowered == "cancel":
    try:
        os.remove(state_file_path)
    except OSError:
        pass
    print("Confirmation session cancelled. Nothing will run.")
    sys.exit(3)

if lowered == "confirm":
    checked_steps = [numbering[n]["step"] for n in order if numbering[n]["checked"]]

    result = {
        "status": "confirmed",
        "playbook_id": playbook_id,
        "name": playbook_name,
        "steps": checked_steps,
    }

    try:
        os.remove(state_file_path)
    except OSError:
        pass

    print(json.dumps(result, indent=2))
    sys.exit(0)

action = "toggle"
tokens_source = stripped
prefix_match = re.match(r'^(check|uncheck)\b(.*)$', stripped, re.IGNORECASE)
if prefix_match:
    action = prefix_match.group(1).lower()
    tokens_source = prefix_match.group(2)

raw_tokens = tokens_source.replace(",", " ").split()
tokens = [tok.strip() for tok in raw_tokens if tok.strip() != ""]

if not tokens:
    print("Error: no selection numbers found in your reply.")
    print("")
    print('Reply with a command: "check N,N", "uncheck N,N", bare numbers to toggle, "confirm", or "cancel".')
    print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
    sys.exit(1)

invalid = []
valid_tokens = []
for tok in tokens:
    if not re.fullmatch(r"[0-9]+", tok):
        invalid.append((tok, "not a whole number"))
        continue
    if tok not in numbering:
        invalid.append((tok, f"out of range (valid: 1-{total})"))
        continue
    valid_tokens.append(tok)

if invalid:
    print("Error: your reply contains invalid selection number(s):")
    for tok, reason in invalid:
        print(f"  - '{tok}': {reason}")
    print("")
    print(f"Valid selection numbers for this session are 1-{total}.")
    print('Reply again with a corrected command ("check N,N", "uncheck N,N", bare numbers, "confirm", or "cancel").')
    print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
    sys.exit(1)

seen = set()
for tok in valid_tokens:
    if tok in seen:
        continue
    seen.add(tok)
    if action == "check":
        numbering[tok]["checked"] = True
    elif action == "uncheck":
        numbering[tok]["checked"] = False
    else:
        numbering[tok]["checked"] = not numbering[tok]["checked"]

state["numbering"] = numbering
with open(state_file_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")

output_lines = ["Updated:", ""] + render_body() + [
    "",
    "-" * 68,
    render_footer(),
    "",
    'Reply with another command ("check N,N", "uncheck N,N", bare numbers to toggle, "confirm", or "cancel").',
]

print("\n".join(output_lines))
print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
sys.exit(0)
PY

python3 "$PY_SCRIPT" "$STATE_FILE" "$RAW_REPLY"
exit $?
