#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-uncharted/scripts/directory-triage.sh
#
# Deterministic front half of the directory-triage step (E20_S08_T03) that
# sits between discovery and any developer/tester Investigative Mode
# dispatch, for both `/uncharted onboard`'s conversational default and
# `/uncharted segment --mode investigate`.
#
# The problem: an investigative pass that walks every directory in a
# candidate set wastes turns (and, worse, a user's attention at the
# confirmation gate) on vendor/generated noise nobody wants a coarse graph
# node for. This script answers the MECHANICAL half of that question —
# "is this directory already excluded by .gitignore, or does it match a
# well-known vendor/generated pattern?" — so the agent only has to spend
# judgement on what's left: the content-based "generalize" cases a fixed
# pattern list can never catch (e.g. "this directory is SOAP request
# mock-ups for a test suite").
#
# This script performs NO judgement of its own and writes nothing. It
# classifies; the agent decides what to do with `remaining`.
#
# ---------------------------------------------------------------------------
# INPUT
# ---------------------------------------------------------------------------
# A root (the repository, or the target `onboard`/`segment` is investigating)
# and a set of candidate directory paths to triage, relative to that root.
# Candidates come from positional arguments, or newline-delimited from stdin
# when none are given — composable with discover-subsystems.sh the same way
# apply-subsystem-cap.sh is:
#
#   discover-subsystems.sh <root> | jq -r '.candidates[].path' \
#     | directory-triage.sh <root>
#
# A candidate that does not exist under <root>, or is not a directory, is
# reported in `notices` and otherwise skipped — it is an input problem, not a
# triage verdict.
#
# ---------------------------------------------------------------------------
# THE DETERMINISTIC IGNORE-LIST
# ---------------------------------------------------------------------------
# Path-COMPONENT match against a fixed, known-noise pattern list — never a
# substring match, so a real subsystem directory named e.g. "targets/" is not
# caught by the "target" pattern. The list is intentionally short and named
# in the task's own acceptance criteria; it is expected to need occasional
# extension as new ecosystems are triaged, and is kept as a single array
# below for exactly that reason — this is a revisitable list, not a closed
# one:
#
#   node_modules  vendor        dist          build         .venv
#   venv          __pycache__   .next         coverage      target
#   .git          .tox          .mypy_cache   .pytest_cache .cache
#   *.egg-info (suffix match on the last path component)
#
# A candidate already excluded by .gitignore (via `git check-ignore`) is
# reported separately (`reason: "gitignore"`) even if it ALSO matches a
# pattern — gitignore is checked first and wins, since "why is this
# ignored" should point at the actual mechanism in effect.
#
# ---------------------------------------------------------------------------
# OPTIONS
# ---------------------------------------------------------------------------
#   --root DIR       Root the candidates are resolved against. Required as
#                     the first positional argument OR via this flag.
#   --json-out FILE  Also write the JSON report to a file. stdout gets it
#                     regardless.
#   -h, --help       Show this help and exit 0.
#
# ---------------------------------------------------------------------------
# OUTPUT (stdout, JSON)
# ---------------------------------------------------------------------------
# {
#   "script": "directory-triage.sh",
#   "version": 1,
#   "root": "<as given>",
#   "root_absolute": "<canonicalised>",
#   "candidate_count": <int>,
#   "ignored_count": <int>,
#   "remaining_count": <int>,
#   "ignored":   [ { "path", "absolute_path", "reason" }, ... ],
#   "remaining": [ { "path", "absolute_path" }, ... ],
#   "notices": [ "<non-fatal diagnostic>", ... ]
# }
#
# `reason` on an ignored entry is either "gitignore" or "pattern:<name>"
# (e.g. "pattern:node_modules") — never a bare boolean, so a consumer never
# has to re-derive why something was excluded.
#
# `remaining` is the generalize-list INPUT, not its output — this script
# does not attempt content-based judgement (reading file contents to guess
# "this looks like SOAP mock-ups") at all. That pass is agent judgement, per
# the Skill Implementation Principle in CLAUDE.md, and lives in
# skills/j-uncharted/SKILL.md's Directory Triage subsection, not here.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0 — success (including zero candidates, or everything remaining)
#   1 — usage error: unknown flag, missing root
#   2 — input error: root does not exist or is not a directory
#
# Examples:
#   directory-triage.sh . src lib vendor node_modules
#   discover-subsystems.sh . | jq -r '.candidates[].path' | directory-triage.sh .
#
# Requires: bash, python3, git (optional — gitignore check is skipped with a
# notice when the root is not inside a git working tree).

set -euo pipefail

SCRIPT_NAME="directory-triage.sh"
ROOT=""
JSON_OUT=""
CANDIDATES=()

print_help() {
  cat <<'EOF'
Usage: directory-triage.sh [--root DIR] [--json-out FILE] [<root>] [candidate...]
       discover-subsystems.sh <root> | jq -r '.candidates[].path' | directory-triage.sh <root>

Classifies candidate directories under <root> into:
  - ignored:   already excluded by .gitignore, or matching a known
               vendor/generated pattern (node_modules, vendor, dist, build,
               .venv, venv, __pycache__, .next, coverage, target, .git,
               .tox, .mypy_cache, .pytest_cache, .cache, *.egg-info)
  - remaining: everything else — the input to the agent-judgement
               generalize-list pass documented in skills/j-uncharted/SKILL.md

Options:
  --root DIR       Root the candidates are resolved against (or give it as
                    the first positional argument).
  --json-out FILE  Also write the JSON report to a file. stdout gets it
                    regardless.
  -h, --help       Show this help and exit 0.

Exit codes: 0 success, 1 usage error, 2 root missing/not a directory.
EOF
}

usage_error() {
  echo "Usage: $SCRIPT_NAME [--root DIR] [--json-out FILE] [<root>] [candidate...]" >&2
  echo "       (candidates may also be piped newline-delimited on stdin)" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --root)
      [ "$#" -ge 2 ] || usage_error
      ROOT="$2"
      shift 2
      ;;
    --json-out)
      [ "$#" -ge 2 ] || usage_error
      JSON_OUT="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage_error
      ;;
    *)
      if [ -z "$ROOT" ]; then
        ROOT="$1"
      else
        CANDIDATES+=("$1")
      fi
      shift
      ;;
  esac
done

# Remaining positionals after `--` are also candidates.
for arg in "$@"; do
  CANDIDATES+=("$arg")
done

[ -n "$ROOT" ] || usage_error

if [ ! -d "$ROOT" ]; then
  echo "$SCRIPT_NAME: root '$ROOT' does not exist or is not a directory" >&2
  exit 2
fi

ROOT_ABS=$(cd -- "$ROOT" && pwd -P)

# If no candidates were given on the command line, read newline-delimited
# candidates from stdin (only when stdin is not a terminal, so an
# interactive invocation with no candidates doesn't hang waiting for input).
if [ "${#CANDIDATES[@]}" -eq 0 ] && [ ! -t 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && CANDIDATES+=("$line")
  done
fi

# Determine gitignore availability once, up front.
GITIGNORE_AVAILABLE=0
if git -C "$ROOT_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GITIGNORE_AVAILABLE=1
fi

# Fixed, path-component ignore-list. Kept as a single array so it stays easy
# to extend — see the header note above.
IGNORE_PATTERNS=(
  node_modules vendor dist build .venv venv __pycache__ .next coverage
  target .git .tox .mypy_cache .pytest_cache .cache
)

# ---------------------------------------------------------------------------
# Build the JSON input for the python3 classifier: one record per candidate,
# already resolved to an absolute path plus its git-ignore verdict (computed
# in bash, since `git check-ignore` is a subprocess call best kept out of the
# python3 half). Pattern matching itself happens in python3 for portable,
# component-wise path matching (os.path based) rather than a second,
# divergent bash implementation.
# ---------------------------------------------------------------------------

NOTICES=()
RECORDS_JSON="[]"

if [ "${#CANDIDATES[@]}" -gt 0 ]; then
  RECORDS_TMP=$(mktemp)
  trap 'rm -f "$RECORDS_TMP"' EXIT

  {
    for candidate in "${CANDIDATES[@]}"; do
      CAND_PATH="$ROOT_ABS/$candidate"
      if [ ! -e "$CAND_PATH" ]; then
        NOTICES+=("candidate '$candidate' does not exist under '$ROOT_ABS' — skipped")
        continue
      fi
      if [ ! -d "$CAND_PATH" ]; then
        NOTICES+=("candidate '$candidate' is not a directory — skipped")
        continue
      fi
      CAND_ABS=$(cd -- "$CAND_PATH" && pwd -P)

      GITIGNORED="false"
      if [ "$GITIGNORE_AVAILABLE" -eq 1 ]; then
        if git -C "$ROOT_ABS" check-ignore -q -- "$CAND_ABS" 2>/dev/null; then
          GITIGNORED="true"
        fi
      fi

      printf '%s\t%s\t%s\n' "$candidate" "$CAND_ABS" "$GITIGNORED"
    done
  } > "$RECORDS_TMP"

  if [ "$GITIGNORE_AVAILABLE" -eq 0 ]; then
    NOTICES+=("root is not inside a git working tree — gitignore check skipped for all candidates")
  fi

  RECORDS_JSON=$(python3 -c '
import json, sys
records = []
with open(sys.argv[1], "r") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        path, abs_path, gitignored = parts
        records.append({"path": path, "absolute_path": abs_path, "gitignored": gitignored == "true"})
print(json.dumps(records))
' "$RECORDS_TMP")
fi

NOTICES_JSON=$(python3 -c '
import json, sys
print(json.dumps(sys.argv[1:]))
' "${NOTICES[@]:-}")
# printf with an empty array above can leave one empty-string arg; strip it.
if [ "${#NOTICES[@]}" -eq 0 ]; then
  NOTICES_JSON="[]"
fi

python3 -c '
import json, sys, os

root = sys.argv[1]
root_absolute = sys.argv[2]
records = json.loads(sys.argv[3])
notices = json.loads(sys.argv[4])
patterns = sys.argv[5:]

def pattern_reason(path):
    # Path-COMPONENT match, never substring: split on os.sep and compare
    # each component (and a suffix-glob case for *.egg-info) against the
    # fixed pattern list.
    components = [c for c in path.split(os.sep) if c]
    for comp in components:
        for pat in patterns:
            if pat.startswith("*."):
                suffix = pat[1:]
                if comp.endswith(suffix):
                    return "pattern:" + pat
            elif comp == pat:
                return "pattern:" + pat
    return None

ignored = []
remaining = []

for rec in records:
    path = rec["path"]
    abs_path = rec["absolute_path"]
    if rec.get("gitignored"):
        ignored.append({"path": path, "absolute_path": abs_path, "reason": "gitignore"})
        continue
    reason = pattern_reason(path)
    if reason:
        ignored.append({"path": path, "absolute_path": abs_path, "reason": reason})
    else:
        remaining.append({"path": path, "absolute_path": abs_path})

report = {
    "script": "directory-triage.sh",
    "version": 1,
    "root": root,
    "root_absolute": root_absolute,
    "candidate_count": len(records),
    "ignored_count": len(ignored),
    "remaining_count": len(remaining),
    "ignored": ignored,
    "remaining": remaining,
    "notices": notices,
}
print(json.dumps(report, indent=2))
' "$ROOT" "$ROOT_ABS" "$RECORDS_JSON" "$NOTICES_JSON" "${IGNORE_PATTERNS[@]}" > "${JSON_OUT:-/dev/stdout}"

if [ -n "$JSON_OUT" ]; then
  cat "$JSON_OUT"
fi
