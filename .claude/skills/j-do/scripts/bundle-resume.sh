#!/usr/bin/env bash
################################################################################
# bundle-resume.sh - decide whether `/do <E##_S##>` starts a fresh bundle or
# resumes a halted one, and print the tasks to run (E44_S08)
#
# Usage: bundle-resume.sh <E##_S##>
#
# Inputs (all resolved through scripts/resolve-root.sh, no hardcoded paths):
#   the story file      <stories>/<E##_S##>_*.md     its `tasks:` list, in order
#   each task file      <tasks>/<task_id>_*.md       its `status:` frontmatter
#   the bundle manifest <queue>/bundle-<E##_S##>.json   story_id, anchor_sha,
#                                                        task_changed_files, tasks
#
# Output (stdout, exactly one JSON object, nothing else on success):
#   {"mode":"fresh|resume","story_id":"...","anchor_sha":"<sha>|null",
#    "run":[...],"skipped":[...],"notes":[...]}
#
# Rules:
#   1. No manifest: mode=fresh, anchor_sha=null, run = the whole `tasks:` list,
#      skipped empty.
#   2. A manifest present is validated: parseable JSON, story_id equal to the
#      argument, anchor_sha a 40-hex SHA, and `git merge-base --is-ancestor
#      <anchor_sha> HEAD` succeeding. Any failure refuses (exit 3) with a
#      one-line cause on stderr.
#   3. Valid manifest: mode=resume, anchor_sha copied verbatim from the manifest.
#      skipped = tasks whose board status is Passed, Passed with remarks or
#      Merged; run = every other task, in `tasks:` order. Failed, In Progress and
#      Blocked tasks are run and also noted. Drift between the manifest's `tasks`
#      and the story's `tasks:` is noted; the story's list wins.
#   4. Board status is authoritative. task_changed_files never decides what is
#      done; it only ever produces a note when it disagrees with the board.
#   5. Strictly read-only: writes nothing, creates no file or directory, takes
#      no lock, changes no git state.
#
# Exit codes:
#   0  success
#   2  usage error
#   3  manifest refused (unparseable, wrong story, bad anchor_sha, not an ancestor)
#   4  story file or a task file could not be found
#   5  python3 or scripts/resolve-root.sh unavailable
################################################################################

set -o errexit
set -o nounset

SCRIPT_NAME="bundle-resume.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

case "${1:-}" in
  -h|--help|help) printf 'Usage: %s E##_S##\n' "$SCRIPT_NAME"; exit 0 ;;
esac
[ "$#" -eq 1 ] || { err "usage: $SCRIPT_NAME E##_S##"; exit 2; }
STORY_ID="$1"
printf '%s' "$STORY_ID" | grep -Eq '^E[0-9]+_S[0-9]+$' || { err "usage: story id must look like E##_S##, got '$STORY_ID'"; exit 2; }

command -v python3 >/dev/null 2>&1 || { err "python3 is required"; exit 5; }

RESOLVE_ROOT=""
for candidate in "$REPO_ROOT/scripts/resolve-root.sh" "$REPO_ROOT/node_modules/@jenga-ai/agent/scripts/resolve-root.sh"; do
  [ -f "$candidate" ] && { RESOLVE_ROOT="$candidate"; break; }
done
[ -n "$RESOLVE_ROOT" ] || { err "could not locate scripts/resolve-root.sh"; exit 5; }

resolve_key() {
  local out
  out="$(bash "$RESOLVE_ROOT" get "$1" 2>/dev/null)" || { err "could not resolve '$1'"; exit 5; }
  [ -n "$out" ] || { err "'$1' resolved to an empty path"; exit 5; }
  printf '%s' "$out"
}

QUEUE_DIR="$(resolve_key queue)"
STORIES_DIR="$(resolve_key stories)"
TASKS_DIR="$(resolve_key tasks)"
ROOT="$(bash "$RESOLVE_ROOT" root)"
MANIFEST="$QUEUE_DIR/bundle-$STORY_ID.json"

# Ancestry is judged here, in bash, so the python below stays free of subprocesses.
# It is only needed when a manifest exists and carries a 40-hex anchor_sha.
ANCESTOR=unknown
if [ -f "$MANIFEST" ]; then
  SHA="$(python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get("anchor_sha", "")
    print(v if isinstance(v, str) else "")
except Exception:
    print("")' "$MANIFEST")"
  if printf '%s' "$SHA" | grep -Eq '^[0-9a-fA-F]{40}$'; then
    if git -C "$ROOT" merge-base --is-ancestor "$SHA" HEAD >/dev/null 2>&1; then ANCESTOR=yes; else ANCESTOR=no; fi
  fi
fi

python3 - "$STORY_ID" "$STORIES_DIR" "$TASKS_DIR" "$MANIFEST" "$ANCESTOR" <<'PY'
import glob
import json
import os
import re
import sys

story_id, stories_dir, tasks_dir, manifest_path, ancestor = sys.argv[1:6]
SKIP = {"Passed", "Passed with remarks", "Merged"}
NOTE_ON_RUN = {"Failed", "In Progress", "Blocked"}


def die(code, msg):
    sys.stderr.write("bundle-resume.sh: " + msg + "\n")
    sys.exit(code)


def front(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    if not lines or lines[0].strip() != "---":
        return [], {}
    block = []
    for line in lines[1:]:
        if line.strip() == "---":
            break
        block.append(line)
    scalars = {}
    for line in block:
        m = re.match(r"^([A-Za-z_]+):\s*(.*)$", line)
        if m and m.group(1) not in scalars:
            scalars[m.group(1)] = m.group(2).strip().strip("\"'")
    tasks, in_tasks = [], False
    for line in block:
        if re.match(r"^tasks:\s*$", line):
            in_tasks = True
            continue
        if in_tasks:
            m = re.match(r"^\s+-\s+(\S+)\s*$", line)
            if m:
                tasks.append(m.group(1))
            elif line.strip() and not line.startswith((" ", "\t")):
                in_tasks = False
    return tasks, scalars


story_files = sorted(glob.glob(os.path.join(stories_dir, story_id + "_*.md")))
if not story_files:
    die(4, "story file not found for " + story_id)
story_tasks, _ = front(story_files[0])

statuses = {}
for tid in story_tasks:
    files = sorted(glob.glob(os.path.join(tasks_dir, tid + "_*.md")))
    if not files:
        die(4, "task file not found for " + tid)
    statuses[tid] = front(files[0])[1].get("status", "?")

if not os.path.isfile(manifest_path):
    fresh_notes = []
    done = ("Passed", "Passed with remarks", "Merged")
    if story_tasks and all(statuses[t] in done for t in story_tasks):
        fresh_notes.append("all_terminal: every task is already Passed/Merged on the board and there is no manifest; a fresh bundle would re-run finished work")
    print(json.dumps({"mode": "fresh", "story_id": story_id, "anchor_sha": None,
                      "run": list(story_tasks), "skipped": [], "notes": fresh_notes}))
    sys.exit(0)

try:
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    if not isinstance(manifest, dict):
        raise ValueError("not an object")
except (OSError, ValueError):
    die(3, "manifest refused: bundle-%s.json is unparseable" % story_id)
if manifest.get("story_id") != story_id:
    die(3, "manifest refused: bundle-%s.json names story %r" % (story_id, manifest.get("story_id")))
anchor = manifest.get("anchor_sha")
if not isinstance(anchor, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", anchor):
    die(3, "manifest refused: anchor_sha is missing or not a 40-hex SHA")
if ancestor != "yes":
    die(3, "manifest refused: anchor_sha %s is not an ancestor of HEAD (history rewritten or abandoned run)" % anchor)

notes = []
changed = manifest.get("task_changed_files")
changed = changed if isinstance(changed, dict) else {}
run, skipped = [], []
for tid in story_tasks:
    st = statuses[tid]
    if st in SKIP:
        skipped.append(tid)
        if tid not in changed:
            notes.append("%s is %s on the board but has no task_changed_files entry; board wins, skipped" % (tid, st))
    else:
        run.append(tid)
        if st in NOTE_ON_RUN:
            notes.append("%s is %s and will be run again" % (tid, st))
        elif tid in changed:
            notes.append("%s has a task_changed_files entry but is %s on the board; board wins, run again" % (tid, st))
m_tasks = manifest.get("tasks")
if isinstance(m_tasks, list):
    extra = [t for t in m_tasks if t not in story_tasks]
    missing = [t for t in story_tasks if t not in m_tasks]
    if extra or missing:
        notes.append("task list drift (story list wins): only in manifest %s, only in story %s" % (extra, missing))

print(json.dumps({"mode": "resume", "story_id": story_id, "anchor_sha": anchor,
                  "run": run, "skipped": skipped, "notes": notes}))
PY
