#!/usr/bin/env bats
#
# E79_S04_T07: scripts/resolve-commit-ref.sh detects disagreeing ref sources and applies a documented policy.
#
# T06 already warns on stderr and continues with the precedence winner; this task makes that a policy
# (--on-conflict warn|fail, default warn held in ONE named constant), returns the disagreement as conflict=<level>:<key>
# lines on stdout (so scripts/task-commit-ref.sh freeze --conflict can record it), and treats several different Jira entries on
# one level as a conflict at that level. Epic E79 decisions pinned here:
#   - decision 7: a key identifies one imported board item and a story or epic key is inherited by the tasks beneath it, so an
#     INHERITED key is never a conflict (several tasks sharing one key is normal); only two levels linked separately that carry
#     DIFFERENT keys disagree;
#   - decision 8: precedence task, story, epic, branch; on disagreement `warn` (continue with the winner, exit 0) is the default
#     and `fail` (exit 7 here, no winner) is the optional extra. The task text said exit 5 for fail; 5 already means
#     "dependency unavailable" in T06, so the orchestrator chose the distinct code 7 (recorded in the summary and a rapport).
#
# What this pins (one named case per acceptance criterion, plus the contract around them):
#   - task ASD-001 versus story ASD-002: winner ASD-001 (source=task), ONE warning naming both levels and keys,
#     conflict=story:ASD-002 on stdout, exit 0;
#   - task versus branch, story versus branch (no task key), epic versus branch (no task or story key), task versus epic: one
#     case each with the documented outcome;
#   - two Jira entries on the same task are a conflict at the task level (and so are two on a lower level);
#   - every level agreeing, or an inherited key, prints no warning and no conflict= line, and the stdout is byte-for-byte what T06
#     printed;
#   - --on-conflict fail: exit 7 on ANY disagreement, no ref= and no source= line, every disagreeing level and key named on
#     stdout and stderr; with no disagreement it behaves exactly as warn; an unresolved run is still exit 1;
#   - the default policy is the single constant DEFAULT_ON_CONFLICT: a copy of the script with only that constant changed flips the
#     default, and the code holds no other place that decides the policy;
#   - the warning is emitted once per invocation, however many levels disagree;
#   - the conflict= lines are ready values for `task-commit-ref.sh freeze --conflict`;
#   - the legacy shapes stay stable: existing stdout lines come first, conflict= lines are appended last; a not-opted-in project is
#     still exit 10 with an empty stdout, whatever --on-conflict says; nothing is ever written;
#   - none of the schema, the validator or the legacy goldens is part of this change; bash -n; no dynamic execution.
#
# The script is always run as `bash <script>`, so these cases do not depend on the file's executable bit. Everything the cases
# create lives under $BATS_TEST_TMPDIR. These cases were written without being executed by their author; the tester runs them.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/resolve-commit-ref.sh"
STORE_SCRIPT="$REPO_ROOT/scripts/task-commit-ref.sh"
REAL_CONFIGS="$REPO_ROOT/project/configs"

ID="E79_S04_T07"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  unset JENGA_CONVENTIONS_SCHEMA JENGA_COMMIT_REF_EXTRACT_SCRIPT
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  CONV="$CFG/conventions.json"
  BOARD="$PROJ/project/board"
  WORK="$BATS_TEST_TMPDIR/work"
  TASK_STORY="E79_S04"
  TASK_EPIC="E79"
  mkdir -p "$CFG" "$BOARD/tasks" "$BOARD/stories" "$BOARD/epics" "$WORK"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  cd "$WORK" || return 1
  git init -q . >/dev/null 2>&1
  git symbolic-ref HEAD refs/heads/E79_S04_T07-add-x
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

tree_sum() {
  {
    find "$PROJ" -print | sort
    find "$PROJ" -type f -exec cksum {} + | sort
    find "$WORK" -print | sort
    find "$WORK" -type f -exec cksum {} + | sort
  } | cksum
}

# count_lines <haystack> <needle>: how many lines of the haystack contain the needle.
count_lines() {
  local n=0 line
  while IFS= read -r line; do
    case "$line" in *"$2"*) n=$((n + 1)) ;; esac
  done <<EOF_COUNT
$1
EOF_COUNT
  printf '%s' "$n"
}

# conflict_lines <output>: only the conflict= lines of the output.
conflict_lines() {
  printf '%s\n' "$1" | grep '^conflict=' || true
}

# --- the acceptance criteria -----------------------------------------------------------------------------------

@test "task key versus story key: the task wins, one warning names both, and conflict=story:ASD-002 is printed" {
  board ASD-001 ASD-002 ""
  rcr
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-001"$'\n'"source=task"$'\n'"tried="
  assert_contains "$stderr" "warning: the sources disagree (task=ASD-001, story=ASD-002); continuing with ASD-001 from task"
  [ "$(count_lines "$stderr" "warning:")" -eq 1 ]
  [ "$(conflict_lines "$output")" = "conflict=story:ASD-002" ]
}

@test "task key versus a different captured branch candidate: the task wins and conflict=branch is printed" {
  board ASD-001 "" ""
  capture ZZZ-9
  rcr
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-001"$'\n'"source=task"$'\n'
  assert_contains "$stderr" "task=ASD-001, branch=ZZZ-9"
  [ "$(conflict_lines "$output")" = "conflict=branch:ZZZ-9" ]
}

@test "story key versus a different branch candidate (no task key): the story wins and conflict=branch is printed" {
  board "" ASD-002 ""
  capture ZZZ-9
  rcr
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-002"$'\n'"source=story"$'\n'
  assert_contains "$stderr" "story=ASD-002, branch=ZZZ-9); continuing with ASD-002 from story"
  [ "$(conflict_lines "$output")" = "conflict=branch:ZZZ-9" ]
}

@test "epic key versus a different branch candidate (no task or story key): the epic wins and conflict=branch is printed" {
  board "" "" ASD-003
  capture ZZZ-9
  rcr
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-003"$'\n'"source=epic"$'\n'
  assert_contains "$stderr" "epic=ASD-003, branch=ZZZ-9); continuing with ASD-003 from epic"
  [ "$(conflict_lines "$output")" = "conflict=branch:ZZZ-9" ]
}

@test "decision 7: a task key against a different epic key is reported but, under warn, never an error" {
  board ASD-001 "" ASD-003
  rcr
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-001"$'\n'"source=task"$'\n'
  assert_contains "$stderr" "task=ASD-001, epic=ASD-003"
  [ "$(conflict_lines "$output")" = "conflict=epic:ASD-003" ]
}

@test "decision 7: the story key a task inherits is not a conflict (no task key of its own, story and epic carry the same key)" {
  board "" ASD-002 ASD-002
  capture ASD-002
  rcr
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-002"$'\n'"source=story"$'\n'
  [ -z "$stderr" ]
  [ -z "$(conflict_lines "$output")" ]
}

@test "decision 7: several tasks may share one key; a task repeating its story's key is no conflict" {
  board ASD-002 ASD-002 ""
  rcr
  [ "$status" -eq 0 ]
  assert_not_contains "$stderr" "disagree"
  [ -z "$(conflict_lines "$output")" ]
}

@test "two Jira entries on the same task are reported as a conflict at the task level" {
  write_item "$BOARD/tasks" "$ID" ASD-001 ASD-009
  rcr
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-001"$'\n'"source=task"$'\n'
  assert_contains "$stderr" "task=ASD-001, task=ASD-009); continuing with ASD-001 from task"
  [ "$(conflict_lines "$output")" = "conflict=task:ASD-009" ]
}

@test "two different Jira entries on the story are a conflict at the story level even when one equals the task's key" {
  write_item "$BOARD/tasks" "$ID" ASD-001
  write_item "$BOARD/stories" "E79_S04" ASD-001 ASD-002
  rcr
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-001"$'\n'"source=task"$'\n'
  [ "$(conflict_lines "$output")" = "conflict=story:ASD-002" ]
}

@test "the same Jira key listed twice on one item is no conflict" {
  write_item "$BOARD/tasks" "$ID" ASD-001 ASD-001
  rcr
  [ "$status" -eq 0 ]
  [ -z "$(conflict_lines "$output")" ]
  assert_not_contains "$stderr" "warning:"
}

@test "all levels agreeing on one key prints no warning and no conflict= line, and the stdout is exactly T06's" {
  board ASD-001 ASD-001 ASD-001
  capture ASD-001
  rcr
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "ref=ASD-001"$'\n'"source=task"$'\n'"tried=task,story,epic,branch"$'\n'"candidate.task=ASD-001"$'\n'"candidate.story=ASD-001"$'\n'"candidate.epic=ASD-001"$'\n'"candidate.branch=ASD-001" ]
}

@test "all four levels disagreeing: the task wins, one warning, one conflict line per losing level in the fixed order" {
  board ASD-001 ASD-002 ASD-003
  capture ZZZ-9
  rcr
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-001"$'\n'"source=task"$'\n'
  [ "$(count_lines "$stderr" "warning:")" -eq 1 ]
  [ "$(conflict_lines "$output")" = $'conflict=story:ASD-002\nconflict=epic:ASD-003\nconflict=branch:ZZZ-9' ]
}

@test "the warning is emitted once per invocation, not once per candidate or per level pair" {
  write_item "$BOARD/tasks" "$ID" ASD-001 ASD-009
  write_item "$BOARD/stories" "E79_S04" ASD-002 ASD-008
  write_item "$BOARD/epics" "E79" ASD-003
  capture ZZZ-9
  rcr
  [ "$status" -eq 0 ]
  [ "$(count_lines "$stderr" "warning:")" -eq 1 ]
  [ "$(count_lines "$stderr" "disagree")" -eq 1 ]
}

@test "conflict= lines come after every line T06 already printed" {
  board ASD-001 ASD-002 ASD-003
  capture ZZZ-9
  rcr
  [ "$status" -eq 0 ]
  last_candidate=0
  first_conflict=0
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    case "$line" in
      candidate.*) last_candidate=$n ;;
      conflict=*) [ "$first_conflict" -ne 0 ] || first_conflict=$n ;;
    esac
  done <<EOF_OUT
$output
EOF_OUT
  [ "$last_candidate" -gt 0 ]
  [ "$first_conflict" -gt "$last_candidate" ]
}

@test "the conflict= lines are ready values for task-commit-ref.sh freeze --conflict" {
  board ASD-001 ASD-002 ASD-003
  rcr
  [ "$status" -eq 0 ]
  args=()
  while IFS= read -r line; do
    case "$line" in conflict=*) args[${#args[@]}]="--conflict"; args[${#args[@]}]="${line#conflict=}" ;; esac
  done <<EOF_OUT
$output
EOF_OUT
  [ "${#args[@]}" -eq 4 ]
  run --separate-stderr bash "$STORE_SCRIPT" freeze "$ID" --ref ASD-001 --source task "${args[@]}"
  [ "$status" -eq 0 ]
  stored="$(grep -rl 'story:ASD-002' "$PROJ" || true)"
  [ -n "$stored" ]
  run jq -r '.conflicts | join(",")' "$stored"
  [ "$status" -eq 0 ]
  [ "$output" = "story:ASD-002,epic:ASD-003" ]
}

# --- --on-conflict fail ----------------------------------------------------------------------------------------

@test "--on-conflict fail: any disagreement is exit 7 with no winner, naming every disagreeing level and key" {
  board ASD-001 ASD-002 ""
  rcr --on-conflict fail
  [ "$status" -eq 7 ]
  assert_not_contains "$output" "ref="
  assert_not_contains "$output" "source="
  assert_contains "$output" "tried=task,story,epic,branch"
  [ "$(conflict_lines "$output")" = $'conflict=task:ASD-001\nconflict=story:ASD-002' ]
  assert_contains "$stderr" "task=ASD-001, story=ASD-002"
  assert_contains "$stderr" "--on-conflict fail chose no ref"
}

@test "--on-conflict fail: exit 7 is distinct from the dependency-unavailable exit 5" {
  board ASD-001 ASD-002 ""
  rcr --on-conflict fail
  [ "$status" -ne 5 ]
  [ "$status" -eq 7 ]
  run grep -n -- '^#   7 ' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "--on-conflict fail: task versus epic, and task versus the branch candidate, are exit 7 too" {
  board ASD-001 "" ASD-003
  rcr --on-conflict fail
  [ "$status" -eq 7 ]
  board ASD-001 "" ""
  capture ZZZ-9
  rcr --on-conflict fail
  [ "$status" -eq 7 ]
  [ "$(conflict_lines "$output")" = $'conflict=task:ASD-001\nconflict=branch:ZZZ-9' ]
}

@test "--on-conflict fail: two Jira entries on one task are exit 7 naming both keys at the task level" {
  write_item "$BOARD/tasks" "$ID" ASD-001 ASD-009
  rcr --on-conflict fail
  [ "$status" -eq 7 ]
  [ "$(conflict_lines "$output")" = $'conflict=task:ASD-001\nconflict=task:ASD-009' ]
}

@test "--on-conflict fail with no disagreement behaves exactly as warn" {
  board ASD-001 ASD-001 ""
  capture ASD-001
  rcr
  warn_status="$status"; warn_out="$output"; warn_err="$stderr"
  rcr --on-conflict fail
  [ "$status" -eq "$warn_status" ]
  [ "$status" -eq 0 ]
  [ "$output" = "$warn_out" ]
  [ "$stderr" = "$warn_err" ]
}

@test "--on-conflict warn given explicitly is the same as the default" {
  board ASD-001 ASD-002 ASD-003
  rcr
  default_status="$status"; default_out="$output"; default_err="$stderr"
  rcr --on-conflict warn
  [ "$status" -eq "$default_status" ]
  [ "$output" = "$default_out" ]
  [ "$stderr" = "$default_err" ]
}

@test "--on-conflict fail does not change an unresolved run: still exit 1 with only tried=" {
  rcr --on-conflict fail
  [ "$status" -eq 1 ]
  [ "$output" = "tried=task,story,epic,branch" ]
}

@test "an inherited key (decision 7) is no conflict even under --on-conflict fail" {
  board "" ASD-002 ASD-002
  rcr --on-conflict fail
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-002"$'\n'"source=story"$'\n'
  [ -z "$stderr" ]
}

# --- the default is one named constant ------------------------------------------------------------------------

@test "the default policy is set in exactly one place: the constant DEFAULT_ON_CONFLICT, set to warn" {
  run grep -c '^DEFAULT_ON_CONFLICT="warn"$' "$SCRIPT"
  [ "$output" = "1" ]
  code="$(grep -vE '^[[:space:]]*#' "$SCRIPT" || true)"
  [ "$(count_lines "$code" 'DEFAULT_ON_CONFLICT=')" -eq 1 ]
  # POLICY is initialised from the constant and otherwise only set from the flag
  [ "$(count_lines "$code" 'POLICY="$DEFAULT_ON_CONFLICT"')" -eq 1 ]
  [ "$(count_lines "$code" 'POLICY="$2"')" -eq 1 ]
  # the policy is read in one place only
  [ "$(count_lines "$code" 'case "$POLICY" in')" -eq 1 ]
}

@test "changing only that constant changes the default behaviour" {
  board ASD-001 ASD-002 ""
  copy="$BATS_TEST_TMPDIR/resolve-commit-ref-fail-default.sh"
  # only two lines differ from the original: the constant, and the sibling directory (the copy lives outside scripts/)
  sed -e 's/^DEFAULT_ON_CONFLICT="warn"$/DEFAULT_ON_CONFLICT="fail"/' \
      -e "s|^here=.*\$|here=\"$REPO_ROOT/scripts\"|" "$SCRIPT" > "$copy"
  run diff "$SCRIPT" "$copy"
  [ "$(printf '%s\n' "$output" | grep -c '^>')" -eq 2 ]
  run --separate-stderr bash "$copy" "$ID"
  [ "$status" -eq 7 ]
  assert_not_contains "$output" "ref="
  # the flag still overrides the constant
  run --separate-stderr bash "$copy" "$ID" --on-conflict warn
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "ref=ASD-001"
  # and the real script keeps its documented default
  rcr
  [ "$status" -eq 0 ]
}

# --- the flag ---------------------------------------------------------------------------------------------------

@test "--on-conflict accepts only warn or fail, once, with a value: anything else is usage error 2" {
  before="$(tree_sum)"
  rcr --on-conflict
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  rcr --on-conflict bogus
  [ "$status" -eq 2 ]
  rcr --on-conflict WARN
  [ "$status" -eq 2 ]
  rcr --on-conflict ""
  [ "$status" -eq 2 ]
  rcr --on-conflict warn --on-conflict fail
  [ "$status" -eq 2 ]
  [ "$(tree_sum)" = "$before" ]
}

@test "--on-conflict works together with --conventions" {
  board ASD-001 ASD-002 ""
  write_conv '.'
  run --separate-stderr bash "$SCRIPT" "$ID" --conventions "$CONV" --on-conflict fail
  [ "$status" -eq 7 ]
}

@test "a project that is not opted in is still exit 10 with an empty stdout, whatever --on-conflict says" {
  rm -f "$CONV"
  board ASD-001 ASD-002 ""
  rcr --on-conflict fail
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  rcr --on-conflict warn
  [ "$status" -eq 10 ]
  [ -z "$output" ]
}

@test "--help documents the flag and exit code 7" {
  run --separate-stderr bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "--on-conflict warn|fail"
  assert_contains "$output" "7 disagreement under --on-conflict fail"
  assert_contains "$output" "10 not applicable"
}

# --- nothing is written ----------------------------------------------------------------------------------------

@test "a disagreement run changes no file in the project or the repository, under either policy" {
  board ASD-001 ASD-002 ASD-003
  capture ZZZ-9
  before="$(tree_sum)"
  rcr
  [ "$status" -eq 0 ]
  rcr --on-conflict fail
  [ "$status" -eq 7 ]
  [ "$(tree_sum)" = "$before" ]
}

@test "hostile keys never run anything: the conflict lines carry only values that passed the gate" {
  canary="$BATS_TEST_TMPDIR/canary"
  write_item "$BOARD/tasks" "$ID" ASD-001
  write_item "$BOARD/stories" "E79_S04" 'ASD-2$(touch '"$canary"')'
  rcr
  [ "$status" -eq 0 ]
  [ ! -e "$canary" ]
  [ -z "$(conflict_lines "$output")" ]
}

# --- static properties -----------------------------------------------------------------------------------------

@test "bash -n passes" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the script still has no dynamic execution, no sourcing, no shell-string invocation and no bash 4 feature" {
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

@test "no schema, validator, golden or sibling-task wrapper file is part of this change" {
  # the files this task must not touch are unchanged relative to the commit this branch started from
  run git -C "$REPO_ROOT" rev-parse --is-inside-work-tree
  [ "$status" -eq 0 ]
  base="$(git -C "$REPO_ROOT" merge-base HEAD main 2>/dev/null || true)"
  [ -n "$base" ] || skip "no main branch to compare against"
  run git -C "$REPO_ROOT" diff --name-only "$base" -- \
    templates/conventions-schema.json scripts/validate-conventions.sh tests/fixtures/conventions-legacy-golden scripts/apply-ref-policy.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
