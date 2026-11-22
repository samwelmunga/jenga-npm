#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for skills/j-break/scripts/run-progress.sh (E92_S02_T04) and the shared ledger reader it uses
# (skills/j-break/scripts/lib/ledger_reader.py).
#
# E92_S06_T22: the after-task call is `--scope story --task <id>[,<id>...]` (one line per distinct parent story, in
# first-seen order). `--resolve-scope` and `--scope run` are kept for compatibility and keep their tests below.
#
# E92_S08_T07: story scope draws with the Node renderer (lib/progress/cli.js after-task / after-story) by default;
# `--legacy` and JENGA_PROGRESS_RENDERER=legacy keep the old bash drawing, locked byte for byte against output captured
# from the script before E92_S08_T07 (the GOLDEN_* values below). Tests that lock the old drawing pass `--legacy`.
# Every Node call pays the label-table cost (seconds on a slow machine), so the Node tests are kept to what they prove.
#
# Each test builds a throwaway project root (JENGA_PROJECT_ROOT) with a fixture board and a fixture ledger written the
# way tests/record-execution.bats does (through record-execution.sh). The real board, queue and ledger are never read or
# written. Tests that need a board-progress.sh of their own run the wrapper from a copied script tree whose
# scripts/board-progress.sh is a stub.
#
# Fixture board (epic E1):
#   E1_S1  T1 Passed, T2 In Progress, T3 Pending, T4 Passed with remarks
#   E1_S2  T1 Passed, T2 Failed
#   E1_S3  T1 Pending                                  (a one-task story)
#   E1_S4  (no tasks)

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RP="$REPO_ROOT/skills/j-break/scripts/run-progress.sh"
REC="$REPO_ROOT/skills/j-break/scripts/record-execution.sh"
RENDER_STATUS="$REPO_ROOT/skills/j-break/scripts/render-execution-status.sh"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs" "$PROJ/project/board/epics" "$PROJ/project/board/stories" "$PROJ/project/board/tasks"
  cat > "$PROJ/project/configs/workflow.json" <<'EOF'
{
  "paths": {
    "board": "project/board",
    "epics": "project/board/epics",
    "stories": "project/board/stories",
    "tasks": "project/board/tasks",
    "queue": "project/queue",
    "configs": "project/configs"
  }
}
EOF
  printf '{"bundle_lock_ttl_minutes": 30}\n' > "$PROJ/project/configs/scope-thresholds.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  unset NO_COLOR JENGA_PROGRESS_LANG LC_CTYPE COLUMNS
  export LANG="en_US.UTF-8"
  unset LC_ALL
  LEDGER="$PROJ/project/queue/execution-ledger.jsonl"

  epic E1 Pending
  story E1_S1 Pending; story E1_S2 Pending; story E1_S3 Pending; story E1_S4 Pending
  task E1_S1_T1 E1_S1 Passed
  task E1_S1_T2 E1_S1 "In Progress"
  task E1_S1_T3 E1_S1 Pending
  task E1_S1_T4 E1_S1 "Passed with remarks"
  task E1_S2_T1 E1_S2 Passed
  task E1_S2_T2 E1_S2 Failed
  task E1_S3_T1 E1_S3 Pending
}

# --- fixture builders (same shape as tests/break-status.bats) ----------------------------------------------------

epic()  { printf -- '---\nid: %s\ntitle: epic %s\nstatus: %s\n---\n' "$1" "$1" "$2" > "$PROJ/project/board/epics/$1_x.md"; }
story() { printf -- '---\nid: %s\nepic_id: E1\ntitle: story %s\nstatus: %s\n---\n' "$1" "$1" "$2" > "$PROJ/project/board/stories/$1_x.md"; }
task()  { printf -- '---\nid: %s\nstory_id: %s\nepic_id: E1\ntitle: task %s\nstatus: %s\n---\n' "$1" "$2" "$1" "$3" > "$PROJ/project/board/tasks/$1_x.md"; }

# ledger <task> <status> <session>: an entry written by the real recorder.
ledger() { bash "$REC" "$1" "$2" --session "$3"; }

# A copy of the script tree whose scripts/board-progress.sh is a stub that records its arguments and prints fixed JSON.
make_stub_tree() {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/skills/j-break/scripts/lib" "$TREE/scripts/lib"
  cp "$RP" "$TREE/skills/j-break/scripts/run-progress.sh"
  cp "$REPO_ROOT/skills/j-break/scripts/lib/ledger_reader.py" "$TREE/skills/j-break/scripts/lib/"
  cp "$REPO_ROOT/scripts/render-progress-bar.sh" "$REPO_ROOT/scripts/resolve-root.sh" "$REPO_ROOT/scripts/checklist-marker.sh" "$TREE/scripts/"
  cp "$REPO_ROOT/scripts/lib/progress-labels.sh" "$TREE/scripts/lib/"
  ARGLOG="$BATS_TEST_TMPDIR/stub-args"
  cat > "$TREE/scripts/board-progress.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGLOG"
cat <<'JSON'
{"schema_version":1,"scope":{"type":"ids","ids":["x"]},"levels":{"tasks":{"counts":{},"totals":{"done":7,"in_progress":1,"failed":0,"pending":1,"rejected":0,"unknown":0,"denominator":9}}},"warnings":[]}
JSON
EOF
  TREE_RP="$TREE/skills/j-break/scripts/run-progress.sh"
}

# strip ANSI colour escapes
plain() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

# b64 <base64>: the decoded bytes on stdout.
b64() { python3 -c 'import base64, sys; sys.stdout.buffer.write(base64.b64decode(sys.argv[1]))' "$1"; }

# The Node entry point the script calls, run the way it runs it.
CLI="$REPO_ROOT/lib/progress/cli.js"

# A PATH with every executable of the current PATH except node.
nodeless_path() {
  local stub="$BATS_TEST_TMPDIR/nodeless-bin" dir f n
  mkdir -p "$stub"
  local IFS=:
  for dir in $PATH; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      n="${f##*/}"
      [ "$n" != "node" ] && [ -x "$f" ] && [ ! -e "$stub/$n" ] && ln -s "$f" "$stub/$n"
    done
  done
  printf '%s' "$stub"
}

# A full copy of the scripts, the j-break scripts and (optionally) the Node renderer, so a test can replace one piece.
# make_full_tree [with-node]  ->  $FULL (root), $FULL_RP
make_full_tree() {
  FULL="$BATS_TEST_TMPDIR/full"
  rm -rf "$FULL"; mkdir -p "$FULL/skills/j-break/scripts/lib" "$FULL/lib"
  cp -R "$REPO_ROOT/scripts" "$FULL/scripts"
  cp "$RP" "$REPO_ROOT/skills/j-break/scripts/story-finished.sh" "$FULL/skills/j-break/scripts/"
  cp "$REPO_ROOT/skills/j-break/scripts/lib/ledger_reader.py" "$FULL/skills/j-break/scripts/lib/"
  if [ "${1:-}" = "with-node" ]; then
    cp -R "$REPO_ROOT/lib/progress" "$REPO_ROOT/lib/config" "$FULL/lib/"
    printf '{"type": "module"}\n' > "$FULL/package.json"
  fi
  FULL_RP="$FULL/skills/j-break/scripts/run-progress.sh"
}

# Output of the script before E92_S08_T07 on this file's fixture board, captured with the pre-change script (base64,
# exact bytes). Each is the story-scope call named next to it, with a fresh queue directory.
#   A  --task E1_S2_T2 --color never --cols 80                        [━━━━━╌╌╌╌╌]⚑ 1/2 · 1 red
#   B  --task E1_S2_T1,E1_S1_T1 --color never --cols 80                (two lines: E1_S2, then E1_S1)
#   C  --task E1_S2_T2 --color always --cols 80                        (ANSI colour)
#   D  --task E1_S2_T2 --color never --cols 14                         1/2 · 1 red
#   E  --task E1_S1_T1,E1_S2_T2 --after-story --color never --cols 80  (two bars, then the E1_S2 story line)
#   F  --task E1_S2_T2 --after-story --color always --cols 80          (ANSI colour, bar and story line)
#   G  LANG=C, --task E1_S2_T2 --after-story --color never --cols 80   (ASCII fallback of the legacy renderers)
GOLDEN_A='W+KUgeKUgeKUgeKUgeKUgeKVjOKVjOKVjOKVjOKVjF3impEgMS8yIMK3IDEgcmVkCg=='
GOLDEN_B='W+KUgeKUgeKUgeKUgeKUgeKVjOKVjOKVjOKVjOKVjF3impEgMS8yIMK3IDEgcmVkClvilIHilIHilIHilIHilIHilYzilYzilYzilYzilYxd4pqRIDIvNCDCtyAxIGluIHByb2dyZXNzCg=='
GOLDEN_C='WxtbMzJt4pSB4pSB4pSB4pSB4pSBG1swbRtbMzFt4pWM4pWM4pWM4pWM4pWMG1swbV3impEgMS8yIMK3IDEgcmVkCg=='
GOLDEN_D='MS8yIMK3IDEgcmVkCg=='
GOLDEN_E='W+KUgeKUgeKUgeKUgeKUgeKVjOKVjOKVjOKVjOKVjF3impEgMi80IMK3IDEgaW4gcHJvZ3Jlc3MKW+KUgeKUgeKUgeKUgeKUgeKVjOKVjOKVjOKVjOKVjF3impEgMS8yIMK3IDEgcmVkCkUxX1MyICDilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHimIUgMS8yIMK3IDUwICUgIOKclSAxIGZhaWxlZAo='
GOLDEN_F='WxtbMzJt4pSB4pSB4pSB4pSB4pSBG1swbRtbMzFt4pWM4pWM4pWM4pWM4pWMG1swbV3impEgMS8yIMK3IDEgcmVkChtbMzZtRTFfUzIbWzBtICAbWzMybeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgRtbMG0bWzMxbeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgRtbMG0bWzMxbeKYhRtbMG0gG1sxbTEvMhtbMG0gwrcgNTAgJSAgG1szMW3inJUgMSBmYWlsZWQbWzBtCg=='
GOLDEN_G='WyMjIyMjLS0tLS1dPiAxLzIgLSAxIHJlZApFMV9TMiAgIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjKiAxLzIgLSA1MCAlICAhIDEgZmFpbGVkCg=='

# golden_args <letter>: the run-progress.sh arguments of that golden case (LANG is set by the caller for G).
golden_args() {
  case "$1" in
    A) echo "--scope story --task E1_S2_T2 --color never --cols 80" ;;
    B) echo "--scope story --task E1_S2_T1,E1_S1_T1 --color never --cols 80" ;;
    C) echo "--scope story --task E1_S2_T2 --color always --cols 80" ;;
    D) echo "--scope story --task E1_S2_T2 --color never --cols 14" ;;
    E) echo "--scope story --task E1_S1_T1,E1_S2_T2 --after-story --color never --cols 80" ;;
    F) echo "--scope story --task E1_S2_T2 --after-story --color always --cols 80" ;;
    G) echo "--scope story --task E1_S2_T2 --after-story --color never --cols 80" ;;
  esac
}

# ---------------------------------------------------------------------------------------------------------------------

@test "executable and passes bash -n" {
  [ -x "$RP" ]
  bash -n "$RP"
  [ -x "$REPO_ROOT/skills/j-break/scripts/lib/ledger_reader.py" ]
}

# --- --resolve-scope ------------------------------------------------------------------------------------------------

@test "--resolve-scope prints run for a 3-task id list" {
  run bash "$RP" --resolve-scope --ids E1_S1_T1,E1_S1_T2,E1_S2_T1
  [ "$status" -eq 0 ]
  [ "$output" = "run" ]
}

@test "--resolve-scope prints story for a single task id" {
  run bash "$RP" --resolve-scope --ids E1_S1_T1
  [ "$status" -eq 0 ]
  [ "$output" = "story" ]
}

@test "--resolve-scope prints run for a story id that expands to 2 or more tasks, story for a one-task story" {
  run bash "$RP" --resolve-scope --ids E1_S1
  [ "$status" -eq 0 ]; [ "$output" = "run" ]
  run bash "$RP" --resolve-scope --ids E1_S3
  [ "$status" -eq 0 ]; [ "$output" = "story" ]
}

@test "--resolve-scope expands an epic id, and counts a task once however many ids name it" {
  run bash "$RP" --resolve-scope --ids E1
  [ "$status" -eq 0 ]; [ "$output" = "run" ]
  run bash "$RP" --resolve-scope --ids E1_S3_T1,E1_S3,E1_S3_T1
  [ "$status" -eq 0 ]; [ "$output" = "story" ]
}

@test "--resolve-scope on an unknown id warns, prints nothing and exits 0" {
  run --separate-stderr bash "$RP" --resolve-scope --ids E77
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == "run-progress.sh: warning: "* ]]
}

# --- --scope run ------------------------------------------------------------------------------------------------------

@test "--scope run with a story id counts that story's tasks" {
  run --separate-stderr bash "$RP" --scope run --ids E1_S1 --session s --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *" 2/4"* ]]           # E1_S1: 2 of 4 tasks done
  [[ "$output" == *"1 in progress"* ]]
}

@test "--scope run prints exactly one newline-terminated line" {
  run bash -c "bash '$RP' --scope run --ids E1_S1 --session s --color never --cols 80 | wc -l | tr -d ' '"
  [ "$output" = "1" ]
}

@test "--scope run with a ledger entry for a task outside the given ids counts that task too" {
  ledger E1_S2_T1 Passed sess-a
  run bash "$RP" --scope run --ids E1_S1 --session sess-a --color never --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *" 3/5"* ]]           # 4 tasks of E1_S1 plus E1_S2_T1, which is Passed
}

@test "a ledger entry for a Failed task of this session is part of the run too" {
  ledger E1_S2_T2 Failed sess-a
  run bash "$RP" --scope run --ids E1_S1 --session sess-a --color never --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *" 2/5"* ]]
  [[ "$output" == *"1 red"* ]]
}

@test "a ledger entry for a different session key is ignored" {
  ledger E1_S2_T1 Passed sess-other
  run bash "$RP" --scope run --ids E1_S1 --session sess-a --color never --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *" 2/4"* ]]
}

@test "a ledger task that is also in the given ids is counted once" {
  ledger E1_S1_T1 Passed sess-a
  run bash "$RP" --scope run --ids E1_S1 --session sess-a --color never --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *" 2/4"* ]]
}

@test "a ledger entry for a story id is not mistaken for a task" {
  ledger E1_S2 Merged sess-a
  run --separate-stderr bash "$RP" --scope run --ids E1_S1 --session sess-a --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *" 2/4"* ]]
}

@test "the session key comes from checklist-marker.sh session-key when --session is absent" {
  local key; key="$(bash "$REPO_ROOT/scripts/checklist-marker.sh" session-key 2>/dev/null)" || skip "no session key resolvable in this environment"
  ledger E1_S2_T1 Passed "$key"
  run bash "$RP" --scope run --ids E1_S1 --color never --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *" 3/5"* ]]
}

# --- --scope story ----------------------------------------------------------------------------------------------------

@test "--scope story counts the parent story's tasks, not the whole run (the after-task call)" {
  ledger E1_S1_T1 Passed sess-a
  run bash "$RP" --scope story --task E1_S2_T1 --session sess-a --color never --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *" 1/2"* ]]           # E1_S2: T1 Passed, T2 Failed
  [[ "$output" == *"1 red"* ]]
}

@test "--scope story reads the parent from the task's own story_id" {
  # A task whose id says S1 but whose story_id says E1_S3 belongs to E1_S3.
  task E1_S1_T9 E1_S3 Passed
  run bash "$RP" --scope story --task E1_S1_T9 --color never --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *" 1/2"* ]]           # E1_S3: T1 Pending, plus the re-parented T9 (Passed)
}

@test "--scope story takes a list: one line per distinct parent story, in first-seen order" {
  run --separate-stderr bash "$RP" --scope story --task E1_S2_T1,E1_S1_T1 --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]
  [[ "$(printf '%s\n' "$output" | sed -n 1p)" == *" 1/2"* ]]   # E1_S2 first: T1 Passed, T2 Failed
  [[ "$(printf '%s\n' "$output" | sed -n 2p)" == *" 2/4"* ]]   # then E1_S1
}

@test "--scope story with the list reversed reverses the lines" {
  run bash "$RP" --scope story --task E1_S1_T1,E1_S2_T1 --color never --cols 80
  [ "$status" -eq 0 ]
  [[ "$(printf '%s\n' "$output" | sed -n 1p)" == *" 2/4"* ]]
  [[ "$(printf '%s\n' "$output" | sed -n 2p)" == *" 1/2"* ]]
}

@test "--scope story with two tasks of the same story prints one line" {
  run bash "$RP" --scope story --task E1_S1_T1,E1_S1_T3 --color never --cols 80
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  [[ "$output" == *" 2/4"* ]]
}

@test "--scope story dedups a story that comes back after another one and ignores blanks and spaces in the list" {
  run bash "$RP" --scope story --task " E1_S1_T1, E1_S2_T1 ,,E1_S1_T2," --color never --cols 80
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]
  [[ "$(printf '%s\n' "$output" | sed -n 1p)" == *" 2/4"* ]]
  [[ "$(printf '%s\n' "$output" | sed -n 2p)" == *" 1/2"* ]]
}

@test "--scope story with a list asks board-progress.sh once per distinct story, in first-seen order" {
  make_stub_tree
  run bash "$TREE_RP" --scope story --task E1_S2_T2,E1_S1_T1,E1_S2_T1,E1_S1_T4 --legacy --color never --cols 80
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]
  [ "$(cat "$ARGLOG")" = "$(printf -- '--story E1_S2\n--story E1_S1')" ]
}

@test "--legacy: the single-story line is byte-identical to the legacy renderer fed the story's counts directly" {
  local bp="$REPO_ROOT/scripts/board-progress.sh" rd="$REPO_ROOT/scripts/render-progress-bar.sh" mode
  bash "$bp" --story E1_S2 > "$BATS_TEST_TMPDIR/direct.json"
  for mode in "--color never --cols 80" "--color always --cols 80" "--color never --cols 14"; do
    bash "$rd" --file "$BATS_TEST_TMPDIR/direct.json" $mode > "$BATS_TEST_TMPDIR/expected"
    bash "$RP" --scope story --task E1_S2_T2 --legacy $mode > "$BATS_TEST_TMPDIR/actual"
    cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual" || { echo "differs for: $mode" >&2; return 1; }
  done
  # NO_COLOR and the ASCII fallback go through the same renderer, unchanged
  NO_COLOR=1 bash "$rd" --file "$BATS_TEST_TMPDIR/direct.json" --cols 80 > "$BATS_TEST_TMPDIR/expected"
  NO_COLOR=1 bash "$RP" --scope story --task E1_S2_T2 --legacy --cols 80 > "$BATS_TEST_TMPDIR/actual"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual"
  LANG=C bash "$rd" --file "$BATS_TEST_TMPDIR/direct.json" --color never --cols 80 > "$BATS_TEST_TMPDIR/expected"
  LANG=C bash "$RP" --scope story --task E1_S2_T2 --legacy --color never --cols 80 > "$BATS_TEST_TMPDIR/actual"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual"
}

@test "--scope story: an unknown id anywhere in the list warns once, prints nothing and exits 0" {
  run --separate-stderr bash "$RP" --scope story --task E1_S1_T1,E1_S1_T99,E1_S2_T1 --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == "run-progress.sh: warning: "* ]]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = "1" ]
}

@test "--scope story: a task that names no story warns once, prints nothing and exits 0" {
  printf -- '---\nid: E1_S1_T7\ntitle: orphan\nstatus: Pending\n---\n' > "$PROJ/project/board/tasks/E1_S1_T7_x.md"
  run --separate-stderr bash "$RP" --scope story --task E1_S1_T7 --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == "run-progress.sh: warning: "* ]]
  run --separate-stderr bash "$RP" --scope story --task E1_S1_T1,E1_S1_T7 --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == "run-progress.sh: warning: "* ]]
}

@test "--scope story: a list of only blanks warns and exits 0" {
  run --separate-stderr bash "$RP" --scope story --task " , ," --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == "run-progress.sh: warning: "* ]]
}

@test "--scope story: a missing helper warns and exits 0, for a single id and for a list" {
  make_stub_tree
  rm "$TREE/scripts/render-progress-bar.sh"
  run --separate-stderr bash "$TREE_RP" --scope story --task E1_S1_T1 --legacy --color never
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == *"warning"*"render-progress-bar.sh"* ]]
  run --separate-stderr bash "$TREE_RP" --scope story --task E1_S1_T1,E1_S2_T1 --legacy --color never
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == *"warning"*"render-progress-bar.sh"* ]]
  make_stub_tree
  rm "$TREE/scripts/resolve-root.sh"
  run --separate-stderr bash "$TREE_RP" --scope story --task E1_S1_T1,E1_S2_T1 --color never
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == *"warning"*"resolve-root.sh"* ]]
}

# --- forwarded options ------------------------------------------------------------------------------------------------

@test "--cols is forwarded: the line never exceeds the width" {
  run bash "$RP" --scope run --ids E1_S1 --session s --color never --cols 14
  [ "$status" -eq 0 ]
  [ "${#output}" -le 14 ]
  [ -n "$output" ]
}

@test "--color always is forwarded and --color never strips colour" {
  run bash "$RP" --scope run --ids E1_S1 --session s --color always --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033['* ]]
  run bash "$RP" --scope run --ids E1_S1 --session s --color never --cols 80
  [[ "$output" != *$'\033['* ]]
}

@test "--level is forwarded: a level the scope does not carry is a warning, not a failed run" {
  run --separate-stderr bash "$RP" --scope run --ids E1_S1 --session s --level epics --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warning"* ]]
}

# --- agreement with render-execution-status.sh -----------------------------------------------------------------------

@test "the tasks the wrapper takes from the ledger are exactly the tasks render-execution-status.sh reports as ran this session" {
  # All four tasks of E1_S1 are in a live bundle, so the status rapport lists them. Their ledger lines are: T1 and T4
  # this session (terminal), T3 another session, T2 this session but with a status that is not terminal. A story entry
  # and a malformed-free blank line are noise both readers must ignore the same way.
  mkdir -p "$PROJ/project/queue"
  printf '{"story_id":"E1_S1","started_at":"%s","tasks":["E1_S1_T1","E1_S1_T2","E1_S1_T3","E1_S1_T4"]}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PROJ/project/queue/bundle-E1_S1.json"
  task E1_S1_T3 E1_S1 Merged
  ledger E1_S1_T1 Passed sess-a
  ledger E1_S1_T4 "Passed with remarks" sess-a
  ledger E1_S1_T3 Merged sess-other
  printf '{"ts":"2026-01-01T00:00:00Z","session_key":"sess-a","item_id":"E1_S1_T2","status":"In Progress","source":"do"}\n\n' >> "$LEDGER"
  ledger E1_S1 Merged sess-a

  run bash "$RENDER_STATUS" --session sess-a
  [ "$status" -eq 0 ]
  local from_render
  from_render="$(printf '%s\n' "$output" | grep 'ran this session$' | grep -oE 'E1_S1_T[0-9]+' | sort -u | tr '\n' ' ')"
  [ "$from_render" = "E1_S1_T1 E1_S1_T4 " ]

  make_stub_tree
  run bash "$TREE/skills/j-break/scripts/run-progress.sh" --scope run --ids E1_S3_T1 --session sess-a --color never --cols 80
  [ "$status" -eq 0 ]
  local from_wrapper
  from_wrapper="$(sed 's/^--ids //' "$ARGLOG" | tr ',' '\n' | grep -vx 'E1_S3_T1' | sort | tr '\n' ' ')"
  [ "$from_wrapper" = "$from_render" ]
}

@test "the shared reader is the one both scripts use" {
  grep -q 'ledger_reader.read_session_ledger' "$RENDER_STATUS"
  grep -q 'lib/ledger_reader.py' "$RP"
  ! grep -q 'execution-ledger.jsonl' "$RP"
}

# --- a progress problem never fails a run -------------------------------------------------------------------------------

@test "an unknown id warns on stderr, prints nothing on stdout and exits 0" {
  run --separate-stderr bash "$RP" --scope run --ids E1_S9 --session s
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == "run-progress.sh: warning: "* ]]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = "1" ]
}

@test "an id of no board shape warns and exits 0" {
  run --separate-stderr bash "$RP" --scope run --ids bogus --session s
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == "run-progress.sh: warning: "* ]]
}

@test "an unknown task id in story scope warns and exits 0" {
  run --separate-stderr bash "$RP" --scope story --task E1_S1_T99
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == "run-progress.sh: warning: "* ]]
}

@test "an empty expansion (a story with no tasks) warns and exits 0" {
  run --separate-stderr bash "$RP" --scope run --ids E1_S4 --session s
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == "run-progress.sh: warning: "* ]]
}

@test "a malformed ledger line warns, prints nothing on stdout and exits 0" {
  ledger E1_S2_T1 Passed sess-a
  printf 'this is not json\n' >> "$LEDGER"
  run --separate-stderr bash "$RP" --scope run --ids E1_S1 --session sess-a
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == "run-progress.sh: warning: "* ]]
  [[ "$stderr" == *"malformed"* ]]
}

@test "a missing board-progress.sh warns and exits 0" {
  make_stub_tree
  rm "$TREE/scripts/board-progress.sh"
  run --separate-stderr bash "$TREE_RP" --scope run --ids E1_S1_T1 --session s
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warning"*"board-progress.sh"* ]]
}

@test "a missing renderer warns and exits 0" {
  make_stub_tree
  rm "$TREE/scripts/render-progress-bar.sh"
  run --separate-stderr bash "$TREE_RP" --scope run --ids E1_S1_T1 --session s
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warning"*"render-progress-bar.sh"* ]]
}

@test "a board-progress.sh that fails warns and exits 0" {
  make_stub_tree
  printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n' > "$TREE/scripts/board-progress.sh"
  run --separate-stderr bash "$TREE_RP" --scope run --ids E1_S1_T1 --session s
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warning"*"boom"* ]]
}

# --- usage errors -----------------------------------------------------------------------------------------------------

@test "missing or conflicting arguments exit 2 and print nothing on stdout" {
  local args
  for args in "" "--scope" "--scope run" "--scope story" "--scope other --ids E1_S1" "--resolve-scope" \
              "--scope run --ids E1_S1 --task E1_S1_T1" "--scope story --task E1_S1_T1 --ids E1_S1" "--scope story --task" \
              "--resolve-scope --scope run --ids E1_S1" "--resolve-scope --ids E1_S1 --task E1_S1_T1" \
              "--scope run --ids" "--wat" "--scope story --task E1_S1_T1 --charset latin1" \
              "--scope story --task E1_S1_T1 --charset"; do
    run --separate-stderr bash -c "bash '$RP' $args"
    [ "$status" -eq 2 ] || { echo "args [$args] exited $status" >&2; return 1; }
    [ -z "$output" ]
    [ -n "$stderr" ]
  done
}

# --- the wrapper does no counting and holds no status names ----------------------------------------------------------

@test "the wrapper contains no status names" {
  run grep -nE 'Pending|In Progress|Passed|Failed|Rejected|Blocked|Backlog|Merged|Done|Publicized|Deployed' "$RP"
  [ "$status" -eq 1 ]
}

@test "counts come only from board-progress.sh: a stub with fixed JSON decides the printed line" {
  make_stub_tree
  run bash "$TREE_RP" --scope run --ids E1_S1_T1,E1_S1_T2 --session s --color never --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *" 7/9"* ]]
  [[ "$output" == *"1 in progress"* ]]
  # and the wrapper asked it for exactly the expanded tasks, once
  [ "$(cat "$ARGLOG")" = "--ids E1_S1_T1,E1_S1_T2" ]
}

@test "story scope asks board-progress.sh for the parent story and nothing else (--legacy)" {
  make_stub_tree
  run bash "$TREE_RP" --scope story --task E1_S2_T2 --legacy --color never --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *" 7/9"* ]]
  [ "$(cat "$ARGLOG")" = "--story E1_S2" ]
}

@test "a story id is expanded through board-progress.sh --story --items before the counting call" {
  make_stub_tree
  run --separate-stderr bash "$TREE_RP" --scope run --ids E1_S1 --session s --color never --cols 80
  # The stub prints no items, so the expansion is empty: a warning, not a line.
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head -n1 "$ARGLOG")" = "--story E1_S1 --items" ]
}

@test "running it writes nothing in the project root" {
  ledger E1_S2_T1 Passed sess-a
  local before after
  before="$(cd "$PROJ" && find . -type f | sort | xargs cksum | cksum)"
  run bash "$RP" --scope run --ids E1_S1 --session sess-a --color never --cols 80
  [ "$status" -eq 0 ]
  after="$(cd "$PROJ" && find . -type f | sort | xargs cksum | cksum)"
  [ "$before" = "$after" ]
}

# --- E92_S08_T07: the Node drawing is the default in story scope ------------------------------------------------------

@test "default: the after-task line is the Node after-task line of the story, byte for byte, UTF-8 with no locale and no colour on a pipe" {
  LANG= node "$CLI" --color never --cols 80 after-task --story E1_S2 > "$BATS_TEST_TMPDIR/expected"
  [ -s "$BATS_TEST_TMPDIR/expected" ]
  run --separate-stderr env LANG= bash "$RP" --scope story --task E1_S2_T2 --cols 80
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(cat "$BATS_TEST_TMPDIR/expected")" ]
  [[ "$output" == "E1_S2  "*" 1/2"* ]]                             # led by the story id (the Node line)
  [[ "$output" != *$'\033['* ]]                                    # auto colour is off: the output is a pipe
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' ')" != "0" ]   # UTF-8 glyphs
}

@test "default: a list is ONE Node call for the distinct stories in first-seen order" {
  node "$CLI" --color never --cols 80 after-task --story E1_S2,E1_S1 > "$BATS_TEST_TMPDIR/expected"
  run --separate-stderr bash "$RP" --scope story --task E1_S2_T2,E1_S1_T1,E1_S2_T1 --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(cat "$BATS_TEST_TMPDIR/expected")" ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "E1_S2  "* ]]
  [[ "${lines[1]}" == "E1_S1  "* ]]
}

@test "default: --charset ascii and --color always are forwarded to Node" {
  run --separate-stderr bash "$RP" --scope story --task E1_S2_T2 --charset ascii --color never --cols 80
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' ')" = "0" ]
  run --separate-stderr bash "$RP" --scope story --task E1_S2_T2 --color always --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033['* ]]
  [[ "$(plain "$output")" == "E1_S2  "*" 1/2"* ]]
}

@test "default with --after-story: the task lines first, then the Node story line once; the ledger decides as before" {
  node "$CLI" --color never --cols 80 after-story --story E1_S2 > "$BATS_TEST_TMPDIR/story-line"
  run --separate-stderr bash "$RP" --scope story --task E1_S1_T1,E1_S2_T2 --after-story --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "E1_S1  "* ]]
  [[ "${lines[1]}" == "E1_S2  "*"1/2 · 1 red" ]]
  [ "${lines[2]}" = "$(cat "$BATS_TEST_TMPDIR/story-line")" ]
  [[ "${lines[2]}" == *"1/2 · 50 %"* ]]
  [ "$(cat "$PROJ/project/queue/story-finished-ledger.tsv")" = "E1_S2"$'\t'"1:0:1:0:0:0:2" ]
  run --separate-stderr bash "$RP" --scope story --task E1_S2_T2 --after-story --color never --cols 80
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]                                         # same finished state: no story line again
}

@test "default: an unknown id or a task naming no story still prints nothing and never reaches the renderer" {
  printf -- '---\nid: E1_S1_T7\ntitle: orphan\nstatus: Pending\n---\n' > "$PROJ/project/board/tasks/E1_S1_T7_x.md"
  for t in E1_S1_T99 E1_S1_T1,E1_S1_T7 nonsense; do
    run --separate-stderr bash "$RP" --scope story --task "$t" --after-story --color never --cols 80
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [[ "$stderr" == "run-progress.sh: warning: "* ]]
    [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = "1" ]
  done
}

@test "default: counts still come only from board-progress.sh (a stub decides the Node line too)" {
  make_full_tree with-node
  ARGLOG="$BATS_TEST_TMPDIR/stub-args"
  cat > "$FULL/scripts/board-progress.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGLOG"
cat <<'JSON'
{"schema_version":1,"scope":{"type":"story","ids":["E1_S2"]},"levels":{"tasks":{"counts":{},"totals":{"done":7,"in_progress":1,"failed":0,"pending":1,"rejected":0,"unknown":0,"denominator":9}}},"warnings":[]}
JSON
STUB
  run --separate-stderr bash "$FULL_RP" --scope story --task E1_S2_T2,E1_S1_T1 --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "${lines[0]}" == "E1_S2  "*" 7/9"* ]]
  [[ "${lines[1]}" == "E1_S1  "*" 7/9"* ]]
  [ "$(cat "$ARGLOG")" = "$(printf -- '--story E1_S2\n--story E1_S1')" ]
}

# --- E92_S08_T07: --legacy and JENGA_PROGRESS_RENDERER=legacy print the pre-change bytes ------------------------------

@test "--legacy and JENGA_PROGRESS_RENDERER=legacy print exactly the bytes the script printed before E92_S08_T07" {
  local c want form
  for c in A B C D E F G; do
    want="$BATS_TEST_TMPDIR/golden-$c"
    b64 "$(eval "echo \$GOLDEN_$c")" > "$want"
    for form in flag env; do
      rm -rf "$PROJ/project/queue"
      if [ "$form" = "flag" ]; then
        if [ "$c" = "G" ]; then LANG=C bash "$RP" $(golden_args "$c") --legacy > "$BATS_TEST_TMPDIR/actual" 2>/dev/null
        else bash "$RP" $(golden_args "$c") --legacy > "$BATS_TEST_TMPDIR/actual" 2>/dev/null; fi
      else
        if [ "$c" = "G" ]; then LANG=C JENGA_PROGRESS_RENDERER=legacy bash "$RP" $(golden_args "$c") > "$BATS_TEST_TMPDIR/actual" 2>/dev/null
        else JENGA_PROGRESS_RENDERER=legacy bash "$RP" $(golden_args "$c") > "$BATS_TEST_TMPDIR/actual" 2>/dev/null; fi
      fi
      cmp "$want" "$BATS_TEST_TMPDIR/actual" || { echo "case $c ($form) differs from the pre-change output" >&2; return 1; }
    done
  done
}

@test "--legacy matches the pre-change script itself, run from git (skipped where that commit is not in history)" {
  local base=4225b162
  git -C "$REPO_ROOT" cat-file -e "$base:skills/j-break/scripts/run-progress.sh" 2>/dev/null || skip "commit $base is not in this repository's history"
  OLD="$BATS_TEST_TMPDIR/old"; mkdir -p "$OLD"
  git -C "$REPO_ROOT" archive "$base" scripts skills/j-break/scripts | tar -x -C "$OLD"
  local c
  for c in A B E F; do
    rm -rf "$PROJ/project/queue"
    bash "$OLD/skills/j-break/scripts/run-progress.sh" $(golden_args "$c") > "$BATS_TEST_TMPDIR/expected" 2>/dev/null
    rm -rf "$PROJ/project/queue"
    bash "$RP" $(golden_args "$c") --legacy > "$BATS_TEST_TMPDIR/actual" 2>/dev/null
    cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual" || { echo "case $c differs from the script at $base" >&2; return 1; }
  done
}

@test "JENGA_PROGRESS_RENDERER with any other value keeps the Node default; --legacy needs no node at all" {
  run --separate-stderr env JENGA_PROGRESS_RENDERER=whatever bash "$RP" --scope story --task E1_S2_T2 --color never --cols 80
  [ "$status" -eq 0 ]; [ -z "$stderr" ]
  [[ "$output" == "E1_S2  "* ]]
  stub="$(nodeless_path)"
  run --separate-stderr env PATH="$stub" bash "$RP" --scope story --task E1_S2_T2 --legacy --color never --cols 80
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(b64 "$GOLDEN_A")" ]
}

# --- E92_S08_T07: never fail -- no node, or a failing Node renderer, is one warning and the legacy lines --------------

@test "node missing from PATH: one warning, the legacy lines (after-story included) and exit 0" {
  stub="$(nodeless_path)"
  run env PATH="$stub" bash -c 'command -v node'
  [ "$status" -ne 0 ]
  run --separate-stderr env PATH="$stub" bash "$RP" $(golden_args E)
  [ "$status" -eq 0 ]
  [ "$output" = "$(b64 "$GOLDEN_E")" ]
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
  [[ "$stderr" == "run-progress.sh: warning: node is not on PATH (legacy drawing used, run unaffected)" ]]
}

@test "a failing Node renderer (warning and no output, or a non-zero exit) is one warning and the legacy line, exit 0" {
  make_full_tree with-node
  for body in 'process.stderr.write("cli.js: warning: boom\n");' 'process.stderr.write("kaput\n"); process.exit(1);'; do
    printf '%s\n' "$body" > "$FULL/lib/progress/cli.js"
    rm -rf "$PROJ/project/queue"
    run --separate-stderr bash "$FULL_RP" $(golden_args E)
    [ "$status" -eq 0 ]
    [ "$output" = "$(b64 "$GOLDEN_E")" ]
    [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
    [[ "$stderr" == "run-progress.sh: warning: the Node renderer failed: "*"(legacy drawing used, run unaffected)" ]]
  done
  [[ "$stderr" == *"kaput"* ]]
}

@test "a missing cli.js is one warning and the legacy line, exit 0" {
  make_full_tree
  run --separate-stderr bash "$FULL_RP" $(golden_args A)
  [ "$status" -eq 0 ]
  [ "$output" = "$(b64 "$GOLDEN_A")" ]
  [ "$stderr" = "run-progress.sh: warning: could not locate lib/progress/cli.js (legacy drawing used, run unaffected)" ]
}

@test "story-finished.sh on its own: a failing Node renderer warns once, draws the legacy story line and records it" {
  make_full_tree with-node
  printf 'process.exit(3);\n' > "$FULL/lib/progress/cli.js"
  run --separate-stderr bash "$FULL/skills/j-break/scripts/story-finished.sh" --story E1_S2 --color never --cols 80
  [ "$status" -eq 0 ]
  [ "$output" = "$(b64 "$GOLDEN_E" | sed -n 3p)" ]
  [ "$stderr" = "story-finished.sh: warning: the Node renderer failed for E1_S2: it printed nothing (legacy drawing used, run unaffected)" ]
  [ "$(cat "$PROJ/project/queue/story-finished-ledger.tsv")" = "E1_S2"$'\t'"1:0:1:0:0:0:2" ]
}

@test "story-finished.sh: --charset is validated (exit 2) and --legacy is accepted" {
  run --separate-stderr bash "$REPO_ROOT/skills/j-break/scripts/story-finished.sh" --story E1_S2 --charset latin1
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr bash "$REPO_ROOT/skills/j-break/scripts/story-finished.sh" --story E1_S2 --legacy --color never --cols 80
  [ "$status" -eq 0 ]
  [ "$output" = "$(b64 "$GOLDEN_E" | sed -n 3p)" ]
}

# --- E92_S08_T07: permissions -------------------------------------------------------------------------------------------

@test "the Node command is not blocked at the Guarded level: Bash(*) is allowed and no deny rule matches bash or node" {
  G="$REPO_ROOT/templates/permission-levels/level-2-guarded.json"
  # E100_S04_T05: the allow list is no longer in the templates; the baseline a consumer runs is root settings.json.
  [ "$(jq -r '.permissions.allow | index("Bash(*)") != null' "$REPO_ROOT/settings.json")" = "true" ]
  # The skills run `bash <run-progress.sh> ...`, which runs node inside the script; neither word starts a deny rule.
  [ "$(jq -r '[.permissions.deny[] | select(test("^Bash\\((bash|node)( |\\*|\\))"))] | length' "$G")" = "0" ]
}
