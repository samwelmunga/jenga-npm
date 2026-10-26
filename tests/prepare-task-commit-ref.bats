#!/usr/bin/env bats
#
# E79_S04_T10: scripts/prepare-task-commit-ref.sh is the single developer entry point that resolves and freezes a task's commit ref
# by composing commit-settings.sh (opt-in), task-commit-ref.sh (the store) and apply-ref-policy.sh (the chain + on_unresolved=fail).
# It adds no resolution logic; these cases pin the sequence and the exit-code contract around it.
#
# What this pins (one named case per acceptance criterion, plus the contract around them):
#   - not opted in: no output, exit 0, and nothing is created anywhere (a fingerprint of the project and the repository is equal);
#   - opted in and resolvable: commit_ref= and source= lines, exit 0, and the store holds the frozen ref;
#   - a second call after the sources changed prints the original frozen ref, exit 0 (it does not even need the board);
#   - unresolved: exit 6, apply-ref-policy's message on stderr, an empty stdout, nothing frozen;
#   - disagreement: under warn (default and explicit) the precedence winner is frozen and the others are conflict= lines, also in the
#     store; under --on-conflict fail exit 8 with nothing frozen; --on-conflict is not consulted for an already frozen ref;
#   - the exit-code reconciliation: the task text said 5 for a disagreement, but 5 is "dependency unavailable" and the resolver's own
#     code is 7 (taken by apply-ref-policy). Prepare uses 8 for the disagreement and 9 for a store that cannot be used (the store's
#     own 6 is "unresolved" here); every other code is passed on. A stub of each composed script proves the mapping;
#   - never interactive: stdin from /dev/null, with stdin closed, identical results; the script has no read builtin or terminal device;
#   - a task worktree: --root / JENGA_PROJECT_ROOT reach the main tree's captured candidate and store;
#   - a hostile key (shell metacharacters) is rejected and never executed; usage errors; --help; bash -n; no dynamic execution;
#   - the exit-code table is in the script header and in project-conventions.md.
#
# The script is always run as `bash <script>`, so these cases do not depend on the file's executable bit.
# Everything the cases create lives under $BATS_TEST_TMPDIR. These cases were written without being executed by their author;
# the tester runs them.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/prepare-task-commit-ref.sh"
STORE_SCRIPT="$REPO_ROOT/scripts/task-commit-ref.sh"
DOC="$REPO_ROOT/project/documentation/project-conventions.md"
REAL_CONFIGS="$REPO_ROOT/project/configs"

ID="E79_S04_T10"

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
  git symbolic-ref HEAD refs/heads/E79_S04_T10-add-x
  git -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init >/dev/null 2>&1
  write_conv '.'
  QDIR="$(bash "$REPO_ROOT/scripts/resolve-root.sh" --strict get queue)"
  STORE_FILE="$QDIR/commit-refs/$ID.json"
}

teardown() {
  chmod -R u+rwx "$BOARD" 2>/dev/null || true
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- helpers ---------------------------------------------------------------------------------------------------

# prep [args...]: run the entry point for the task with stdout in $output and stderr in $stderr.
prep() {
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

# stored <field>: the value the store reports for the task (empty and status 1 when nothing is frozen).
stored() {
  bash "$STORE_SCRIPT" get "$ID" --field "$1"
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

# A scratch tree whose scripts/ directory is a set of symlinks to the real scripts, so single scripts can be replaced by stubs
# while the entry point still finds its siblings next to itself.
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
  SSCRIPT="$SROOT/scripts/prepare-task-commit-ref.sh"
  export STUB_OUT="$BATS_TEST_TMPDIR/stub.out" STUB_RC="$BATS_TEST_TMPDIR/stub.rc"
  export STUB_GET_RC="$BATS_TEST_TMPDIR/stub.get.rc" STUB_GET_OUT="$BATS_TEST_TMPDIR/stub.get.out"
  export STUB_GET_SRC="$BATS_TEST_TMPDIR/stub.get.src" STUB_FREEZE_RC="$BATS_TEST_TMPDIR/stub.freeze.rc"
}

# stub_apply <exit status> <stdout text>: replace apply-ref-policy.sh by a stub that prints the text and exits.
stub_apply() {
  rm -f "$SROOT/scripts/apply-ref-policy.sh"
  printf '%s' "$2" > "$STUB_OUT"
  printf '%s' "$1" > "$STUB_RC"
  cat > "$SROOT/scripts/apply-ref-policy.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_OUT"
exit "$(cat "$STUB_RC")"
EOF
}

# stub_store <get exit> <get ref> <get source> <freeze exit>: replace task-commit-ref.sh by a stub for get and freeze.
stub_store() {
  rm -f "$SROOT/scripts/task-commit-ref.sh"
  printf '%s' "$1" > "$STUB_GET_RC"
  printf '%s' "$2" > "$STUB_GET_OUT"
  printf '%s' "$3" > "$STUB_GET_SRC"
  printf '%s' "$4" > "$STUB_FREEZE_RC"
  cat > "$SROOT/scripts/task-commit-ref.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  get)
    rc="$(cat "$STUB_GET_RC")"
    if [ "$rc" -eq 0 ]; then
      case "$*" in
        *"--field source"*) cat "$STUB_GET_SRC"; printf '\n' ;;
        *) cat "$STUB_GET_OUT"; printf '\n' ;;
      esac
    fi
    exit "$rc"
    ;;
  freeze)
    exit "$(cat "$STUB_FREEZE_RC")"
    ;;
esac
exit 2
EOF
}

sprep() { # run the scratch copy of the entry point
  run --separate-stderr bash "$SSCRIPT" "$@" "$ID"
}

GOOD_OUT=$'ref=ASD-001\nsource=task\ntried=task,story,epic,branch\ncandidate.task=ASD-001'

# --- not opted in ------------------------------------------------------------------------------------------------

@test "not opted in (no conventions file): no output, exit 0, and nothing is created" {
  rm -f "$CONV"
  board ASD-001 "" ""
  before="$(tree_sum)"
  prep
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ ! -e "$QDIR/commit-refs" ]
  [ "$(tree_sum)" = "$before" ]
}

@test "not opted in (apply_to_board_commits false): no output, exit 0, nothing created, the board is never opened" {
  write_conv '.categories["commit-format"].values.apply_to_board_commits = false'
  board ASD-001 "" ""
  chmod 000 "$BOARD/tasks" "$BOARD/stories" "$BOARD/epics"
  prep
  chmod 755 "$BOARD/tasks" "$BOARD/stories" "$BOARD/epics"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ ! -e "$QDIR/commit-refs" ]
}

@test "an invalid conventions file is exit 3 with an empty stdout" {
  printf 'this is not json\n' > "$CONV"
  prep
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ ! -e "$QDIR/commit-refs" ]
}

@test "--conventions is forwarded: opted in through the named file, silent without it" {
  board ASD-001 "" ""
  cp "$CONV" "$BATS_TEST_TMPDIR/other.json"
  rm -f "$CONV"
  prep
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  prep --conventions "$BATS_TEST_TMPDIR/other.json"
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ASD-001"$'\n'"source=task" ]
}

# --- resolved and frozen -------------------------------------------------------------------------------------------

@test "opted in with a task key: prints commit_ref= and source=, exit 0, and the store holds the frozen ref" {
  board ASD-001 "" ""
  prep
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ASD-001"$'\n'"source=task" ]
  [ "$(stored ref)" = "ASD-001" ]
  [ "$(stored source)" = "task" ]
  run jq -r '.conflicts | length' "$STORE_FILE"
  [ "$output" = "0" ]
}

@test "the output key is commit_ref= and never the resolver's ref=" {
  board "" ASD-002 ""
  prep
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "commit_ref=ASD-002"$'\n'
  assert_contains "$output" "source=story"
  assert_not_contains "$output" $'\nref='
  assert_not_contains "$output" "tried="
}

@test "a story key, an epic key and a captured branch key are each frozen with their source" {
  board "" "" ASD-003
  prep
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ASD-003"$'\n'"source=epic" ]
  bash "$STORE_SCRIPT" clear "$ID"
  board "" "" ""
  capture ZZZ-9
  prep
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ZZZ-9"$'\n'"source=branch" ]
}

@test "a second call after the sources changed prints the original frozen ref and changes nothing" {
  board ASD-001 "" ""
  capture ZZZ-9
  prep
  [ "$status" -eq 0 ]
  # the first call disagrees (captured ZZZ-9 against the task key), so it also prints a conflict= line; the frozen path prints only two
  [ "$output" = "commit_ref=ASD-001"$'\n'"source=task"$'\n'"conflict=branch:ZZZ-9" ]
  first="$(printf '%s\n' "$output" | sed -n '1,2p')"
  sum_before="$(cksum < "$STORE_FILE")"
  board ASD-099 ASD-098 ASD-097
  run --separate-stderr bash "$STORE_SCRIPT" capture-branch "$ID" --branch "feature/QQQ-1-foo" --candidate QQQ-1
  [ "$status" -eq 0 ]
  prep
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [ "$output" = "commit_ref=ASD-001"$'\n'"source=task" ]
  [ "$(stored ref)" = "ASD-001" ]
  [ "$(stored source)" = "task" ]
  # the repeated capture changed nothing, and the repeated prepare wrote nothing
  [ "$(cksum < "$STORE_FILE")" = "$sum_before" ]
}

@test "a second call re-resolves nothing: it succeeds with the whole board gone" {
  board "" ASD-002 ""
  prep
  [ "$status" -eq 0 ]
  rm -rf "$BOARD"
  prep
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ASD-002"$'\n'"source=story" ]
  [ -z "$stderr" ]
}

@test "commits 1..n agree: three calls in a row print the same two lines" {
  board ASD-001 "" ""
  prep
  one="$output"
  prep
  two="$output"
  prep
  three="$output"
  [ "$one" = "$two" ]
  [ "$two" = "$three" ]
}

@test "a project that opts out after the freeze sees nothing, even with a frozen ref in the store" {
  board ASD-001 "" ""
  prep
  [ "$status" -eq 0 ]
  rm -f "$CONV"
  prep
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- unresolved ------------------------------------------------------------------------------------------------

@test "unresolved: exit 6, empty stdout, the policy message on stderr, nothing frozen" {
  board "" "" ""
  prep
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "apply-ref-policy: no commit ref could be resolved for $ID; sources tried: task external_refs, story external_refs, epic external_refs, captured branch candidate (none); on_unresolved=fail"
  assert_contains "$stderr" "fix:"
  [ ! -e "$STORE_FILE" ]
}

@test "unresolved with a captured branch that carries no key: still exit 6, the branch is named, nothing frozen" {
  board "" "" ""
  run --separate-stderr bash "$STORE_SCRIPT" capture-branch "$ID" --branch "main"
  [ "$status" -eq 0 ]
  prep
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_contains "$stderr" "captured branch candidate (main)"
  run bash "$STORE_SCRIPT" get "$ID"
  [ "$status" -eq 1 ]
}

@test "unresolved leaves the project and the repository unchanged and produces no EST-style subject" {
  board "" "" ""
  before="$(tree_sum)"
  head_before="$(git -C "$WORK" rev-parse HEAD)"
  prep
  [ "$status" -eq 6 ]
  [ "$(tree_sum)" = "$before" ]
  [ "$(git -C "$WORK" rev-parse HEAD)" = "$head_before" ]
  [ -z "$output" ]
  assert_not_contains "$stderr" "task($ID)"
}

@test "a hostile key (shell metacharacters) is rejected, never executed, and the task is unresolved" {
  write_item "$BOARD/tasks" "$ID" "ASD-001; touch $CANARY"
  write_item "$BOARD/stories" "E79_S04"
  write_item "$BOARD/epics" "E79" '$(touch '"$CANARY"')'
  prep
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  [ ! -e "$CANARY" ]
  [ ! -e "$STORE_FILE" ]
}

# --- disagreement ------------------------------------------------------------------------------------------------

@test "warn (the default): the task key is frozen, the others are conflict= lines, exit 0, one warning" {
  board ASD-001 ASD-002 ASD-003
  prep
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ASD-001"$'\n'"source=task"$'\n'"conflict=story:ASD-002"$'\n'"conflict=epic:ASD-003" ]
  assert_contains "$stderr" "disagree"
  [ "$(stored ref)" = "ASD-001" ]
  run jq -c '.conflicts' "$STORE_FILE"
  [ "$output" = '["story:ASD-002","epic:ASD-003"]' ]
}

@test "explicit --on-conflict warn behaves exactly like the default" {
  board ASD-001 ASD-002 ""
  prep --on-conflict warn
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ASD-001"$'\n'"source=task"$'\n'"conflict=story:ASD-002" ]
}

@test "a task key against a different captured branch key under warn: the task wins, conflict=branch is recorded" {
  board ASD-001 "" ""
  capture ZZZ-9
  prep
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ASD-001"$'\n'"source=task"$'\n'"conflict=branch:ZZZ-9" ]
}

@test "--on-conflict fail with a disagreement: exit 8, empty stdout, every level and key named, nothing frozen" {
  board ASD-001 ASD-002 ""
  prep --on-conflict fail
  [ "$status" -eq 8 ]
  [ -z "$output" ]
  assert_contains "$stderr" "the sources disagree for $ID"
  assert_contains "$stderr" "ASD-001"
  assert_contains "$stderr" "story:ASD-002"
  assert_contains "$stderr" "nothing was frozen"
  [ ! -e "$STORE_FILE" ]
}

@test "the disagreement code is 8 and not 5, 6, 7 or 9, and it is the code the header documents" {
  board ASD-001 ASD-002 ""
  prep --on-conflict fail
  [ "$status" -eq 8 ]
  [ "$status" -ne 5 ]
  grep -q '^#   8   NEW: the sources disagree' "$SCRIPT"
}

@test "--on-conflict fail without a disagreement freezes normally (an inherited or equal key is no conflict)" {
  board ASD-001 ASD-001 ASD-001
  prep --on-conflict fail
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ASD-001"$'\n'"source=task" ]
  [ "$(stored ref)" = "ASD-001" ]
}

@test "--on-conflict fail is not consulted for a ref that is already frozen" {
  board ASD-001 ASD-002 ""
  prep
  [ "$status" -eq 0 ]
  prep --on-conflict fail
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ASD-001"$'\n'"source=task" ]
}

@test "the frozen path prints only commit_ref= and source=, never the conflict lines" {
  board ASD-001 ASD-002 ""
  prep
  assert_contains "$output" "conflict=story:ASD-002"
  prep
  assert_not_contains "$output" "conflict="
}

# --- the store and the exit-code mapping --------------------------------------------------------------------------

@test "a corrupted store file is exit 3 with an empty stdout" {
  board ASD-001 "" ""
  mkdir -p "$QDIR/commit-refs"
  printf 'not json at all\n' > "$STORE_FILE"
  prep
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "a symbolic link as the store directory is exit 9 (the store's own 6), not 6" {
  board ASD-001 "" ""
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere" "$QDIR"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$QDIR/commit-refs"
  prep
  [ "$status" -eq 9 ]
  [ "$status" -ne 6 ]
  [ -z "$output" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
}

@test "the exit codes of apply-ref-policy are passed on: 2, 3, 5, 6 and 7 keep their numbers, stdout empty" {
  mk_scratch
  stub_apply 0 ""
  local rc
  for rc in 2 3 5 6 7; do
    stub_apply "$rc" ""
    sprep
    [ "$status" -eq "$rc" ]
    [ -z "$output" ]
  done
}

@test "an exit status apply-ref-policy never returns is exit 5 (a broken contract), stdout empty" {
  mk_scratch
  stub_apply 11 "$GOOD_OUT"
  sprep
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "success without a ref= line, or with an unknown source, is exit 5 and nothing is frozen" {
  mk_scratch
  stub_apply 0 $'source=task\ntried=task'
  sprep
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  stub_apply 0 $'ref=ASD-001\nsource=sideways\ntried=task'
  sprep
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [ ! -e "$STORE_FILE" ]
}

@test "a conflict line with unexpected characters is exit 5, never frozen and never printed" {
  mk_scratch
  stub_apply 0 $'ref=ASD-001\nsource=task\ntried=task\nconflict=story:A;B'
  sprep
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  assert_not_contains "$stderr" "A;B"
  [ ! -e "$STORE_FILE" ]
}

@test "the exit codes of the store are mapped: freeze 4 stays 4, 3 stays 3, 5 stays 5, 6 becomes 9, others become 5" {
  mk_scratch
  stub_apply 0 "$GOOD_OUT"
  local pair want rc
  for pair in "4:4" "3:3" "5:5" "6:9" "11:5"; do
    rc="${pair%%:*}"
    want="${pair##*:}"
    stub_store 1 "" "" "$rc"
    sprep
    [ "$status" -eq "$want" ]
    [ -z "$output" ]
  done
}

@test "the exit codes of the store's get are mapped the same way and the resolver is never run" {
  mk_scratch
  stub_apply 0 "$GOOD_OUT"
  local pair want rc
  for pair in "3:3" "5:5" "6:9" "11:5"; do
    rc="${pair%%:*}"
    want="${pair##*:}"
    stub_store "$rc" "" "" 0
    sprep
    [ "$status" -eq "$want" ]
    [ -z "$output" ]
  done
}

@test "a frozen ref from the store is returned without running apply-ref-policy" {
  mk_scratch
  stub_apply 6 ""
  stub_store 0 "ASD-077" "epic" 0
  sprep
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ASD-077"$'\n'"source=epic" ]
}

@test "the store printing an unknown source is exit 5, not a printed line" {
  mk_scratch
  stub_apply 6 ""
  stub_store 0 "ASD-077" "sideways" 0
  sprep
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "the ref reaches the store only as the value of --ref, never as a lone argument" {
  grep -q -- '--ref "\$REF"' "$SCRIPT"
  run grep -nE 'bash "\$STORE" +"?\$REF' "$SCRIPT"
  [ "$status" -eq 1 ]
}

# --- never interactive -------------------------------------------------------------------------------------------

@test "stdin from /dev/null and a closed stdin give identical results, resolved and unresolved" {
  board ASD-001 "" ""
  run --separate-stderr bash "$SCRIPT" "$ID" </dev/null
  [ "$status" -eq 0 ]
  a_out="$output"
  bash "$STORE_SCRIPT" clear "$ID"
  run --separate-stderr bash "$SCRIPT" "$ID" <&-
  [ "$status" -eq 0 ]
  [ "$output" = "$a_out" ]
  board "" "" ""
  bash "$STORE_SCRIPT" clear "$ID"
  run --separate-stderr bash "$SCRIPT" "$ID" </dev/null
  [ "$status" -eq 6 ]
  b_err="$stderr"
  run --separate-stderr bash "$SCRIPT" "$ID" <&-
  [ "$status" -eq 6 ]
  [ "$stderr" = "$b_err" ]
}

@test "the script has no read builtin, no terminal device and no prompt" {
  code="$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)"
  run grep -nw 'read' <<< "$code"
  [ "$status" -eq 1 ]
  run grep -nE '/dev/tty|/dev/stdin|[[:space:]]select[[:space:]]|stty|tty -s|<&0|\[ -t ' <<< "$code"
  [ "$status" -eq 1 ]
}

@test "every composed script is run with stdin from /dev/null" {
  grep -q 'bash "\$SETTINGS" opted-in </dev/null' "$SCRIPT"
  grep -q 'bash "\$STORE" get "\$ID" </dev/null' "$SCRIPT"
  grep -q 'bash "\$STORE" get "\$ID" --field source </dev/null' "$SCRIPT"
  grep -q 'bash "\$APPLY" "\$ID" </dev/null' "$SCRIPT"
  grep -q 'bash "\$STORE" "\${FARGS\[@\]}" </dev/null' "$SCRIPT"
}

@test "no EST fallback and no placeholder: the script holds no fallback literal" {
  run grep -nE 'NOREF|UNKNOWN|N/A|commit-template' "$SCRIPT"
  [ "$status" -eq 1 ]
}

# --- a task worktree -------------------------------------------------------------------------------------------

@test "from a linked worktree, --root and JENGA_PROJECT_ROOT reach the main tree's captured candidate and store" {
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
  [ ! -e "$LINKED/project/queue/commit-refs/$ID.json" ]
  run --separate-stderr env -u JENGA_PROJECT_ROOT bash "$SCRIPT" --root "$PROJ" "$ID"
  [ "$status" -eq 0 ]
  [ "$output" = "commit_ref=ZZZ-9"$'\n'"source=branch" ]
  [ -f "$STORE_FILE" ]
  [ ! -e "$LINKED/project/queue/commit-refs/$ID.json" ]
}

@test "a second call from the worktree and one from the main tree return the same frozen ref" {
  board "" "" ""
  capture ZZZ-9
  LINKED="$BATS_TEST_TMPDIR/linked"
  git -C "$WORK" worktree add -q "$LINKED" -b linked-branch
  cd "$LINKED" || return 1
  run --separate-stderr env JENGA_PROJECT_ROOT="$PROJ" bash "$SCRIPT" "$ID"
  [ "$status" -eq 0 ]
  first="$output"
  run --separate-stderr env JENGA_PROJECT_ROOT="$PROJ" bash "$SCRIPT" "$ID"
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  cd "$WORK" || return 1
  prep
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
}

@test "outside a linked worktree, or with a root given, the worktree note is not printed" {
  board "" "" ""
  prep
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

@test "usage errors are exit 2 with an empty stdout and nothing created" {
  before="$(tree_sum)"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SCRIPT" "not-a-task-id"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" "E79_S04_T10; touch $CANARY"
  [ "$status" -eq 2 ]
  [ ! -e "$CANARY" ]
  run --separate-stderr bash "$SCRIPT" "$ID" "E79_S04_T11"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" --bogus "$ID"
  [ "$status" -eq 2 ]
  prep --on-conflict
  [ "$status" -eq 2 ]
  prep --on-conflict ignore
  [ "$status" -eq 2 ]
  prep --on-conflict warn --on-conflict fail
  [ "$status" -eq 2 ]
  prep --root
  [ "$status" -eq 2 ]
  prep --root "$BATS_TEST_TMPDIR/no-such-dir"
  [ "$status" -eq 2 ]
  prep --conventions
  [ "$status" -eq 2 ]
  [ "$(tree_sum)" = "$before" ]
}

@test "--help prints the usage on stdout with the exit codes and exits 0" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage:"
  assert_contains "$output" "--on-conflict warn|fail"
  assert_contains "$output" "8 disagreement under --on-conflict fail"
  assert_contains "$output" "--root <main working tree>"
  [ -z "$stderr" ]
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

@test "the script reuses the three composed scripts rather than re-implementing them" {
  grep -q 'commit-settings.sh' "$SCRIPT"
  grep -q 'task-commit-ref.sh' "$SCRIPT"
  grep -q 'apply-ref-policy.sh' "$SCRIPT"
  # the chain and the validator are reached only through the composed scripts: no direct call outside comments
  code="$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)"
  run grep -nE 'resolve-commit-ref|(^|[^-])commit-ref\.sh|jq ' <<< "$code"
  [ "$status" -eq 1 ]
}

@test "apply-ref-policy is not asked for --on-conflict: the disagreement policy is applied here, on its conflict= lines" {
  code="$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)"
  run grep -nE 'APPLY.*--on-conflict|--on-conflict.*APPLY' <<< "$code"
  [ "$status" -eq 1 ]
}

@test "the header documents every exit code, and the two new ones are marked NEW" {
  local n
  for n in 0 2 3 4 5 6 7 8 9; do
    grep -qE "^#   $n   " "$SCRIPT"
  done
  grep -q '^#   9   NEW:' "$SCRIPT"
  grep -q '^#   8   NEW:' "$SCRIPT"
}

@test "project-conventions.md documents the entry point, its exit-code table and the scripts-index row" {
  grep -q 'prepare-task-commit-ref.sh' "$DOC"
  grep -qE '^\| 8 \| .*--on-conflict fail' "$DOC"
  grep -qE '^\| 9 \| ' "$DOC"
  grep -qE '^\| `scripts/prepare-task-commit-ref.sh` \|' "$DOC"
}
