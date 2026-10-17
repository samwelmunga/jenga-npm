#!/usr/bin/env bats
#
# End-to-end coverage for the j.commit test gate (E72_S04_T05).
#
# What this adds over the unit suites. tests/commit-test-gate-decide.bats, commit-test-gate-scoped.bats and
# commit-test-gate-run.bats each prove one script in isolation (and the last two run COPIES of their script in a stub
# package tree). Nothing else drives the three REAL scripts, from their checkout location, in the order skills/j-commit's
# SKILL.md calls them, over one scratch project:
#
#     test-gate-decide.sh resolve -> prompt -> answer
#       -> test-gate-scoped.sh (plan)  -> test-gate-run.sh scoped | test-gate-run.sh full
#       -> test-gate-decide.sh failure-prompt -> failure-answer -> directive
#       -> test-gate-run.sh log
#
# so this suite is about the SEAMS: the plan JSON the runner consumes, the catalog the plan hands over, the trailer lines
# the failure prompt and the directive consume, the exit codes a caller must treat as "do not proceed", and the events a
# whole scenario leaves in events.json. It deliberately does not read SKILL.md (E72_S04_T04's structural suite does) and
# does not repeat a unit case.
#
# How the cases are built
#   - Every test gets a scratch git repository under BATS_TEST_TMPDIR (src/*.sh, tests/*.bats, a scope map, a minimal
#     project/configs/workflow.json so JENGA_PROJECT_ROOT resolves, and a .gitignore for project/ so configs and logs never
#     count as changed files). JENGA_PROJECT_ROOT points at it, the working directory is inside it, git is isolated from
#     the host. test-config.json and events.json are scratch files there.
#   - Discovery is always a hand-written JSON file handed over with --discovery-file: no real discovery of any repository
#     ever runs. Suites are stubs whose command is `bash -c 'echo ran-<name> >> "$MARKER"; exit <code>'`, so the marker file
#     proves what ran and in what order. The bats-ecosystem suite is the one exception: its command must start with `bats `
#     for the plan to narrow it, so `bats` is an exported shell function that records its arguments in the marker and never
#     starts the real bats.
#   - "Nothing is committed" is a HEAD comparison: commit_if_proceeds commits in the scratch repository only when
#     `directive` says GATE=PROCEED, exactly what the skill does.
#   - This repository is never written. setup/teardown fingerprint its project/configs, the top-level files of
#     project/logs, HEAD and the staged list (cksum, as tests/conventions-precommit-timing.bats does) and the test fails if
#     they moved. The repository's real `npm test`, `bats tests/*.bats` and discovery are never run, and nothing uses the
#     network.
#   - Every script invocation goes through `bash <script>`, so the executable bit is not relied on. No line below begins
#     with `[[` (tests/bats-assertion-convention.bats).
#   - Time: stub suites only. The one wait is the interrupt case, bounded at 10 seconds before the suite is killed.

# shellcheck disable=SC2016,SC2030,SC2031,SC2119,SC2120,SC2317,SC2329
# SC2016: jq programs, JSON fixtures and suite commands are single-quoted on purpose ($MARKER must reach the suite's own
# shell unexpanded). SC2030/SC2031: bats runs each @test in its own subshell, so reading $status/$output after `run` is
# correct. SC2317/SC2329: the exported `bats` stub is reached through `bash -c` in run-suites.sh, not through a call
# the linter can see. SC2119/SC2120: plan_scoped takes optional extra arguments that no case currently passes.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
BASH_BIN="$(command -v bash)"
DECIDE="$REPO_ROOT/skills/j-commit/scripts/test-gate-decide.sh"
SCOPED="$REPO_ROOT/skills/j-commit/scripts/test-gate-scoped.sh"
RUNNER="$REPO_ROOT/skills/j-commit/scripts/test-gate-run.sh"

# Fingerprint of everything in THIS repository the suite promises not to touch.
repo_fingerprint() {
  {
    find "$REPO_ROOT/project/configs" -type f -exec cksum {} + 2>/dev/null | sort
    find "$REPO_ROOT/project/logs" -maxdepth 1 -type f -exec cksum {} + 2>/dev/null | sort
    git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null
    git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null
  } | cksum
}

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE JENGA_COMMIT_INLINE JENGA_COMMIT_NONINTERACTIVE
  export LC_ALL=C
  # The scripts' own scratch directories go under a private TMPDIR.
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"

  PROJ="$BATS_TEST_TMPDIR/proj"
  OUT="$BATS_TEST_TMPDIR/out"
  DISC="$BATS_TEST_TMPDIR/discovery.json"
  MARKER="$BATS_TEST_TMPDIR/marker"
  CONFIG="$PROJ/project/configs/test-config.json"
  EVENTS="$PROJ/project/logs/events.json"
  export MARKER
  export JENGA_PROJECT_ROOT="$PROJ"
  mkdir -p "$OUT"

  REAL_BEFORE="$(repo_fingerprint)"
  stub_bats
  make_project
  std_discovery
  cd "$PROJ" || return 1
}

teardown() {
  [ "$(repo_fingerprint)" = "$REAL_BEFORE" ]
}

# ---- fixture helpers ---------------------------------------------------------------------------------------------

# The only `bats` the gate ever executes: records the arguments it was given. BATS_STUB_EXIT makes it fail on request.
stub_bats() {
  bats() {
    printf 'ran-bats %s\n' "$*" >> "$MARKER"
    return "${BATS_STUB_EXIT:-0}"
  }
  export -f bats
}

# make_project: the scratch repository with one commit ($HEAD0). src/alpha.sh is covered by tests/alpha.bats, src/beta.sh
# by tests/beta.bats; tests/gamma.bats and docs/guide.md are covered by no rule.
make_project() {
  mkdir -p "$PROJ/src" "$PROJ/tests" "$PROJ/docs" "$PROJ/project/configs"
  git -C "$PROJ" init -q
  git -C "$PROJ" config user.name "Fixture"
  git -C "$PROJ" config user.email "fixture@example.invalid"
  git -C "$PROJ" config commit.gpgsign false
  printf 'project/\n' > "$PROJ/.gitignore"
  jq -n '{paths: {configs: "project/configs", logs: "project/logs"}}' > "$PROJ/project/configs/workflow.json"
  printf '#!/bin/sh\necho alpha\n' > "$PROJ/src/alpha.sh"
  printf '#!/bin/sh\necho beta\n' > "$PROJ/src/beta.sh"
  printf '# guide\n' > "$PROJ/docs/guide.md"
  printf '@test "alpha" { true; }\n' > "$PROJ/tests/alpha.bats"
  printf '@test "beta" { true; }\n' > "$PROJ/tests/beta.bats"
  printf '@test "gamma" { true; }\n' > "$PROJ/tests/gamma.bats"
  printf '%s\n' '{"map_version":1,"rules":[{"source":"src/alpha.sh","tests":["tests/alpha.bats"]},{"source":"src/beta.sh","tests":["tests/beta.bats"]}]}' > "$PROJ/scope-map.json"
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "fixture"
  HEAD0="$(head_sha)"
}

head_sha() {
  git -C "$PROJ" rev-parse HEAD
}

staged_list() {
  git -C "$PROJ" diff --cached --name-only
}

# edit_only <path>...: modify tracked files without staging them.
edit_only() {
  local f
  for f in "$@"; do
    printf 'edit\n' >> "$PROJ/$f"
  done
}

# stage_edit <path>...: modify tracked files and stage them (what `git commit` would record).
stage_edit() {
  local f
  for f in "$@"; do
    printf 'edit\n' >> "$PROJ/$f"
    git -C "$PROJ" add -- "$f"
  done
}

# cfg <commit_prompt_default>: the project's test-config.json, with the scope map from make_project.
cfg() {
  mkdir -p "$PROJ/project/configs"
  jq -n --arg d "$1" '{tools: {}, commit_scope_map_file: "scope-map.json", commit_prompt_default: $d}' > "$CONFIG"
}

# cfg_raw <json>: any test-config.json content.
cfg_raw() {
  mkdir -p "$PROJ/project/configs"
  printf '%s\n' "$1" > "$CONFIG"
}

# suite_json <id> <name> <ecosystem> <command> [<paths-json>]
suite_json() {
  jq -nc --arg id "$1" --arg name "$2" --arg eco "$3" --arg cmd "$4" --argjson paths "${5:-[]}" \
    '{id: $id, name: $name, type: "unit", ecosystem: $eco, command: $cmd, paths: $paths}'
}

# stub_cmd <name> <exit-code>: the suite command that records `ran-<name>` and exits with the code.
stub_cmd() {
  printf "bash -c 'echo ran-%s >> \"\$MARKER\"; exit %s'" "$1" "$2"
}

# bats_suite: the bats-ecosystem suite the plan narrows. Run whole it expands the glob over all three test files.
bats_suite() {
  suite_json "bats:tests" "bats tests" bats 'bats tests/*.bats' '["tests/*.bats"]'
}

# write_disc <suite-json>...: the discovery document at $DISC, suites in the order given.
write_disc() {
  printf '%s\n' "$@" | jq -cs '{suites: ., warnings: []}' > "$DISC"
}

# std_discovery: the bats suite plus one unrelated stub suite (catalog order: bats:tests, stub:other).
std_discovery() {
  write_disc "$(bats_suite)" "$(suite_json "stub:other" "other stub" stub "$(stub_cmd other 0)" '["other/*"]')"
}

# failing_discovery: a passing suite and a failing one (catalog order: good, bad).
failing_discovery() {
  write_disc "$(suite_json "stub:a-good" "good suite" stub "$(stub_cmd good 0)")" \
             "$(suite_json "stub:b-bad" "bad suite" stub "$(stub_cmd bad 1)")"
}

# ---- the skill's calls --------------------------------------------------------------------------------------------

# decide <args>: test-gate-decide.sh. Sets $status, $output, $stderr.
decide() {
  run --separate-stderr "$BASH_BIN" "$DECIDE" "$@"
}

# plan_scoped [args]: test-gate-scoped.sh over the scratch project and discovery file; the plan lands in $OUT/plan.json.
plan_scoped() {
  run --separate-stderr "$BASH_BIN" "$SCOPED" --out-dir "$OUT" --root "$PROJ" --discovery-file "$DISC" "$@"
}

# run_scoped: test-gate-run.sh scoped on the plan plan_scoped wrote.
run_scoped() {
  run --separate-stderr "$BASH_BIN" "$RUNNER" scoped --plan "$OUT/plan.json" --root "$PROJ" --out-dir "$OUT"
}

# run_full: test-gate-run.sh full over the scratch project and discovery file.
run_full() {
  run --separate-stderr "$BASH_BIN" "$RUNNER" full --out-dir "$OUT" --root "$PROJ" --discovery-file "$DISC"
}

# log_event <args>: test-gate-run.sh log; must succeed.
log_event() {
  run --separate-stderr "$BASH_BIN" "$RUNNER" log --root "$PROJ" "$@"
  [ "$status" -eq 0 ]
}

# commit_if_proceeds <directive args>: what the skill does with the directive. Sets $DIRECTIVE_STATUS and $DIRECTIVE_OUT,
# and commits the staged work in the scratch repository only on GATE=PROCEED (exit 0). Any non-zero status, including a
# usage error, means "do not proceed".
commit_if_proceeds() {
  DIRECTIVE_STATUS=0
  DIRECTIVE_OUT="$("$BASH_BIN" "$DECIDE" directive "$@" 2>/dev/null)" || DIRECTIVE_STATUS=$?
  if [ "$DIRECTIVE_STATUS" -eq 0 ]; then
    git -C "$PROJ" commit -q -m "gate: proceeded"
  fi
}

# ---- assertions ---------------------------------------------------------------------------------------------------

# marks: the lines the stub suites recorded, joined with commas (empty when nothing ran).
marks() {
  if [ -e "$MARKER" ]; then
    paste -sd, "$MARKER"
  fi
}

# json_check <jq expression>: $output must satisfy it.
json_check() {
  if ! printf '%s' "$output" | jq -e "$1" > /dev/null; then
    printf 'jq check failed: %s\n--- output ---\n%s\n--------------\n' "$1" "$output" >&2
    return 1
  fi
}

# event_check <jq expression>: events.json must satisfy it.
event_check() {
  if ! jq -e "$1" "$EVENTS" > /dev/null; then
    printf 'events check failed: %s\n--- events.json ---\n%s\n-------------------\n' "$1" "$(cat "$EVENTS" 2>&1)" >&2
    return 1
  fi
}

# trailer_is <result> <failed names>: the LAST TWO lines of $output are exactly the runner's trailer.
trailer_is() {
  local got want
  got="$(printf '%s\n' "$output" | tail -n 2)"
  want="$(printf 'TEST_GATE_RESULT=%s\nTEST_GATE_FAILED=%s' "$1" "$2")"
  if [ "$got" != "$want" ]; then
    printf 'trailer mismatch\n--- got ---\n%s\n--- want ---\n%s\n-----------\n' "$got" "$want" >&2
    return 1
  fi
}

# trailer_failed: the names the trailer reports.
trailer_failed() {
  printf '%s\n' "$output" | sed -n 's/^TEST_GATE_FAILED=//p' | tail -n 1
}

# directive_is <expected exit> <directive args>: 0 is GATE=PROCEED, 1 is GATE=HALT, anything else is a usage error that
# must never be mistaken for either.
directive_is() {
  local want="$1"
  shift
  decide directive "$@"
  [ "$status" -eq "$want" ]
  case "$want" in
    0) [ "$output" = "GATE=PROCEED" ] ;;
    1) [ "$output" = "GATE=HALT" ] ;;
  esac
}

# nothing_ran: no stub suite wrote the marker and the runner never created a run.log.
nothing_ran() {
  [ ! -e "$MARKER" ]
  [ ! -e "$OUT/run.log" ]
}

# ================================================================================================================
# Option 1: scoped
# ================================================================================================================

@test "option 1, scoped, mapped: only the mapped suite runs, narrowed to the mapped test files, and the commit proceeds" {
  cfg ""
  stage_edit src/alpha.sh src/beta.sh

  decide resolve
  [ "$status" -eq 0 ]
  json_check '.action == "prompt" and .choice == null'
  decide prompt
  assert_output_contains "1. Test covering committed scope (scoped run)"
  decide answer 1
  [ "$output" = "scoped" ]

  plan_scoped
  [ "$status" -eq 0 ]
  json_check '.status == "mapped" and .source == "staged" and .changed_count == 2 and .selection == [1]'
  json_check '.suites | length == 1'
  json_check '.suites[0].id == "bats:tests" and .suites[0].narrowed == true'
  json_check '.suites[0].tests == ["tests/alpha.bats", "tests/beta.bats"]'
  # The derived catalog holds only the mapped suite; planning ran nothing.
  [ "$(jq '.runnable | length' "$OUT/catalog.json")" -eq 1 ]
  nothing_ran

  run_scoped
  [ "$status" -eq 0 ]
  trailer_is passed ""
  # Exactly one line: the unrelated stub suite never ran, and the unmapped gamma test is not in the narrowed command.
  [ "$(marks)" = "ran-bats tests/alpha.bats tests/beta.bats" ]

  commit_if_proceeds passed
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$DIRECTIVE_OUT" = "GATE=PROCEED" ]
  [ "$(head_sha)" != "$HEAD0" ]

  log_event --action passed --choice scoped --caller interactive
  event_check '.[-1] | .event == "commit_test_gate" and .action == "passed" and .choice == "scoped" and .caller == "interactive"'
}

@test "option 1, zero mapped, answer 1: the plan is zero and never green, the fallback names the file, and the full catalog runs in order" {
  cfg ""
  stage_edit docs/guide.md

  plan_scoped
  [ "$status" -eq 0 ]
  json_check '.status == "zero" and .selection == [] and .unmapped_files == ["docs/guide.md"]'
  json_check '.warnings | index("No tests found for the changed files") != null'
  json_check '(.message | contains("docs/guide.md")) and ((.message | ascii_downcase | contains("passed")) | not)'
  local message
  message="$(printf '%s' "$output" | jq -r '.message')"
  nothing_ran

  # A zero plan cannot be run as a scoped run: refused, nothing on stdout (so no TEST_GATE_ line), nothing executed.
  run_scoped
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  nothing_ran

  decide fallback-prompt --reason "$message"
  [ "$status" -eq 0 ]
  assert_output_contains "docs/guide.md"
  assert_output_contains "1. Run j.test (full suite)"
  assert_output_contains "2. Skip tests"
  assert_output_not_contains "passed"

  decide fallback-answer 1
  [ "$output" = "full" ]
  run_full
  [ "$status" -eq 0 ]
  trailer_is passed ""
  [ "$(marks)" = "ran-bats tests/alpha.bats tests/beta.bats tests/gamma.bats,ran-other" ]
}

@test "option 1, zero mapped, answer 2: nothing runs, nothing is reported as passed, and the commit proceeds as skipped" {
  cfg ""
  stage_edit docs/guide.md

  plan_scoped
  [ "$status" -eq 0 ]
  json_check '.status == "zero"'
  local message
  message="$(printf '%s' "$output" | jq -r '.message')"

  decide fallback-prompt --reason "$message"
  assert_output_not_contains "passed"
  decide fallback-answer 2
  [ "$output" = "skip" ]
  # Blank is skip too.
  decide fallback-answer ""
  [ "$output" = "skip" ]

  # No runner call was made at all: no marker, no run.log, so there is no result line that could say passed.
  nothing_ran

  commit_if_proceeds skipped
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  assert_contains "$DIRECTIVE_OUT" "GATE=PROCEED"
  assert_not_contains "$DIRECTIVE_OUT" "passed"
  [ "$(head_sha)" != "$HEAD0" ]

  log_event --action fallback --choice skip --reason "$message" --caller interactive
  event_check '.[-1] | .action == "fallback" and .choice == "skip" and (.reason | contains("docs/guide.md"))'
}

@test "option 1, mapping error: a configured but missing map file gives status error and the same fallback offer, never a pass" {
  cfg_raw '{"commit_scope_map_file":"missing-map.json"}'
  stage_edit src/alpha.sh

  plan_scoped
  # The script reports the failure in the plan; it does not fail.
  [ "$status" -eq 0 ]
  json_check '.status == "error" and .selection == [] and .catalog_file == null and .map_scope_exit == 3'
  json_check '(.message | contains("missing-map.json")) and ((.message | ascii_downcase | contains("passed")) | not)'
  local message
  message="$(printf '%s' "$output" | jq -r '.message')"
  nothing_ran

  run_scoped
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  nothing_ran

  decide fallback-prompt --reason "$message"
  [ "$status" -eq 0 ]
  assert_output_contains "missing-map.json"
  assert_output_contains "1. Run j.test (full suite)"
  assert_output_contains "2. Skip tests"
  assert_output_not_contains "passed"

  decide fallback-answer 2
  [ "$output" = "skip" ]
  nothing_ran
  commit_if_proceeds skipped
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$(head_sha)" != "$HEAD0" ]
}

@test "option 1, source selection: with a non-empty index only the staged change is mapped, and the index is left alone" {
  cfg ""
  stage_edit src/alpha.sh
  edit_only src/beta.sh
  local index_before
  index_before="$(cksum < "$PROJ/.git/index")"

  plan_scoped
  [ "$status" -eq 0 ]
  json_check '.status == "mapped" and .source == "staged" and .changed_count == 1'
  json_check '.suites[0].tests == ["tests/alpha.bats"]'
  [ "$(cksum < "$PROJ/.git/index")" = "$index_before" ]

  run_scoped
  [ "$status" -eq 0 ]
  # beta.sh is modified but not staged, so its test is not part of this commit's scoped run.
  [ "$(marks)" = "ran-bats tests/alpha.bats" ]
  [ "$(staged_list)" = "src/alpha.sh" ]
}

@test "option 1, source selection: with an empty index the working-tree change is mapped, and nothing gets staged" {
  cfg ""
  edit_only src/beta.sh
  git -C "$PROJ" diff --cached --quiet
  local index_before
  index_before="$(cksum < "$PROJ/.git/index")"

  plan_scoped
  [ "$status" -eq 0 ]
  json_check '.status == "mapped" and .source == "working" and .changed_count == 1'
  json_check '.suites[0].tests == ["tests/beta.bats"]'
  [ "$(cksum < "$PROJ/.git/index")" = "$index_before" ]
  [ -z "$(staged_list)" ]

  run_scoped
  [ "$status" -eq 0 ]
  [ "$(marks)" = "ran-bats tests/beta.bats" ]
}

# ================================================================================================================
# Option 2: full
# ================================================================================================================

@test "option 2, full: every runnable suite runs once in catalog order and an identical-command duplicate is deduped" {
  cfg ""
  stage_edit src/alpha.sh
  # stub:dup-a and stub:dup-b are the same command (how an `npm test` alias of a suite looks to build-catalog.sh).
  write_disc "$(bats_suite)" \
             "$(suite_json "stub:dup-a" "dup a" stub "$(stub_cmd dup 0)")" \
             "$(suite_json "stub:dup-b" "dup b" stub "$(stub_cmd dup 0)")" \
             "$(suite_json "stub:zeta" "zeta" stub "$(stub_cmd zeta 0)")"

  decide answer 2
  [ "$output" = "full" ]

  run_full
  [ "$status" -eq 0 ]
  trailer_is passed ""
  assert_output_contains "3 passed, 0 failed. Exit code: 0"
  [ "$(marks)" = "ran-bats tests/alpha.bats tests/beta.bats tests/gamma.bats,ran-dup,ran-zeta" ]
  [ "$(grep -c '^ran-dup$' "$MARKER")" -eq 1 ]
  [ "$(jq -c '[.runnable[].id]' "$OUT/catalog.json")" = '["bats:tests","stub:dup-a","stub:zeta"]' ]
  [ "$(jq -r '.runnable[1].also[0].id' "$OUT/catalog.json")" = "stub:dup-b" ]

  commit_if_proceeds passed
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$(head_sha)" != "$HEAD0" ]
}

# ================================================================================================================
# Option 3: skip, and the recorded-default paths
# ================================================================================================================

@test "option 3, skip: a blank answer with no recorded default skips, nothing runs, and the commit proceeds" {
  cfg ""
  stage_edit src/alpha.sh

  decide resolve
  json_check '.action == "prompt" and .recorded_default == ""'
  decide prompt
  assert_output_contains "Enter selection (1-3), or blank to skip:"

  decide answer ""
  [ "$status" -eq 0 ]
  [ "$output" = "skip" ]
  decide answer "   "
  [ "$output" = "skip" ]
  decide answer 3
  [ "$output" = "skip" ]
  nothing_ran

  commit_if_proceeds skipped
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$DIRECTIVE_OUT" = "GATE=PROCEED" ]
  assert_not_contains "$DIRECTIVE_OUT" "passed"
  [ "$(head_sha)" != "$HEAD0" ]

  log_event --action skip --choice skip --caller interactive
  event_check '.[-1] | .action == "skip" and .choice == "skip" and .failed_suites == []'
}

@test "recorded default skip: resolve applies it without a prompt, nothing runs, and the commit proceeds" {
  cfg skip
  stage_edit src/alpha.sh

  decide resolve
  [ "$status" -eq 0 ]
  json_check '.action == "skip" and .choice == "skip" and .recorded_default == "skip" and .default_source == "config"'
  json_check '.reason == "recorded default" and .noninteractive == false'
  nothing_ran

  commit_if_proceeds skipped
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$(head_sha)" != "$HEAD0" ]

  log_event --action skip --choice skip --reason "recorded default" --caller interactive
  event_check '.[-1] | .action == "skip" and .reason == "recorded default"'
}

@test "recorded default scoped: resolve runs the scoped path without a prompt, through the plan and the runner" {
  cfg scoped
  stage_edit src/alpha.sh

  decide resolve
  [ "$status" -eq 0 ]
  json_check '.action == "run" and .choice == "scoped" and .recorded_default == "scoped" and .reason == "recorded default"'

  plan_scoped
  json_check '.status == "mapped" and .selection == [1]'
  run_scoped
  [ "$status" -eq 0 ]
  trailer_is passed ""
  [ "$(marks)" = "ran-bats tests/alpha.bats" ]

  commit_if_proceeds passed
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$(head_sha)" != "$HEAD0" ]
}

@test "recorded default full: resolve runs the full catalog without a prompt" {
  cfg full
  stage_edit src/alpha.sh

  decide resolve
  [ "$status" -eq 0 ]
  json_check '.action == "run" and .choice == "full" and .recorded_default == "full" and .reason == "recorded default"'

  run_full
  [ "$status" -eq 0 ]
  trailer_is passed ""
  [ "$(marks)" = "ran-bats tests/alpha.bats tests/beta.bats tests/gamma.bats,ran-other" ]

  commit_if_proceeds passed
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$(head_sha)" != "$HEAD0" ]
}

@test "--tests ask overrides a recorded default, shows the recorded-default notation, and blank or 'default' selects it" {
  cfg full
  stage_edit src/alpha.sh

  # Without the flag the recorded default is applied silently.
  decide resolve
  json_check '.action == "run" and .choice == "full"'

  decide resolve --tests ask
  [ "$status" -eq 0 ]
  json_check '.action == "prompt" and .choice == null and .recorded_default == "full" and .reason == "per-invocation override"'

  decide prompt --default full
  assert_output_contains "Enter selection (1-3), 'default' or blank for the recorded default (full):"
  decide answer "" --default full
  [ "$output" = "full" ]
  decide answer default --default full
  [ "$output" = "full" ]
  decide answer 3 --default full
  [ "$output" = "skip" ]
  # An answer outside the range is refused and nothing is printed for a caller to act on.
  decide answer 4 --default full
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  nothing_ran

  # Asking was a per-invocation choice: the recorded default is untouched.
  [ "$(jq -r '.commit_prompt_default' "$CONFIG")" = "full" ]
}

@test "an absent commit_prompt_default (no file, then a consumer-style config with only tools) behaves as empty and prompts" {
  # No test-config.json at all.
  [ ! -e "$CONFIG" ]
  decide resolve
  [ "$status" -eq 0 ]
  json_check '.action == "prompt" and .recorded_default == "" and .default_source == "absent" and .warnings == []'

  # A config written before commit_prompt_default existed: tools only.
  cfg_raw '{"tools":{"npm":{"command":"npm test"}}}'
  decide resolve
  [ "$status" -eq 0 ]
  json_check '.action == "prompt" and .choice == null and .recorded_default == "" and .default_source == "absent" and .warnings == []'

  # The prompt that follows has no recorded-default notation, and blank skips.
  decide prompt
  assert_output_contains "or blank to skip:"
  decide answer ""
  [ "$output" = "skip" ]
  nothing_ran
}

# ================================================================================================================
# Failure: the three answers, and a blank one
# ================================================================================================================

@test "failure, answer 1 (fix first): the failed suite is named in the prompt, the directive HALTs, and nothing is committed" {
  cfg ""
  failing_discovery
  stage_edit src/alpha.sh

  run_full
  [ "$status" -eq 1 ]
  trailer_is failed "bad suite"
  # A failing suite does not stop the run: both suites ran, in catalog order.
  [ "$(marks)" = "ran-good,ran-bad" ]
  local failed
  failed="$(trailer_failed)"

  decide failure-prompt --failed "$failed"
  [ "$status" -eq 0 ]
  assert_output_contains "Tests failed: bad suite"
  assert_output_contains "1. Fix first (nothing is committed)"
  assert_output_contains "2. Commit anyway"
  assert_output_contains "3. Abort the commit (nothing is committed)"

  decide failure-answer 1
  [ "$output" = "fix" ]

  directive_is 1 failed --choice fix
  commit_if_proceeds failed --choice fix
  [ "$DIRECTIVE_STATUS" -eq 1 ]
  [ "$DIRECTIVE_OUT" = "GATE=HALT" ]
  [ "$(head_sha)" = "$HEAD0" ]
  [ "$(staged_list)" = "src/alpha.sh" ]

  log_event --action halt --choice fix --failed "$failed" --caller interactive
  event_check '.[-1] | .action == "halt" and .choice == "fix" and .failed_suites == ["bad suite"] and .caller == "interactive"'
}

@test "failure, answer 2 (commit anyway): the directive PROCEEDs, the override logs the failed suites, and the choice is not persisted" {
  cfg ""
  failing_discovery
  stage_edit src/alpha.sh
  cp "$CONFIG" "$BATS_TEST_TMPDIR/config.before"

  run_full
  [ "$status" -eq 1 ]
  trailer_is failed "bad suite"
  local failed
  failed="$(trailer_failed)"

  decide failure-answer 2
  [ "$output" = "anyway" ]

  commit_if_proceeds failed --choice anyway
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$DIRECTIVE_OUT" = "GATE=PROCEED" ]
  [ "$(head_sha)" != "$HEAD0" ]

  log_event --action override --choice anyway --failed "$failed" --caller interactive
  event_check '.[-1] | .action == "override" and .choice == "anyway" and .failed_suites == ["bad suite"]'

  # test-config.json is byte-identical, so the next commit is gated again.
  cmp "$CONFIG" "$BATS_TEST_TMPDIR/config.before"
  stage_edit src/beta.sh
  decide resolve
  [ "$status" -eq 0 ]
  json_check '.action == "prompt" and .recorded_default == ""'
}

@test "failure, answer 3 (abort): the directive HALTs and nothing is committed" {
  cfg ""
  failing_discovery
  stage_edit src/alpha.sh

  run_full
  [ "$status" -eq 1 ]
  local failed
  failed="$(trailer_failed)"

  decide failure-answer 3
  [ "$output" = "abort" ]

  directive_is 1 failed --choice abort
  commit_if_proceeds failed --choice abort
  [ "$DIRECTIVE_STATUS" -eq 1 ]
  [ "$(head_sha)" = "$HEAD0" ]
  [ "$(staged_list)" = "src/alpha.sh" ]

  log_event --action halt --choice abort --failed "$failed" --caller interactive
  event_check '.[-1] | .action == "halt" and .choice == "abort" and .failed_suites == ["bad suite"]'
}

@test "failure, blank answer: the answer is rejected, and nothing a caller could build from it ever proceeds" {
  cfg ""
  failing_discovery
  stage_edit src/alpha.sh

  run_full
  [ "$status" -eq 1 ]

  decide failure-answer ""
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "no default"
  decide failure-answer "   "
  [ "$status" -eq 1 ]
  [ -z "$output" ]

  # What a caller holds after the rejected answer is an empty choice; the directive refuses it (usage error) and so does
  # a directive called with no choice at all (HALT): neither is PROCEED, so the scratch commit never happens.
  local choice
  choice="$("$BASH_BIN" "$DECIDE" failure-answer "" 2> /dev/null)" || true
  [ -z "$choice" ]
  commit_if_proceeds failed --choice "$choice"
  [ "$DIRECTIVE_STATUS" -eq 2 ]
  [ "$(head_sha)" = "$HEAD0" ]
  commit_if_proceeds failed
  [ "$DIRECTIVE_STATUS" -eq 1 ]
  [ "$DIRECTIVE_OUT" = "GATE=HALT" ]
  [ "$(head_sha)" = "$HEAD0" ]

  log_event --action halt --reason "blank answer to the failure prompt" --failed "bad suite" --caller interactive
  event_check '.[-1] | .action == "halt" and .choice == null and .failed_suites == ["bad suite"]'
}

# ================================================================================================================
# Error, interrupt, nothing runnable
# ================================================================================================================

@test "error: a catalog that cannot be built is error, runs nothing, offers the same choices, and only commit anyway proceeds" {
  cfg ""
  stage_edit src/alpha.sh
  printf 'this is not discovery json\n' > "$DISC"

  run_full
  [ "$status" -eq 2 ]
  trailer_is error ""
  assert_contains "$stderr" "build-catalog.sh failed"
  [ ! -e "$MARKER" ]
  # The cause the skill would show: the runner's first stderr line (read now, before another call replaces $stderr).
  local cause
  cause="$(printf '%s\n' "$stderr" | sed -n '1p')"
  [ -n "$cause" ]

  # TEST_GATE_FAILED is empty here, and failure-prompt refuses an empty list: the caller supplies the cause instead.
  decide failure-prompt --failed "" --kind error
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  decide failure-prompt --failed "build-catalog.sh failed" --kind error
  [ "$status" -eq 0 ]
  assert_output_contains "Tests could not be run: build-catalog.sh failed"
  local error_prompt failed_prompt
  error_prompt="$(printf '%s\n' "$output" | tail -n 4)"
  decide failure-prompt --failed "bad suite" --kind failed
  failed_prompt="$(printf '%s\n' "$output" | tail -n 4)"
  [ "$error_prompt" = "$failed_prompt" ]
  assert_contains "$error_prompt" "1. Fix first"
  assert_contains "$error_prompt" "2. Commit anyway"
  assert_contains "$error_prompt" "3. Abort the commit"

  directive_is 1 error --choice fix
  directive_is 1 error --choice abort
  directive_is 1 error
  commit_if_proceeds error --choice abort
  [ "$DIRECTIVE_STATUS" -eq 1 ]
  [ "$(head_sha)" = "$HEAD0" ]

  log_event --action error --reason "$cause" --caller interactive
  event_check '.[-1] | .action == "error" and .failed_suites == [] and (.reason | length > 0)'

  commit_if_proceeds error --choice anyway
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$DIRECTIVE_OUT" = "GATE=PROCEED" ]
  [ "$(head_sha)" != "$HEAD0" ]
  log_event --action override --choice anyway --reason "$cause" --caller interactive
  event_check '.[-1] | .action == "override" and .choice == "anyway"'
}

@test "interrupted: SIGTERM during a slow stub suite is interrupted, the directive HALTs with or without a choice, and nothing is committed" {
  cfg ""
  stage_edit src/alpha.sh
  # The slow suite starts a sleeper in its own process group so the test can prove the interrupt stopped it.
  write_disc "$(suite_json "stub:a-quick" "quick" stub "$(stub_cmd quick 0)")" \
             "$(suite_json "stub:b-slow" "slow" stub 'sleep 31 & echo $! > "$MARKER.sleeppid"; echo started > "$MARKER.started"; wait; echo ran-slow >> "$MARKER"')" \
             "$(suite_json "stub:c-never" "never" stub "$(stub_cmd never 0)")"

  INT_OUT="$BATS_TEST_TMPDIR/int.out"
  INT_ERR="$BATS_TEST_TMPDIR/int.err"
  export INT_OUT INT_ERR
  # The runner starts from a launcher under `set -m` (a backgrounded non-interactive job ignores SIGINT, and a script
  # cannot trap a signal it inherited as ignored). Every wait is bounded; SIGTERM goes to the runner once the slow suite
  # has reported that it started.
  local launcher='
    set -m
    "$@" > "$INT_OUT" 2> "$INT_ERR" &
    pid=$!
    n=0
    while [ ! -f "$MARKER.started" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
    if [ ! -f "$MARKER.started" ]; then kill -KILL -- "-$pid" 2>/dev/null; exit 97; fi
    kill -TERM "$pid"
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL -- "-$pid" 2>/dev/null; exit 98; fi
    wait "$pid"
  '
  run "$BASH_BIN" -c "$launcher" _ "$BASH_BIN" "$RUNNER" full --out-dir "$OUT" --root "$PROJ" --discovery-file "$DISC"
  [ "$status" -eq 130 ]
  output="$(cat "$INT_OUT")"
  trailer_is interrupted ""
  assert_output_contains "- slow (unit) (interrupted)"
  assert_output_contains "- never (unit) (not run)"
  assert_output_not_contains "TEST_GATE_RESULT=passed"
  # Only the first suite finished; the slow one was stopped and the last never started.
  [ "$(marks)" = "ran-quick" ]
  # The slow suite's sleeper is gone too (bounded wait, killed if it somehow survived).
  local sleeper n=0
  sleeper="$(cat "$MARKER.sleeppid")"
  while kill -0 "$sleeper" 2> /dev/null && [ "$n" -lt 30 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  if kill -0 "$sleeper" 2> /dev/null; then
    kill -KILL "$sleeper" 2> /dev/null
    return 1
  fi

  # The user stopped it: HALT, no prompt, whatever choice anyone passes.
  directive_is 1 interrupted
  directive_is 1 interrupted --choice anyway
  commit_if_proceeds interrupted
  [ "$DIRECTIVE_STATUS" -eq 1 ]
  [ "$DIRECTIVE_OUT" = "GATE=HALT" ]
  [ "$(head_sha)" = "$HEAD0" ]

  log_event --action interrupted --caller interactive
  event_check '.[-1] | .action == "interrupted" and .failed_suites == []'
}

@test "nothing runnable: a catalog with no runnable suite is unavailable (exit 3), runs nothing, says so, and the directive PROCEEDs" {
  cfg ""
  stage_edit src/alpha.sh
  # A config-only suite has no command, so it is listed as not runnable and can never be run.
  write_disc "$(suite_json "config:semgrep:sast" "semgrep (sast)" config "")"

  run_full
  [ "$status" -eq 3 ]
  assert_output_contains "No runnable test suites were found; no tests were run."
  assert_output_not_contains "passed"
  trailer_is unavailable ""
  [ ! -e "$MARKER" ]
  [ "$(jq '.runnable | length' "$OUT/catalog.json")" -eq 0 ]
  [ "$(jq '.not_runnable | length' "$OUT/catalog.json")" -eq 1 ]

  commit_if_proceeds unavailable
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$DIRECTIVE_OUT" = "GATE=PROCEED" ]
  [ "$(head_sha)" != "$HEAD0" ]
  directive_is 0 unavailable --choice abort

  log_event --action unavailable --reason "no runnable suite" --caller interactive
  event_check '.[-1] | .action == "unavailable" and .reason == "no runnable suite"'

  # No suite discovered at all is the same answer.
  printf '{"suites":[],"warnings":[]}\n' > "$DISC"
  run_full
  [ "$status" -eq 3 ]
  assert_output_contains "no tests were run"
  assert_output_not_contains "passed"
  trailer_is unavailable ""
  [ ! -e "$MARKER" ]
}

# ================================================================================================================
# Non-interactive callers
# ================================================================================================================

# noninteractive_gate [resolve args]: a recorded default of full and `--tests full` are both in play, yet resolve skips.
# The helper then does what the skill does with resolve's answer (it would start a suite only on `run`), so a wrong
# answer would show up as a marker. Asserts the whole contract: skip, nothing ran, directive PROCEED, one logged event.
noninteractive_gate() {
  cfg full
  stage_edit src/alpha.sh

  decide resolve --tests full "$@"
  [ "$status" -eq 0 ]
  json_check '.action == "skip" and .choice == "skip" and .noninteractive == true and .recorded_default == "full"'
  assert_output_contains "non-interactive caller"
  local action reason
  action="$(printf '%s' "$output" | jq -r '.action')"
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  if [ "$action" = "run" ]; then
    run_full
  fi
  nothing_ran

  directive_is 0 skipped
  commit_if_proceeds skipped
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  [ "$DIRECTIVE_OUT" = "GATE=PROCEED" ]
  [ "$(head_sha)" != "$HEAD0" ]

  log_event --action skip --choice skip --reason "$reason" --caller noninteractive
  event_check '.[-1] | .event == "commit_test_gate" and .agent == "j.commit" and .action == "skip" and .caller == "noninteractive" and (.reason | contains("non-interactive"))'
  # The recorded default is untouched: a non-interactive skip is not a decision to change it.
  [ "$(jq -r '.commit_prompt_default' "$CONFIG")" = "full" ]
}

@test "non-interactive via --caller noninteractive: skips whatever the default and --tests say, logs it, and the commit proceeds" {
  noninteractive_gate --caller noninteractive
}

@test "non-interactive via --inline: skips whatever the default and --tests say, logs it, and the commit proceeds" {
  noninteractive_gate --inline
}

@test "non-interactive via JENGA_COMMIT_INLINE=1: skips whatever the default and --tests say, logs it, and the commit proceeds" {
  export JENGA_COMMIT_INLINE=1
  noninteractive_gate
}

@test "non-interactive via JENGA_COMMIT_NONINTERACTIVE=1: skips whatever the default and --tests say, logs it, and the commit proceeds" {
  export JENGA_COMMIT_NONINTERACTIVE=1
  noninteractive_gate
}

# ================================================================================================================
# Audit trail
# ================================================================================================================

@test "audit trail: a scenario that skips, fails and overrides leaves its commit_test_gate events in order in a valid array" {
  cfg ""
  mkdir -p "$PROJ/project/logs"
  printf '%s\n' '[{"event":"session_start","agent":"developer","session_id":"earlier","date":"2026-10-14T00:00:00Z"}]' > "$EVENTS"

  # Commit 1: the user skips.
  stage_edit src/alpha.sh
  decide answer 3
  [ "$output" = "skip" ]
  commit_if_proceeds skipped
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  log_event --action skip --choice skip --caller interactive

  # Commit 2: the full run fails, and the user commits anyway.
  failing_discovery
  stage_edit src/beta.sh
  run_full
  [ "$status" -eq 1 ]
  local failed
  failed="$(trailer_failed)"
  [ "$failed" = "bad suite" ]
  log_event --action failed --failed "$failed" --caller interactive
  decide failure-answer 2
  [ "$output" = "anyway" ]
  commit_if_proceeds failed --choice anyway
  [ "$DIRECTIVE_STATUS" -eq 0 ]
  log_event --action override --choice anyway --failed "$failed" --caller interactive

  event_check 'type == "array" and length == 4'
  event_check '.[0] == {"event":"session_start","agent":"developer","session_id":"earlier","date":"2026-10-14T00:00:00Z"}'
  event_check '[.[1:][].action] == ["skip", "failed", "override"]'
  event_check '[.[1:][] | .event == "commit_test_gate" and .agent == "j.commit" and (.date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))] | all'
  event_check '[.[1:][].failed_suites] == [[], ["bad suite"], ["bad suite"]]'
  event_check '[.[1:][].caller] == ["interactive", "interactive", "interactive"]'
  # Two commits landed, each after a PROCEED.
  [ "$(git -C "$PROJ" rev-list --count "$HEAD0..HEAD")" -eq 2 ]
  # The locked write left nothing behind: no temp file, no lock directory.
  [ "$(find "$PROJ/project/logs" -mindepth 1 | wc -l | tr -d ' ')" -eq 1 ]
}
