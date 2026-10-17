#!/usr/bin/env bats
#
# Coverage for E72_S04_T04: the j.commit test gate is wired into the skills.
#
# Two halves.
#   Structural: skills/j-commit/SKILL.md carries the Test gate step (3.5) after the prerequisites step and before the
#   pre-commit gate step, documents --tests and --caller and the Inline Mode skip, names every gate script in
#   conversation order, says what a halt prints, and contains none of the gate's deterministic logic; j-lgtm and
#   j-dev-done forward --tests and stop on a halt; agents/developer.md tells the developer to call j.commit
#   non-interactively. These cases only read text. No gate script is executed here (their own suites,
#   commit-test-gate-decide/scoped/run.bats, cover behaviour) and no test command is run.
#   Behavioural: skills/j-dev-done/scripts/classify-commit-outcome.sh handles all four outcomes (halt on nothing to
#   commit, halt on the test gate, PROCEED, usage error). It only classifies text it is given.
#
# Assertions use `[ ]` and tests/helpers/assertions.bash only. Nothing here touches this repo's project/ state.

# shellcheck disable=SC2016
# (the needles are literal skill text such as "$GATE_DIR" and backticks; nothing is meant to expand.)

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL="$REPO_ROOT/skills/j-commit/SKILL.md"
LGTM="$REPO_ROOT/skills/j-lgtm/SKILL.md"
DEVDONE="$REPO_ROOT/skills/j-dev-done/SKILL.md"
CLASSIFY="$REPO_ROOT/skills/j-dev-done/scripts/classify-commit-outcome.sh"
DEVELOPER="$REPO_ROOT/agents/developer.md"
SCRIPTS="$REPO_ROOT/skills/j-commit/scripts"
DECIDE="$SCRIPTS/test-gate-decide.sh"

require_devdone() {
  [ -f "$DEVDONE" ] || skip "skills/j-dev-done is private and not shipped in the public mirror"
}

HALT_LINE="TEST_GATE=HALT"
HALT_MSG="Commit halted at the test gate: nothing was committed."
NOTHING_MSG="No implementation to commit."

# --- text helpers -----------------------------------------------------------------------------------------------

# section <heading>: the skill text from the heading up to the next "## " heading.
section() {
  awk -v h="$1" '$0 == h { on = 1; print; next } on && /^## / { exit } on { print }' "$SKILL"
}

# normal_step <prefix>: the normal-mode "## Instructions" lines from the one starting with <prefix> up to the next
# numbered step heading.
normal_step() {
  awk -v p="$1" '
    /^## Instructions/ { ins = 1; next }
    ins && /^## / { exit }
    ins && /^[0-9]+(\.[0-9]+)?\. \*\*/ { on = (index($0, p) == 1) }
    ins && on { print }
  ' "$SKILL"
}

# step_numbers <heading>: the numbered step labels (1 2 3 3.5 4 ...) inside a "## " section, in order.
step_numbers() {
  section "$1" | sed -n 's/^\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\)\. .*/\1/p' | tr '\n' ' '
}

# gate_text: the whole normal-mode Test gate step.
gate_text() { normal_step '3.5. **Test gate** '; }

# pos <haystack> <needle>: the offset of the first occurrence of <needle>; fails when it is absent.
pos() {
  case "$1" in *"$2"*) ;; *) echo "missing: $2" >&2; return 1 ;; esac
  local before="${1%%"$2"*}"
  printf '%s' "${#before}"
}

# assert_in_order <haystack> <needle>...: every needle is present, first occurrences in ascending order.
assert_in_order() {
  local hay="$1" last=-1 here needle
  shift
  for needle in "$@"; do
    here="$(pos "$hay" "$needle")" || { echo "not found: $needle" >&2; return 1; }
    if [ "$here" -le "$last" ]; then
      echo "out of order: $needle (offset $here, previous $last)" >&2
      return 1
    fi
    last="$here"
  done
}

classify() { run --separate-stderr bash "$CLASSIFY" "$@"; }

# --- j-commit SKILL.md: position and numbering -----------------------------------------------------------------

@test "normal mode has steps 1 2 3 3.5 4 5 6: the Test gate is a new step and nothing is renumbered" {
  [ "$(step_numbers "## Instructions")" = "1 2 3 3.5 4 5 6 " ]
}

@test "the Test gate step comes after the prerequisites step and before the pre-commit gate step" {
  hdrs="$(awk '/^## Instructions/ { ins = 1; next } ins && /^## / { exit } ins && /^[0-9]+(\.[0-9]+)?\. \*\*/ { print }' "$SKILL")"
  assert_in_order "$hdrs" \
    '3. **Verify user-action prerequisites**' \
    '3.5. **Test gate** ' \
    '4. **Pre-commit gate** ' \
    '5. **Commit** '
}

@test "the pre-commit gate is still the last step before the commit command" {
  step4="$(normal_step '4. **Pre-commit gate** ')"
  assert_contains "$step4" "immediately before the commit command"
  # step 5 is the commit itself, and no numbered step sits between them
  [ "$(step_numbers "## Instructions")" = "1 2 3 3.5 4 5 6 " ]
  assert_contains "$(normal_step '5. **Commit** ')" "**Epic:** "
}

@test "the Test gate step states why it sits there and that it writes no situation marker" {
  g="$(gate_text)"
  [ -n "$g" ]
  assert_contains "$g" "merge orphaned worktrees"
  assert_contains "$g" "final only after step 3"
  assert_contains "$g" "must never be open across them"
  assert_contains "$g" "writes **no** situation marker"
  assert_contains "$g" "leaves none behind"
  assert_not_contains "$g" "checklist-marker.sh"
  assert_not_contains "$g" "checklist.sh"
}

@test "the Pre-commit gate and commit-format sections are untouched by the test gate" {
  gate="$(section "## Pre-commit gate")"
  assert_contains "$gate" "checklist.sh check pre-commit --run"
  assert_contains "$gate" "**Mark the situation.**"
  assert_not_contains "$gate" "test-gate"
  assert_not_contains "$gate" "TEST_GATE"
  conv="$(section "## Project commit-format convention")"
  assert_not_contains "$conv" "test-gate"
}

@test "the frontmatter of SKILL.md is unchanged" {
  fm="$(awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on { print }' "$SKILL")"
  expected='name: j.commit
description: Commit implemented epic, story, or task work using the EST naming convention. Also handles user-action prerequisites and new-epic boundaries. Use after completing any EST work item.
keywords:
  - commit
  - save
  - git commit
  - done
  - push
  - j-commit
examples:
  - "commit this work"
  - "save my changes"
  - "j-commit"'
  [ "$fm" = "$expected" ]
}

# --- j-commit SKILL.md: arguments, Inline Mode -----------------------------------------------------------------

@test "--tests and --caller are documented, with the caller rule" {
  a="$(section "## Arguments")"
  [ -n "$a" ]
  assert_contains "$a" "--tests <ask|skip|scoped|full>"
  assert_contains "$a" "per-invocation"
  assert_contains "$a" "\`ask\` forces the prompt"
  assert_contains "$a" "--caller <interactive|noninteractive>"
  assert_contains "$a" "--caller noninteractive"
  assert_contains "$a" "sub-agent"
  assert_contains "$a" "sender-object caller"
  assert_contains "$a" "--caller interactive"
}

@test "Inline Mode skips the test gate: resolve --inline, prints the skip, logs it, never prompts" {
  inline="$(section "## Inline Mode (called by /do for inline-scoped tasks)")"
  [ -n "$inline" ]
  assert_contains "$inline" "never prompts and never runs tests"
  assert_contains "$inline" "test-gate-decide.sh\" resolve --inline"
  assert_contains "$inline" "Tests skipped: <reason>"
  assert_contains "$inline" "test-gate-run.sh\" log --action skip"
  # still before the pre-commit gate, and the inline steps are renumbered by nothing
  [ "$(step_numbers "## Inline Mode (called by /do for inline-scoped tasks)")" = "1 2 3 3.5 4 5 6 " ]
  assert_in_order "$inline" '3.5. **Test gate skip**' '4. **Pre-commit gate**'
}

# --- j-commit SKILL.md: the conversation -----------------------------------------------------------------------

@test "the Test gate step names every call in conversation order" {
  assert_in_order "$(gate_text)" \
    'test-gate-decide.sh" resolve' \
    'test-gate-decide.sh" prompt' \
    'test-gate-decide.sh" answer "<raw>"' \
    'test-gate-run.sh" full --out-dir "$GATE_DIR"' \
    'test-gate-scoped.sh" --out-dir "$GATE_DIR"' \
    'test-gate-run.sh" scoped --plan "$GATE_DIR/plan.json"' \
    'test-gate-decide.sh" fallback-prompt --reason' \
    'test-gate-decide.sh" fallback-answer' \
    'test-gate-decide.sh" failure-prompt --failed' \
    'test-gate-decide.sh" failure-answer' \
    'test-gate-decide.sh" directive <result> --choice'
  assert_contains "$(gate_text)" 'test-gate-run.sh" log --action'
}

@test "every gate script the SKILL names exists under skills/j-commit/scripts/, and it names all three" {
  names="$(grep -o 'test-gate-[a-z]*\.sh' "$SKILL" | sort -u | tr '\n' ' ')"
  [ "$names" = "test-gate-decide.sh test-gate-run.sh test-gate-scoped.sh " ]
  for n in $names; do
    [ -f "$SCRIPTS/$n" ]
  done
}

@test "the three-option prompt: the SKILL words the options and the script prints the exact text" {
  g="$(gate_text)"
  assert_contains "$g" "three options"
  assert_contains "$g" "scoped run of the tests covering the committed scope"
  assert_contains "$g" "the full suite through \`j.test\`"
  assert_contains "$g" "3 skip"
  assert_contains "$g" "exactly as printed"
  # the exact prompt text lives in the script (never restated in the SKILL, so it cannot drift from it)
  for line in \
    "Run tests before committing?" \
    "1. Test covering committed scope (scoped run)" \
    "2. Run j.test (full suite)" \
    "3. Skip tests" \
    "Enter selection (1-3), or blank to skip:"; do
    grep -qF "$line" "$DECIDE"
  done
  assert_not_contains "$g" "Run tests before committing?"
}

@test "the skip, run and prompt actions, the fallback and the failure rules are all relayed" {
  g="$(gate_text)"
  assert_contains "$g" "Tests skipped: <reason>"
  assert_contains "$g" "never \"passed\""
  assert_contains "$g" "not a pass"
  assert_contains "$g" "no tests were run (never a pass)"
  assert_contains "$g" "TEST_GATE_RESULT=<result>"
  assert_contains "$g" "TEST_GATE_FAILED=<names>"
  assert_contains "$g" "attempted and could not execute"
  assert_contains "$g" "no \`TEST_GATE_\` line at all"
  assert_contains "$g" "there is no default and a blank answer never proceeds"
  assert_contains "$g" "re-invoked after the fix"
  assert_contains "$g" "runs again from scratch"
  for outcome in passed failed error unavailable interrupted override halt; do
    assert_contains "$g" "\`$outcome\`"
  done
}

@test "the Test gate step carries no parsing, mapping, proceed/halt or logging logic of its own" {
  g="$(gate_text)"
  # no text tools, no JSON tooling and no shell branching or loops spelled out inline (whole-word matches only, so
  # ordinary prose such as "used " or "in case" is never mistaken for a command)
  run grep -Ew 'awk|sed|grep|xargs' <<< "$g"
  [ "$status" -eq 1 ]
  run grep -E 'jq +-|^ *(case|while|for) |^ *if ' <<< "$g"
  [ "$status" -eq 1 ]
  assert_not_contains "$g" 'if ['
  assert_not_contains "$g" '$(( '
  # the only shell it spells out is the script-dir lookup and the scratch-dir lifecycle; it never touches the log
  assert_not_contains "$g" "events.json"
  assert_not_contains "$g" "git add"
  assert_not_contains "$g" "git commit"
}

@test "a halt prints both lines, leaves nothing staged, committed or marked, and cleans up" {
  g="$(gate_text)"
  assert_contains "$g" "$HALT_LINE"
  assert_contains "$g" "$HALT_MSG"
  assert_contains "$g" "nothing is staged, committed or marked"
  assert_contains "$g" "rm -rf \"\$GATE_DIR\""
  assert_contains "$g" "on every exit path"
  assert_contains "$g" "/lgtm"
  assert_contains "$g" "/dev-done"
}

@test "no choice is persisted, and the developer agent never runs tests" {
  g="$(gate_text)"
  assert_contains "$g" "is written to \`test-config.json\`"
  assert_contains "$g" "the next commit gates again"
  assert_contains "$g" "jenga config set test-config.commit_prompt_default <value>"
  assert_contains "$g" "The developer agent never runs tests (CLAUDE.md)"
  assert_contains "$g" "a human answers this prompt"
  assert_contains "$g" "a non-interactive caller skips with a logged note instead"
}

# --- j-lgtm, j-dev-done, developer.md --------------------------------------------------------------------------

@test "j-lgtm forwards --tests and stops on a halt without running /continue or returning to /do" {
  t="$(cat "$LGTM")"
  assert_contains "$t" "--tests <ask|skip|scoped|full>"
  assert_contains "$t" "unchanged"
  assert_contains "$t" "$HALT_LINE"
  assert_contains "$t" "nothing was committed"
  assert_contains "$t" "**stop here**"
  assert_contains "$t" "do not invoke \`/continue\` and do not return to a \`/do\` workflow"
  # the stop comes before the original continue/return step
  assert_in_order "$t" "**stop here**" "return to that workflow"
}

@test "j-dev-done forwards --tests, names both halt messages and documents the ungated self-sync commit" {
  require_devdone
  t="$(cat "$DEVDONE")"
  assert_contains "$t" "--tests <ask|skip|scoped|full>"
  assert_contains "$t" "unchanged"
  assert_contains "$t" "$NOTHING_MSG"
  assert_contains "$t" "$HALT_MSG"
  assert_contains "$t" "$HALT_LINE"
  assert_contains "$t" "Do **not** invoke"
  assert_contains "$t" "deliberately **not** test-gated"
  assert_contains "$t" "chore(self-sync)"
  assert_contains "$t" "commit-post-sync.sh"
}

@test "agents/developer.md tells the developer to call j.commit with --caller noninteractive" {
  t="$(cat "$DEVELOPER")"
  assert_in_order "$t" 'Use the `j.commit` skill to commit.' '--caller noninteractive' '### Crucial Tier: `advisory`'
  assert_contains "$t" "you still never run tests, the tester does"
}

# --- classify-commit-outcome.sh --------------------------------------------------------------------------------

@test "the classifier is executable, passes bash -n, and its header names both halt signals" {
  require_devdone
  [ -x "$CLASSIFY" ]
  run bash -n "$CLASSIFY"
  [ "$status" -eq 0 ]
  hdr="$(sed -n '1,/^set -euo pipefail/p' "$CLASSIFY")"
  assert_contains "$hdr" "$NOTHING_MSG"
  assert_contains "$hdr" "$HALT_MSG"
  assert_contains "$hdr" "$HALT_LINE"
}

@test "classifier: the exact nothing-to-commit message halts with that message (unchanged)" {
  require_devdone
  classify "$NOTHING_MSG"
  [ "$status" -eq 1 ]
  [ "$output" = "$NOTHING_MSG" ]
  classify "  $NOTHING_MSG  "
  [ "$status" -eq 1 ]
  [ "$output" = "$NOTHING_MSG" ]
  classify "agent prose before
$NOTHING_MSG
and after"
  [ "$status" -eq 1 ]
  [ "$output" = "$NOTHING_MSG" ]
}

@test "classifier: a standalone TEST_GATE=HALT line halts with the test-gate message and exit 1" {
  require_devdone
  classify "$HALT_LINE
$HALT_MSG"
  [ "$status" -eq 1 ]
  [ "$output" = "$HALT_MSG" ]
  # the line alone is enough, with surrounding prose and whitespace
  classify "reconcile: no drift
   $HALT_LINE
Nothing else printed."
  [ "$status" -eq 1 ]
  [ "$output" = "$HALT_MSG" ]
  # via stdin, as the skill calls it
  run --separate-stderr bash -c "printf '%s\n' 'x' '$HALT_LINE' | bash '$CLASSIFY'"
  [ "$status" -eq 1 ]
  [ "$output" = "$HALT_MSG" ]
}

@test "classifier: ordinary output proceeds, and a TEST_GATE=HALT that is not a standalone line is not a signal" {
  require_devdone
  classify "Committed task(E72_S04_T04): wire the gate
All Done!"
  [ "$status" -eq 0 ]
  [ "$output" = "PROCEED" ]
  classify "the gate printed TEST_GATE=HALT earlier but that was a quote"
  [ "$status" -eq 0 ]
  [ "$output" = "PROCEED" ]
  classify "TEST_GATE=HALTED"
  [ "$status" -eq 0 ]
  [ "$output" = "PROCEED" ]
  classify "$HALT_MSG"
  [ "$status" -eq 0 ]
  [ "$output" = "PROCEED" ]
  classify "TEST_GATE=PROCEED"
  [ "$status" -eq 0 ]
  [ "$output" = "PROCEED" ]
}

@test "classifier: no input and too many arguments are usage errors (exit 2)" {
  require_devdone
  run --separate-stderr bash "$CLASSIFY" < /dev/null
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  classify "one" "two"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  classify ""
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}
