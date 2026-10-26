#!/usr/bin/env bats
#
# E79_S04_T06: scripts/resolve-commit-ref.sh walks the commit ref resolution chain (the task's, its story's and its epic's
# external_refs Jira key, then the branch candidate captured at worktree creation) and reports what it found.
#
# What this pins (one named case per acceptance criterion, plus the contract around them):
#   - a key on the task wins (source=task) although the story, the epic and the captured branch candidate carry other keys;
#   - a task without a key resolves to its story's, then its epic's, then the captured branch candidate, one case each;
#   - nothing anywhere is exit 1 with tried=task,story,epic,branch on stdout and no ref= or source= line;
#   - ref_source: external_refs ignores a captured candidate, perceived_branch ignores the board (and never opens it);
#   - the captured candidate is used when the task branch's own name holds no key (a real scratch repository whose HEAD
#     is E79_S04_T06-add-x, with the candidate captured from feature/ASD-001-foo by the real extractor);
#   - an invalid key on a board item (asd-1, a key over the length cap, a key the recorded pattern does not match) is not a
#     candidate, the chain moves on, and the notice on stderr names the level, never the value;
#   - a project that is not opted in (no conventions.json, no template, apply_to_board_commits false) gets exit 10, empty
#     stdout, empty stderr, and the script never opens a board file (the board directory is unreadable);
#   - the script writes nothing: checksums of the project tree and of the scratch repository are unchanged;
#   - disagreement between valid candidates warns on stderr and continues with the precedence winner (decision 8), one case
#     per pair of levels; agreeing levels print no warning;
#   - the story and epic ids come from the task's own frontmatter when well formed, else from the task id; a missing task
#     file or missing parents do not fail the chain;
#   - hostile board content never runs anything (a canary stays absent); more than one key at one level uses the first;
#   - usage errors, --help, exit 3 for unusable settings, bash -n, no dynamic execution, no bash 4 feature.
#
# The script is always run as `bash <script>`, so these cases do not depend on the file's executable bit.
# Everything the cases create lives under $BATS_TEST_TMPDIR. These cases were written without being executed by their
# author; the tester runs them.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/resolve-commit-ref.sh"
STORE_SCRIPT="$REPO_ROOT/scripts/task-commit-ref.sh"
REAL_CONFIGS="$REPO_ROOT/project/configs"

ID="E79_S04_T06"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_COMMIT_REF_EXTRACT_SCRIPT
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  CONV="$CFG/conventions.json"
  BOARD="$PROJ/project/board"
  WORK="$BATS_TEST_TMPDIR/work"
  CANARY="$BATS_TEST_TMPDIR/canary"
  TASK_STORY="E79_S04"
  TASK_EPIC="E79"
  mkdir -p "$CFG" "$BOARD/tasks" "$BOARD/stories" "$BOARD/epics" "$WORK"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  cd "$WORK" || return 1
  git init -q . >/dev/null 2>&1
  git symbolic-ref HEAD refs/heads/E79_S04_T06-add-x
  write_conv '.'
}

teardown() {
  chmod -R u+rwx "$BOARD" 2>/dev/null || true
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- helpers ---------------------------------------------------------------------------------------------------

# rcr [args...]: run the resolver for the task with stdout in $output and stderr in $stderr.
rcr() {
  run --separate-stderr bash "$SCRIPT" "$ID" "$@"
}

# base_json: an opted-in conventions.json with only the minimum recorded (ref_source and ref_pattern are defaulted).
base_json() {
  cat <<'JSON'
{
  "conventions_version": 1,
  "categories": {
    "commit-format": {
      "source": "custom",
      "summary": "ref first",
      "values": { "style": "ref-first", "template": "{ref} {summary}", "apply_to_board_commits": true }
    }
  }
}
JSON
}

# write_conv <jq filter>: write the project's conventions.json from base_json.
write_conv() {
  base_json | jq "$1" > "$CONV"
}

# write_item <dir> <item-id> [key...]: a board item with one external_refs Jira entry per key (or an empty list). A task
# also carries story_id and epic_id.
write_item() {
  local dir="$1" iid="$2" k
  shift 2
  {
    printf -- '---\nid: %s\n' "$iid"
    case "$iid" in
      *_T*) printf 'story_id: %s\nepic_id: %s\n' "$TASK_STORY" "$TASK_EPIC" ;;
    esac
    if [ "$#" -gt 0 ]; then
      printf 'external_refs:\n'
      for k in "$@"; do
        printf '  - system: jira\n    kind: issue\n    key: %s\n' "$k"
      done
    else
      printf 'external_refs: []\n'
    fi
    printf -- '---\n# body\n'
  } > "$dir/${iid}_x.md"
}

# board <task-key> <story-key> <epic-key>: write the three items; an empty argument means "no key on that item".
board() {
  if [ -n "$1" ]; then write_item "$BOARD/tasks" "$ID" "$1"; else write_item "$BOARD/tasks" "$ID"; fi
  if [ -n "$2" ]; then write_item "$BOARD/stories" "E79_S04" "$2"; else write_item "$BOARD/stories" "E79_S04"; fi
  if [ -n "$3" ]; then write_item "$BOARD/epics" "E79" "$3"; else write_item "$BOARD/epics" "E79"; fi
}

# capture <ref>: record a captured branch candidate for the task, the way worktree creation does.
capture() {
  run --separate-stderr bash "$STORE_SCRIPT" capture-branch "$ID" --branch "feature/$1-foo" --candidate "$1"
  [ "$status" -eq 0 ]
}

# tree_sum: a fingerprint of the whole scratch project (names and contents) and of the scratch repository.
tree_sum() {
  {
    find "$PROJ" -print | sort
    find "$PROJ" -type f -exec cksum {} + | sort
    find "$WORK" -print | sort
    find "$WORK" -type f -exec cksum {} + | sort
  } | cksum
}

# pad <n>: n letter A's.
pad() {
  head -c "$1" /dev/zero | tr '\000' 'A'
}

# expect_found <ref> <source>: the last run found that winner and printed the three lines in order.
expect_found() {
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=$1"$'\n'"source=$2"$'\n'"tried="
}

# expect_unresolved <tried>: exit 1, only the tried= line on stdout, a notice on stderr.
expect_unresolved() {
  [ "$status" -eq 1 ]
  [ "$output" = "tried=$1" ]
  [ -n "$stderr" ]
}

# --- the chain -------------------------------------------------------------------------------------------------

@test "a key on the task wins although the story, the epic and the captured branch candidate carry other keys" {
  board ASD-001 ASD-002 ASD-003
  capture ZZZ-9
  rcr
  [ "$status" -eq 0 ]
  expected="ref=ASD-001"$'\n'"source=task"$'\n'"tried=task,story,epic,branch"$'\n'"candidate.task=ASD-001"$'\n'"candidate.story=ASD-002"$'\n'"candidate.epic=ASD-003"$'\n'"candidate.branch=ZZZ-9"$'\n'"conflict=story:ASD-002"$'\n'"conflict=epic:ASD-003"$'\n'"conflict=branch:ZZZ-9"
  [ "$output" = "$expected" ]
}

@test "a task without its own key resolves to its story's key" {
  board "" ASD-002 ASD-003
  capture ZZZ-9
  rcr
  expect_found ASD-002 story
  assert_contains "$output" "candidate.story=ASD-002"
  assert_not_contains "$output" "candidate.task="
}

@test "without a story key it resolves to the epic's key" {
  board "" "" ASD-003
  capture ZZZ-9
  rcr
  expect_found ASD-003 epic
}

@test "with none of the three it resolves to the captured branch candidate" {
  board "" "" ""
  capture ZZZ-9
  rcr
  expect_found ZZZ-9 branch
  [ "$output" = "ref=ZZZ-9"$'\n'"source=branch"$'\n'"tried=task,story,epic,branch"$'\n'"candidate.branch=ZZZ-9" ]
}

@test "with nothing anywhere the script exits 1 and tried=task,story,epic,branch is printed" {
  board "" "" ""
  rcr
  expect_unresolved "task,story,epic,branch"
  assert_not_contains "$output" "ref="
  assert_not_contains "$output" "source="
}

@test "a missing board entirely and no candidate is also unresolved, not an error" {
  rcr
  expect_unresolved "task,story,epic,branch"
}

@test "an empty captured candidate (a branch with no key) is an empty level" {
  board "" "" ""
  run --separate-stderr bash "$STORE_SCRIPT" capture-branch "$ID" --branch main
  [ "$status" -eq 0 ]
  rcr
  expect_unresolved "task,story,epic,branch"
}

# --- ref_source ------------------------------------------------------------------------------------------------

@test "ref_source external_refs ignores a captured branch candidate" {
  write_conv '.categories["commit-format"].values.ref_source = "external_refs"'
  board "" "" ""
  capture ZZZ-9
  rcr
  expect_unresolved "task,story,epic"
  board "" "" ASD-003
  rcr
  expect_found ASD-003 epic
  assert_contains "$output" "tried=task,story,epic"$'\n'
  assert_not_contains "$output" "branch"
}

@test "ref_source perceived_branch ignores board external_refs" {
  write_conv '.categories["commit-format"].values.ref_source = "perceived_branch"'
  board ASD-001 ASD-002 ASD-003
  rcr
  expect_unresolved "branch"
  capture ZZZ-9
  rcr
  [ "$output" = "ref=ZZZ-9"$'\n'"source=branch"$'\n'"tried=branch"$'\n'"candidate.branch=ZZZ-9" ]
  [ -z "$stderr" ]
}

@test "ref_source perceived_branch never opens a board file" {
  [ "$(id -u)" -ne 0 ] || skip "an unreadable directory is readable for root"
  write_conv '.categories["commit-format"].values.ref_source = "perceived_branch"'
  board ASD-001 ASD-002 ASD-003
  capture ZZZ-9
  chmod 000 "$BOARD"
  rcr
  [ "$status" -eq 0 ]
  [ "$output" = "ref=ZZZ-9"$'\n'"source=branch"$'\n'"tried=branch"$'\n'"candidate.branch=ZZZ-9" ]
  [ -z "$stderr" ]
}

@test "--conventions is handed to the settings reader" {
  board "" "" ""
  capture ZZZ-9
  rcr
  expect_found ZZZ-9 branch
  base_json | jq '.categories["commit-format"].values.ref_source = "external_refs"' > "$BATS_TEST_TMPDIR/alt.json"
  rcr --conventions "$BATS_TEST_TMPDIR/alt.json"
  expect_unresolved "task,story,epic"
}

# --- the realistic branch case ---------------------------------------------------------------------------------

@test "a captured candidate is used when the task branch name itself contains no key" {
  board "" "" ""
  [ "$(git -C "$WORK" symbolic-ref --short HEAD)" = "E79_S04_T06-add-x" ]
  run --separate-stderr bash "$STORE_SCRIPT" capture-branch "$ID" --branch feature/ASD-001-foo
  [ "$status" -eq 0 ]
  rcr
  [ "$output" = "ref=ASD-001"$'\n'"source=branch"$'\n'"tried=task,story,epic,branch"$'\n'"candidate.branch=ASD-001" ]
  # nothing was read from the task branch: with no capture the same branch name yields nothing
  run --separate-stderr bash "$STORE_SCRIPT" clear "$ID"
  [ "$status" -eq 0 ]
  rcr
  expect_unresolved "task,story,epic,branch"
}

# --- validation of every candidate -----------------------------------------------------------------------------

@test "a lowercase key on a board item is not a candidate and the notice names the level" {
  board asd-1 ASD-002 ""
  rcr
  expect_found ASD-002 story
  assert_contains "$stderr" "resolve-commit-ref: task: "
  assert_not_contains "$stderr" "asd-1"
}

@test "a key over the length cap is not a candidate and the notice names the level, never the value" {
  long="$(pad 70)-1"
  board "$long" "" ASD-003
  rcr
  expect_found ASD-003 epic
  assert_contains "$stderr" "task candidate was rejected"
  assert_not_contains "$stderr" "$long"
  assert_not_contains "$output" "$long"
}

@test "a key the project's recorded ref_pattern does not match is not a candidate" {
  write_conv '.categories["commit-format"].values.ref_pattern = "PRJ-[0-9]+"'
  board ASD-001 PRJ-7 ""
  rcr
  expect_found PRJ-7 story
  assert_contains "$stderr" "task candidate was rejected"
}

@test "a hostile key on the board never runs anything" {
  hostile='$(touch '"$CANARY"')'
  write_item "$BOARD/tasks" "$ID" "$hostile"
  write_item "$BOARD/stories" "E79_S04" "ASD-001; touch $CANARY"
  write_item "$BOARD/epics" "E79"
  rcr
  expect_unresolved "task,story,epic,branch"
  [ ! -e "$CANARY" ]
}

@test "a level that lists several valid keys uses the first and says so" {
  write_item "$BOARD/tasks" "$ID" ASD-001 ASD-009
  rcr
  expect_found ASD-001 task
  assert_contains "$stderr" "the task level lists more than one valid key"
}

# --- the not-opted-in path -------------------------------------------------------------------------------------

@test "no conventions.json is exit 10 with empty stdout and stderr, and no board file is opened" {
  [ "$(id -u)" -ne 0 ] || skip "an unreadable directory is readable for root"
  board ASD-001 ASD-002 ASD-003
  rm -f "$CONV"
  chmod 000 "$BOARD"
  rcr
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a conventions.json without a template is exit 10" {
  [ "$(id -u)" -ne 0 ] || skip "an unreadable directory is readable for root"
  board ASD-001 "" ""
  printf '{"conventions_version": 1, "categories": {}}\n' > "$CONV"
  chmod 000 "$BOARD"
  rcr
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "apply_to_board_commits false is exit 10" {
  [ "$(id -u)" -ne 0 ] || skip "an unreadable directory is readable for root"
  board ASD-001 "" ""
  write_conv '.categories["commit-format"].values.apply_to_board_commits = false'
  chmod 000 "$BOARD"
  rcr
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "not applicable is neither found nor nothing found" {
  board ASD-001 "" ""
  rm -f "$CONV"
  rcr
  [ "$status" -ne 0 ]
  [ "$status" -ne 1 ]
  [ "$status" -eq 10 ]
}

# --- the disagreement signal -----------------------------------------------------------------------------------

@test "task and story disagree: warn on stderr and continue with the task's key" {
  board ASD-001 ASD-002 ""
  rcr
  expect_found ASD-001 task
  assert_contains "$stderr" "warning: the sources disagree (task=ASD-001, story=ASD-002); continuing with ASD-001 from task"
}

@test "story and epic disagree: warn and continue with the story's key" {
  board "" ASD-002 ASD-003
  rcr
  expect_found ASD-002 story
  assert_contains "$stderr" "warning: the sources disagree (story=ASD-002, epic=ASD-003); continuing with ASD-002 from story"
}

@test "epic and the branch candidate disagree: warn and continue with the epic's key" {
  board "" "" ASD-003
  capture ZZZ-9
  rcr
  expect_found ASD-003 epic
  assert_contains "$stderr" "warning: the sources disagree (epic=ASD-003, branch=ZZZ-9); continuing with ASD-003 from epic"
}

@test "all four disagree: the warning names every level and the task wins" {
  board ASD-001 ASD-002 ASD-003
  capture ZZZ-9
  rcr
  expect_found ASD-001 task
  assert_contains "$stderr" "task=ASD-001, story=ASD-002, epic=ASD-003, branch=ZZZ-9"
}

@test "sources that agree print no warning" {
  board ASD-001 ASD-001 ASD-001
  capture ASD-001
  rcr
  expect_found ASD-001 task
  assert_not_contains "$stderr" "disagree"
  [ -z "$stderr" ]
}

@test "a disagreement is not an error: the exit status is 0" {
  board ASD-001 ASD-002 ""
  rcr
  [ "$status" -eq 0 ]
}

# --- story and epic ids ----------------------------------------------------------------------------------------

@test "the story and epic ids come from the task's own frontmatter when well formed" {
  TASK_STORY="E79_S09"
  TASK_EPIC="E80"
  write_item "$BOARD/tasks" "$ID"
  write_item "$BOARD/stories" "E79_S04" ASD-002
  write_item "$BOARD/stories" "E79_S09" ASD-009
  write_item "$BOARD/epics" "E79" ASD-003
  write_item "$BOARD/epics" "E80" ASD-080
  rcr
  expect_found ASD-009 story
  assert_contains "$output" "candidate.epic=ASD-080"
}

@test "a malformed story_id in the frontmatter falls back to the id derived from the task id" {
  TASK_STORY="not-a-story"
  TASK_EPIC="../x"
  write_item "$BOARD/tasks" "$ID"
  write_item "$BOARD/stories" "E79_S04" ASD-002
  write_item "$BOARD/epics" "E79" ASD-003
  rcr
  expect_found ASD-002 story
  assert_contains "$output" "candidate.epic=ASD-003"
}

@test "a missing task file does not fail the chain: the parents are derived from the id" {
  write_item "$BOARD/stories" "E79_S04" ASD-002
  write_item "$BOARD/epics" "E79" ASD-003
  rcr
  expect_found ASD-002 story
  assert_contains "$stderr" "the task level could not be read"
}

@test "missing story and epic files leave those levels empty" {
  write_item "$BOARD/tasks" "$ID"
  capture ZZZ-9
  rcr
  expect_found ZZZ-9 branch
  assert_contains "$stderr" "the story level could not be read"
  assert_contains "$stderr" "the epic level could not be read"
}

# --- unusable settings -----------------------------------------------------------------------------------------

@test "an invalid conventions file is exit 3 with nothing on stdout" {
  board ASD-001 "" ""
  printf '{not json\n' > "$CONV"
  rcr
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "the reserved ref_source prompt cannot reach the resolver: exit 3" {
  board ASD-001 "" ""
  write_conv '.categories["commit-format"].values.ref_source = "prompt"'
  rcr
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# --- the script writes nothing ---------------------------------------------------------------------------------

@test "a found run changes no file in the project or the repository" {
  board ASD-001 ASD-002 ASD-003
  capture ZZZ-9
  before="$(tree_sum)"
  rcr
  [ "$status" -eq 0 ]
  [ "$(tree_sum)" = "$before" ]
}

@test "an unresolved run changes no file in the project or the repository" {
  board "" "" ""
  before="$(tree_sum)"
  rcr
  [ "$status" -eq 1 ]
  [ "$(tree_sum)" = "$before" ]
}

@test "a not-applicable run changes no file in the project or the repository" {
  board ASD-001 "" ""
  rm -f "$CONV"
  before="$(tree_sum)"
  rcr
  [ "$status" -eq 10 ]
  [ "$(tree_sum)" = "$before" ]
}

@test "the output is deterministic" {
  board ASD-001 ASD-002 ASD-003
  capture ZZZ-9
  rcr
  first="$output"
  rcr
  [ "$output" = "$first" ]
}

@test "every stdout line is key=value and the keys are the documented ones" {
  board ASD-001 ASD-002 ASD-003
  capture ZZZ-9
  rcr
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    case "$line" in
      ref=*|source=*|tried=*|candidate.task=*|candidate.story=*|candidate.epic=*|candidate.branch=*|conflict=*) ;;
      *) return 1 ;;
    esac
  done <<EOF_OUT
$output
EOF_OUT
}

# --- usage -----------------------------------------------------------------------------------------------------

@test "--help prints the usage and the exit codes and exits 0" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "resolve-commit-ref.sh <task-id>"
  assert_contains "$output" "10 not applicable"
}

@test "usage errors are exit 2, print nothing on stdout and create nothing" {
  before="$(tree_sum)"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" E79_S04
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "../x"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" 'E79_S04_T06/../../y'
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "$ID" E79_S04_T07
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "$ID" --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "$ID" --conventions
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "$ID" --conventions a --conventions b
  [ "$status" -eq 2 ]
  [ "$(tree_sum)" = "$before" ]
}

# --- static properties -----------------------------------------------------------------------------------------

@test "bash -n passes" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the script has no dynamic execution, no sourcing, no shell-string invocation and no bash 4 feature" {
  run grep -nE '(^|[^A-Za-z_])eval([^A-Za-z_]|$)' "$SCRIPT"
  [ "$status" -eq 1 ]
  run grep -nE '(sh|bash) +-c' "$SCRIPT"
  [ "$status" -eq 1 ]
  run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$SCRIPT"
  [ "$status" -eq 1 ]
  # the header comment names the bash 4 features it avoids, so only code lines are checked here
  code="$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)"
  run grep -nE 'declare +-A|local +-A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)|&>>|\[\[ +-v ' <<< "$code"
  [ "$status" -eq 1 ]
}

@test "the script reuses the settings reader, the gate, the board reader and the store rather than re-implementing them" {
  grep -q 'commit-settings.sh' "$SCRIPT"
  grep -q 'commit-ref.sh' "$SCRIPT"
  grep -q 'read-external-refs.sh' "$SCRIPT"
  grep -q 'task-commit-ref.sh' "$SCRIPT"
  grep -q 'resolve-root.sh' "$SCRIPT"
  code="$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)"
  assert_not_contains "$code" "project/"
  assert_not_contains "$code" "jq "
}

@test "candidates reach the gate on stdin, never as a positional argument" {
  code="$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)"
  assert_contains "$code" "printf '%s' \"\$1\" | bash \"\$GATE\" validate --pattern"
}
