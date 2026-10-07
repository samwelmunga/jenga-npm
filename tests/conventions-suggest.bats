#!/usr/bin/env bats
#
# Coverage for E69_S05_T06: the non-blocking "run j.conventions" suggestion at the end of j.init and
# `j.uncharted onboard`.
#
# Contract under test: scripts/conventions-suggest.sh's own header comment (prints one tip line only when
# "<configs>/conventions.json" does not exist, ALWAYS exits 0, writes nothing) and the skill text of
# skills/j-init/SKILL.md (step 5) and skills/j-uncharted/SKILL.md (the end of the onboard mode only).
#
# Every behavioural test builds a scratch project under $BATS_TEST_TMPDIR and aims the script at it with
# JENGA_PROJECT_ROOT. Nothing here touches this repository's project/configs/; teardown proves it by checksum.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SUGGEST="$REPO_ROOT/scripts/conventions-suggest.sh"
INIT_SKILL="$REPO_ROOT/skills/j-init/SKILL.md"
UNCHARTED_SKILL="$REPO_ROOT/skills/j-uncharted/SKILL.md"
REAL_CONFIGS="$REPO_ROOT/project/configs"
TIP="Tip: run j.conventions"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  PROJ="$BATS_TEST_TMPDIR/proj"
  CFG="$PROJ/project/configs"
  mkdir -p "$CFG"
  printf '{}\n' > "$CFG/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
}

teardown() {
  chmod -R u+rwx "$PROJ" 2>/dev/null || true
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

suggest() { run --separate-stderr bash "$SUGGEST"; }

# section_between <file> <start-heading-regex> <end-heading-regex>
section_between() {
  awk -v s="$2" -v e="$3" '
    $0 ~ s && !on { on = 1; print; next }
    on && $0 ~ e { exit }
    on { print }
  ' "$1"
}

# --- the script ------------------------------------------------------------------------------------------------

@test "no conventions.json prints the tip and exits 0" {
  [ ! -e "$CFG/conventions.json" ]
  suggest
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "$TIP"
  assert_contains "$output" "(commit format, naming, formatting, ...)"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a recorded conventions.json prints nothing and exits 0" {
  printf '{"conventions_version":1,"categories":{}}\n' > "$CFG/conventions.json"
  suggest
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a garbled conventions.json still prints nothing and exits 0 (the file exists; validating it is not this script's job)" {
  printf '{not json at all\n' > "$CFG/conventions.json"
  suggest
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a conventions.json that is a directory exits 0" {
  mkdir "$CFG/conventions.json"
  suggest
  [ "$status" -eq 0 ]
}

@test "an unresolvable configs path (a root with no workflow.json registry) exits 0 and prints nothing" {
  export JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/no-such-root"
  suggest
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a missing resolver exits 0 and prints nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/lonely"
  cp "$SUGGEST" "$BATS_TEST_TMPDIR/lonely/conventions-suggest.sh"
  run --separate-stderr bash "$BATS_TEST_TMPDIR/lonely/conventions-suggest.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unreadable configs directory exits 0" {
  chmod 000 "$CFG"
  suggest
  [ "$status" -eq 0 ]
  chmod 755 "$CFG"
}

@test "a malformed workflow.json (registry unreadable as JSON) exits 0" {
  printf '{broken\n' > "$CFG/workflow.json"
  suggest
  [ "$status" -eq 0 ]
}

@test "an unwritable project tree exits 0 (the script never needs to write)" {
  chmod -R a-w "$PROJ"
  suggest
  [ "$status" -eq 0 ]
  chmod -R u+w "$PROJ"
}

@test "the script writes no file" {
  before="$(find "$PROJ" -type f -exec cksum {} + | sort | cksum)"
  suggest
  after="$(find "$PROJ" -type f -exec cksum {} + | sort | cksum)"
  [ "$before" = "$after" ]
  [ "$(find "$PROJ" -type f | wc -l | tr -d ' ')" -eq 1 ]
}

@test "it never exits non-zero even when the resolver itself fails" {
  mkdir -p "$BATS_TEST_TMPDIR/fake/scripts"
  cp "$SUGGEST" "$BATS_TEST_TMPDIR/fake/scripts/conventions-suggest.sh"
  printf '#!/usr/bin/env bash\nexit 9\n' > "$BATS_TEST_TMPDIR/fake/scripts/resolve-root.sh"
  run --separate-stderr bash "$BATS_TEST_TMPDIR/fake/scripts/conventions-suggest.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- the skill text --------------------------------------------------------------------------------------------

@test "j-init: step 5 runs the script as a final non-blocking line" {
  step5="$(section_between "$INIT_SKILL" '^### 5\. Prompt next step' '^### [0-9]')"
  [ -n "$step5" ]
  assert_contains "$step5" "scripts/conventions-suggest.sh"
  assert_contains "$step5" "node_modules/@jenga-ai/agent/scripts/conventions-suggest.sh"
  assert_contains "$step5" "non-blocking suggestion, not a question"
  assert_contains "$step5" "do not wait for an answer"
  assert_contains "$step5" "never changes this skill's flow or exit status"
  assert_contains "$step5" "As the very last line"
}

@test "j-init: the suggestion appears only in step 5" {
  [ "$(grep -c 'conventions-suggest.sh' "$INIT_SKILL")" -ge 1 ]
  before5="$(awk '/^### 5\. Prompt next step/ { exit } { print }' "$INIT_SKILL")"
  assert_not_contains "$before5" "conventions-suggest"
}

@test "j-uncharted: the onboard mode ends with the non-blocking suggestion" {
  onboard="$(section_between "$UNCHARTED_SKILL" '^### `onboard`' '^### `refresh`')"
  [ -n "$onboard" ]
  assert_contains "$onboard" "#### Closing suggestion"
  assert_contains "$onboard" "scripts/conventions-suggest.sh"
  assert_contains "$onboard" "non-blocking suggestion, not a question"
  assert_contains "$onboard" "must not interrupt"
  assert_contains "$onboard" "conversational flow"
  assert_contains "$onboard" "convergence or exit status"
  assert_contains "$onboard" "both"
  # it is the LAST subsection of onboard, after the PROJECT_SUMMARY.md step
  last_heading="$(printf '%s\n' "$onboard" | grep '^#### ' | tail -n 1)"
  assert_contains "$last_heading" "Closing suggestion"
}

@test "j-uncharted: segment, import and refresh are untouched by the suggestion" {
  segment="$(section_between "$UNCHARTED_SKILL" '^### `segment`' '^### `import`')"
  import="$(section_between "$UNCHARTED_SKILL" '^### `import`' '^### `onboard`')"
  refresh="$(section_between "$UNCHARTED_SKILL" '^### `refresh`' '^## Constraints')"
  [ -n "$segment" ]
  [ -n "$import" ]
  [ -n "$refresh" ]
  assert_not_contains "$segment" "conventions-suggest"
  assert_not_contains "$import" "conventions-suggest"
  assert_not_contains "$refresh" "conventions-suggest"
  # and the rest of the file (before onboard, after refresh) does not mention it either
  head_part="$(awk '/^### `onboard`/ { exit } { print }' "$UNCHARTED_SKILL")"
  assert_not_contains "$head_part" "conventions-suggest"
}

@test "neither skill edit names .claude/ or .agents/" {
  run grep -h "conventions-suggest" "$INIT_SKILL" "$UNCHARTED_SKILL"
  [ "$status" -eq 0 ]
  assert_output_not_contains ".claude/"
  assert_output_not_contains ".agents/"
}
