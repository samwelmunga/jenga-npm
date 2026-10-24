#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/scope-test-gate.sh (E72_S06_T03).
#
# The gate resolves the test-run mode of a board scope (task, story, epic) through scope-policy.sh and then runs nothing
# (none), the suites mapped from the scope's changed files (scoped) or the whole catalog (full), reporting through its
# exit code: 0 satisfied, 1 a suite failed, 2 usage error, 3 infrastructure error. This suite pins the contract in its
# header: the three modes, the changed-file derivation for a task, a story and an epic (and the --range/--rev override),
# the two fallbacks to the full catalog, the empty full catalog, the failing suite, the JSON object, the exit codes, and
# the promise that it never touches the board.
#
# How the cases are written
#   - The script locates its helper scripts through BASH_SOURCE, so every case runs a COPY of it inside a throwaway
#     package tree ($PKG: the real j-test scripts, scripts/resolve-root.sh). Only $PKG's discover-tests.sh is replaced,
#     by a stub that counts its calls and prints a fixture, so "discovery runs once" is a call counter and no real
#     discovery (25-35 s on a large tree) ever happens. Everything else is the real code.
#   - Every case works on a consuming-project style fixture built in BATS_TEST_TMPDIR: a git repository with four small
#     suites, commits named like board commits (`task(E99_S01_T01): ...`), a project/ tree holding the board (one epic,
#     two stories, three tasks' worth of commits, all left untracked as in a worktree that does not carry the board),
#     a scope map and a test-config.json. Nothing here reads or writes this repository's project/ tree.
#   - Suite commands are shell one-liners served from the discovery fixture; each appends its name to $RUN_MARK, and the
#     gamma suite fails when GAMMA_FAIL is set, so "which suites ran" is the content of one file.
#   - Assertions use `[ ]` and tests/helpers/assertions.bash only.

# shellcheck disable=SC2016,SC2030,SC2031
# SC2016: jq programs and fixture JSON are single-quoted on purpose; the suite commands expand $RUN_MARK when they run.
# SC2030/SC2031: bats runs each @test in its own subshell, so reading $status/$output after `run` is correct.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
BASH_BIN="$(command -v bash)"

# Four suites, one per area of the fixture. Each appends its name to $RUN_MARK (exported by setup).
STD_DISC='{"suites":[
  {"id":"bats:alpha","name":"alpha tests","type":"unit","ecosystem":"bats","command":"echo alpha >> \"$RUN_MARK\"","paths":["alpha/*.bats"]},
  {"id":"bats:beta","name":"beta tests","type":"unit","ecosystem":"bats","command":"echo beta >> \"$RUN_MARK\"","paths":["beta/*.bats"]},
  {"id":"bats:delta","name":"delta tests","type":"unit","ecosystem":"bats","command":"echo delta >> \"$RUN_MARK\"","paths":["delta/*.bats"]},
  {"id":"bats:gamma","name":"gamma tests","type":"unit","ecosystem":"bats","command":"echo gamma >> \"$RUN_MARK\"; [ -z \"${GAMMA_FAIL:-}\" ]","paths":["gamma/*.bats"]}],
  "warnings":[]}'

# One rule per area: a changed src/<area>/*.sh runs <area>/*.bats.
STD_MAP='{"map_version":1,"rules":[
  {"source":"src/alpha/*.sh","tests":["alpha/*.bats"]},
  {"source":"src/beta/*.sh","tests":["beta/*.bats"]},
  {"source":"src/delta/*.sh","tests":["delta/*.bats"]},
  {"source":"src/gamma/*.sh","tests":["gamma/*.bats"]}]}'

# The policy file every case starts from: only the scope map location, so each policy key is absent (its default).
BASE_CFG='{"commit_scope_map_file":"project/scope-map.json"}'

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GAMMA_FAIL JENGA_PROJECT_ROOT
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"

  DISC_COUNT="$BATS_TEST_TMPDIR/discovery-calls"
  RUN_MARK="$BATS_TEST_TMPDIR/run-mark"
  DISC_STUB_JSON="$BATS_TEST_TMPDIR/discovery.json"
  export DISC_COUNT RUN_MARK DISC_STUB_JSON
  printf '%s' "$STD_DISC" > "$DISC_STUB_JSON"

  build_pkg
  seed_repo
  set_cfg "$BASE_CFG"
}

# ---- fixture helpers ---------------------------------------------------------------------------------------------

# build_pkg: the throwaway package tree. discover-tests.sh is the counting stub; everything else is the real script.
build_pkg() {
  PKG="$BATS_TEST_TMPDIR/pkg"
  GATE="$PKG/skills/j-test/scripts/scope-test-gate.sh"
  mkdir -p "$PKG/skills/j-test/scripts" "$PKG/scripts" "$PKG/templates"
  cp "$REPO_ROOT"/skills/j-test/scripts/*.sh "$PKG/skills/j-test/scripts/"
  cp "$REPO_ROOT/scripts/resolve-root.sh" "$PKG/scripts/"
  cp "$REPO_ROOT/templates/test-scope-map.json" "$PKG/templates/"
  cat > "$PKG/skills/j-test/scripts/discover-tests.sh" <<'STUB'
#!/usr/bin/env bash
# Stub: counts its calls, then prints the fixture.
printf 'run\n' >> "$DISC_COUNT"
cat "$DISC_STUB_JSON"
STUB
}

put() {
  mkdir -p "$(dirname "$REPO/$1")"
  printf '%s\n' "${2:-content of $1}" > "$REPO/$1"
}

edit() { printf 'changed\n' >> "$REPO/$1"; }

commit_all() {
  git -C "$REPO" add -A -- . ':!project'
  git -C "$REPO" commit -q -m "$1"
}

# seed_repo: the consuming-project fixture (see the header). The board, the scope map and the config stay untracked.
seed_repo() {
  local f
  REPO="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Fixture"
  git -C "$REPO" config user.email "fixture@example.invalid"
  git -C "$REPO" config commit.gpgsign false
  for f in alpha/a.bats beta/b.bats gamma/g.bats delta/d.bats src/alpha/a.sh src/beta/b.sh src/gamma/g.sh \
           src/delta/d.sh README.md docs/readme.md; do
    put "$f"
  done
  commit_all "seed"

  edit src/alpha/a.sh;  commit_all "task(E99_S01_T01): alpha change"
  SHA_ALPHA="$(git -C "$REPO" rev-parse HEAD)"
  # Names the task but is not a `task(...)` commit (a rapport): its gamma edit must NOT count towards E99_S01_T01.
  edit src/gamma/g.sh;  commit_all "chore(E99_S01_T01): add rapport - noise"
  edit src/beta/b.sh;   commit_all "task(E99_S01_T02): beta change"
  SHA_BETA="$(git -C "$REPO" rev-parse HEAD)"
  edit src/gamma/g.sh;  commit_all "task(E99_S02_T01): gamma change"
  SHA_GAMMA="$(git -C "$REPO" rev-parse HEAD)"
  edit docs/readme.md;  commit_all "task(E99_S03_T01): docs only"
  # A task branch whose own commit does not name the task; only its merge commit does.
  git -C "$REPO" checkout -q -b E99_S04_T01-delta
  edit src/delta/d.sh;  commit_all "wip: delta thing"
  git -C "$REPO" checkout -q -
  git -C "$REPO" merge -q --no-ff -m "Merge branch 'E99_S04_T01-delta' into HEAD" E99_S04_T01-delta

  put project/configs/workflow.json '{}'
  put project/scope-map.json "$STD_MAP"
  # A block list in the story, an inline list in the epic: both shapes the board uses.
  put project/board/stories/E99_S01_two-tasks.md '---
id: E99_S01
epic_id: E99
title: Two tasks
status: In Progress
tasks:
  - E99_S01_T01
  - E99_S01_T02
---

# Story'
  put project/board/stories/E99_S02_one-task.md '---
id: E99_S02
tasks:
  - E99_S02_T01
---'
  put project/board/epics/E99_fixture-epic.md '---
id: E99
title: Fixture epic
stories: [E99_S01, E99_S02]
---'
}

# set_cfg <json>: write the scratch test-config.json.
set_cfg() { printf '%s' "$1" > "$REPO/project/configs/test-config.json"; }

# cfg_with <key> <value>: BASE_CFG plus one policy key.
cfg_with() { set_cfg "$(printf '%s' "$BASE_CFG" | jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}')"; }

# ---- running and reading -----------------------------------------------------------------------------------------

# gate <args...>: run the script against the fixture; $status, $output (stdout) and $stderr.
gate() { run --separate-stderr "$BASH_BIN" "$GATE" --root "$REPO" "$@"; }

# marks: the suites that ran, sorted, comma-separated; "none" when no suite ran.
marks() {
  if [ -f "$RUN_MARK" ]; then
    LC_ALL=C sort "$RUN_MARK" | paste -sd ',' -
  else
    printf 'none'
  fi
}

discovery_calls() {
  if [ -f "$DISC_COUNT" ]; then wc -l < "$DISC_COUNT" | tr -d ' '; else printf '0'; fi
}

# board_snapshot: a checksum of every file under the fixture's board plus the file list.
board_snapshot() {
  (cd "$REPO" && find project/board -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done)
}

# jq_ok <expression>: the expression is true of stdout (which must hold exactly one JSON value).
jq_ok() {
  if ! printf '%s' "$output" | jq -e "$1" > /dev/null; then
    printf 'json check failed: %s\n--- stdout ---\n%s\n--------------\n' "$1" "$output"
    return 1
  fi
}

# ---- none --------------------------------------------------------------------------------------------------------

@test "policy none (the task default) prints exactly the message, exits 0 and runs and discovers nothing" {
  gate --scope task --id E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "no suite run (policy none)" ]
  [ "$(marks)" = "none" ]
  [ "$(discovery_calls)" = "0" ]
}

@test "policy none set explicitly for a story behaves the same" {
  cfg_with test_run_story none
  gate --scope story --id E99_S01
  [ "$status" -eq 0 ]
  [ "$output" = "no suite run (policy none)" ]
  [ "$(marks)" = "none" ]
}

@test "policy none ignores an unusable --rev (nothing is derived)" {
  gate --scope task --id E99_S01_T01 --rev not-a-commit
  [ "$status" -eq 0 ]
  [ "$output" = "no suite run (policy none)" ]
}

# ---- scoped: derivation ------------------------------------------------------------------------------------------

@test "scoped task runs only the suite mapped from that task's commits" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha" ]
  assert_output_contains "scope test gate: task E99_S01_T01, policy scoped"
  assert_output_contains "running 1 suite(s): alpha tests (unit)"
  assert_output_contains "1 passed, 0 failed"
  assert_output_contains "scope test gate: satisfied"
}

@test "a commit that merely mentions the task id (a rapport) does not widen the task's changed files" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01
  [ "$status" -eq 0 ]
  # the rapport commit edited src/gamma/g.sh; gamma must not have run
  [ "$(marks)" = "alpha" ]
}

@test "scoped task finds the work of a task branch through its merge commit" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S04_T01
  [ "$status" -eq 0 ]
  [ "$(marks)" = "delta" ]
}

@test "scoped story unions the commits of the tasks in its tasks: frontmatter list" {
  gate --scope story --id E99_S01
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha,beta" ]
  assert_output_contains "running 2 suite(s)"
  assert_output_contains "2 passed, 0 failed"
}

@test "scoped epic unions the commits of its stories' tasks (an inline stories: list)" {
  cfg_with test_run_epic scoped
  gate --scope epic --id E99
  [ "$status" -eq 0 ]
  # E99_S03 and E99_S04 are not listed in the epic, so docs-only and delta stay out
  [ "$(marks)" = "alpha,beta,gamma" ]
  assert_output_contains "running 3 suite(s)"
}

@test "discovery runs exactly once for a scoped run" {
  gate --scope story --id E99_S01
  [ "$status" -eq 0 ]
  [ "$(discovery_calls)" = "1" ]
}

@test "without the board files the id prefix finds the same commits for a story" {
  rm -rf "$REPO/project/board"
  gate --scope story --id E99_S01
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha,beta" ]
}

@test "without the board files the id prefix finds the same commits for an epic" {
  rm -rf "$REPO/project/board"
  cfg_with test_run_epic scoped
  gate --scope epic --id E99
  [ "$status" -eq 0 ]
  # the prefix has no epic membership list, so S03 (docs) and S04 (delta) join: all four areas but docs map to suites
  [ "$(marks)" = "alpha,beta,delta,gamma" ]
}

@test "a malformed entry in a tasks: list is ignored with a warning" {
  put project/board/stories/E99_S01_two-tasks.md '---
id: E99_S01
tasks:
  - E99_S01_T01
  - not-an-id
---'
  gate --scope story --id E99_S01
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha" ]
  assert_contains "$stderr" "not a well-formed id: not-an-id"
}

# ---- scoped: the explicit override ---------------------------------------------------------------------------------

@test "--rev overrides the derivation verbatim" {
  gate --scope story --id E99_S01 --rev "$SHA_GAMMA"
  [ "$status" -eq 0 ]
  [ "$(marks)" = "gamma" ]
  assert_output_contains "changed files: from --rev $SHA_GAMMA"
}

@test "--range overrides the derivation verbatim" {
  gate --scope story --id E99_S01 --range "$SHA_ALPHA..$SHA_BETA"
  [ "$status" -eq 0 ]
  # alpha's commit is the left side (excluded); the rapport commit (gamma) and beta's commit are in the range
  [ "$(marks)" = "beta,gamma" ]
  assert_output_contains "changed files: from --range $SHA_ALPHA..$SHA_BETA"
}

@test "--range maps the range even for an id that has no commits of its own" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S09_T09 --range "$SHA_ALPHA~1..$SHA_ALPHA"
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha" ]
}

# ---- scoped: fallbacks to the full catalog ---------------------------------------------------------------------------

@test "zero mapped suites says so and runs the full catalog" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S03_T01
  [ "$status" -eq 0 ]
  assert_output_contains "scoped policy: no suite maps to the changed files; falling back to the full catalog"
  [ "$(marks)" = "alpha,beta,delta,gamma" ]
  assert_output_contains "running 4 suite(s)"
}

@test "an id with no commits at all says so (distinct message) and runs the full catalog" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S09_T09
  [ "$status" -eq 0 ]
  assert_output_contains "scoped policy: no commits found for E99_S09_T09; falling back to the full catalog"
  assert_output_not_contains "no suite maps to the changed files"
  [ "$(marks)" = "alpha,beta,delta,gamma" ]
}

@test "a scoped run never exits 0 having executed nothing" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S03_T01
  [ "$status" -eq 0 ]
  [ "$(marks)" != "none" ]
}

@test "a fallback to an empty full catalog is exit 3" {
  printf '%s' '{"suites":[],"warnings":[]}' > "$DISC_STUB_JSON"
  cfg_with test_run_task scoped
  gate --scope task --id E99_S03_T01
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "an empty catalog is an error, not a pass"
  [ "$(marks)" = "none" ]
}

# ---- full ------------------------------------------------------------------------------------------------------------

@test "policy full runs the whole catalog (the epic default)" {
  gate --scope epic --id E99
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha,beta,delta,gamma" ]
  assert_output_contains "scope test gate: epic E99, policy full"
  assert_output_contains "4 passed, 0 failed"
  [ "$(discovery_calls)" = "1" ]
}

@test "policy full set for a task runs everything" {
  cfg_with test_run_task full
  gate --scope task --id E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha,beta,delta,gamma" ]
}

@test "policy full with an empty catalog is exit 3, not a pass" {
  printf '%s' '{"suites":[],"warnings":[]}' > "$DISC_STUB_JSON"
  gate --scope epic --id E99
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "no runnable test suite"
}

@test "policy full does not need a git repository" {
  local nogit="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$nogit/project/configs"
  printf '%s' '{}' > "$nogit/project/configs/workflow.json"
  printf '%s' '{"test_run_task":"full"}' > "$nogit/project/configs/test-config.json"
  run --separate-stderr "$BASH_BIN" "$GATE" --root "$nogit" --scope task --id E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha,beta,delta,gamma" ]
}

# ---- failing suite ---------------------------------------------------------------------------------------------------

@test "a failing suite gives exit 1 and the failure is in the summary" {
  export GAMMA_FAIL=1
  cfg_with test_run_task scoped
  gate --scope task --id E99_S02_T01
  [ "$status" -eq 1 ]
  [ "$(marks)" = "gamma" ]
  assert_output_contains "✗ gamma tests (unit)"
  assert_output_contains "0 passed, 1 failed"
  assert_output_contains "scope test gate: FAILED"
  assert_output_contains "do not close task E99_S02_T01"
}

@test "one failing suite among several still gives exit 1 and the others still ran" {
  export GAMMA_FAIL=1
  cfg_with test_run_epic scoped
  gate --scope epic --id E99
  [ "$status" -eq 1 ]
  [ "$(marks)" = "alpha,beta,gamma" ]
  assert_output_contains "2 passed, 1 failed"
}

@test "a failing suite under a full policy gives exit 1" {
  export GAMMA_FAIL=1
  gate --scope epic --id E99
  [ "$status" -eq 1 ]
}

# ---- configuration -----------------------------------------------------------------------------------------------------

@test "absent keys use the defaults: task none, story scoped, epic full" {
  gate --scope task --id E99_S01_T01
  [ "$output" = "no suite run (policy none)" ]
  gate --scope story --id E99_S01
  assert_output_contains "policy scoped"
  gate --scope epic --id E99
  assert_output_contains "policy full"
}

@test "an absent test-config.json also uses the defaults" {
  rm -f "$REPO/project/configs/test-config.json"
  gate --scope task --id E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "no suite run (policy none)" ]
  [ "$stderr" = "" ]
}

@test "an invalid config value uses the default with a warning on stderr" {
  cfg_with test_run_story banana
  gate --scope story --id E99_S01
  [ "$status" -eq 0 ]
  assert_contains "$stderr" "test_run_story"
  assert_contains "$stderr" 'using the default "scoped"'
  [ "$(marks)" = "alpha,beta" ]
}

@test "--config reads the policy from another file" {
  printf '%s' '{"test_run_task":"scoped","commit_scope_map_file":"project/scope-map.json"}' > "$BATS_TEST_TMPDIR/other.json"
  gate --scope task --id E99_S01_T01 --config "$BATS_TEST_TMPDIR/other.json"
  [ "$status" -eq 0 ]
  [ "$(marks)" = "alpha" ]
}

# ---- JSON ----------------------------------------------------------------------------------------------------------------

@test "--json prints one object that parses and carries effective_mode after a fallback" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S03_T01 --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
  jq_ok '.scope == "task" and .id == "E99_S03_T01" and .mode == "scoped" and .effective_mode == "full"'
  jq_ok '.fallback_reason == "no-mapped-suites" and .suites_run == 4 and .passed == 4 and .failed == 0'
  jq_ok '.exit_code == 0 and (.suites | length) == 4'
}

@test "--json after the no-commits fallback names that reason" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S09_T09 --json
  [ "$status" -eq 0 ]
  jq_ok '.effective_mode == "full" and .fallback_reason == "no-commits"'
}

@test "--json without a fallback has a null fallback_reason and equal modes" {
  gate --scope story --id E99_S01 --json
  [ "$status" -eq 0 ]
  jq_ok '.mode == "scoped" and .effective_mode == "scoped" and .fallback_reason == null'
  jq_ok '.suites_run == 2 and .passed == 2 and .failed == 0'
}

@test "--json keeps stdout to the object: human text and suite output go to stderr" {
  gate --scope story --id E99_S01 --json
  [ "$status" -eq 0 ]
  jq_ok 'type == "object"'
  assert_contains "$stderr" "Test Results"
  assert_contains "$stderr" "running 2 suite(s)"
}

@test "--json for a failing run carries the counts and exit_code 1" {
  export GAMMA_FAIL=1
  cfg_with test_run_task scoped
  gate --scope task --id E99_S02_T01 --json
  [ "$status" -eq 1 ]
  jq_ok '.failed == 1 and .passed == 0 and .exit_code == 1'
}

@test "--json under policy none reports zero suites" {
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 0 ]
  jq_ok '.mode == "none" and .effective_mode == "none" and .suites_run == 0 and .suites == [] and .fallback_reason == null'
}

# ---- usage and infrastructure errors ----------------------------------------------------------------------------------

@test "no arguments is a usage error" {
  gate
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "missing --scope"
  [ "$output" = "" ]
}

@test "an unknown scope is a usage error" {
  gate --scope sprint --id E99
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "unknown scope: sprint"
}

@test "a missing --id is a usage error" {
  gate --scope task
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "missing --id"
}

@test "an id that is malformed for the scope is a usage error" {
  gate --scope task --id E99_S01
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "not a task id"
  gate --scope story --id E99_S01_T01
  [ "$status" -eq 2 ]
  gate --scope epic --id E99_S01
  [ "$status" -eq 2 ]
  gate --scope epic --id e99
  [ "$status" -eq 2 ]
}

@test "--range together with --rev is a usage error" {
  gate --scope story --id E99_S01 --range "$SHA_ALPHA..$SHA_BETA" --rev "$SHA_GAMMA"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "at most one of --range and --rev"
}

@test "an unknown option is a usage error" {
  gate --scope task --id E99_S01_T01 --frobnicate
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "unknown argument: --frobnicate"
}

@test "an option without its argument is a usage error" {
  gate --scope task --id
  [ "$status" -eq 2 ]
}

@test "a --root that is not a directory is a usage error" {
  run --separate-stderr "$BASH_BIN" "$GATE" --root "$BATS_TEST_TMPDIR/nope" --scope task --id E99_S01_T01
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--root is not a directory"
}

@test "an unknown revision for --rev is a usage error under a scoped policy" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --rev 0000000000000000000000000000000000000000
  [ "$status" -eq 2 ]
  [ "$(marks)" = "none" ]
}

@test "a malformed --range is a usage error under a scoped policy" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --range nonsense
  [ "$status" -eq 2 ]
}

@test "--help prints the usage and exits 0" {
  gate --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: scope-test-gate.sh"
}

@test "a scoped policy without a git repository is exit 3" {
  local nogit="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$nogit/project/configs"
  printf '%s' '{}' > "$nogit/project/configs/workflow.json"
  printf '%s' '{"test_run_task":"scoped"}' > "$nogit/project/configs/test-config.json"
  run --separate-stderr "$BASH_BIN" "$GATE" --root "$nogit" --scope task --id E99_S01_T01
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "needs a git repository"
  [ "$(marks)" = "none" ]
}

@test "a missing helper script is exit 3" {
  rm "$PKG/skills/j-test/scripts/run-suites.sh"
  gate --scope epic --id E99
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "run-suites.sh"
}

# ---- the board is never touched ------------------------------------------------------------------------------------------

@test "the gate never modifies any file under project/board" {
  local before after
  before="$(board_snapshot)"
  [ -n "$before" ]
  set_cfg '{"commit_scope_map_file":"project/scope-map.json","test_run_task":"scoped","test_run_epic":"scoped"}'
  gate --scope task --id E99_S01_T01
  [ "$status" -eq 0 ]
  gate --scope story --id E99_S01
  [ "$status" -eq 0 ]
  gate --scope epic --id E99
  [ "$status" -eq 0 ]
  export GAMMA_FAIL=1
  gate --scope task --id E99_S02_T01
  [ "$status" -eq 1 ]
  after="$(board_snapshot)"
  [ "$before" = "$after" ]
}

@test "the gate leaves no scratch directory behind" {
  gate --scope story --id E99_S01
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}
