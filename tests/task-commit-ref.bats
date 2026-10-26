#!/usr/bin/env bats
#
# E79_S04_T05: scripts/task-commit-ref.sh is the per-task commit ref store (capture the branch candidate, freeze the
# resolved ref write-once, read it back re-validated).
#
# What this pins (one named case per acceptance criterion, plus the contract around them):
#   - capture-branch, freeze and get round-trip; the file lands under the resolved queue directory and
#     JENGA_PROJECT_ROOT redirects it to a scratch project;
#   - freeze is write-once: the same ref again is exit 0 and changes nothing, a different ref is exit 4 and the file's
#     checksum is unchanged; a new capture or an edited task file after the freeze does not move the frozen ref;
#   - hostile refs (shell metacharacters, an embedded or trailing newline) exit non-zero, write nothing, and run
#     nothing (a canary stays absent);
#   - a hand-edited or corrupted store file makes `get` exit 3 and print nothing;
#   - a task id that is not E##_S##_T## is exit 2 and creates nothing;
#   - two concurrent freezes with different refs leave exactly one frozen value, the loser exits 4;
#   - capture-branch with the extractor (a stub, so this file does not depend on the parallel `extract` task) and with
#     --candidate; idempotency; a branch with no key records null;
#   - .gitignore ignores the store (and its temp and lock files), .publicignore already blocks project/queue/;
#   - usage errors, --help, bash -n, no dynamic execution, no bash 4 feature.
#
# The script is always run as `bash <script>`, so these cases do not depend on the file's executable bit.
# Everything the cases create lives under $BATS_TEST_TMPDIR. The new cases here were written without being executed by
# their author.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/task-commit-ref.sh"
GATE="$REPO_ROOT/scripts/commit-ref.sh"
REAL_CONFIGS="$REPO_ROOT/project/configs"

ID="E79_S04_T05"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_COMMIT_REF_EXTRACT_SCRIPT
  PROJ="$BATS_TEST_TMPDIR/proj"
  WORK="$BATS_TEST_TMPDIR/work"
  CANARY="$BATS_TEST_TMPDIR/canary"
  STORE_DIR="$PROJ/project/queue/commit-refs"
  STORE="$STORE_DIR/$ID.json"
  mkdir -p "$PROJ/project/configs" "$PROJ/project/board/tasks" "$WORK"
  printf '{}\n' > "$PROJ/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  cd "$WORK" || return 1
  make_stub
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
  [ ! -e "$REPO_ROOT/project/queue/commit-refs" ]
}

# --- helpers ---------------------------------------------------------------------------------------------------

# tcr <args...>: run the script with stdout in $output and stderr in $stderr.
tcr() {
  run --separate-stderr bash "$SCRIPT" "$@"
}

# make_stub: a stand-in for `commit-ref.sh extract` (reads the branch on stdin). Selected per case through
# JENGA_COMMIT_REF_EXTRACT_SCRIPT, which replaces only the extract call; the validate call always goes to the real gate.
make_stub() {
  STUB="$BATS_TEST_TMPDIR/stub-extract.sh"
  cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
[ "${1:-}" = "extract" ] || exit 2
IFS= read -r b
case "$b" in
  *ASD-001*) printf 'ASD-001\n'; exit 0 ;;
  *hostile*) printf 'a;b\n'; exit 0 ;;
  *reject*) exit 3 ;;
  *) exit 1 ;;
esac
EOS
}

# sum_store: a fingerprint of the store file (content only).
sum_store() {
  cksum < "$STORE"
}

# edit_store <jq filter>: hand-edit the store file the way a person (or a bug) could.
edit_store() {
  jq "$1" "$STORE" > "$STORE.edit" && mv "$STORE.edit" "$STORE"
}

# frozen: capture a candidate and freeze ASD-001, the common starting state.
frozen() {
  tcr capture-branch "$ID" --branch feature/ASD-001-foo --candidate ASD-001
  [ "$status" -eq 0 ]
  tcr freeze "$ID" --ref ASD-001 --source task
  [ "$status" -eq 0 ]
}

# expect_fail <exit-code>: the last run failed with that code, nothing on stdout and a message on stderr.
expect_fail() {
  [ "$status" -eq "$1" ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

# --- the round trip --------------------------------------------------------------------------------------------

@test "capture-branch, freeze and get round-trip under the resolved queue directory" {
  tcr capture-branch "$ID" --branch feature/ASD-001-foo --candidate ASD-001
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$STORE" ]
  tcr freeze "$ID" --ref ASD-001 --source branch
  [ "$status" -eq 0 ]
  tcr get "$ID"
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
  tcr get "$ID" --field ref
  [ "$output" = "ASD-001" ]
  tcr get "$ID" --field source
  [ "$output" = "branch" ]
  tcr get "$ID" --field candidate
  [ "$output" = "ASD-001" ]
  [ "$(jq -r '.task_id' "$STORE")" = "$ID" ]
  [ "$(jq -r '.branch' "$STORE")" = "feature/ASD-001-foo" ]
  [ "$(jq -r '.branch_candidate' "$STORE")" = "ASD-001" ]
  [ "$(jq -r '.ref' "$STORE")" = "ASD-001" ]
  [ "$(jq -r '.source' "$STORE")" = "branch" ]
  [ "$(jq -r '.conflicts | length' "$STORE")" = "0" ]
  [ "$(jq -r '.captured_at | type' "$STORE")" = "string" ]
  [ "$(jq -r '.frozen_at | type' "$STORE")" = "string" ]
}

@test "JENGA_PROJECT_ROOT redirects the store, and the real repository gets no store" {
  frozen
  [ -f "$PROJ/project/queue/commit-refs/$ID.json" ]
  [ ! -e "$REPO_ROOT/project/queue/commit-refs" ]
}

@test "the queue directory comes from the registry, not a hardcoded project/ path" {
  printf '{"paths":{"queue":"state/q"}}\n' > "$PROJ/project/configs/workflow.json"
  tcr freeze "$ID" --ref ASD-001 --source task
  [ "$status" -eq 0 ]
  [ -f "$PROJ/state/q/commit-refs/$ID.json" ]
  [ ! -e "$PROJ/project/queue/commit-refs" ]
}

@test "get with nothing stored, or captured but not frozen, is exit 1 with no output" {
  tcr get "$ID"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  tcr capture-branch "$ID" --branch main --candidate ASD-009
  [ "$status" -eq 0 ]
  tcr get "$ID"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  tcr get "$ID" --field source
  [ "$status" -eq 1 ]
}

@test "freeze stores the source and the conflict texts in order" {
  tcr freeze "$ID" --ref ASD-001 --source task --conflict "story says ASD-002" --conflict "branch says ASD-003"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.conflicts' "$STORE")" = '["story says ASD-002","branch says ASD-003"]' ]
  [ "$(jq -r '.source' "$STORE")" = "task" ]
}

@test "the store file is private and no temp file or lock directory is left behind" {
  frozen
  [ "$(ls -ld "$STORE" | cut -c1-10)" = "-rw-------" ]
  [ "$(ls -A "$STORE_DIR")" = "$ID.json" ]
}

# --- write-once freeze -----------------------------------------------------------------------------------------

@test "freezing the same ref again is exit 0 and the file is unchanged" {
  frozen
  before="$(sum_store)"
  tcr freeze "$ID" --ref ASD-001 --source story --conflict "later disagreement"
  [ "$status" -eq 0 ]
  [ "$before" = "$(sum_store)" ]
  [ "$(jq -r '.source' "$STORE")" = "task" ]
}

@test "freezing a different ref is exit 4 and the file's checksum is unchanged" {
  frozen
  before="$(sum_store)"
  tcr freeze "$ID" --ref ASD-002 --source task
  expect_fail 4
  [ "$before" = "$(sum_store)" ]
  tcr get "$ID"
  [ "$output" = "ASD-001" ]
}

@test "after the freeze, new sources do not move the frozen ref (a new capture, an edited task file)" {
  frozen
  before="$(sum_store)"
  tcr capture-branch "$ID" --branch feature/ASD-777-other --candidate ASD-777
  [ "$status" -eq 0 ]
  printf -- '---\nid: %s\nexternal_refs:\n  - system: jira\n    key: ASD-555\n---\n' "$ID" > "$PROJ/project/board/tasks/${ID}_x.md"
  [ "$before" = "$(sum_store)" ]
  tcr get "$ID"
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
  tcr get "$ID" --field candidate
  [ "$output" = "ASD-001" ]
  tcr freeze "$ID" --ref ASD-555 --source task
  [ "$status" -eq 4 ]
  tcr get "$ID"
  [ "$output" = "ASD-001" ]
}

@test "two concurrent freezes with different refs leave exactly one frozen value; the loser exits 4" {
  local round winner loser
  for round in 1 2 3; do
    rm -f "$BATS_TEST_TMPDIR/rc1" "$BATS_TEST_TMPDIR/rc2"
    ( rc=0; bash "$SCRIPT" freeze "$ID" --ref ASD-001 --source task >/dev/null 2>&1 3>&- || rc=$?; echo "$rc" > "$BATS_TEST_TMPDIR/rc1" ) &
    p1=$!
    ( rc=0; bash "$SCRIPT" freeze "$ID" --ref ASD-002 --source task >/dev/null 2>&1 3>&- || rc=$?; echo "$rc" > "$BATS_TEST_TMPDIR/rc2" ) &
    p2=$!
    wait "$p1" "$p2"
    [ "$(cat "$BATS_TEST_TMPDIR/rc1" "$BATS_TEST_TMPDIR/rc2" | sort | tr '\n' ' ')" = "0 4 " ]
    if [ "$(cat "$BATS_TEST_TMPDIR/rc1")" = "0" ]; then winner="ASD-001"; else winner="ASD-002"; fi
    tcr get "$ID"
    [ "$status" -eq 0 ]
    [ "$output" = "$winner" ]
    [ "$(jq -r '.ref' "$STORE")" = "$winner" ]
    [ "$(ls -A "$STORE_DIR")" = "$ID.json" ]
    tcr clear "$ID"
    [ "$status" -eq 0 ]
  done
}

# --- hostile refs ----------------------------------------------------------------------------------------------

@test "a ref with shell metacharacters is rejected, nothing is written, and the canary stays absent" {
  tcr freeze "$ID" --ref "ASD-001;touch $CANARY" --source task
  expect_fail 3
  tcr freeze "$ID" --ref "ASD-001\$(touch $CANARY)" --source task
  expect_fail 3
  tcr freeze "$ID" --ref "ASD-001\`touch $CANARY\`" --source task
  expect_fail 3
  tcr freeze "$ID" --ref "ASD-001 && touch $CANARY" --source task
  expect_fail 3
  tcr freeze "$ID" --ref "ASD-001|touch $CANARY" --source task
  expect_fail 3
  [ ! -e "$CANARY" ]
  [ ! -e "$STORE" ]
  [ ! -e "$STORE_DIR" ]
}

@test "a ref with an embedded or a trailing newline is rejected and writes nothing" {
  tcr freeze "$ID" --ref $'ASD-001\nASD-002' --source task
  expect_fail 3
  tcr freeze "$ID" --ref $'ASD-001\n' --source task
  expect_fail 3
  tcr freeze "$ID" --ref $'ASD-001\r' --source task
  expect_fail 3
  tcr freeze "$ID" --ref '' --source task
  expect_fail 3
  [ ! -e "$STORE_DIR" ]
}

@test "a ref that fails the pattern is rejected (lower case, trailing text)" {
  tcr freeze "$ID" --ref asd-001 --source task
  expect_fail 3
  tcr freeze "$ID" --ref ASD-001-extra --source task
  expect_fail 3
  [ ! -e "$STORE_DIR" ]
}

@test "a rejected freeze after a good one leaves the file untouched" {
  frozen
  before="$(sum_store)"
  tcr freeze "$ID" --ref "ASD-002;touch $CANARY" --source task
  expect_fail 3
  [ "$before" = "$(sum_store)" ]
  [ ! -e "$CANARY" ]
}

@test "a hostile --candidate is rejected and writes nothing" {
  tcr capture-branch "$ID" --branch feature/x --candidate "ASD-001;touch $CANARY"
  expect_fail 3
  tcr capture-branch "$ID" --branch feature/x --candidate $'ASD-001\nASD-002'
  expect_fail 3
  [ ! -e "$CANARY" ]
  [ ! -e "$STORE_DIR" ]
}

@test "a branch name with shell metacharacters is stored as data and never executed" {
  export JENGA_COMMIT_REF_EXTRACT_SCRIPT="$STUB"
  tcr capture-branch "$ID" --branch "feature/x;touch $CANARY"
  [ "$status" -eq 0 ]
  [ ! -e "$CANARY" ]
  [ "$(jq -r '.branch' "$STORE")" = "feature/x;touch $CANARY" ]
  [ "$(jq -r '.branch_candidate' "$STORE")" = "null" ]
}

@test "a branch name with a control character, or an empty one, is a usage error and writes nothing" {
  tcr capture-branch "$ID" --branch $'feature/x\nASD-001' --candidate ASD-001
  expect_fail 2
  tcr capture-branch "$ID" --branch '' --candidate ASD-001
  expect_fail 2
  [ ! -e "$STORE_DIR" ]
}

# --- a corrupted or hand-edited store --------------------------------------------------------------------------

@test "a hand-edited ref that is not allowlisted makes get exit 3 and print nothing" {
  frozen
  edit_store '.ref = "ASD-001;touch x"'
  tcr get "$ID"
  expect_fail 3
  tcr get "$ID" --field ref
  expect_fail 3
  tcr get "$ID" --field source
  expect_fail 3
}

@test "other corruptions of the ref are exit 3 as well (trailing newline, NUL, wrong type, pattern, length)" {
  frozen
  edit_store '.ref = "ASD-001\n"'
  tcr get "$ID"
  expect_fail 3
  edit_store '.ref = "ASD-001\u0000x"'
  tcr get "$ID"
  expect_fail 3
  edit_store '.ref = 42'
  tcr get "$ID"
  expect_fail 3
  edit_store '.ref = "asd-001"'
  tcr get "$ID"
  expect_fail 3
  edit_store '.ref = ("ASD-" + ("1" * 80))'
  tcr get "$ID"
  expect_fail 3
}

@test "a source outside task|story|epic|branch, or a task_id that is not this task's, is exit 3" {
  frozen
  edit_store '.source = "elsewhere"'
  tcr get "$ID"
  expect_fail 3
  edit_store '.source = "task" | .task_id = "E79_S04_T99"'
  tcr get "$ID"
  expect_fail 3
}

@test "a file that is not JSON, or not an object, is exit 3 for get, freeze and capture-branch, and is left alone" {
  frozen
  printf 'not json at all' > "$STORE"
  before="$(sum_store)"
  tcr get "$ID"
  expect_fail 3
  tcr freeze "$ID" --ref ASD-001 --source task
  expect_fail 3
  tcr capture-branch "$ID" --branch main --candidate ASD-001
  expect_fail 3
  [ "$before" = "$(sum_store)" ]
  printf '[]\n' > "$STORE"
  tcr get "$ID"
  expect_fail 3
}

@test "a hand-edited candidate makes get --field candidate exit 3 while the frozen ref still reads" {
  frozen
  edit_store '.branch_candidate = "x;y"'
  tcr get "$ID" --field candidate
  expect_fail 3
  tcr get "$ID"
  [ "$status" -eq 0 ]
  [ "$output" = "ASD-001" ]
}

@test "clear discards a corrupted store, after which a fresh freeze works" {
  frozen
  printf 'not json' > "$STORE"
  tcr clear "$ID"
  [ "$status" -eq 0 ]
  [ ! -e "$STORE" ]
  tcr freeze "$ID" --ref ASD-002 --source epic
  [ "$status" -eq 0 ]
  tcr get "$ID"
  [ "$output" = "ASD-002" ]
}

# --- the task id is a file name --------------------------------------------------------------------------------

@test "a task id such as ../x, E79_S04_T01/../../y or an empty string is exit 2 and creates no file" {
  local bad verb
  for bad in '../x' 'E79_S04_T01/../../y' '' 'E79_S04_T01x' 'e79_s04_t01' 'E79_S04' 'E79_S04_T01.json' '-h' 'E79_S04_T01 ' $'E79_S04_T01\n'; do
    for verb in capture-branch freeze get clear; do
      case "$verb" in
        capture-branch) tcr capture-branch "$bad" --branch main --candidate ASD-001 ;;
        freeze) tcr freeze "$bad" --ref ASD-001 --source task ;;
        *) tcr "$verb" "$bad" ;;
      esac
      [ "$status" -eq 2 ]
      [ -z "$output" ]
    done
  done
  [ ! -e "$STORE_DIR" ]
  [ ! -e "$PROJ/project/queue" ]
  [ ! -e "$PROJ/y" ]
  [ ! -e "$PROJ/x.json" ]
  [ ! -e "$BATS_TEST_TMPDIR/x.json" ]
}

# --- capture-branch --------------------------------------------------------------------------------------------

@test "capture-branch extracts through the extractor and records the candidate" {
  export JENGA_COMMIT_REF_EXTRACT_SCRIPT="$STUB"
  tcr capture-branch "$ID" --branch feature/ASD-001-foo
  [ "$status" -eq 0 ]
  [ "$(jq -r '.branch_candidate' "$STORE")" = "ASD-001" ]
  [ "$(jq -r '.branch' "$STORE")" = "feature/ASD-001-foo" ]
  tcr get "$ID" --field candidate
  [ "$output" = "ASD-001" ]
}

@test "a branch with no key records null and still exits 0" {
  export JENGA_COMMIT_REF_EXTRACT_SCRIPT="$STUB"
  tcr capture-branch "$ID" --branch main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r '.branch_candidate' "$STORE")" = "null" ]
  [ "$(jq -r '.branch' "$STORE")" = "main" ]
  tcr get "$ID" --field candidate
  [ "$status" -eq 1 ]
}

@test "capture-branch is idempotent: a second capture, even on another branch, changes nothing" {
  export JENGA_COMMIT_REF_EXTRACT_SCRIPT="$STUB"
  tcr capture-branch "$ID" --branch feature/ASD-001-foo
  [ "$status" -eq 0 ]
  before="$(sum_store)"
  tcr capture-branch "$ID" --branch main
  [ "$status" -eq 0 ]
  [ "$before" = "$(sum_store)" ]
  tcr capture-branch "$ID" --branch feature/ASD-001-foo --candidate ASD-005
  [ "$status" -eq 0 ]
  [ "$before" = "$(sum_store)" ]
}

@test "a capture that found no key stays captured: a later capture does not overwrite the null" {
  export JENGA_COMMIT_REF_EXTRACT_SCRIPT="$STUB"
  tcr capture-branch "$ID" --branch main
  [ "$status" -eq 0 ]
  before="$(sum_store)"
  tcr capture-branch "$ID" --branch feature/ASD-001-foo
  [ "$status" -eq 0 ]
  [ "$before" = "$(sum_store)" ]
  [ "$(jq -r '.branch_candidate' "$STORE")" = "null" ]
}

@test "capture-branch after a freeze that never captured fills in the capture fields and keeps the frozen ref" {
  tcr freeze "$ID" --ref ASD-001 --source task
  [ "$status" -eq 0 ]
  tcr capture-branch "$ID" --branch feature/ASD-002-x --candidate ASD-002
  [ "$status" -eq 0 ]
  [ "$(jq -r '.branch_candidate' "$STORE")" = "ASD-002" ]
  tcr get "$ID"
  [ "$output" = "ASD-001" ]
}

@test "an extractor that rejects the branch is exit 3; one that prints a hostile value is exit 3; nothing is written" {
  export JENGA_COMMIT_REF_EXTRACT_SCRIPT="$STUB"
  tcr capture-branch "$ID" --branch feature/reject-me
  expect_fail 3
  tcr capture-branch "$ID" --branch feature/hostile-one
  expect_fail 3
  [ ! -e "$STORE" ]
}

@test "without --candidate and with no usable extract, capture-branch is exit 5 and says to pass --candidate" {
  printf '#!/usr/bin/env bash\nexit 2\n' > "$BATS_TEST_TMPDIR/no-extract.sh"
  export JENGA_COMMIT_REF_EXTRACT_SCRIPT="$BATS_TEST_TMPDIR/no-extract.sh"
  tcr capture-branch "$ID" --branch feature/ASD-001-foo
  expect_fail 5
  assert_contains "$stderr" "--candidate"
  [ ! -e "$STORE" ]
  export JENGA_COMMIT_REF_EXTRACT_SCRIPT="$BATS_TEST_TMPDIR/missing.sh"
  tcr capture-branch "$ID" --branch feature/ASD-001-foo
  expect_fail 5
}

@test "with the real commit-ref.sh extract (when it exists in this tree), capture-branch finds the key" {
  run bash -c 'printf "feature/ASD-001-foo\n" | bash "$0" extract' "$GATE"
  if [ "$status" -ne 0 ]; then skip "commit-ref.sh has no working extract subcommand in this tree yet"; fi
  tcr capture-branch "$ID" --branch feature/ASD-001-foo
  [ "$status" -eq 0 ]
  [ "$(jq -r '.branch_candidate' "$STORE")" = "ASD-001" ]
  tcr capture-branch "E79_S04_T06" --branch main
  [ "$status" -eq 0 ]
  [ "$(jq -r '.branch_candidate' "$STORE_DIR/E79_S04_T06.json")" = "null" ]
}

# --- clear -----------------------------------------------------------------------------------------------------

@test "clear removes the file; clearing an absent store, or with no directory at all, is exit 0 and creates nothing" {
  tcr clear "$ID"
  [ "$status" -eq 0 ]
  [ ! -e "$STORE_DIR" ]
  frozen
  [ -f "$STORE" ]
  tcr clear "$ID"
  [ "$status" -eq 0 ]
  [ ! -e "$STORE" ]
  tcr clear "$ID"
  [ "$status" -eq 0 ]
  tcr get "$ID"
  [ "$status" -eq 1 ]
}

@test "stores of different tasks are independent" {
  tcr freeze "$ID" --ref ASD-001 --source task
  tcr freeze E79_S04_T06 --ref ASD-002 --source story
  tcr get "$ID"
  [ "$output" = "ASD-001" ]
  tcr get E79_S04_T06
  [ "$output" = "ASD-002" ]
  tcr clear "$ID"
  tcr get E79_S04_T06
  [ "$output" = "ASD-002" ]
}

# --- refusals --------------------------------------------------------------------------------------------------

@test "a symlinked store directory or store file is refused with exit 6" {
  mkdir -p "$PROJ/project/queue" "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$STORE_DIR"
  tcr freeze "$ID" --ref ASD-001 --source task
  expect_fail 6
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
  rm "$STORE_DIR"
  mkdir -p "$STORE_DIR"
  printf '{}' > "$BATS_TEST_TMPDIR/target.json"
  ln -s "$BATS_TEST_TMPDIR/target.json" "$STORE"
  tcr get "$ID"
  expect_fail 6
  tcr freeze "$ID" --ref ASD-001 --source task
  expect_fail 6
  [ "$(cat "$BATS_TEST_TMPDIR/target.json")" = "{}" ]
}

@test "with no working-file root (no registry, no JENGA_PROJECT_ROOT) it is exit 5 and creates nothing" {
  unset JENGA_PROJECT_ROOT
  mkdir -p "$BATS_TEST_TMPDIR/bare"
  cd "$BATS_TEST_TMPDIR/bare" || return 1
  tcr freeze "$ID" --ref ASD-001 --source task
  expect_fail 5
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/bare")" ]
}

# --- .gitignore ------------------------------------------------------------------------------------------------

@test ".gitignore carries the commit-refs entry and git check-ignore reports a sample store file as ignored" {
  grep -qxF 'project/queue/commit-refs/' "$REPO_ROOT/.gitignore"
  run git -C "$REPO_ROOT" check-ignore -q -- "project/queue/commit-refs/$ID.json"
  [ "$status" -eq 0 ]
  run git -C "$REPO_ROOT" check-ignore -q -- "project/queue/commit-refs/.$ID.AbCdEf"
  [ "$status" -eq 0 ]
  run git -C "$REPO_ROOT" check-ignore -q -- "project/queue/commit-refs/$ID.json.lock.d/pid"
  [ "$status" -eq 0 ]
}

@test ".publicignore already blocks project/queue/, so the mirror needs no entry of its own" {
  grep -qxF 'project/queue/' "$REPO_ROOT/.publicignore"
}

# --- usage -----------------------------------------------------------------------------------------------------

@test "--help prints the usage on stdout and exits 0" {
  tcr --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "capture-branch"
  assert_contains "$output" "freeze"
  [ -z "$stderr" ]
  tcr -h
  [ "$status" -eq 0 ]
}

@test "usage errors are exit 2 with nothing on stdout" {
  tcr
  expect_fail 2
  tcr nonsense "$ID"
  expect_fail 2
  tcr freeze
  expect_fail 2
  tcr freeze "$ID"
  expect_fail 2
  tcr freeze "$ID" --ref ASD-001
  expect_fail 2
  tcr freeze "$ID" --ref ASD-001 --source nowhere
  expect_fail 2
  tcr freeze "$ID" --ref
  expect_fail 2
  tcr freeze "$ID" --ref ASD-001 --ref ASD-002 --source task
  expect_fail 2
  tcr freeze "$ID" --source task --ref ASD-001 --bogus
  expect_fail 2
  tcr freeze "$ID" --ref ASD-001 --source task extra
  expect_fail 2
  tcr freeze "$ID" --ref ASD-001 --source task --conflict $'a\nb'
  expect_fail 2
  tcr capture-branch "$ID"
  expect_fail 2
  tcr capture-branch "$ID" --ref ASD-001
  expect_fail 2
  tcr get "$ID" --field nothing
  expect_fail 2
  tcr get "$ID" --ref ASD-001
  expect_fail 2
  tcr clear "$ID" --field ref
  expect_fail 2
  [ ! -e "$STORE_DIR" ]
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

@test "the script reuses the gate, the lock and the root resolver rather than re-implementing them" {
  grep -q 'commit-ref.sh' "$SCRIPT"
  grep -q 'with-lock.sh' "$SCRIPT"
  grep -q 'resolve-root.sh' "$SCRIPT"
  # only comments may name the path
  code="$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)"
  assert_not_contains "$code" "project/queue"
  assert_not_contains "$code" '"project/'
}
