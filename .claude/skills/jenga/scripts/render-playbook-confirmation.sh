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
#   render-playbook-confirmation.sh "<playbook_id>" "<name>" "<comma-separated ordered step names>" ["<json-conditionals>" ["<json-origins>"]]
#       Start a new confirmation session. `<playbook_id>` and `<name>` come straight from
#       `match-playbook.sh`'s `playbook_match` output; `<comma-separated ordered step names>` is
#       that same output's `steps` array joined with commas, in original playbook order.
#
#       `<json-conditionals>` is OPTIONAL (E53_S04_T04). When given, it is a JSON object mapping a
#       conditional step's name -> the name of the EARLIER step it depends on, e.g.
#       `{"stepC": "stepA"}`. Only steps that actually carry a conditional (per `load-playbooks.sh`'s
#       StepObject `conditional` field, resolved by the calling agent from the playbook's raw
#       StepObject data before invoking this script -- this script owns only the RENDERING side of
#       that contract, never the resolution of it) appear as keys. Omitting this argument (the
#       original 3-arg form) renders the chain exactly as before this task -- fully backward
#       compatible.
#
#       `<json-origins>` is OPTIONAL (E53_S05_T03), and may only be given when `<json-conditionals>`
#       is also given (pass `"{}"` for conditionals if there are none, to reach the 5th slot). It is
#       a JSON object mapping a composed/nested step's name -> `{"playbook_id": "...", "depth": N}`,
#       for every step whose `_origin_depth` (per `load-playbooks.sh`'s catalog output, E53_S05_T01)
#       is greater than 1. Steps absent from this object are depth-1 (the top-level playbook's own
#       steps) and render exactly as before this task. The calling agent (`/jenga`'s
#       natural-language branch, wired in E53_S05_T07) resolves this metadata from
#       `load-playbooks.sh`'s catalog output before invoking this script -- this script owns only
#       the RENDERING side of that contract, mirroring `<json-conditionals>`'s own scope boundary.
#       Omitting this argument entirely reproduces the exact pre-this-task behavior, fully backward
#       compatible.
#
#   render-playbook-confirmation.sh <state_file> "<raw_reply>"
#       Continue an existing confirmation session. <state_file> is the path printed on STDERR by
#       the start-mode invocation (or by any prior continue-mode invocation). <raw_reply> is the
#       user's raw chat text for this turn. The conditional markers and origin/nesting annotations
#       (if any) persist across continue-mode re-renders automatically -- they are stored in the
#       state file, computed once at start, and never recomputed from arguments.
#
# ---------------------------------------------------------------------------
# CONDITIONAL MARKER DISPLAY (E53_S04_T02 / E53_S04_T04)
# ---------------------------------------------------------------------------
# A step whose name is a key in the conditionals map gets a visible suffix appended to its line in
# the rendered chain: " (may be skipped depending on step N's result)", where N is the 1-indexed
# DISPLAY POSITION (per this session's `order`, not necessarily the original playbook array index)
# of the step it depends on. This makes the chain's real conditional structure visible before
# confirmation, per the story's explicit requirement that confirming a chain never hides its real
# step count or conditional structure from the user. This is display-only: it does not change
# checked/unchecked mechanics, does not add a new toggle command, and unchecking a conditional step
# (or the step it depends on) behaves exactly like unchecking any other step -- the ACTUAL runtime
# skip decision is `run-playbook-step.sh should-skip`'s job, entirely independent of what a user
# checks/unchecks here.
#
# ---------------------------------------------------------------------------
# NESTED/ORIGIN DISPLAY (E53_S05_T03)
# ---------------------------------------------------------------------------
# A step whose name is a key in the origins map (depth > 1, i.e. it was spliced in from a composed
# playbook) gets TWO visual treatments on its rendered line, applied together:
#   - two extra leading spaces of indentation before the checkbox, visually grouping it apart from
#     depth-1 (top-level) steps, and
#   - a trailing annotation: " (from playbook: <playbook_id>, depth <N>)".
# This is display-only, exactly like the conditional marker, and composes freely with it on the
# same line (origin annotation first, conditional marker after) -- both are independent,
# orthogonal annotations. Numbering stays FLAT 1..N across the WHOLE list regardless of nesting --
# there is still exactly ONE overall numbered, editable, confirmable list, never a separate
# confirmation per nested playbook, per `CLAUDE.md`'s Interaction Pattern. A playbook with no
# depth > 1 steps (the `origins` map is empty or the argument was omitted) renders identically to
# before this task -- no indentation, no annotation, byte-for-byte unchanged.
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

if [ $# -eq 3 ] || [ $# -eq 4 ] || [ $# -eq 5 ]; then
  MODE="start"
  PLAYBOOK_ID="$1"
  PLAYBOOK_NAME="$2"
  RAW_STEPS="$3"
  RAW_CONDITIONALS="${4:-}"
  RAW_ORIGINS="${5:-}"
elif [ $# -eq 2 ]; then
  MODE="continue"
  STATE_FILE="$1"
  RAW_REPLY="$2"
else
  echo "Usage:" >&2
  echo "  render-playbook-confirmation.sh \"<playbook_id>\" \"<name>\" \"<comma-separated ordered step names>\" [\"<json-conditionals>\" [\"<json-origins>\"]]   # start" >&2
  echo "  render-playbook-confirmation.sh <state_file> \"<raw_reply>\"                                                                                          # continue" >&2
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
raw_conditionals = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] != "" else None
raw_origins = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] != "" else None

steps = [s.strip() for s in raw_steps.split(",") if s.strip() != ""]

if not steps:
    print("Error: no valid step names parsed from the given list", file=sys.stderr)
    sys.exit(2)

numbering = {}
for i, step in enumerate(steps, start=1):
    numbering[str(i)] = {"step": step, "checked": True}

total = len(numbering)

conditionals = {}
if raw_conditionals is not None:
    try:
        parsed = json.loads(raw_conditionals)
    except Exception as e:
        print(f"Error: <json-conditionals> is not valid JSON: {e}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(parsed, dict):
        print("Error: <json-conditionals> must be a JSON object", file=sys.stderr)
        sys.exit(2)
    for step_name, depends_on in parsed.items():
        if step_name not in steps:
            print(f"Error: conditional given for '{step_name}', which is not in the step list", file=sys.stderr)
            sys.exit(2)
        if not isinstance(depends_on, str) or depends_on not in steps:
            print(f"Error: conditional for '{step_name}' depends_on '{depends_on}', which is not a step in this playbook", file=sys.stderr)
            sys.exit(2)
        conditionals[step_name] = depends_on

# --- E53_S05_T03: origin/nesting metadata (depth > 1 steps only) ---
origins = {}
if raw_origins is not None:
    try:
        parsed = json.loads(raw_origins)
    except Exception as e:
        print(f"Error: <json-origins> is not valid JSON: {e}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(parsed, dict):
        print("Error: <json-origins> must be a JSON object", file=sys.stderr)
        sys.exit(2)
    for step_name, meta in parsed.items():
        if step_name not in steps:
            print(f"Error: origin metadata given for '{step_name}', which is not in the step list", file=sys.stderr)
            sys.exit(2)
        if (
            not isinstance(meta, dict)
            or not isinstance(meta.get("playbook_id"), str)
            or not meta.get("playbook_id")
            or not isinstance(meta.get("depth"), int)
            or isinstance(meta.get("depth"), bool)
            or meta.get("depth") <= 1
        ):
            print(
                f"Error: origin metadata for '{step_name}' must be an object with a non-empty "
                f"string 'playbook_id' and an integer 'depth' > 1",
                file=sys.stderr,
            )
            sys.exit(2)
        origins[step_name] = {"playbook_id": meta["playbook_id"], "depth": meta["depth"]}

state = {
    "version": 1,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "playbook_id": playbook_id,
    "playbook_name": playbook_name,
    "total_steps": total,
    "order": [str(i) for i in range(1, total + 1)],
    "numbering": numbering,
    "conditionals": conditionals,
    "origins": origins,
}

with open(state_file_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")


def conditional_marker(step_name):
    """" (may be skipped depending on step N's result)" for a conditional step, else ''."""
    depends_on = conditionals.get(step_name)
    if not depends_on:
        return ""
    for n in state["order"]:
        if numbering[n]["step"] == depends_on:
            return f" (may be skipped depending on step {n}'s result)"
    return ""  # depends_on step not found in this display's order -- defensive, should not happen


def origin_indent_and_marker(step_name):
    """(indent, suffix) for a depth>1 (composed/nested) step, else ('', ''). See header 'NESTED/
    ORIGIN DISPLAY' -- indentation groups nested steps visually; the suffix names the originating
    playbook and depth. Numbering itself is never affected -- still flat 1..N."""
    meta = origins.get(step_name)
    if not meta:
        return "", ""
    return "  ", f" (from playbook: {meta['playbook_id']}, depth {meta['depth']})"


def render_body():
    lines = []
    for n in state["order"]:
        rec = numbering[n]
        box = "[x]" if rec["checked"] else "[ ]"
        indent, origin_suffix = origin_indent_and_marker(rec["step"])
        lines.append(f"{indent}  {box} {n}. {rec['step']}{origin_suffix}{conditional_marker(rec['step'])}")
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

  python3 "$PY_SCRIPT" "$STATE_FILE" "$PLAYBOOK_ID" "$PLAYBOOK_NAME" "$RAW_STEPS" "$RAW_CONDITIONALS" "$RAW_ORIGINS"
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
conditionals = state.get("conditionals", {})
origins = state.get("origins", {})


def conditional_marker(step_name):
    """" (may be skipped depending on step N's result)" for a conditional step, else ''."""
    depends_on = conditionals.get(step_name)
    if not depends_on:
        return ""
    for n in order:
        if numbering[n]["step"] == depends_on:
            return f" (may be skipped depending on step {n}'s result)"
    return ""  # depends_on step not found in this display's order -- defensive, should not happen


def origin_indent_and_marker(step_name):
    """(indent, suffix) for a depth>1 (composed/nested) step, else ('', ''). Read from the state
    file's persisted `origins` map -- never recomputed from arguments on a continue-mode turn."""
    meta = origins.get(step_name)
    if not meta:
        return "", ""
    return "  ", f" (from playbook: {meta['playbook_id']}, depth {meta['depth']})"


def render_body():
    lines = []
    for n in order:
        rec = numbering[n]
        box = "[x]" if rec["checked"] else "[ ]"
        indent, origin_suffix = origin_indent_and_marker(rec["step"])
        lines.append(f"{indent}  {box} {n}. {rec['step']}{origin_suffix}{conditional_marker(rec['step'])}")
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
