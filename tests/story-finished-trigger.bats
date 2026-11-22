#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for the after-story line (E92_S06_T23): skills/j-break/scripts/story-finished.sh (the trigger) reached through
# `run-progress.sh --scope story --task <ids> --after-story`.
#
# Every test builds a throwaway project root (JENGA_PROJECT_ROOT) with a fixture board; the ledger therefore lands in the
# fixture's own queue directory and the real project/queue is never read or written.
#
# Fixture board (epic E1):
#   E1_S1  T1 Passed, T2 Passed                      finished, all done
#   E1_S2  T1 Passed, T2 Failed                      finished with a Failed task
#   E1_S3  T1 Pending                                not finished
#   E1_S4  T1 In Progress, T2 Passed                 not finished
#   E1_S5  T1 Passed                                 finished (a one-task story)
#   E1_S6  T1 Rejected                               nothing counted
#   E1_S7  T1 Passed, T2 Rejected                    finished, one rejected
#
# E92_S08_T07: the default drawing is now the Node renderer. This file locks the LEGACY drawing (render-progress-bar.sh,
# render-story-bar.sh) and the trigger's decision and ledger, so setup pins JENGA_PROGRESS_RENDERER=legacy and every
# assertion keeps its pre-change meaning. The Node default and the fallback are covered in tests/run-progress.bats.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RP="$REPO_ROOT/skills/j-break/scripts/run-progress.sh"
SF="$REPO_ROOT/skills/j-break/scripts/story-finished.sh"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs" "$PROJ/project/board/epics" "$PROJ/project/board/stories" "$PROJ/project/board/tasks"
  cat > "$PROJ/project/configs/workflow.json" <<'JSON'
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
JSON
  printf '{"bundle_lock_ttl_minutes": 30}\n' > "$PROJ/project/configs/scope-thresholds.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_PROGRESS_RENDERER=legacy
  unset NO_COLOR JENGA_PROGRESS_LANG LC_CTYPE COLUMNS
  export LANG="en_US.UTF-8"
  unset LC_ALL
  ESC=$'\033'
  LEDGER="$PROJ/project/queue/story-finished-ledger.tsv"

  epic E1 Pending
  for s in E1_S1 E1_S2 E1_S3 E1_S4 E1_S5 E1_S6 E1_S7; do story "$s" Pending; done
  task E1_S1_T1 E1_S1 Passed; task E1_S1_T2 E1_S1 Passed
  task E1_S2_T1 E1_S2 Passed; task E1_S2_T2 E1_S2 Failed
  task E1_S3_T1 E1_S3 Pending
  task E1_S4_T1 E1_S4 "In Progress"; task E1_S4_T2 E1_S4 Passed
  task E1_S5_T1 E1_S5 Passed
  task E1_S6_T1 E1_S6 Rejected
  task E1_S7_T1 E1_S7 Passed; task E1_S7_T2 E1_S7 Rejected
}

epic()  { printf -- '---\nid: %s\ntitle: epic %s\nstatus: %s\n---\n' "$1" "$1" "$2" > "$PROJ/project/board/epics/$1_x.md"; }
story() { printf -- '---\nid: %s\nepic_id: E1\ntitle: story %s\nstatus: %s\n---\n' "$1" "$1" "$2" > "$PROJ/project/board/stories/$1_x.md"; }
task()  { printf -- '---\nid: %s\nstory_id: %s\nepic_id: E1\ntitle: task %s\nstatus: %s\n---\n' "$1" "$2" "$1" "$3" > "$PROJ/project/board/tasks/$1_x.md"; }
# set_status <task id> <status>: rewrite the status of an existing fixture task.
set_status() { sed -i.bak "s/^status: .*/status: $2/" "$PROJ/project/board/tasks/$1_x.md" && rm -f "$PROJ/project/board/tasks/$1_x.md.bak"; }

# after <task ids>: the after-task bars and the after-story lines, plain text.
after() { bash "$RP" --scope story --task "$1" --after-story --session s --cols 80 --color never; }
STAR_LINE_RE='^E1_S[0-9]  [━╌]+[★⚑] [0-9]+/[0-9]+ · [0-9]+ %'

@test "executable and passes bash -n" {
  [ -x "$SF" ]
  bash -n "$SF"
}

@test "a story with all tasks Passed prints one story line (green star, full bar, N/N · 100 %) after the task bar; the next call prints nothing for it" {
  run --separate-stderr after E1_S1_T2
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "[━━━━━━━━━━]★ 2/2" ]]                      # the after-task bar comes first, unchanged
  [ "${lines[1]}" = "E1_S1  $(printf '━%.0s' $(seq 1 30))★ 2/2 · 100 %" ]
  run --separate-stderr after E1_S1_T2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]                                         # only the after-task bar
  [[ "${lines[0]}" == "[━━━━━━━━━━]★ 2/2" ]]
}

@test "the star is green and the bar fully green when colour is on" {
  run bash "$RP" --scope story --task E1_S1_T2 --after-story --session s --cols 80 --color always
  [[ "$output" == *"${ESC}[32m★${ESC}[0m"* ]]
  [[ "$output" == *"${ESC}[32m$(printf '━%.0s' $(seq 1 30))${ESC}[0m"* ]]
}

@test "a finished story with a Failed task prints a RED star, red failed cells (bar not fully green) and a failed count" {
  run bash "$RP" --scope story --task E1_S2_T2 --after-story --session s --cols 80 --color always
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  story_line="${lines[1]}"
  [[ "$story_line" == *"${ESC}[31m★${ESC}[0m"* ]]
  [[ "$story_line" == *"${ESC}[31m━"* ]]
  [[ "$story_line" != *"${ESC}[32m$(printf '━%.0s' $(seq 1 30))"* ]]
  plain="$(printf '%s' "$story_line" | sed "s/${ESC}\[[0-9;]*m//g")"
  [[ "$plain" == *"1/2 · 50 %"* ]]
  [[ "$plain" == *"✕ 1 failed"* ]]
}

@test "a story with pending or in-progress tasks prints no story line and leaves no ledger record" {
  run after E1_S3_T1
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  run after E1_S4_T2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ ! -e "$LEDGER" ]
}

@test "a story whose tasks are all Rejected has nothing counted and prints no story line" {
  run after E1_S6_T1
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ ! -e "$LEDGER" ]
}

@test "a finished story with a Rejected task prints a green star and the rejected count" {
  run after E1_S7_T1
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[1]}" == "E1_S7  "*"★ 1/1 · 100 %  ⊘ 1 rejected" ]]
}

@test "once per completion: a later task of ANOTHER story prints nothing for the finished one" {
  run after E1_S1_T2
  [ "${#lines[@]}" -eq 2 ]
  run after E1_S3_T1
  [ "${#lines[@]}" -eq 1 ]
  run after E1_S1_T1,E1_S3_T1
  [ "${#lines[@]}" -eq 2 ]                                         # two after-task bars, no story line
  [[ "${lines[0]}" == "[━━━━━━━━━━]★ 2/2" ]]
}

@test "a changed outcome prints again: Failed re-run and Passed, and the repeat of that state prints nothing" {
  run after E1_S2_T2
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[1]}" == *"1/2 · 50 %"* ]]
  run after E1_S2_T2
  [ "${#lines[@]}" -eq 1 ]
  set_status E1_S2_T2 Passed
  run after E1_S2_T2
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[1]}" == *"2/2 · 100 %"* ]]
  [[ "${lines[1]}" != *"✕"* ]]
  run after E1_S2_T2
  [ "${#lines[@]}" -eq 1 ]
}

@test "the ledger keeps one record per story with the latest signature, so A then B then A prints each time" {
  run after E1_S2_T2
  [ "${#lines[@]}" -eq 2 ]
  [ "$(grep -c '^E1_S2'$'\t' "$LEDGER")" -eq 1 ]
  set_status E1_S2_T2 Passed
  run after E1_S2_T2
  [ "${#lines[@]}" -eq 2 ]
  [ "$(grep -c '^E1_S2'$'\t' "$LEDGER")" -eq 1 ]
  set_status E1_S2_T2 Failed
  run after E1_S2_T2
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[1]}" == *"1/2 · 50 %"* ]]
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 1 ]
}

@test "a story that stopped being finished and finished again prints again" {
  run after E1_S1_T2
  [ "${#lines[@]}" -eq 2 ]
  set_status E1_S1_T2 "In Progress"
  run after E1_S1_T1
  [ "${#lines[@]}" -eq 1 ]
  set_status E1_S1_T2 Failed
  run after E1_S1_T2
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[1]}" == *"1/2 · 50 %"* ]]
}

@test "a wave that finishes the last tasks of two stories prints the task lines first, then two story lines" {
  run --separate-stderr after E1_S1_T2,E1_S2_T2,E1_S3_T1
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "${#lines[@]}" -eq 5 ]
  [[ "${lines[0]}" == "[━━━━━━━━━━]★ 2/2" ]]                       # E1_S1 bar
  [[ "${lines[1]}" == "[━━━━━╌╌╌╌╌]⚑ 1/2 · 1 red" ]]               # E1_S2 bar
  [[ "${lines[2]}" == "[╌╌╌╌╌╌╌╌╌╌]⚑ 0/1" ]]                       # E1_S3 bar
  [[ "${lines[3]}" == "E1_S1  "* ]]
  [[ "${lines[4]}" == "E1_S2  "* ]]
  [[ "${lines[3]}" =~ $STAR_LINE_RE ]]
}

@test "two tasks of one finished story print that story line once" {
  run after E1_S1_T1,E1_S1_T2
  [ "${#lines[@]}" -eq 2 ]
}

@test "without --after-story nothing changes: no story line, no ledger" {
  run bash "$RP" --scope story --task E1_S1_T2 --session s --cols 80 --color never
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ ! -e "$LEDGER" ]
}

@test "--after-story needs --scope story (usage error, exit 2)" {
  run --separate-stderr bash "$RP" --scope run --ids E1_S1 --after-story
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$RP" --resolve-scope --ids E1_S1 --after-story
  [ "$status" -eq 2 ]
}

@test "a task with no story, an unknown id or a missing task never fails the run (one warning, exit 0, nothing on stdout)" {
  printf -- '---\nid: E1_S1_T9\ntitle: orphan\nstatus: Passed\n---\n' > "$PROJ/project/board/tasks/E1_S1_T9_x.md"
  run --separate-stderr bash "$RP" --scope story --task E1_S1_T9 --after-story --session s --cols 80 --color never
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == "run-progress.sh: warning: "* ]]
  run --separate-stderr bash "$RP" --scope story --task E9_S9_T9 --after-story --session s --cols 80 --color never
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == "run-progress.sh: warning: "* ]]
  run --separate-stderr bash "$RP" --scope story --task nonsense --after-story --session s --cols 80 --color never
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == "run-progress.sh: warning: "* ]]
  [ ! -e "$LEDGER" ]
}

@test "an unknown story id given to the trigger directly is one warning and exit 0" {
  run --separate-stderr bash "$SF" --story E9_S9 --cols 80 --color never
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'story-finished.sh: warning')" -eq 1 ]
}

@test "an unreadable ledger never fails the run: one warning, no story line, the task bar still printed" {
  [ "$(id -u)" -ne 0 ] || skip "root can read any file"
  mkdir -p "$PROJ/project/queue"; printf 'E1_S1\t2:0:0:0:0:0:2\n' > "$LEDGER"; chmod 000 "$LEDGER"
  run --separate-stderr after E1_S1_T2
  chmod 644 "$LEDGER"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "[━━━━━━━━━━]★ 2/2" ]]
  [[ "$stderr" == *"story-finished.sh: warning"* ]]
}

@test "a ledger that is a directory never fails the run either" {
  mkdir -p "$LEDGER"
  run --separate-stderr after E1_S1_T2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$stderr" == *"story-finished.sh: warning"* ]]
}

@test "a malformed ledger line is ignored and the story is still announced" {
  mkdir -p "$PROJ/project/queue"; printf 'garbage without a tab\n\n' > "$LEDGER"
  run after E1_S1_T2
  [ "${#lines[@]}" -eq 2 ]
  run after E1_S1_T2
  [ "${#lines[@]}" -eq 1 ]
}

@test "an unwritable queue directory warns once, prints the line, and never fails the run" {
  [ "$(id -u)" -ne 0 ] || skip "root can write anywhere"
  mkdir -p "$PROJ/project/queue"; chmod 555 "$PROJ/project/queue"
  run --separate-stderr after E1_S1_T2
  chmod 755 "$PROJ/project/queue"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$stderr" == *"story-finished.sh: warning"* ]]
}

@test "a missing renderer or a missing trigger is one warning and exit 0; the task bar is still printed" {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/skills/j-break/scripts/lib"
  cp -R "$REPO_ROOT/scripts" "$TREE/scripts"
  cp "$RP" "$SF" "$TREE/skills/j-break/scripts/"
  cp "$REPO_ROOT/skills/j-break/scripts/lib/ledger_reader.py" "$TREE/skills/j-break/scripts/lib/"
  rm "$TREE/scripts/render-story-bar.sh"
  run --separate-stderr bash "$TREE/skills/j-break/scripts/run-progress.sh" --scope story --task E1_S1_T2 --after-story --session s --cols 80 --color never
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$stderr" == *"story-finished.sh: warning: could not locate scripts/render-story-bar.sh"* ]]
  rm "$TREE/skills/j-break/scripts/story-finished.sh"
  run --separate-stderr bash "$TREE/skills/j-break/scripts/run-progress.sh" --scope story --task E1_S1_T2 --after-story --session s --cols 80 --color never
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$stderr" == *"run-progress.sh: warning: could not locate"* ]]
}

@test "the trigger counts nothing itself: the decision and the line come only from board-progress.sh output" {
  # A stub board-progress.sh that always answers "3 done, 1 failed" is the only source of counts: the fixture board is ignored.
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/skills/j-break/scripts" "$TREE/scripts/lib"
  cp "$SF" "$TREE/skills/j-break/scripts/"
  cp "$REPO_ROOT/scripts/render-story-bar.sh" "$REPO_ROOT/scripts/resolve-root.sh" "$TREE/scripts/"
  cp "$REPO_ROOT/scripts/lib/progress-labels.sh" "$TREE/scripts/lib/"
  ARGLOG="$BATS_TEST_TMPDIR/args"
  cat > "$TREE/scripts/board-progress.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGLOG"
cat <<'JSON'
{"schema_version":1,"scope":{"type":"story","ids":["E1_S3"]},"levels":{"tasks":{"counts":{},"totals":{"done":3,"in_progress":0,"failed":1,"pending":0,"rejected":0,"unknown":0,"denominator":4}}},"warnings":[]}
JSON
STUB
  run bash "$TREE/skills/j-break/scripts/story-finished.sh" --story E1_S3 --cols 80 --color never
  [ "$status" -eq 0 ]
  [[ "$output" == "E1_S3  "*"★ 3/4 · 75 %  ✕ 1 failed" ]]
  [ "$(cat "$ARGLOG")" = "--story E1_S3" ]
  run grep -nE 'project/board|board/tasks|^[^#]*grep .*status' "$SF" "$REPO_ROOT/scripts/render-story-bar.sh"
  [ "$status" -ne 0 ]
}

@test "unknown buckets or a stub with pending tasks keep the story unfinished" {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/skills/j-break/scripts" "$TREE/scripts/lib"
  cp "$SF" "$TREE/skills/j-break/scripts/"
  cp "$REPO_ROOT/scripts/render-story-bar.sh" "$REPO_ROOT/scripts/resolve-root.sh" "$TREE/scripts/"
  cp "$REPO_ROOT/scripts/lib/progress-labels.sh" "$TREE/scripts/lib/"
  for totals in '"done":3,"in_progress":0,"failed":0,"pending":1,"rejected":0,"unknown":0,"denominator":4' \
                '"done":3,"in_progress":1,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":4' \
                '"done":3,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":1,"denominator":4' \
                '"done":0,"in_progress":0,"failed":0,"pending":0,"rejected":2,"unknown":0,"denominator":0'; do
    printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n{"scope":{"ids":["E1_S3"]},"levels":{"tasks":{"totals":{%s}}}}\nJSON\n' "$totals" > "$TREE/scripts/board-progress.sh"
    run bash "$TREE/skills/j-break/scripts/story-finished.sh" --story E1_S3 --cols 80 --color never
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$totals"; false; }
  done
  [ ! -e "$LEDGER" ]
}

@test "the ledger lives in the queue directory the project resolves, not in a fixed place" {
  python3 - "$PROJ/project/configs/workflow.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["paths"]["queue"] = "custom-queue"; json.dump(d, open(p, "w"))
PY
  mkdir -p "$PROJ/custom-queue"
  run after E1_S1_T2
  [ "${#lines[@]}" -eq 2 ]
  [ -f "$PROJ/custom-queue/story-finished-ledger.tsv" ]
  [ ! -e "$LEDGER" ]
}

@test "the ledger record is the story id and a signature of the final bucket counts, tab separated" {
  run after E1_S2_T2
  [ "$(cat "$LEDGER")" = "E1_S2"$'\t'"1:0:1:0:0:0:2" ]
}

@test "the ledger and its lock are gitignored like the rest of the queue's transient state" {
  run git -C "$REPO_ROOT" check-ignore -q project/queue/story-finished-ledger.tsv
  [ "$status" -eq 0 ]
  run git -C "$REPO_ROOT" check-ignore -q project/queue/story-finished-ledger.tsv.lock/x
  [ "$status" -eq 0 ]
  mkdir -p "$PROJ/project/queue"
  run after E1_S1_T2
  [ ! -d "$LEDGER.lock" ]                                          # the best-effort lock is released
}

@test "Swedish words come from the label library" {
  JENGA_PROGRESS_LANG=sv run after E1_S2_T2
  [[ "${lines[1]}" == *"✕ 1 misslyckad"* ]]
}

@test "the story line is never wider than the terminal, at any width" {
  for cols in 40 50 60 80 120; do
    rm -f "$LEDGER"
    run bash "$RP" --scope story --task E1_S2_T2,E1_S7_T1 --after-story --session s --cols "$cols" --color never
    [ "$status" -eq 0 ]
    w="$(printf '%s\n' "$output" | python3 -c 'import sys; print(max(len(l.rstrip("\n")) for l in sys.stdin))')"
    [ "$w" -le "$cols" ] || { echo "cols=$cols width=$w"; false; }
  done
}

@test "a non-UTF-8 locale prints ASCII only, story line included" {
  LC_ALL=C run bash "$RP" --scope story --task E1_S2_T2 --after-story --session s --cols 80 --color never
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' ')" = "0" ]
  [[ "${lines[1]}" == *"* 1/2 - 50 %  ! 1 failed" ]]
}
