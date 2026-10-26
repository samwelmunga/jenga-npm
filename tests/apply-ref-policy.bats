#!/usr/bin/env bats
#
# E79_S04_T08: scripts/apply-ref-policy.sh applies the Phase 1 unresolved-ref policy (on_unresolved=fail, open decision 5) on top
# of scripts/resolve-commit-ref.sh: a resolved ref is passed through, a project that is not opted in sees nothing, and an
# unresolved ref stops the task with a message naming the sources tried. No prompt, no EST fallback, no placeholder ref.
#
# What this pins (one named case per acceptance criterion, plus the contract around them):
#   - resolved: the resolver's stdout and stderr are passed through unchanged, exit 0 (also when the sources disagree);
#   - unresolved (nothing anywhere): exit 6, empty stdout, and the stderr message names the task id and every source consulted
#     in order, including the branch the candidate would have come from (or none); the list follows ref_source;
#   - the stored branch name is shown only when it is printable (hand-edited store, newline, over-long, symlinked file);
#   - never interactive: stdin from /dev/null, with stdin closed and with a pipe that never closes all finish inside a
#     wall-clock bound that needs no GNU timeout, with identical results; the script has no read builtin and no terminal device;
#   - after exit 6 the project tree (store, board, config) and the git history are unchanged and no EST-form or placeholder
#     subject exists anywhere; the script holds no fallback literal and no subject builder;
#   - not opted in: exit 0, empty stdout and stderr, and no board file is opened (the board directory is unreadable);
#   - a policy other than fail (a stub settings reader bypasses the validator) is exit 7 and the resolver is never run;
#   - --check gives the same stdout, stderr and exit codes and writes nothing;
#   - the resolver's exit codes are mapped (10 silent, 2/3/5 passed on, anything else 5) and its stdout is passed through
#     verbatim whatever lines it prints and in whatever order (a stub resolver prints a future conflict= line);
#   - a task worktree: --root / JENGA_PROJECT_ROOT reach the main tree's store, and the unresolved message says so otherwise;
#   - usage errors, --help, bash -n, no dynamic execution, no bash 4 feature.
#
# The script is always run as `bash <script>`, so these cases do not depend on the file's executable bit.
# Everything the cases create lives under $BATS_TEST_TMPDIR. These cases were written without being executed by their
# author; the tester runs them.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/apply-ref-policy.sh"
REAL_RESOLVER="$REPO_ROOT/scripts/resolve-commit-ref.sh"
STORE_SCRIPT="$REPO_ROOT/scripts/task-commit-ref.sh"
REAL_CONFIGS="$REPO_ROOT/project/configs"

ID="E79_S04_T08"

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
  git symbolic-ref HEAD refs/heads/E79_S04_T08-add-x
  git -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init >/dev/null 2>&1
  write_conv '.'
  QDIR="$(bash "$REPO_ROOT/scripts/resolve-root.sh" --strict get queue)"
  export STUB_OUT="$BATS_TEST_TMPDIR/stub.out" STUB_RC="$BATS_TEST_TMPDIR/stub.rc" STUB_MARK="$BATS_TEST_TMPDIR/stub.mark"
}

teardown() {
  chmod -R u+rwx "$BOARD" 2>/dev/null || true
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- helpers ---------------------------------------------------------------------------------------------------

# apr [args...]: run the wrapper for the task with stdout in $output and stderr in $stderr.
apr() {
  run --separate-stderr bash "$SCRIPT" "$@" "$ID"
}

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

# write_item <dir> <item-id> [key...]: a board item with one external_refs Jira entry per key (or an empty list).
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

# capture_branch_only <branch>: record a branch that carries no key (candidate null, the branch name is stored).
capture_branch_only() {
  run --separate-stderr bash "$STORE_SCRIPT" capture-branch "$ID" --branch "$1"
  [ "$status" -eq 0 ]
}

# set_stored_branch <value>: overwrite the stored branch name (a hand-edited store).
set_stored_branch() {
  local f="$QDIR/commit-refs/$ID.json"
  [ -f "$f" ]
  jq --arg b "$1" '.branch = $b' "$f" > "$f.new" && mv "$f.new" "$f"
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

pad() {
  head -c "$1" /dev/zero | tr '\000' 'A'
}

# The exact first line of the message, for the sources given.
msg_line() { # msg_line <sources text>
  printf 'apply-ref-policy: no commit ref could be resolved for %s; sources tried: %s; on_unresolved=fail' "$ID" "$1"
}

FULL_SOURCES_NONE="task external_refs, story external_refs, epic external_refs, captured branch candidate (none)"

# A scratch tree whose scripts/ directory is a set of symlinks to the real scripts, so single scripts can be replaced by stubs
# while the wrapper still finds its siblings next to itself.
mk_scratch() {
  SROOT="$BATS_TEST_TMPDIR/sroot"
  local f b
  mkdir -p "$SROOT/scripts"
  for f in "$REPO_ROOT"/*; do
    b="$(basename "$f")"
    case "$b" in
      scripts|project|tests|node_modules) continue ;;
    esac
    ln -s "$f" "$SROOT/$b"
  done
  for f in "$REPO_ROOT"/scripts/*; do
    ln -s "$f" "$SROOT/scripts/$(basename "$f")"
  done
  SSCRIPT="$SROOT/scripts/apply-ref-policy.sh"
}

# stub_resolver <exit status> <stdout text>: replace the resolver in the scratch tree by a stub that prints the text and exits.
stub_resolver() {
  rm -f "$SROOT/scripts/resolve-commit-ref.sh"
  printf '%s' "$2" > "$STUB_OUT"
  printf '%s' "$1" > "$STUB_RC"
  rm -f "$STUB_MARK"
  cat > "$SROOT/scripts/resolve-commit-ref.sh" <<'EOF'
#!/usr/bin/env bash
: > "$STUB_MARK"
cat "$STUB_OUT"
exit "$(cat "$STUB_RC")"
EOF
}

# stub_settings <sed expression>: replace the settings reader by one that runs the real one and edits its output with sed.
stub_settings() {
  rm -f "$SROOT/scripts/commit-settings.sh"
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/stub.sed"
  cat > "$SROOT/scripts/commit-settings.sh" <<EOF
#!/usr/bin/env bash
bash "$REPO_ROOT/scripts/commit-settings.sh" "\$@" | sed -f "$BATS_TEST_TMPDIR/stub.sed"
EOF
}

sapr() { # run the scratch copy of the wrapper
  run --separate-stderr bash "$SSCRIPT" "$@" "$ID"
}

# run_bounded <seconds> <null|closed|pipe> <args...>: run the wrapper with the given stdin and a hard wall-clock bound that
# needs no GNU timeout. Sets B_STATUS (124 when the bound was hit), B_OUT and B_ERR.
run_bounded() {
  local secs="$1" mode="$2" i pid
  shift 2
  local out="$BATS_TEST_TMPDIR/b.out" err="$BATS_TEST_TMPDIR/b.err" rcf="$BATS_TEST_TMPDIR/b.rc"
  rm -f "$out" "$err" "$rcf"
  case "$mode" in
    null) ( set +e; bash "$SCRIPT" "$@" >"$out" 2>"$err" </dev/null; echo $? >"$rcf" ) 3>&- & ;;
    closed) ( set +e; bash "$SCRIPT" "$@" >"$out" 2>"$err" <&-; echo $? >"$rcf" ) 3>&- & ;;
    pipe) ( set +e; sleep $((secs + 4)) | { bash "$SCRIPT" "$@" >"$out" 2>"$err"; echo $? >"$rcf"; } ) 3>&- & ;;
  esac
  pid=$!
  i=0
  while [ ! -s "$rcf" ] && [ "$i" -lt $((secs * 10)) ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ -s "$rcf" ]; then
    B_STATUS="$(cat "$rcf")"
  else
    B_STATUS=124
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  fi
  B_OUT="$(cat "$out" 2>/dev/null || true)"
  B_ERR="$(cat "$err" 2>/dev/null || true)"
}

# --- resolved --------------------------------------------------------------------------------------------------

@test "a resolved ref is passed through unchanged: same stdout, same stderr, exit 0" {
  board ASD-001 ASD-002 ASD-003
  capture ZZZ-9
  run --separate-stderr bash "$REAL_RESOLVER" "$ID"
  [ "$status" -eq 0 ]
  want_out="$output"
  want_err="$stderr"
  [ -n "$want_err" ]
  apr
  [ "$status" -eq 0 ]
  [ "$output" = "$want_out" ]
  [ "$stderr" = "$want_err" ]
  assert_starts_with "$output" "ref=ASD-001"$'\n'"source=task"$'\n'
}

@test "a story key, an epic key and a branch-only key are each passed through" {
  board "" ASD-002 ""
  apr
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-002"$'\n'"source=story"$'\n'
  board "" "" ASD-003
  apr
  assert_starts_with "$output" "ref=ASD-003"$'\n'"source=epic"$'\n'
  board "" "" ""
  capture ZZZ-9
  apr
  [ "$status" -eq 0 ]
  [ "$output" = "ref=ZZZ-9"$'\n'"source=branch"$'\n'"tried=task,story,epic,branch"$'\n'"candidate.branch=ZZZ-9" ]
}

@test "a resolved run writes nothing and an unresolved message is not printed" {
  board ASD-001 "" ""
  before="$(tree_sum)"
  apr
  [ "$status" -eq 0 ]
  assert_not_contains "$stderr" "no commit ref could be resolved"
  [ "$(tree_sum)" = "$before" ]
}

# --- unresolved: the message -----------------------------------------------------------------------------------

@test "with no source anywhere: exit 6, empty stdout, and the message names the task id and every source in order" {
  board "" "" ""
  apr
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$(msg_line "$FULL_SOURCES_NONE")"
  assert_contains "$stderr" "link a Jira key with scripts/link-external-ref.sh, or create the task from a branch that carries one"
  assert_contains "$stderr" "$ID"
}

@test "the message order is task, story, epic, then the captured branch candidate" {
  board "" "" ""
  apr
  [ "$status" -eq 6 ]
  line="$(printf '%s\n' "$stderr" | grep -F "no commit ref could be resolved")"
  rest="${line#*sources tried: }"
  [ "${rest%%,*}" = "task external_refs" ]
  rest="${rest#*, }"
  [ "${rest%%,*}" = "story external_refs" ]
  rest="${rest#*, }"
  [ "${rest%%,*}" = "epic external_refs" ]
  rest="${rest#*, }"
  assert_starts_with "$rest" "captured branch candidate ("
}

@test "a missing board entirely is also unresolved (exit 6), not an error" {
  apr
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$(msg_line "$FULL_SOURCES_NONE")"
}

@test "the message names the branch the candidate would have come from" {
  board "" "" ""
  capture_branch_only main
  apr
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$(msg_line "task external_refs, story external_refs, epic external_refs, captured branch candidate (main)")"
  capture_branch_only main
  set_stored_branch "release/2026-10.x"
  apr
  assert_contains "$stderr" "captured branch candidate (release/2026-10.x); on_unresolved=fail"
}

@test "an invalid board key is not a candidate, so the task is unresolved, and the resolver's notice stays on stderr" {
  board asd-1 "" ""
  apr
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "resolve-commit-ref: "
  assert_contains "$stderr" "$(msg_line "$FULL_SOURCES_NONE")"
}

@test "ref_source external_refs lists only the board levels" {
  write_conv '.categories["commit-format"].values.ref_source = "external_refs"'
  board "" "" ""
  capture ZZZ-9
  apr
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$(msg_line "task external_refs, story external_refs, epic external_refs")"
  assert_not_contains "$stderr" "captured branch candidate"
}

@test "ref_source perceived_branch lists only the captured branch candidate" {
  write_conv '.categories["commit-format"].values.ref_source = "perceived_branch"'
  board ASD-001 ASD-002 ASD-003
  capture_branch_only main
  apr
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$(msg_line "captured branch candidate (main)")"
  assert_not_contains "$stderr" "task external_refs"
}

@test "--conventions is handed to the settings reader and the resolver" {
  board "" "" ""
  capture ZZZ-9
  apr
  [ "$status" -eq 0 ]
  base_json | jq '.categories["commit-format"].values.ref_source = "external_refs"' > "$BATS_TEST_TMPDIR/alt.json"
  apr --conventions "$BATS_TEST_TMPDIR/alt.json"
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "$(msg_line "task external_refs, story external_refs, epic external_refs")"
}

@test "a hand-edited stored branch name with spaces, a newline or an over-long value is shown as unprintable and runs nothing" {
  board "" "" ""
  capture_branch_only main
  set_stored_branch 'a b; touch '"$CANARY"
  apr
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "captured branch candidate (unprintable); on_unresolved=fail"
  assert_not_contains "$stderr" "touch"
  set_stored_branch $'feature/x\nforged: line'
  apr
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "captured branch candidate (unprintable); on_unresolved=fail"
  assert_not_contains "$stderr" "forged"
  set_stored_branch "$(pad 201)"
  apr
  assert_contains "$stderr" "captured branch candidate (unprintable); on_unresolved=fail"
  set_stored_branch '$(touch '"$CANARY"')'
  apr
  assert_contains "$stderr" "captured branch candidate (unprintable); on_unresolved=fail"
  [ ! -e "$CANARY" ]
}

@test "a null or empty stored branch is shown as none, and a symlinked store file is never followed" {
  board "" "" ""
  capture_branch_only main
  set_stored_branch ""
  apr
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "captured branch candidate (none); on_unresolved=fail"
  f="$QDIR/commit-refs/$ID.json"
  set_stored_branch "leakybranch"
  mv "$f" "$BATS_TEST_TMPDIR/elsewhere.json"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.json" "$f"
  apr
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "captured branch candidate (none); on_unresolved=fail"
  assert_not_contains "$stderr" "leakybranch"
}

# --- unresolved: no side effects, no fallback ------------------------------------------------------------------

@test "after exit 6 the store, the board, the config and the git history are unchanged and no subject or placeholder ref exists" {
  board "" "" ""
  capture_branch_only main
  before="$(tree_sum)"
  head_before="$(git -C "$WORK" rev-parse HEAD)"
  log_before="$(git -C "$WORK" log --oneline | wc -l | tr -d ' ')"
  store_before="$(find "$QDIR" -type f -exec cksum {} + | sort | cksum)"
  apr
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  [ "$(tree_sum)" = "$before" ]
  [ "$(git -C "$WORK" rev-parse HEAD)" = "$head_before" ]
  [ "$(git -C "$WORK" log --oneline | wc -l | tr -d ' ')" = "$log_before" ]
  [ "$(find "$QDIR" -type f -exec cksum {} + | sort | cksum)" = "$store_before" ]
  assert_not_contains "$output" "task("
  assert_not_contains "$stderr" "ref="
  assert_not_contains "$stderr" "task(E79"
}

@test "the same unresolved run with --check exits 6, prints the same message and writes nothing" {
  board "" "" ""
  capture_branch_only main
  apr
  want_status="$status"
  want_err="$stderr"
  want_out="$output"
  before="$(tree_sum)"
  apr --check
  [ "$status" -eq "$want_status" ]
  [ "$status" -eq 6 ]
  [ "$output" = "$want_out" ]
  [ "$stderr" = "$want_err" ]
  [ "$(tree_sum)" = "$before" ]
}

@test "--check on a resolved task and on a project that is not opted in gives the same exit codes and output as the real run" {
  board ASD-001 "" ""
  apr
  want_out="$output"
  want_err="$stderr"
  apr --check
  [ "$status" -eq 0 ]
  [ "$output" = "$want_out" ]
  [ "$stderr" = "$want_err" ]
  rm -f "$CONV"
  apr --check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# --- never interactive -----------------------------------------------------------------------------------------

@test "an unresolved run finishes inside the wall-clock bound with stdin from /dev/null, with stdin closed and with a pipe that never closes, with identical results" {
  board "" "" ""
  capture_branch_only main
  run_bounded 12 null "$ID"
  [ "$B_STATUS" -eq 6 ]
  want_err="$B_ERR"
  [ -z "$B_OUT" ]
  assert_contains "$want_err" "no commit ref could be resolved for $ID"
  run_bounded 12 closed "$ID"
  [ "$B_STATUS" -eq 6 ]
  [ "$B_ERR" = "$want_err" ]
  [ -z "$B_OUT" ]
  run_bounded 12 pipe "$ID"
  [ "$B_STATUS" -eq 6 ]
  [ "$B_ERR" = "$want_err" ]
  [ -z "$B_OUT" ]
}

@test "a resolved run and a not-opted-in run are equally independent of stdin" {
  board ASD-001 "" ""
  run_bounded 12 null "$ID"
  [ "$B_STATUS" -eq 0 ]
  want_out="$B_OUT"
  want_err="$B_ERR"
  run_bounded 12 pipe "$ID"
  [ "$B_STATUS" -eq 0 ]
  [ "$B_OUT" = "$want_out" ]
  [ "$B_ERR" = "$want_err" ]
  rm -f "$CONV"
  run_bounded 12 pipe "$ID"
  [ "$B_STATUS" -eq 0 ]
  [ -z "$B_OUT" ]
  [ -z "$B_ERR" ]
}

@test "the script has no read builtin, no terminal device and no prompt" {
  code="$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)"
  run grep -nw 'read' <<< "$code"
  [ "$status" -eq 1 ]
  run grep -nE '/dev/tty|/dev/stdin|[[:space:]]select[[:space:]]|stty|tty -s|<&0|\[ -t ' <<< "$code"
  [ "$status" -eq 1 ]
}

@test "the resolver is always run with stdin from /dev/null" {
  grep -q 'bash "\$RESOLVE" "\$ID" --conventions "\$CONV" </dev/null' "$SCRIPT"
  grep -q 'bash "\$RESOLVE" "\$ID" </dev/null' "$SCRIPT"
}

# --- no EST fallback, one policy -------------------------------------------------------------------------------

@test "the script holds no fallback literal and no EST-style subject builder" {
  run grep -nE 'NOREF|UNKNOWN|N/A' "$SCRIPT"
  [ "$status" -eq 1 ]
  run grep -nE 'commit-template|\{ref\}|\{summary\}|(task|story|epic)\(' "$SCRIPT"
  [ "$status" -eq 1 ]
  run grep -nE 'git +(commit|tag|push|add)|task-commit-ref.sh +(freeze|clear|capture-branch)' "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "the only policy value in the script is fail" {
  run bash -c 'grep -oE "on_unresolved=[A-Za-z_-]*" "$1" | sort -u' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "on_unresolved=fail" ]
}

# --- not opted in ----------------------------------------------------------------------------------------------

@test "no conventions.json is exit 0 with empty stdout and stderr, and no board file is opened" {
  [ "$(id -u)" -ne 0 ] || skip "an unreadable directory is readable for root"
  board ASD-001 ASD-002 ASD-003
  rm -f "$CONV"
  chmod 000 "$BOARD"
  apr
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "apply_to_board_commits false and a template without the flag are not opted in either" {
  [ "$(id -u)" -ne 0 ] || skip "an unreadable directory is readable for root"
  board ASD-001 ASD-002 ASD-003
  write_conv '.categories["commit-format"].values.apply_to_board_commits = false'
  chmod 000 "$BOARD"
  apr
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  chmod -R u+rwx "$BOARD"
  write_conv 'del(.categories["commit-format"].values.apply_to_board_commits)'
  chmod 000 "$BOARD"
  apr
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a not-opted-in project never reaches the resolver" {
  mk_scratch
  stub_resolver 0 $'ref=ASD-001\n'
  rm -f "$CONV"
  sapr
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ ! -e "$STUB_MARK" ]
}

@test "an invalid conventions file is exit 3 with empty stdout" {
  board ASD-001 "" ""
  printf '{' > "$CONV"
  apr
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# --- a policy other than fail ----------------------------------------------------------------------------------

@test "an effective policy other than fail is exit 7 and the resolver is never run" {
  mk_scratch
  stub_resolver 0 $'ref=ASD-001\nsource=task\ntried=task\n'
  board ASD-001 "" ""
  for v in prompt use-fallback-ref warn skip ""; do
    stub_settings "s/^on_unresolved=.*/on_unresolved=$v/"
    rm -f "$STUB_MARK"
    sapr
    [ "$status" -eq 7 ]
    [ -z "$output" ]
    assert_contains "$stderr" "only 'fail' is supported in Phase 1"
    [ ! -e "$STUB_MARK" ]
  done
}

@test "a missing on_unresolved line is exit 7, and a hostile value is refused without being echoed or run" {
  mk_scratch
  stub_resolver 0 $'ref=ASD-001\n'
  stub_settings '/^on_unresolved=/d'
  sapr
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  stub_settings "s|^on_unresolved=.*|on_unresolved=fail; touch $CANARY|"
  sapr
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  assert_not_contains "$stderr" "touch"
  [ ! -e "$CANARY" ]
  stub_settings 's/^on_unresolved=.*/on_unresolved=fail /'
  sapr
  [ "$status" -eq 7 ]
}

@test "a value outside the schema enum recorded in conventions.json never reaches a ref decision" {
  board ASD-001 "" ""
  write_conv '.categories["commit-format"].values.on_unresolved = "prompt"'
  apr
  [ "$status" -ne 0 ]
  [ "$status" -ne 6 ]
  [ -z "$output" ]
}

@test "--check returns exit 7 for a bad policy, exactly as the real run does" {
  mk_scratch
  stub_resolver 0 $'ref=ASD-001\n'
  stub_settings 's/^on_unresolved=.*/on_unresolved=prompt/'
  sapr
  want="$status"
  sapr --check
  [ "$status" -eq "$want" ]
  [ "$status" -eq 7 ]
}

# --- the resolver's contract, with a stub resolver -------------------------------------------------------------

@test "the resolver's stdout is passed through verbatim, whatever lines it prints and in whatever order" {
  mk_scratch
  stub_resolver 0 $'conflict=task=ASD-001,story=ASD-002\ncandidate.task=ASD-001\nsource=task\nfuture.line=x y\nref=ASD-001\ntried=task,story\n'
  sapr
  [ "$status" -eq 0 ]
  [ "$output" = $'conflict=task=ASD-001,story=ASD-002\ncandidate.task=ASD-001\nsource=task\nfuture.line=x y\nref=ASD-001\ntried=task,story' ]
}

@test "resolver exit 10 is silent exit 0 and resolver exits 2, 3 and 5 are passed on" {
  mk_scratch
  stub_resolver 10 ""
  sapr
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  for rc in 2 3 5; do
    stub_resolver "$rc" $'tried=task\n'
    sapr
    [ "$status" -eq "$rc" ]
    [ -z "$output" ]
  done
}

@test "an unexpected resolver exit status (4, 6, 7, 99) is exit 5, never 6 or 0" {
  mk_scratch
  for rc in 4 6 7 99; do
    stub_resolver "$rc" $'ref=ASD-001\n'
    sapr
    [ "$status" -eq 5 ]
    [ -z "$output" ]
  done
}

@test "an unresolved result finds tried= wherever it is, follows its order, and ignores other lines" {
  mk_scratch
  stub_resolver 1 $'conflict=none\ntried=branch,task\nother=1\n'
  sapr
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "$(msg_line "captured branch candidate (none), task external_refs")"
}

@test "an unresolved result with a missing, empty or unknown tried= list is exit 5 with nothing on stdout" {
  mk_scratch
  stub_resolver 1 $'other=1\n'
  sapr
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  stub_resolver 1 $'tried=\n'
  sapr
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  stub_resolver 1 $'tried=task,bogus\n'
  sapr
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "a missing sibling script is exit 5" {
  mk_scratch
  rm -f "$SROOT/scripts/resolve-commit-ref.sh"
  board ASD-001 "" ""
  sapr
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

# --- a task worktree --------------------------------------------------------------------------------------------

@test "from a linked worktree the unresolved message says where the candidate lives, and --root or JENGA_PROJECT_ROOT reach it" {
  board "" "" ""
  capture ZZZ-9
  LINKED="$BATS_TEST_TMPDIR/linked"
  git -C "$WORK" worktree add -q "$LINKED" -b linked-branch
  cp -R "$PROJ/project" "$LINKED/project"
  rm -rf "$LINKED/project/queue"
  cd "$LINKED" || return 1
  run --separate-stderr env -u JENGA_PROJECT_ROOT bash "$SCRIPT" "$ID"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "captured branch candidate (none); on_unresolved=fail"
  assert_contains "$stderr" "linked git worktree"
  assert_contains "$stderr" "--root"
  run --separate-stderr env -u JENGA_PROJECT_ROOT bash "$SCRIPT" --root "$PROJ" "$ID"
  [ "$status" -eq 0 ]
  [ "$output" = "ref=ZZZ-9"$'\n'"source=branch"$'\n'"tried=task,story,epic,branch"$'\n'"candidate.branch=ZZZ-9" ]
  run --separate-stderr env JENGA_PROJECT_ROOT="$PROJ" bash "$SCRIPT" "$ID"
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ZZZ-9"$'\n'
}

@test "outside a linked worktree, or with a root given, the worktree note is not printed" {
  board "" "" ""
  apr
  [ "$status" -eq 6 ]
  assert_not_contains "$stderr" "linked git worktree"
  LINKED="$BATS_TEST_TMPDIR/linked"
  git -C "$WORK" worktree add -q "$LINKED" -b linked-branch
  cd "$LINKED" || return 1
  run --separate-stderr bash "$SCRIPT" --root "$PROJ" "$ID"
  [ "$status" -eq 6 ]
  assert_not_contains "$stderr" "linked git worktree"
}

# --- usage and static properties -------------------------------------------------------------------------------

@test "--help prints the usage on stdout and exits 0" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage:"
  assert_contains "$output" "on_unresolved=fail"
  [ -z "$stderr" ]
}

@test "usage errors are exit 2, print nothing on stdout and create nothing" {
  before="$(tree_sum)"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" ""
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" E79_S04
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "../x"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" 'E79_S04_T08/../../y'
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" 'E79_S04_T08;touch'
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "$ID" E79_S04_T07
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "$ID" --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "$ID" --conventions
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "$ID" --conventions a --conventions b
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "$ID" --root
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "$ID" --root "$BATS_TEST_TMPDIR/no-such-dir"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(tree_sum)" = "$before" ]
}

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
  code="$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)"
  run grep -nE 'declare +-A|local +-A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)|&>>|\[\[ +-v ' <<< "$code"
  [ "$status" -eq 1 ]
}

@test "the script reuses the settings reader, the resolver and the root resolver rather than re-implementing them" {
  grep -q 'commit-settings.sh' "$SCRIPT"
  grep -q 'resolve-commit-ref.sh' "$SCRIPT"
  grep -q 'resolve-root.sh' "$SCRIPT"
}

@test "the resolver script is not edited by this task's wrapper: the wrapper never passes a conflict flag" {
  run grep -n -- '--on-conflict' "$SCRIPT"
  [ "$status" -eq 1 ]
}
