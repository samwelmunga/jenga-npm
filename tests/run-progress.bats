#!/usr/bin/env bats
#
# Coverage for skills/j-break/scripts/run-progress.sh (E92_S02_T04) and the shared ledger reader it uses
# (skills/j-break/scripts/lib/ledger_reader.py).
#
# E92_S06_T22: the after-task call is `--scope story --task <id>[,<id>...]` (one line per distinct parent story, in
# first-seen order). `--resolve-scope` and `--scope run` are kept for compatibility and keep their tests below.
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
  run bash "$TREE_RP" --scope story --task E1_S2_T2,E1_S1_T1,E1_S2_T1,E1_S1_T4 --color never --cols 80
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]
  [ "$(cat "$ARGLOG")" = "$(printf -- '--story E1_S2\n--story E1_S1')" ]
}

@test "the single-story line is byte-identical to the renderer fed the story's counts directly" {
  local bp="$REPO_ROOT/scripts/board-progress.sh" rd="$REPO_ROOT/scripts/render-progress-bar.sh" mode
  bash "$bp" --story E1_S2 > "$BATS_TEST_TMPDIR/direct.json"
  for mode in "--color never --cols 80" "--color always --cols 80" "--color never --cols 14"; do
    bash "$rd" --file "$BATS_TEST_TMPDIR/direct.json" $mode > "$BATS_TEST_TMPDIR/expected"
    bash "$RP" --scope story --task E1_S2_T2 $mode > "$BATS_TEST_TMPDIR/actual"
    cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual" || { echo "differs for: $mode" >&2; return 1; }
  done
  # NO_COLOR and the ASCII fallback go through the same renderer, unchanged
  NO_COLOR=1 bash "$rd" --file "$BATS_TEST_TMPDIR/direct.json" --cols 80 > "$BATS_TEST_TMPDIR/expected"
  NO_COLOR=1 bash "$RP" --scope story --task E1_S2_T2 --cols 80 > "$BATS_TEST_TMPDIR/actual"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual"
  LANG=C bash "$rd" --file "$BATS_TEST_TMPDIR/direct.json" --color never --cols 80 > "$BATS_TEST_TMPDIR/expected"
  LANG=C bash "$RP" --scope story --task E1_S2_T2 --color never --cols 80 > "$BATS_TEST_TMPDIR/actual"
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
  run --separate-stderr bash "$TREE_RP" --scope story --task E1_S1_T1 --color never
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == *"warning"*"render-progress-bar.sh"* ]]
  run --separate-stderr bash "$TREE_RP" --scope story --task E1_S1_T1,E1_S2_T1 --color never
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
              "--scope run --ids" "--wat"; do
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

@test "story scope asks board-progress.sh for the parent story and nothing else" {
  make_stub_tree
  run bash "$TREE_RP" --scope story --task E1_S2_T2 --color never --cols 80
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
