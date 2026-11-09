#!/usr/bin/env bats
#
# E86_S06_T05: the upgrade-and-go regression. The proof that width-agnostic board IDs need no migration step.
#
# Method (documented in project/documentation/board-ids.md, section "Fixture and regression method"):
#   - tests/fixtures/e86-two-digit-golden/board/ is a frozen two-digit-only board (the generator's --two-digit variant
#     plus a six-file slice of the real board), and commits.txt replays its throwaway git history with pinned dates.
#   - tests/fixtures/e86-two-digit-golden/golden/ holds the output of the PRE-E86 scripts (baseline ref 39c530fa) on that
#     board, captured once by tests/helpers/e86-capture-baseline.sh and committed.
#   - This file runs the CURRENT scripts through the same function the capture used (e86_run_all in
#     tests/helpers/e86-upgrade-and-go-lib.sh: same invocations, same board, same output filter) and asserts each output
#     file is byte-identical to its golden. The git ref is never needed here, so the test also runs in the public mirror.
#
# Isolation: the harness project, its throwaway git repository, TMPDIR, HOME and every scratch file live under
# $BATS_FILE_TMPDIR. The scripts are pointed at the harness through JENGA_PROJECT_ROOT, JENGA_PROJECT_DIR and
# CLAUDE_PROJECT_DIR, and run as copies installed inside it. Nothing here touches this repository's own project/ tree
# and nothing needs the network. Nothing is renamed and there is no migration step.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FX="$REPO_ROOT/tests/fixtures/e86-two-digit-golden"
LIB="$REPO_ROOT/tests/helpers/e86-upgrade-and-go-lib.sh"
CAPTURE="$REPO_ROOT/tests/helpers/e86-capture-baseline.sh"

setup_file() {
  F="$BATS_FILE_TMPDIR"
  mkdir -p "$F/tmp"
  export TMPDIR="$F/tmp"
  command -v jq >/dev/null 2>&1 || return 0
  # shellcheck source=tests/helpers/e86-upgrade-and-go-lib.sh
  . "$LIB"
  E86_NODE_PATH="$(e86_node_path "$REPO_ROOT" 2>/dev/null)" || E86_NODE_PATH=""
  export E86_NODE_PATH
  rc=0
  ( e86_run_all "$FX" "$REPO_ROOT" "$F/work" "$F/out" ) > "$F/run.log" 2>&1 || rc=$?
  echo "$rc" > "$F/run.rc"
}

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  F="$BATS_FILE_TMPDIR"
  OUT="$F/out"
  [ "$(cat "$F/run.rc")" = "0" ] || { cat "$F/run.log" >&2; return 1; }
}

# golden_identical <name>  - the current scripts' output file equals the committed golden, byte for byte.
golden_identical() {
  [ -f "$FX/golden/$1.txt" ]
  [ -f "$OUT/$1.txt" ]
  run diff -u "$FX/golden/$1.txt" "$OUT/$1.txt"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" | head -60 >&2
    return 1
  fi
}

@test "the harness is a temp-tree copy of the frozen board and the run touched nothing else" {
  [ "$(ls "$F/work")" != "" ]
  case "$F" in "$REPO_ROOT"/*) false ;; esac
  [ -d "$F/work/h/.git" ]
  [ -z "$(grep -rlF "$REPO_ROOT" "$OUT" || true)" ]
  [ -z "$(grep -rlF "$F/work" "$OUT" || true)" ]
}

@test "the frozen board is two-digit only, sanitised, and replays to the history the goldens were captured on" {
  # every board ID in every file name has at most two digits per segment
  run bash -c "cd '$FX/board/proj/board' && find . -type f | grep -E '/E[0-9]{3,}|_S[0-9]{3,}|_T[0-9]{3,}'"
  [ "$status" -eq 1 ]
  # no absolute path of a developer machine, no secret-shaped content
  run grep -rEn '/Users/|/home/[a-z]|C:\\|BEGIN [A-Z ]*PRIVATE KEY|api[_-]?key|password|secret' "$FX/board" "$FX/commits.txt"
  [ "$status" -eq 1 ]
  # the replayed throwaway history carries the commit that the fixture's bundle manifest and handoffs anchor to
  anchor="$(jq -r .anchor_sha "$FX/board/proj/queue/bundle-E01_S01.json")"
  [ "$(git -C "$F/work/h" cat-file -t "$anchor")" = "commit" ]
  [ "$(git -C "$F/work/h" log -n1 --format=%s "$anchor")" = "story(E01_S01): add fixture story" ]
}

@test "validate-board.sh output is identical to the pre-E86 golden" { golden_identical validate-board; }
@test "board-scan.sh output is identical to the pre-E86 golden" { golden_identical board-scan; }
@test "cascade-resolve.sh output is identical to the pre-E86 golden" { golden_identical cascade-resolve; }
@test "resolve-id.sh output is identical to the pre-E86 golden, the legacy inputs E01s02, 'e01 S04 t02', 0103 and E01 included" {
  grep -qF "$ resolve-id.sh 'E01s02'" "$FX/golden/resolve-id.txt"
  grep -qF "$ resolve-id.sh 'e01 S04 t02'" "$FX/golden/resolve-id.txt"
  grep -qF "$ resolve-id.sh '0103'" "$FX/golden/resolve-id.txt"
  grep -qF "$ resolve-id.sh 'E01'" "$FX/golden/resolve-id.txt"
  golden_identical resolve-id
}
@test "board_index.py output is identical to the pre-E86 golden" { golden_identical board-index; }
@test "check-story-closeable.sh output is identical to the pre-E86 golden" { golden_identical check-story-closeable; }
@test "extract-task-diff-stats.sh output is identical to the pre-E86 golden" { golden_identical extract-task-diff-stats; }
@test "bundle-resume.sh output is identical to the pre-E86 golden" { golden_identical bundle-resume; }
@test "validate-proposed-items.sh output is identical to the pre-E86 golden" { golden_identical validate-proposed-items; }
@test "commit-subject-check.sh output is identical to the pre-E86 golden" { golden_identical commit-subject-check; }
@test "commits-for-item.sh output is identical to the pre-E86 golden" { golden_identical commits-for-item; }
@test "render-ranked-list.sh output is identical to the pre-E86 golden" { golden_identical render-ranked-list; }
@test "next-board-id.sh gives the old numbering rule's next ID for every parent on the two-digit board" {
  # the baseline has no allocator: the golden holds the old rule's answers (highest number plus one, padded to two digits)
  grep -qF "$ next epic" "$FX/golden/next-board-id.txt"
  golden_identical next-board-id
}
@test "the dashboard board listing (parseBoard as JSON) is identical to the pre-E86 golden" {
  [ -n "$E86_NODE_PATH" ] || skip "gray-matter is not resolvable from project/app/api (npm install not run)"
  command -v node >/dev/null 2>&1 || skip "node is required"
  golden_identical dashboard-board
}

@test "every compared script has a golden with its cases and the golden set has no stray file" {
  for n in validate-board board-scan cascade-resolve resolve-id board-index check-story-closeable extract-task-diff-stats \
    bundle-resume validate-proposed-items commit-subject-check commits-for-item render-ranked-list next-board-id dashboard-board; do
    [ "$(grep -c '^=== end$' "$FX/golden/$n.txt")" -ge 1 ]
  done
  [ "$(ls "$FX/golden" | wc -l | tr -d ' ')" -eq 14 ]
  [ "$(ls "$OUT" | grep -v -x -e tree-before.txt -e tree-after.txt -e git-status-after.txt | wc -l | tr -d ' ')" -eq 14 ]
}

@test "nothing is renamed: every board file keeps its name and content after every script ran" {
  cmp "$OUT/tree-before.txt" "$OUT/tree-after.txt"
  # the harness tree is the committed frozen tree, file for file
  run diff -r "$FX/board/proj" "$F/work/h/project"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$OUT/tree-after.txt" | tr -d ' ')" -eq "$(find "$FX/board/proj" -type f | wc -l | tr -d ' ')" ]
  # git sees no rename, deletion, modification or new file below project/
  [ -z "$(git -C "$F/work/h" status --porcelain)" ]
  [ "$(head -n1 "$OUT/git-status-after.txt")" = "$(git -C "$F/work/h" rev-parse HEAD)" ]
}

@test "no migration step: the unmodified two-digit board gives the current scripts the same results the old ones gave" {
  # The goldens were captured by the pre-E86 scripts on this exact, untouched board and the current scripts reproduce them
  # (the per-script tests above), with no command run between "board as it was" and "scripts run": the run issued only
  # the scripts, the tree did not change (the test above), and the board it read has no file or ID wider than two digits.
  [ "$(grep -h -c '^exit=0$' "$FX/golden/validate-board.txt")" -ge 1 ]
  [ "$(grep -h -c '^exit=0$' "$OUT/validate-board.txt")" = "$(grep -h -c '^exit=0$' "$FX/golden/validate-board.txt")" ]
  [ "$(find "$F/work/h/project" -type f | wc -l | tr -d ' ')" -eq "$(find "$FX/board/proj" -type f | wc -l | tr -d ' ')" ]
  [ -z "$(find "$F/work/h/project" -type f -newer "$F/work/h/.git/HEAD" | head -1)" ]
}

@test "the capture helper is a regeneration path only: it explains itself and refuses cleanly without the baseline ref" {
  run bash "$CAPTURE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--check"* && "$output" == *"--write"* && "$output" == *"39c530fa"* ]]
  run bash "$CAPTURE" --check --ref 0000000000000000000000000000000000000000
  [ "$status" -eq 3 ]
  run bash "$CAPTURE"
  [ "$status" -eq 2 ]
  # the test itself never calls it
  [ -z "$(grep -n 'e86-capture-baseline' "$LIB" | grep -v '^[0-9]*:#' || true)" ]
}
