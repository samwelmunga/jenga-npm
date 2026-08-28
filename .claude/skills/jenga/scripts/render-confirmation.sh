#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/render-confirmation.sh
#
# Turn-by-turn checkbox-tree confirmation renderer for `/jenga`'s
# interactive scope-selection flow (E45_S02_T02). Renders the full nested
# Epic > Story > Task resolution tree (with per-level counts) produced by
# `skills/jenga/scripts/cascade-resolve.sh` (E45_S01_T03) as a
# checkbox-style confirmation screen, and lets the user toggle individual
# items off/on before committing to a final execution set.
#
# Used by BOTH interactive entry modes that require confirmation:
#   - Bare `/jenga`     -> after render-picker.sh (E45_S02_T01) resolves a
#                          numbered selection to board IDs.
#   - `/jenga <ids>`    -> after resolve-id.sh (E45_S01_T02) resolves the
#                          fuzzy-ID grammar to board IDs, bypassing the
#                          picker but NOT this confirmation step.
# Only `/jenga *` (the literal wildcard) skips this script entirely — that
# branch is wired in E45_S03_T01, not here.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A TWO-INVOCATION, STATE-FILE SCRIPT (READ BEFORE CHANGING)
# ---------------------------------------------------------------------------
# Identical constraint to render-picker.sh: Claude Code's Bash tool runs a
# command to completion and returns — it cannot block mid-script waiting on
# the next chat message. So this confirmation screen is split across
# (at least) two invocations of this same script, coordinated by the
# calling agent, never by this script itself:
#
#   1. Turn 1 (start mode): this script resolves the given board IDs via
#      cascade-resolve.sh, builds a numbered checkbox tree, writes that
#      snapshot (plus live checked/unchecked state) to a temp "state file",
#      and prints a human-readable tree + instructions to STDOUT.
#   2. The calling agent relays this script's literal STDOUT to the user
#      as a chat message, verbatim — no summarizing, no reformatting.
#   3. The user replies in chat with a command: a toggle ("check 3,5",
#      "uncheck 2", or bare numbers), "confirm", or "cancel".
#   4. The calling agent re-invokes this script, passing the state file
#      path (captured from the prior turn's STDERR — see OUTPUT CONTRACT
#      below) and the user's raw reply as two arguments (continue mode).
#   5. This script updates the checked/unchecked state and either:
#        - emits an updated tree for another turn (state file kept), or
#        - emits a plain-text error turn for a bad command/number (state
#          file kept, unchanged, ready for another continue-mode retry), or
#        - emits the final resolved, user-approved execution set as JSON
#          (state file removed) for `/jenga`'s Phase 1/2/3 logic to consume.
#
# Do NOT attempt to "fix" this with a blocking read, a stdin prompt loop,
# or a polling/sleep loop waiting for external input — none of those work
# with the Bash tool's run-to-completion model, and ad-hoc polling loops as
# an inter-turn signaling mechanism are explicitly prohibited elsewhere in
# this repo's agent-coordination conventions (see epic E37).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/render-confirmation.sh "<comma-separated-ids>"
#       Start a new confirmation session. The argument is a comma-separated
#       list of exact, already-resolved board IDs — the same input
#       cascade-resolve.sh itself takes (e.g. from render-picker.sh's
#       `resolved_ids_csv` field, or from collecting `resolved_id` values
#       out of resolve-id.sh's per-segment output). This script invokes
#       cascade-resolve.sh itself with this argument — mirroring how
#       render-picker.sh invokes board-scan.sh itself, and how
#       cascade-resolve.sh / resolve-id.sh invoke board-scan.sh itself.
#       Never pass pre-computed cascade-resolve.sh JSON in from outside;
#       that would break the single-source-of-truth invocation chain
#       (board-scan -> cascade-resolve -> render-confirmation) every
#       sibling script in this family relies on.
#
#   skills/jenga/scripts/render-confirmation.sh <state_file> "<raw_reply>"
#       Continue an existing confirmation session. <state_file> is the
#       path printed on STDERR by the start-mode invocation (or by any
#       prior continue-mode invocation — the path is stable across turns
#       until the session ends). <raw_reply> is the user's raw chat text
#       for this turn, passed as a single argument (quote it).
#
# ---------------------------------------------------------------------------
# TOGGLE COMMAND GRAMMAR
# ---------------------------------------------------------------------------
# A reply (case-insensitive, whitespace-insensitive around tokens) is one
# of:
#
#   cancel                  Abort the session. State file removed.
#   confirm                 Finalize with the CURRENT checked state.
#   check <numbers>         Set the listed displayed number(s) to checked.
#   uncheck <numbers>       Set the listed displayed number(s) to unchecked.
#   <numbers>               Bare numbers (no "check"/"uncheck" prefix)
#                           TOGGLE the current checked state of each listed
#                           displayed number.
#
# <numbers> is a comma- and/or whitespace-separated list of positive
# integers referring to the numbers printed in THIS session's tree (e.g.
# "3,5" or "3, 5" or "check 3 5"). Validation is ALL-OR-NOTHING per turn,
# same philosophy as render-picker.sh: if a reply contains any non-numeric
# token or any number outside the valid 1..N range for this session, the
# ENTIRE turn is rejected as an error turn (state left untouched) — there
# is no partial application of the valid numbers in a mixed-validity reply.
#
# Toggling is NOT cascading: unchecking a parent epic/story does not
# automatically uncheck its children, and vice versa. Each displayed
# number is an independent checkbox. This is a deliberate simplicity
# choice — the task only requires "uncheck or re-check individual
# presented items", not cascading selection logic (that expansion/cascade
# concern already belongs to cascade-resolve.sh, per its own header).
#
# ---------------------------------------------------------------------------
# OUTPUT CONTRACT (deliberately NOT uniform JSON — see rationale below)
# ---------------------------------------------------------------------------
# Same split-by-audience contract as render-picker.sh:
#
#   - Start mode, and continue-mode TOGGLE / ERROR turns:
#       STDOUT = plain human-readable text (the tree + instructions, or an
#                error message + retry instructions). This is exactly what
#                the calling agent relays verbatim to the user.
#       STDERR = a single line: `STATE_FILE: <absolute path>` — metadata
#                for the calling AGENT to capture for the next invocation.
#                Never intended for the human to read; do not relay it.
#
#   - Continue mode, CONFIRMED (final) turn:
#       STDOUT = a single JSON object (schema below) — the machine-readable
#                handoff to `/jenga`'s Phase 1/2/3 logic. This is NOT meant
#                to be relayed to the user verbatim.
#       STDERR = empty (state file has been removed; nothing to carry
#                forward).
#
#   - Continue mode, CANCELLED (`cancel` reply, case-insensitive):
#       STDOUT = plain human-readable cancellation acknowledgement.
#       STDERR = empty (state file has been removed).
#
# CONFIRMED JSON schema — deliberately identical field names to
# cascade-resolve.sh's own output schema (see that script's header), so
# `/jenga`'s Phase 1/2/3 logic can consume this as a drop-in, scoped-down
# version of a cascade-resolve.sh result rather than learning a second
# shape:
#
#   {
#     "status":           "confirmed",
#     "items":             [ <board-scan.sh item objects, checked-only,
#                             in tree DFS order> ],
#     "resolved_ids":      ["E01", "E01_S02", "E01_S02_T01"],
#     "resolved_ids_csv":  "E01,E01_S02,E01_S02_T01",
#     "counts":            {"epics": 1, "stories": 1, "tasks": 1},
#     "undecomposed":      [ <cascade-resolve.sh undecomposed entries,
#                             filtered to ids still checked> ],
#     "warnings":          [ <cascade-resolve.sh warnings, passthrough,
#                             unaffected by checkbox state> ]
#   }
#
# ---------------------------------------------------------------------------
# TREE STRUCTURE (recomputed from `items`, NOT trusted from `items` order)
# ---------------------------------------------------------------------------
# Stories are nested under their epic when that epic is ALSO present in the
# resolved `items` set (epic_id present among resolved epics); tasks are
# nested under their story when that story is likewise present. This can
# and does diverge from a literal walk of cascade-resolve.sh's own
# `resolved_ids` array order — e.g. selecting an individual task directly
# (without its epic or story) never adds that task's story to `items`
# (see cascade-resolve.sh's task-input branch), so the task renders as a
# top-level "Directly Selected Task" here, not nested under a story stub
# that doesn't exist. This mirrors render-picker.sh's own handling of
# unlinked stories/tasks.
#
# ---------------------------------------------------------------------------
# STATE FILE
# ---------------------------------------------------------------------------
# Created under `mktemp -t jenga-confirm-XXXXXX.json`. Stores:
#   - `numbering`: displayed number -> {item, level, checked} — the ONLY
#     field that mutates across turns is `checked`.
#   - `layout`: the fixed print order (item lines + header markers),
#     computed once at start. Continue mode never recomputes tree shape —
#     it only re-renders from `layout` + the live `checked` flags in
#     `numbering`, and only ever mutates `checked` values.
#   - `undecomposed` / `warnings`: passthrough from cascade-resolve.sh,
#     used only at confirm-time filtering / informational display.
#
# If the state file is missing or unreadable when continue mode is invoked
# (e.g. the OS temp dir was cleared), this is treated as a real setup
# problem (exit 2), not a per-input validation failure — the user has to
# restart the confirmation (start mode) from scratch.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   start mode rendered successfully; OR continue mode applied a
#       toggle/check/uncheck command and re-rendered the tree; OR continue
#       mode fully confirmed (final JSON emitted)
#   1   continue mode: at least one invalid/out-of-range number, or no
#       numbers found, in the reply — an error turn was emitted, retry
#       with the same state file
#   2   usage error, or a real setup problem (cascade-resolve.sh / python3
#       unavailable, state file missing/corrupt)
#   3   continue mode: user replied "cancel" — session aborted, state file
#       removed
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASCADE_RESOLVE="$SCRIPT_DIR/cascade-resolve.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by render-confirmation.sh" >&2
  exit 2
fi

if [ $# -eq 1 ]; then
  MODE="start"
  RAW_IDS="$1"
elif [ $# -eq 2 ]; then
  MODE="continue"
  STATE_FILE="$1"
  RAW_REPLY="$2"
else
  echo "Usage:" >&2
  echo "  render-confirmation.sh \"<comma-separated-ids>\"        # start a new confirmation session" >&2
  echo "  render-confirmation.sh <state_file> \"<raw_reply>\"      # continue an existing session" >&2
  exit 2
fi

if [ "$MODE" = "start" ]; then
  if [ ! -x "$CASCADE_RESOLVE" ]; then
    echo "Error: cascade-resolve.sh not found or not executable at $CASCADE_RESOLVE" >&2
    exit 2
  fi

  if [ -z "${RAW_IDS// /}" ]; then
    echo "Error: no IDs given to render-confirmation.sh" >&2
    exit 2
  fi

  CASCADE_JSON="$("$CASCADE_RESOLVE" "$RAW_IDS")" || {
    echo "Error: cascade-resolve.sh failed" >&2
    exit 2
  }

  STATE_FILE="$(mktemp -t jenga-confirm-XXXXXX.json)"

  # As with render-picker.sh: the rendering/state-writing logic is written
  # to a temp .py file rather than piped in via `python3 -`, because the
  # cascade JSON is delivered on stdin — `python3 -` would consume stdin
  # itself as the script source.
  PY_SCRIPT="$(mktemp -t render-confirmation-start-XXXXXX.py)"
  trap 'rm -f "$PY_SCRIPT"' EXIT

  cat > "$PY_SCRIPT" <<'PY'
import json
import sys
from datetime import datetime, timezone

state_file_path = sys.argv[1]
cascade_json = sys.stdin.read()

try:
    cascade = json.loads(cascade_json)
except Exception as e:
    print(f"Error: could not parse cascade-resolve.sh output as JSON: {e}", file=sys.stderr)
    sys.exit(2)

items = cascade.get("items", [])
undecomposed = cascade.get("undecomposed", [])
warnings = cascade.get("warnings", [])

undecomposed_ids = {u["id"] for u in undecomposed if u.get("id")}

epics = [i for i in items if i.get("type") == "epic"]
stories = [i for i in items if i.get("type") == "story"]
tasks = [i for i in items if i.get("type") == "task"]

epic_ids_present = {e["id"] for e in epics}
story_ids_present = {s["id"] for s in stories}

stories_by_epic = {}
orphan_stories = []
for s in stories:
    epic_id = s.get("epic_id")
    if epic_id in epic_ids_present:
        stories_by_epic.setdefault(epic_id, []).append(s)
    else:
        orphan_stories.append(s)

tasks_by_story = {}
orphan_tasks = []
for t in tasks:
    story_id = t.get("story_id")
    if story_id in story_ids_present:
        tasks_by_story.setdefault(story_id, []).append(t)
    else:
        orphan_tasks.append(t)

INDENT = {"epic": "", "story": "    ", "task": "        "}
LEVEL_TAG = {"epic": "EPIC", "story": "STORY", "task": "TASK"}

numbering = {}
layout = []
counter = 1


def pluralize_story(n):
    return f"{n} stor{'y' if n == 1 else 'ies'}"


def pluralize_task(n):
    return f"{n} task{'' if n == 1 else 's'}"


def add_item(item, level, indent):
    global counter
    n = str(counter)
    counter += 1
    suffix = ""
    if item.get("id") in undecomposed_ids:
        suffix = "  [needs decomposition -- no children on the board yet]"
    numbering[n] = {"item": item, "level": level, "checked": True}
    layout.append({"kind": "item", "number": n, "level": level, "indent": indent, "suffix": suffix})
    return n


def append_suffix(extra):
    entry = layout[-1]
    if not extra:
        return
    if entry["suffix"]:
        entry["suffix"] = entry["suffix"] + f"  ({extra} in this selection)"
    else:
        entry["suffix"] = f"  ({extra} in this selection)"


for e in epics:
    add_item(e, "epic", INDENT["epic"])
    child_stories = stories_by_epic.get(e["id"], [])
    story_count = len(child_stories)
    task_count = sum(len(tasks_by_story.get(s["id"], [])) for s in child_stories)
    parts = []
    if story_count:
        parts.append(pluralize_story(story_count))
    if task_count:
        parts.append(pluralize_task(task_count))
    append_suffix(", ".join(parts))

    for s in child_stories:
        add_item(s, "story", INDENT["story"])
        child_tasks = tasks_by_story.get(s["id"], [])
        if child_tasks:
            append_suffix(pluralize_task(len(child_tasks)))
        for t in child_tasks:
            add_item(t, "task", INDENT["task"])

if orphan_stories:
    layout.append({"kind": "header", "text": ""})
    layout.append({"kind": "header", "text": "-- Directly Selected Stories (no epic in this selection) --"})
    for s in orphan_stories:
        add_item(s, "story", INDENT["story"])
        child_tasks = tasks_by_story.get(s["id"], [])
        if child_tasks:
            append_suffix(pluralize_task(len(child_tasks)))
        for t in child_tasks:
            add_item(t, "task", INDENT["task"])

if orphan_tasks:
    layout.append({"kind": "header", "text": ""})
    layout.append({"kind": "header", "text": "-- Directly Selected Tasks (no story in this selection) --"})
    for t in orphan_tasks:
        # Visually promoted to the "story" indent (top-level under this
        # header, matching render-picker.sh's own convention for unlinked
        # tasks) but the LEVEL stays "task" -- level drives the [TASK] tag
        # and the checked/unchecked footer counts, and must reflect the
        # item's real type regardless of indent/display position.
        add_item(t, "task", INDENT["story"])

total = len(numbering)

state = {
    "version": 1,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "total_items": total,
    "layout": layout,
    "numbering": numbering,
    "undecomposed": undecomposed,
    "warnings": warnings,
}

with open(state_file_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")


def render_body():
    lines = []
    for entry in layout:
        if entry["kind"] == "header":
            lines.append(entry["text"])
            continue
        rec = numbering[entry["number"]]
        item = rec["item"]
        box = "[x]" if rec["checked"] else "[ ]"
        title = item.get("title") or "(untitled)"
        status = item.get("status") or "(no status)"
        lines.append(
            f"{entry['indent']}{box} {entry['number']}. [{LEVEL_TAG[entry['level']]}] "
            f"{item['id']} — {title}  (status: {status}){entry['suffix']}"
        )
    return lines


def render_footer():
    checked = {"epic": 0, "story": 0, "task": 0}
    unchecked = {"epic": 0, "story": 0, "task": 0}
    for rec in numbering.values():
        bucket = checked if rec["checked"] else unchecked
        bucket[rec["level"]] += 1
    total_checked = sum(checked.values())
    total_unchecked = sum(unchecked.values())
    line = (
        f"Currently checked: {checked['epic']} epic(s), {pluralize_story(checked['story'])}, "
        f"{pluralize_task(checked['task'])} ({total_checked} total)."
    )
    if total_unchecked:
        line += f" {total_unchecked} item(s) unchecked and will be excluded."
    return line


header = [
    "=" * 68,
    " /jenga -- Confirm Execution Scope",
    "=" * 68,
    "Everything below is checked [x] by default. Uncheck items you do NOT",
    "want to run, or re-check items you previously unchecked, by number.",
    "",
    "Commands:",
    '  check <numbers>    -- check the listed item(s), e.g. "check 3,5"',
    '  uncheck <numbers>  -- uncheck the listed item(s), e.g. "uncheck 2"',
    '  <numbers>          -- bare numbers toggle their current state',
    '  confirm            -- proceed with the currently checked items',
    '  cancel             -- abort, nothing will run',
    "-" * 68,
    "",
]

if warnings:
    header.append("Note -- some inputs were skipped during resolution:")
    for w in warnings:
        header.append(f"  - '{w.get('input')}': {w.get('reason')}")
    header.append("")

if total == 0:
    body = ["(Nothing resolved -- there is nothing to confirm.)"]
else:
    body = render_body()

footer = [
    "",
    "-" * 68,
    render_footer() if total else "Nothing to select.",
    "",
    'Reply with a command ("check N,N", "uncheck N,N", bare numbers to toggle, "confirm", or "cancel").',
]

print("\n".join(header + body + footer))
print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
PY

  python3 "$PY_SCRIPT" "$STATE_FILE" <<< "$CASCADE_JSON"
  exit 0
fi

# --------------------------------------------------------------------------
# continue mode
# --------------------------------------------------------------------------

if [ ! -f "$STATE_FILE" ]; then
  echo "Error: state file not found at $STATE_FILE" >&2
  echo "The confirmation session may have expired (e.g. temp dir was cleared)." >&2
  echo "Start a new confirmation session with: render-confirmation.sh \"<comma-separated-ids>\"" >&2
  exit 2
fi

PY_SCRIPT="$(mktemp -t render-confirmation-continue-XXXXXX.py)"
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

numbering = state.get("numbering", {})
layout = state.get("layout", [])
undecomposed = state.get("undecomposed", [])
warnings = state.get("warnings", [])
total = state.get("total_items", len(numbering))

LEVEL_TAG = {"epic": "EPIC", "story": "STORY", "task": "TASK"}


def pluralize_story(n):
    return f"{n} stor{'y' if n == 1 else 'ies'}"


def pluralize_task(n):
    return f"{n} task{'' if n == 1 else 's'}"


def render_body():
    lines = []
    for entry in layout:
        if entry["kind"] == "header":
            lines.append(entry["text"])
            continue
        rec = numbering[entry["number"]]
        item = rec["item"]
        box = "[x]" if rec["checked"] else "[ ]"
        title = item.get("title") or "(untitled)"
        status = item.get("status") or "(no status)"
        lines.append(
            f"{entry['indent']}{box} {entry['number']}. [{LEVEL_TAG[entry['level']]}] "
            f"{item['id']} — {title}  (status: {status}){entry.get('suffix', '')}"
        )
    return lines


def render_footer():
    checked = {"epic": 0, "story": 0, "task": 0}
    unchecked = {"epic": 0, "story": 0, "task": 0}
    for rec in numbering.values():
        bucket = checked if rec["checked"] else unchecked
        bucket[rec["level"]] += 1
    total_checked = sum(checked.values())
    total_unchecked = sum(unchecked.values())
    line = (
        f"Currently checked: {checked['epic']} epic(s), {pluralize_story(checked['story'])}, "
        f"{pluralize_task(checked['task'])} ({total_checked} total)."
    )
    if total_unchecked:
        line += f" {total_unchecked} item(s) unchecked and will be excluded."
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
    checked_ids_in_order = []
    items_by_id = {}
    for entry in layout:
        if entry["kind"] != "item":
            continue
        rec = numbering[entry["number"]]
        if rec["checked"]:
            item = rec["item"]
            item_id = item["id"]
            if item_id not in items_by_id:
                checked_ids_in_order.append(item_id)
                items_by_id[item_id] = item

    checked_id_set = set(checked_ids_in_order)
    items_out = [items_by_id[i] for i in checked_ids_in_order]

    counts = {"epics": 0, "stories": 0, "tasks": 0}
    for it in items_out:
        t = it.get("type")
        if t == "epic":
            counts["epics"] += 1
        elif t == "story":
            counts["stories"] += 1
        elif t == "task":
            counts["tasks"] += 1

    undecomposed_out = [u for u in undecomposed if u.get("id") in checked_id_set]

    result = {
        "status": "confirmed",
        "items": items_out,
        "resolved_ids": checked_ids_in_order,
        "resolved_ids_csv": ",".join(checked_ids_in_order),
        "counts": counts,
        "undecomposed": undecomposed_out,
        "warnings": warnings,
    }

    try:
        os.remove(state_file_path)
    except OSError:
        pass

    print(json.dumps(result, indent=2))
    sys.exit(0)

# Determine command kind: "check"/"uncheck" prefix, or bare numbers (toggle).
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

# All-or-nothing application, de-duplicated (first-seen wins on dupes).
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
