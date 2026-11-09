#!/usr/bin/env bash
# e86-capture-baseline.sh - regenerate (or verify) the upgrade-and-go goldens from the pre-E86 scripts
# (epic E86, task E86_S06_T05). NOT run by tests/e86-upgrade-and-go.bats, which uses the committed goldens only.
#
# Usage:
#   bash tests/helpers/e86-capture-baseline.sh --check      regenerate into a temp dir and compare with the committed goldens
#                                                           (exit 0 identical, 1 differs); writes nothing in the repository
#   bash tests/helpers/e86-capture-baseline.sh --write      regenerate and overwrite tests/fixtures/e86-two-digit-golden/golden/
#   bash tests/helpers/e86-capture-baseline.sh --refreeze   rebuild the frozen board (board/ and commits.txt) from
#                                                           tests/helpers/mixed-width-board.sh --two-digit plus the real-board
#                                                           slice read from the baseline ref; then run --write
#   bash tests/helpers/e86-capture-baseline.sh -h | --help
#   Option: --ref <ref>   baseline ref (default 39c530fa, the HEAD before any E86 change)
#
# What it does: extracts the baseline ref's scripts (git archive of scripts/, skills/, lib/ and project/app/api/) into a
# temporary directory, then calls e86_run_all from tests/helpers/e86-upgrade-and-go-lib.sh, the same function the bats file
# calls with the current checkout, so the baseline and the current scripts run the identical invocations on the identical
# frozen board. Scripts that do not exist at the baseline (scripts/next-board-id.sh, the shared scripts/lib/) are not run:
# the next-ID goldens come from the old numbering rule (e86_old_next_id in the library).
#
# Needs git, bash, python3, jq, node (the dashboard parser) and the baseline commit in the local object database (it is
# absent from the public mirror; the goldens exist so the test never needs it). No network. Temporary files only, removed
# on exit; the only repository writes are --write and --refreeze, below tests/fixtures/e86-two-digit-golden/.
#
# Exit codes: 0 ok / identical; 1 --check found a difference; 2 usage; 3 baseline ref or a tool unavailable; 4 a step failed.

set -u
umask 022

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
FX="$REPO_ROOT/tests/fixtures/e86-two-digit-golden"
REF="39c530fa"
MODE=""

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check|--write|--refreeze) MODE="$1" ;;
    --ref) shift; [ $# -gt 0 ] || { echo "e86-capture-baseline: --ref needs a value" >&2; exit 2; }; REF="$1" ;;
    *) echo "e86-capture-baseline: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "e86-capture-baseline: one of --check, --write, --refreeze is required" >&2; usage >&2; exit 2; }

for tool in git python3 jq node tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "e86-capture-baseline: $tool is required" >&2; exit 3; }
done
git -C "$REPO_ROOT" cat-file -e "$REF^{commit}" 2>/dev/null || {
  echo "e86-capture-baseline: baseline ref $REF is not in this repository's object database" >&2; exit 3; }

# shellcheck source=tests/helpers/e86-upgrade-and-go-lib.sh
. "$REPO_ROOT/tests/helpers/e86-upgrade-and-go-lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/e86-capture.XXXXXX")" || exit 4
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# The frozen tree is stored as board/proj/ (copied to project/ when the harness is built): the public mirror's
# .publicignore patterns (project/board/, project/queue/, project/todo.md, ...) match at any depth, so a board/project/ copy
# would arrive in the mirror without its board.
#
# The real board slice frozen next to the generated board: ID-disjoint from it where possible, read from the baseline
# ref (never the working tree), so the freeze is reproducible. Two epics, two stories, two tasks.
SLICE="
project/board/epics/E02_agent-conversation-guardrails.md
project/board/stories/E02_S02_spinoff-skill.md
project/board/epics/E03_parallel-workflow-orchestration.md
project/board/stories/E03_S01_dooo-parallel-execution-orchestrator.md
project/board/tasks/E03_S01_T02_scaffold-dooo-skill.md
project/board/tasks/E03_S01_T04_update-help-skill-listing.md
"

refreeze() {
  local gen="$TMP/gen" rel base
  bash "$REPO_ROOT/tests/helpers/mixed-width-board.sh" "$gen" --two-digit > "$TMP/gen.out" 2>&1 || { cat "$TMP/gen.out" >&2; return 4; }
  rm -rf "$FX/board" "$FX/commits.txt"
  mkdir -p "$FX/board"
  cp -R "$gen/project" "$FX/board/proj" || return 4
  # Extra stories E01_S02, E01_S03 and E01_S04 (with task E01_S04_T02), derived from E01_S01 with its ID rewritten, so the
  # negotiated legacy inputs "E01s02", "e01 S04 t02" and "0103" resolve to real items instead of "not found". The epic
  # file is left as generated: changing it would change the commit the fixture's bundle manifest anchors to.
  python3 - "$FX/board/proj/board" <<'PY' || return 4
import re, sys
board = sys.argv[1]
src = open(board + "/stories/E01_S01_fixture-story.md").read()
task = open(board + "/tasks/E01_S01_T02_fixture-task.md").read()
for n, tasks in (("02", []), ("03", []), ("04", ["E01_S04_T02"])):
    sid = "E01_S" + n
    body = src.replace("E01_S01", sid)
    block = "tasks:\n" + "".join("  - %s\n" % t for t in tasks) if tasks else "tasks: []\n"
    body = re.sub(r"tasks:\n(  - [^\n]*\n)+", block, body)
    open(board + "/stories/%s_fixture-story.md" % sid, "w").write(body)
open(board + "/tasks/E01_S04_T02_fixture-task.md", "w").write(
    task.replace("E01_S01_T02", "E01_S04_T02").replace("E01_S01_T01", "E01_S04_T01").replace("E01_S01", "E01_S04"))
PY
  : > "$FX/commits.txt"
  # "<subject>TAB<paths>" per commit, oldest first (an empty commit has no paths).
  git -C "$gen" log --reverse --format='%x01%s' --name-only | awk -v RS='\001' -v ORS='' 'NR > 1 {
    n = split($0, l, "\n"); printf "%s", l[1];
    p = ""; for (i = 2; i <= n; i++) if (l[i] != "") p = p (p == "" ? "" : " ") l[i];
    printf "\t%s\n", p }' >> "$FX/commits.txt"
  for rel in project/board/stories/E01_S02_fixture-story.md project/board/stories/E01_S03_fixture-story.md \
    project/board/stories/E01_S04_fixture-story.md project/board/tasks/E01_S04_T02_fixture-task.md; do
    base="$(basename "$rel" _fixture-story.md)"
    case "$rel" in
      */stories/*) printf 'story(%s): add fixture story\t%s\n' "$base" "$rel" >> "$FX/commits.txt" ;;
      */tasks/*) printf 'task(E01_S04_T02): add fixture task\t%s\n' "$rel" >> "$FX/commits.txt" ;;
    esac
  done
  for rel in $SLICE; do
    mkdir -p "$FX/board/proj/$(dirname "${rel#project/}")"
    git -C "$REPO_ROOT" show "$REF:$rel" > "$FX/board/proj/${rel#project/}" || { echo "slice file $rel is missing at $REF" >&2; return 4; }
    base="$(basename "$rel" .md)"
    case "$rel" in
      */epics/*) printf 'epic(%s): add real-board slice\t%s\n' "${base%%_*}" "$rel" >> "$FX/commits.txt" ;;
      */stories/*) printf 'story(%s): add real-board slice\t%s\n' "$(printf '%s' "$base" | cut -d_ -f1,2)" "$rel" >> "$FX/commits.txt" ;;
      */tasks/*) printf 'task(%s): add real-board slice\t%s\n' "$(printf '%s' "$base" | cut -d_ -f1,2,3)" "$rel" >> "$FX/commits.txt" ;;
    esac
  done
}

[ "$MODE" = "--refreeze" ] && { refreeze || exit 4; MODE="--write"; }

[ -d "$FX/board/proj" ] && [ -f "$FX/commits.txt" ] || { echo "e86-capture-baseline: frozen board missing in $FX (run --refreeze)" >&2; exit 4; }

# Extract the baseline scripts, checkout-shaped.
mkdir -p "$TMP/baseline"
git -C "$REPO_ROOT" archive "$REF" scripts skills lib project/app/api | tar -x -C "$TMP/baseline" || exit 4

E86_NODE_PATH="$(e86_node_path "$REPO_ROOT")" || { echo "e86-capture-baseline: gray-matter is not resolvable from project/app/api (run npm install)" >&2; exit 3; }
export E86_NODE_PATH

( e86_run_all "$FX" "$TMP/baseline" "$TMP/work" "$TMP/out" ) || { echo "e86-capture-baseline: the baseline run failed" >&2; exit 4; }

# Evidence files stay out of the goldens: they describe the run, not a script's output.
rm -f "$TMP/out/tree-before.txt" "$TMP/out/tree-after.txt" "$TMP/out/git-status-after.txt"

case "$MODE" in
  --write)
    rm -rf "$FX/golden"
    mkdir -p "$FX/golden"
    cp "$TMP/out/"*.txt "$FX/golden/" || exit 4
    echo "e86-capture-baseline: wrote $(ls "$FX/golden" | wc -l | tr -d ' ') golden files from baseline $REF into ${FX#"$REPO_ROOT"/}/golden"
    ;;
  --check)
    if diff -r "$FX/golden" "$TMP/out" > "$TMP/diff.txt"; then
      echo "e86-capture-baseline: the baseline run ($REF) reproduces the committed goldens byte for byte ($(ls "$TMP/out" | wc -l | tr -d ' ') files)"
    else
      cat "$TMP/diff.txt"
      echo "e86-capture-baseline: the baseline run ($REF) does NOT reproduce the committed goldens" >&2
      exit 1
    fi
    ;;
esac
