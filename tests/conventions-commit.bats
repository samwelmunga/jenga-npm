#!/usr/bin/env bats
#
# Coverage for E69_S05_T04: skills/j-commit applies the project's commit-format convention to NON-board commits only.
#
# Two halves. Structural: skills/j-commit/SKILL.md carries the board/non-board split, keeps the three EST patterns
# unchanged, calls the digest with --agent commit and says an empty digest changes nothing. Behavioural:
# skills/j-commit/scripts/commit-subject-check.sh classifies a subject and checks it against the recorded convention,
# and a hostile convention (one that would reject EST subjects) cannot affect a board subject. The data-level half of
# the EST proof (digest EST line, generated checklist text) is in tests/conventions-digest.bats.
#
# Scratch projects under $BATS_TEST_TMPDIR via JENGA_PROJECT_ROOT; nothing here touches this repo's project/configs/.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL="$REPO_ROOT/skills/j-commit/SKILL.md"
CHECK="$REPO_ROOT/skills/j-commit/scripts/commit-subject-check.sh"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  CONV="$CFG/conventions.json"
  mkdir -p "$CFG"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# section <heading>: the skill text from the heading up to the next "## " heading.
section() {
  awk -v h="$1" '$0 == h { on = 1; print; next } on && /^## / { exit } on { print }' "$SKILL"
}

write_conv() {
  printf '%s\n' "{\"conventions_version\":1,\"categories\":{\"commit-format\":{\"source\":\"custom\",\"summary\":\"s\",\"values\":$1}}}" > "$CONV"
}

check() { run --separate-stderr bash "$CHECK" "$@"; }

# --- the skill text --------------------------------------------------------------------------------------------

@test "SKILL.md has the Project commit-format convention section with the board / non-board split" {
  sec="$(section "## Project commit-format convention")"
  [ -n "$sec" ]
  assert_contains "$sec" "board commit"
  assert_contains "$sec" "non-board commit"
  assert_contains "$sec" "**Board commits: EST naming exactly as written above, unchanged and mandatory.**"
  assert_contains "$sec" "never changes it"
}

@test "SKILL.md applies the convention to non-board commits via the digest with --agent commit" {
  sec="$(section "## Project commit-format convention")"
  assert_contains "$sec" "scripts/conventions-digest.sh --agent commit"
  assert_contains "$sec" "node_modules/@jenga-ai/agent/scripts/conventions-digest.sh"
  assert_contains "$sec" "commit-subject-check.sh"
  assert_contains "$sec" "It shapes the message of **non-board** commits only"
}

@test "SKILL.md states an empty digest leaves the skill's behaviour unchanged" {
  sec="$(section "## Project commit-format convention")"
  assert_contains "$sec" "Empty digest: behave exactly as before."
  assert_contains "$sec" "prints nothing"
  assert_contains "$sec" "the pre-commit gate behave exactly as they did before"
}

@test "SKILL.md keeps all three EST patterns unchanged" {
  run grep -c 'task(<E##_S##_T##>): <short description of what was done>' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -c '`epic(<Epic Title>): <MAX_50_CHAR_SUMMARY>`' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -c '`story(<Epic Title>_<Story Title>): <MAX_50_CHAR_SUMMARY>`' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "the inline-mode steps still produce task(<E##_S##_T##>): and say inline commits are board commits" {
  inline="$(awk '/^## Inline Mode/ { on = 1; next } on && /^## / { exit } on { print }' "$SKILL")"
  assert_contains "$inline" 'task(<E##_S##_T##>): <short description of what was done>'
  assert_contains "$inline" "An inline commit is always a board commit"
  assert_contains "$inline" "never applies here"
}

@test "SKILL.md leaves the Pre-commit gate section intact and does not edit the gate for the convention" {
  gate="$(section "## Pre-commit gate")"
  assert_contains "$gate" "checklist.sh check pre-commit --run"
  assert_contains "$gate" "**Mark the situation.**"
  assert_not_contains "$gate" "conventions-digest"
  assert_not_contains "$gate" "commit-subject-check"
}

@test "the skill text does not name .claude/ or .agents/ as an edit target for the convention" {
  sec="$(section "## Project commit-format convention")"
  assert_not_contains "$sec" ".claude/"
  assert_not_contains "$sec" ".agents/"
}

# --- commit-subject-check.sh: classification -------------------------------------------------------------------

@test "board subjects are classified as board and exit 0 without consulting the convention" {
  write_conv '{"style":"x","message_regex":"^(feat|fix): [a-z]"}'
  for s in "task(E01_S01_T01): x" "story(Epic Title_Story Title): y" "epic(Epic Title): z" "chore(E69_S05_T01): tester verification" "merge: E69_S04 into main"; do
    check "$s"
    [ "$status" -eq 0 ]
    assert_starts_with "$output" "kind=board;"
  done
}

@test "board ids inside a multi-id, suffixed or merge subject are still classified as board" {
  write_conv '{"style":"x","message_regex":"^(feat|fix): [a-z]"}'
  for s in "chore(E53_S13_T02,E53_S13_T03): add rapport" "chore(E69_S05/S06): x" "chore(E17_S08_T04+T05): x" "docs(E69_S05_T05-plan): x" "Merge branch 'E28_S18_T01-diagnose'" "merge: main into E67_S04_T02-x" 'Revert "task(E69_S05_T01): x"'; do
    check "$s"
    [ "$status" -eq 0 ]
    assert_starts_with "$output" "kind=board;"
  done
}

@test "a letter or digit next to E<digits> is not a board id token (E2E, EC2, V2E5)" {
  write_conv '{"style":"x","message_regex":"^(feat|fix): [a-z]"}'
  for s in "chore(E2E tests): x" "docs(EC2 setup): x" "merge: E2E suite into main" "chore(V2E5): x"; do
    check "$s"
    [ "$status" -eq 1 ]
    assert_starts_with "$output" "kind=non-board;"
  done
}

@test "a non-board subject is classified as non-board" {
  check "docs: tidy the readme"
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "kind=non-board;"
}

# --- commit-subject-check.sh: the convention -------------------------------------------------------------------

@test "EST proof: a hostile convention rejects a non-board subject but never a board subject" {
  write_conv '{"style":"no prefixes","message_regex":"^(feat|fix): [a-z]"}'
  # the regex really would reject an EST subject if it were applied
  run bash -c 'printf "%s\n" "task(E01_S01_T01): x" | grep -Eq "^(feat|fix): [a-z]"'
  [ "$status" -ne 0 ]
  # ... and the check never applies it to a board subject
  check "task(E01_S01_T01): x"
  [ "$status" -eq 0 ]
  assert_contains "$output" "convention is not applied"
  # a non-board subject that violates it is reported
  check "docs: x"
  [ "$status" -eq 1 ]
  assert_contains "$output" "does not match the recorded message_regex"
  # a conforming non-board subject passes
  check "feat: add a thing"
  [ "$status" -eq 0 ]
  assert_contains "$output" "conforms"
}

@test "subject_max_length is enforced for non-board subjects only" {
  write_conv '{"style":"short","subject_max_length":20}'
  check "docs: this subject is far too long"
  [ "$status" -eq 1 ]
  assert_contains "$output" "over the recorded subject_max_length of 20"
  check "task(E01_S01_T01): this subject is far too long but is a board commit"
  [ "$status" -eq 0 ]
  check "docs: short"
  [ "$status" -eq 0 ]
}

@test "no conventions.json means no convention: exit 0 (behaviour unchanged)" {
  [ ! -e "$CONV" ]
  check "anything goes"
  [ "$status" -eq 0 ]
  assert_contains "$output" "no commit-format convention recorded"
}

@test "a recorded style with nothing machine-checkable exits 0" {
  write_conv '{"style":"imperative"}'
  check "Add a thing"
  [ "$status" -eq 0 ]
  assert_contains "$output" "nothing machine-checkable"
}

@test "an invalid conventions file never blocks a commit: exit 0 with a note on stderr" {
  printf '{"conventions_version":1,"categories":{"commit-format":{"source":"custom","summary":"s","values":{"style":"x","message_regex":"^feat"},"strength":"block"}}}\n' > "$CONV"
  check "docs: x"
  [ "$status" -eq 0 ]
  assert_contains "$stderr" "invalid"
}

@test "an unusable regex is not applied (exit 0, note on stderr)" {
  write_conv '{"style":"x","message_regex":"(unclosed"}'
  check "docs: x"
  [ "$status" -eq 0 ]
  assert_contains "$stderr" "not a valid extended regular expression"
}

@test "usage errors exit 2" {
  run --separate-stderr bash "$CHECK"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$CHECK" --bogus x
  [ "$status" -eq 2 ]
}

@test "the check script writes no file" {
  write_conv '{"style":"x","message_regex":"^feat"}'
  before="$(find "$PROJ" -type f -exec cksum {} + | sort | cksum)"
  check "docs: x"
  after="$(find "$PROJ" -type f -exec cksum {} + | sort | cksum)"
  [ "$before" = "$after" ]
}
