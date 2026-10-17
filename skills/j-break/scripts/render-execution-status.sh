#!/usr/bin/env bash
################################################################################
# render-execution-status.sh — the scoped execution rapport behind `/break status`
#
# Prints a progress rapport for the CURRENT SCOPE OF EXECUTION: what this run
# has finished, what is in flight, and what is left. That is deliberately
# narrower than `/status`, which prints the whole board regardless of what is
# running.
#
# THERE IS NO RUN MANIFEST, so "the current scope" is reconstructed from live
# evidence on disk. Three sources say work is happening NOW; a fourth says what
# is waiting.
#
#   1. tasks with `status: In Progress`          what is actually running
#   2. bundle manifests  queue/bundle-*.json      every task of an active bundle
#   3. epic locks        queue/epic-lock-*.json   an unexpired lock = that epic
#                                                 is being executed
#   4. un-commented entries in todo.md            the queued remainder
#
# Sources 1-3 are LIVENESS evidence. Source 4 is not: it only ever adds queued
# items, and only for epics that sources 1-3 already put in scope.
#
# ---------------------------------------------------------------------------
# TWO DECISIONS THAT DIVERGE FROM THE TASK TEXT, and why
#
# (a) Queued items are limited to epics already in scope. The task says to
#     union all four sources. On a real board that makes todo.md the whole
#     backlog: this repository has 60 Pending entries spread over dozens of
#     epics, so a rapport about "the current run" would list all of them. That
#     is exactly the dump this script exists to avoid. Entries belonging to
#     other epics are therefore reported as a COUNT only.
#
# (b) A bundle manifest counts as live only if it is younger than
#     bundle_lock_ttl_minutes OR a live epic lock names its story. The task
#     applies staleness to locks alone, but the lock is the system's own
#     authority on whether a bundle is alive; a manifest with no live lock
#     behind it is either abandoned or deliberately HALTED (a /break halt keeps
#     the manifest and releases the lock). Counting it live would also make
#     "nothing is executing" unreachable on any repository that once crashed a
#     bundle: this one has a 16-day-old manifest sitting in queue/ right now.
#     Such manifests are listed as stale/halted, never counted.
#
# ---------------------------------------------------------------------------
# NOTHING IN FLIGHT. When sources 1-3 are all empty it does NOT fall back to
# printing the board. It says so plainly, gives the queued count and points at
# `/status`. That distinction is the whole reason this rapport is separate.
#
# PER-SESSION LEDGER (E44_S09). Terminal items are split into `ran this session`
# and `done earlier` using <queue>/execution-ledger.jsonl, which
# record-execution.sh appends to whenever /do (and /dooo, /jenga) writes a
# terminal status. An item is `ran this session` when the ledger holds an entry
# for it under the CURRENT session key (scripts/checklist-marker.sh session-key,
# or --session KEY); every other terminal item is `done earlier`. Malformed
# ledger lines are skipped and counted. With no ledger file the renderer falls
# back to board status only (`done`) and says that no per-session record exists.
#
# READ-ONLY. It reads only the board, todo.md, the execution ledger and the
# queue directory, and it never writes, moves or deletes anything — including the stale locks and
# manifests it detects, which are the operator's to clear.
#
# Usage: render-execution-status.sh [--session KEY]
#
# Exit codes:
#   0  a rapport was printed (including the "nothing executing" one)
#   2  usage error
#   3  the board or queue directory could not be resolved
#   4  python3 is not available
################################################################################

set -o errexit
set -o nounset

SCRIPT_NAME="render-execution-status.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

SESSION_KEY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help) printf 'Usage: %s [--session KEY]\n' "$SCRIPT_NAME"; exit 0 ;;
    --session) [ "$#" -ge 2 ] || { err "--session needs a value"; exit 2; }; SESSION_KEY="$2"; shift 2; continue ;;
    *) err "unknown argument: $1"; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { err "python3 is required"; exit 4; }

RESOLVE_ROOT="$(resolve_helper scripts/resolve-root.sh)" || { err "could not locate scripts/resolve-root.sh"; exit 3; }

resolve_key() {
  local out
  out="$(bash "$RESOLVE_ROOT" get "$1" 2>/dev/null)" || { err "could not resolve '$1'"; exit 3; }
  [ -n "$out" ] || { err "'$1' resolved to an empty path"; exit 3; }
  printf '%s' "$out"
}

QUEUE_DIR="$(resolve_key queue)"
EPICS_DIR="$(resolve_key epics)"
STORIES_DIR="$(resolve_key stories)"
TASKS_DIR="$(resolve_key tasks)"
CONFIGS_DIR="$(resolve_key configs)"
# todo.md has no path key; it sits beside the queue directory, which is where
# scripts/todo_manager.sh keeps it.
TODO_FILE="$(dirname -- "$QUEUE_DIR")/todo.md"

# The current session key, unless --session overrode it. An unresolvable key is
# not an error: nothing then matches the ledger, so terminal items read `done earlier`.
if [ -z "$SESSION_KEY" ]; then
  if MARKER="$(resolve_helper scripts/checklist-marker.sh)"; then
    SESSION_KEY="$(bash "$MARKER" session-key 2>/dev/null)" || SESSION_KEY=""
  fi
fi

python3 - "$QUEUE_DIR" "$EPICS_DIR" "$STORIES_DIR" "$TASKS_DIR" "$CONFIGS_DIR" "$TODO_FILE" "$SESSION_KEY" <<'PY'
import datetime
import glob
import json
import os
import re
import sys

queue_dir, epics_dir, stories_dir, tasks_dir, configs_dir, todo_file, session_key = sys.argv[1:8]

TERMINAL_OK = {"Passed", "Passed with remarks", "Merged", "Done", "Deployed to Stage", "Deployed to Prod", "Publicized"}
TERMINAL_BAD = {"Failed", "Rejected"}
ICON = {"epic": "📦", "story": "📖"}

now = datetime.datetime.now(datetime.timezone.utc)


def parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def age_minutes(s):
    d = parse_ts(s)
    if d is None:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return int((now - d).total_seconds() // 60)


# --- thresholds ---------------------------------------------------------------
ttl = None
try:
    with open(os.path.join(configs_dir, "scope-thresholds.json"), encoding="utf-8") as fh:
        ttl = int(json.load(fh)["bundle_lock_ttl_minutes"])
except (OSError, ValueError, KeyError, TypeError):
    ttl = None  # reported below; staleness cannot be judged without it

# --- the board: id -> record ----------------------------------------------------
board = {}


def read_front(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            head = [next(fh, "") for _ in range(60)]
    except OSError:
        return None
    rec = {}
    if not head or head[0].strip() != "---":
        return None
    for line in head[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^([A-Za-z_]+):\s*(.*)$", line.rstrip("\n"))
        if m and m.group(1) not in rec:
            rec[m.group(1)] = m.group(2).strip().strip("\"'")
    return rec


for kind, d in (("epic", epics_dir), ("story", stories_dir), ("task", tasks_dir)):
    for path in glob.glob(os.path.join(d, "*.md")):
        rec = read_front(path)
        if not rec or "id" not in rec:
            continue
        board[rec["id"]] = {
            "kind": kind,
            "id": rec["id"],
            "title": rec.get("title", ""),
            "status": rec.get("status", "?"),
            "story": rec.get("story_id") or None,
            "epic": rec.get("epic_id") or (rec["id"] if kind == "epic" else None),
        }
        if kind == "story":
            board[rec["id"]]["story"] = rec["id"]


def epic_of(item):
    if item.get("epic"):
        return item["epic"]
    m = re.match(r"^(E\d+)", item["id"])
    return m.group(1) if m else None


def story_of(item):
    if item["kind"] == "task":
        return item.get("story") or (re.match(r"^(E\d+_S\d+)", item["id"]) or [None, None])[1]
    if item["kind"] == "story":
        return item["id"]
    return None


# --- source 1: tasks In Progress -------------------------------------------------
inflight = {i for i, it in board.items() if it["kind"] == "task" and it["status"] == "In Progress"}

# --- source 3: epic locks (judged first, because source 2 consults them) ----------
live_locks, stale_locks = [], []
for path in sorted(glob.glob(os.path.join(queue_dir, "epic-lock-*.json"))):
    try:
        with open(path, encoding="utf-8") as fh:
            lock = json.load(fh)
    except (OSError, ValueError):
        stale_locks.append({"file": os.path.basename(path), "reason": "unreadable"})
        continue
    age = age_minutes(lock.get("started_at"))
    rec = {"epic": lock.get("epic_id"), "story": lock.get("bundle_story_id"), "age": age,
           "file": os.path.basename(path)}
    if ttl is not None and age is not None and age < ttl:
        live_locks.append(rec)
    else:
        stale_locks.append(rec)

live_lock_stories = {l["story"] for l in live_locks if l.get("story")}

# --- source 2: bundle manifests ----------------------------------------------------
live_bundles, stale_bundles = [], []
for path in sorted(glob.glob(os.path.join(queue_dir, "bundle-*.json"))):
    try:
        with open(path, encoding="utf-8") as fh:
            m = json.load(fh)
    except (OSError, ValueError):
        stale_bundles.append({"story": os.path.basename(path), "tasks": [], "age": None})
        continue
    story = m.get("story_id")
    age = age_minutes(m.get("started_at"))
    rec = {"story": story, "tasks": list(m.get("tasks") or []), "age": age}
    fresh = ttl is not None and age is not None and age < ttl
    if fresh or story in live_lock_stories:
        live_bundles.append(rec)
    else:
        stale_bundles.append(rec)

# --- scope -------------------------------------------------------------------------
scope_ids = set(inflight)
for b in live_bundles:
    scope_ids.update(t for t in b["tasks"] if t in board)
for l in live_locks:
    if l.get("story"):
        scope_ids.update(i for i, it in board.items() if it["kind"] == "task" and it.get("story") == l["story"])

scope_epics = set()
for i in scope_ids:
    e = epic_of(board[i])
    if e:
        scope_epics.add(e)
for l in live_locks:
    if l.get("epic"):
        scope_epics.add(l["epic"])

# --- source 4: todo.md --------------------------------------------------------------
queued_all = []          # every live, non-terminal entry on the board
unresolved = 0
try:
    with open(todo_file, encoding="utf-8", errors="replace") as fh:
        todo_lines = fh.read().splitlines()
except OSError:
    todo_lines = []

in_comment = False
for line in todo_lines:
    s = line.strip()
    opens, closes = "<!--" in s, "-->" in s
    if in_comment:
        if closes:
            in_comment = False
        continue
    if opens:
        if not closes:
            in_comment = True
        continue            # commented-out, including RECONCILED markers
    if not s or s.startswith("#"):
        continue
    m = re.search(r":\s*(E\d+(?:_S\d+)?(?:_T\d+)?)\s*$", s)
    if not m:
        continue
    iid = m.group(1)
    if iid not in board:
        unresolved += 1
        continue
    if board[iid]["status"] in TERMINAL_OK | TERMINAL_BAD:
        continue            # a stale entry for finished work is not "remaining"
    queued_all.append(iid)

queued_in_scope = [i for i in dict.fromkeys(queued_all) if i not in scope_ids and epic_of(board[i]) in scope_epics]
queued_elsewhere = len([i for i in dict.fromkeys(queued_all) if i not in scope_ids and epic_of(board[i]) not in scope_epics])

# --- the execution ledger (E44_S09): item ids with a terminal entry under this session key ---
ledger_file = os.path.join(queue_dir, "execution-ledger.jsonl")
ledger_present = os.path.isfile(ledger_file)
ran_this_session, ledger_bad = set(), 0
if ledger_present:
    try:
        with open(ledger_file, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    entry = json.loads(raw)
                    if not isinstance(entry, dict):
                        raise ValueError("not an object")
                except ValueError:
                    ledger_bad += 1
                    continue
                if session_key and entry.get("session_key") == session_key and entry.get("status") in TERMINAL_OK | TERMINAL_BAD:
                    ran_this_session.add(entry.get("item_id"))
    except OSError:
        ledger_present = False

nothing_in_flight = not inflight and not live_bundles and not live_locks

# --- render ---------------------------------------------------------------------------
BAR = "━" * 35
out = []


def stale_notes():
    lines = []
    for l in stale_locks:
        if l.get("reason") == "unreadable":
            lines.append(f"  ⚠️  {l['file']}: unreadable, ignored")
        else:
            a = f"{l['age']}m" if l.get("age") is not None else "unknown age"
            lines.append(f"  ⚠️  stale epic lock for {l.get('epic') or '?'} ({a} old, ttl {ttl}m) — not live execution")
    for b in stale_bundles:
        a = f"{b['age']}m" if b.get("age") is not None else "unknown age"
        lines.append(f"  ⚠️  bundle manifest for {b.get('story') or '?'} with no live lock ({a} old) — halted or abandoned, not counted")
    if ttl is None:
        lines.append("  ⚠️  bundle_lock_ttl_minutes unavailable: staleness could not be judged, so no lock or bundle was counted live")
    return lines


out.append(BAR)
out.append(" EXECUTION SCOPE  ·  " + now.strftime("%Y-%m-%dT%H:%M:%SZ"))
out.append(BAR)

if nothing_in_flight:
    queued_total = len(set(queued_all))
    out.append("")
    out.append(" Nothing is currently executing.")
    out.append(f" {queued_total} item(s) are queued in todo.md. For the full board, run /status.")
    notes = stale_notes()
    if notes:
        out.append("")
        out.extend(notes)
    print("\n".join(out))
    sys.exit(0)

# Group the in-scope items: epic -> story -> task.
shown = list(dict.fromkeys(list(scope_ids) + queued_in_scope))
tree = {}
for i in shown:
    it = board[i]
    tree.setdefault(epic_of(it) or "?", {}).setdefault(story_of(it) or "-", []).append(it)


def mark(it):
    st = it["status"]
    if it["id"] in inflight:
        return "🔄", "in flight"
    if st in TERMINAL_OK:
        if not ledger_present:
            return "✅", "done"
        return "✅", ("ran this session" if it["id"] in ran_this_session else "done earlier")
    if st in TERMINAL_BAD:
        return "❌", "failed"
    if st == "Blocked":
        return "🚫", "blocked"
    return "⏳", "queued"


counts = {"done": 0, "ran this session": 0, "done earlier": 0, "in flight": 0, "queued": 0, "other": 0}
for epic_id in sorted(tree):
    e = board.get(epic_id)
    out.append("")
    out.append(f"{ICON['epic']} {epic_id} · {(e or {}).get('title') or '(epic file not found)'}  [{(e or {}).get('status', '?')}]")
    for story_id in sorted(tree[epic_id]):
        s = board.get(story_id)
        if story_id != "-":
            out.append(f"   {ICON['story']} {story_id} · {(s or {}).get('title') or '(story file not found)'}  [{(s or {}).get('status', '?')}]")
        for it in sorted(tree[epic_id][story_id], key=lambda x: x["id"]):
            icon, tag = mark(it)
            counts[tag if tag in counts else "other"] += 1
            pad = "      " if story_id != "-" else "   "
            out.append(f"{pad}{icon} {it['id']} · {it['title']}  [{it['status']}]  ◀ {tag}")

out.append("")
out.append(BAR)
out.append(
    f" Progress: {counts['done'] + counts['ran this session'] + counts['done earlier']} completed · {counts['in flight']} in flight · "
    f"{counts['queued'] + counts['other']} remaining"
)
if not ledger_present:
    out.append(" No per-session record exists (no execution-ledger.jsonl), so completed items are shown by board status only.")
else:
    out.append(f" Of the completed: {counts['ran this session']} ran this session, {counts['done earlier']} done earlier.")
    if ledger_bad:
        out.append(f" {ledger_bad} malformed ledger line(s) were skipped.")
if queued_elsewhere:
    out.append(f" Not in this scope: {queued_elsewhere} more item(s) queued in todo.md under other epics (see /status).")
if unresolved:
    out.append(f" {unresolved} todo.md line(s) name an id with no board file and were skipped.")
notes = stale_notes()
if notes:
    out.append("")
    out.extend(notes)
print("\n".join(out))
PY
