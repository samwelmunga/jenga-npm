#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-reconcile/scripts/detect-done-before-dependency.sh   (E92_S11_T02)
#
# Finds every task that is DONE although one of its dependencies is NOT done: a board contradiction. User decision
# 2026-11-15 (story E92_S11): "En ticket kan inte både vara genomförd och samtidigt vara beroende av en icke genomförd
# ticket. Om ticketen är genomförd före dess är det ett defacto bevis för att den inte var beroende av den andra
# ticketen." It happens when a dependency was done and later reopened (Failed on re-judgment, j.redo, set back to
# Pending), or when depends_on is simply wrong.
#
# The detection is NOT re-derived here. scripts/board-progress.sh --graph states it per task as `unfinished_deps` (the
# effective dependencies, own depends_on then the story's, that are not satisfied, for a task in the done bucket; [] for
# every other task). This script only collects the tasks whose list is not empty and adds the current status of each
# named dependency (one `board-progress.sh --ids <deps> --items` call), so the report can name it.
#
# REPORT-ONLY. It reads the board and prints JSON. It never writes a file, never changes a status, never edits a
# depends_on: deciding whether the dependency or the task is wrong is the user's call (skills/j-reconcile/SKILL.md).
#
# Usage:
#   detect-done-before-dependency.sh [--within <E##|E##_S##>] [--root <dir>]
#
#   --within  restrict to one epic or story (forwarded to board-progress.sh --graph --within; satisfaction is still
#             computed over the whole board)
#   --root    the project root (forwarded to board-progress.sh)
#
# Output (stdout, one JSON object, keys in this order, findings in numeric task id order as the script lists them):
#   {
#     "count": <number of findings>,
#     "findings": [
#       { "task": "E01_S01_T04", "title": "...", "status": "Passed", "story_id": "E01_S01", "epic_id": "E01",
#         "unfinished_deps": [ { "id": "E01_S01_T02", "level": "task", "status": "Failed" }, ... ] }
#     ]
#   }
#   level is task, story or epic; status is the dependency's own board status ("" when it could not be read).
#
# Exit codes: 0 the board was read (with or without findings; a board with no epic file at all gives count 0);
#             2 usage error; 4 board-progress.sh is missing or failed (its stderr is passed through).
#
# board-progress.sh is looked up, first match wins: JENGA_BOARD_PROGRESS (a path; the test seam), then
# <this skill>/../../scripts/board-progress.sh, scripts/board-progress.sh, node_modules/@jenga-ai/agent/scripts/.
#
# Requires: bash, python3. jq is NOT required.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
PACKAGE_ROOT="$(jenga_package_root "$SCRIPT_DIR")" || true
usage() { sed -n '19,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
usage_err() { printf 'detect-done-before-dependency.sh: %s\n' "$1" >&2; usage >&2; exit 2; }

within=""
root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --within)   [ "$#" -ge 2 ] || usage_err "--within needs a value"; within="$2"; shift 2 ;;
    --within=*) within="${1#--within=}"; shift ;;
    --root)     [ "$#" -ge 2 ] || usage_err "--root needs a value"; root="$2"; shift 2 ;;
    --root=*)   root="${1#--root=}"; shift ;;
    *) usage_err "unknown argument: $1" ;;
  esac
done

find_board_progress() {
  local cand
  if [ -n "${JENGA_BOARD_PROGRESS:-}" ]; then
    [ -f "$JENGA_BOARD_PROGRESS" ] && printf '%s' "$JENGA_BOARD_PROGRESS"
    return 0
  fi
  for cand in "$PACKAGE_ROOT/scripts/board-progress.sh" "scripts/board-progress.sh" "node_modules/@jenga-ai/agent/scripts/board-progress.sh"; do
    if [ -f "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
}

BP="$(find_board_progress)"
[ -n "$BP" ] || { printf 'detect-done-before-dependency.sh: board-progress.sh not found\n' >&2; exit 4; }

common=()
[ -n "$root" ] && common=(--root "$root")
graph_args=(--graph)
[ -n "$within" ] && graph_args+=(--within "$within")

rc=0
graph="$(bash "$BP" "${graph_args[@]}" ${common[@]+"${common[@]}"})" || rc=$?
if [ "$rc" -eq 3 ]; then
  printf '{"count":0,"findings":[]}\n'   # no epic file at all: nothing to report
  exit 0
fi
[ "$rc" -eq 0 ] || { printf 'detect-done-before-dependency.sh: board-progress.sh --graph failed (exit %s)\n' "$rc" >&2; exit 4; }

# The distinct unfinished dependency ids, in first-seen order.
deps="$(printf '%s' "$graph" | python3 -I -c '
import json, sys
seen = []
for t in json.load(sys.stdin).get("tasks", []):
    for d in t.get("unfinished_deps") or []:
        if d not in seen:
            seen.append(d)
print(",".join(seen))
')"

items='{}'
if [ -n "$deps" ]; then
  rc=0
  items="$(bash "$BP" --ids "$deps" --items ${common[@]+"${common[@]}"})" || rc=$?
  [ "$rc" -eq 0 ] || { printf 'detect-done-before-dependency.sh: board-progress.sh --ids --items failed (exit %s)\n' "$rc" >&2; exit 4; }
fi

GRAPH="$graph" ITEMS="$items" python3 -I -c '
import json, os
graph = json.loads(os.environ["GRAPH"])
items = json.loads(os.environ["ITEMS"])
status = {}
for level, plural in (("task", "tasks"), ("story", "stories"), ("epic", "epics")):
    for it in ((items.get("levels") or {}).get(plural) or {}).get("items") or []:
        status[it["id"]] = (level, it.get("status", ""))
def level_of(i):
    return "task" if "_T" in i else ("story" if "_S" in i else "epic")
findings = []
for t in graph.get("tasks", []):
    unf = t.get("unfinished_deps") or []
    if not unf:
        continue
    findings.append({
        "task": t["id"], "title": t.get("title", ""), "status": t.get("status", ""),
        "story_id": t.get("story_id", ""), "epic_id": t.get("epic_id", ""),
        "unfinished_deps": [{"id": d, "level": status.get(d, (level_of(d), ""))[0], "status": status.get(d, ("", ""))[1]} for d in unf],
    })
print(json.dumps({"count": len(findings), "findings": findings}, ensure_ascii=False, separators=(",", ":")))
'
