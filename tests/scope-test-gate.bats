#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/scope-test-gate.sh (E72_S06_T03).
#
# The gate resolves the test-run mode of a board scope (task, story, epic) through scope-policy.sh and then runs nothing
# (none), the suites mapped from the scope's changed files (scoped) or the whole catalog (full), reporting through its
# exit code: 0 satisfied, 1 a suite failed, 2 usage error, 3 infrastructure error. This suite pins the contract in its
# header: the three modes, the changed-file derivation for a task, a story and an epic (and the --range/--rev override),
# the two ways a scoped derivation can produce nothing, the empty full catalog, the failing suite, the JSON object, the
# exit codes, and the promise that it never touches the board.
#
# E72_S08_T02 removed the escalation to the full catalog from both of those two ways, and they are now handled
# DIFFERENTLY FROM EACH OTHER: no-commits is an explicit non-pass (exit 3, nothing run, effective_mode stays "scoped")
# and no-mapped-suites runs E72_S08_T06's bounded default suite set (effective_mode "default-set"). BASE_CFG therefore
# carries a `test_default_suite_set`, so the floor is resolvable in every case; it names ONE of the fixture's four test
# files, which is what lets a case tell "the floor ran" apart from "everything ran".
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

# The policy file every case starts from: the scope map location and the bounded default suite set, so each POLICY key
# is absent (its default). The floor is `beta/*.bats` — one of the four fixture test files, so it is a non-empty strict
# subset of the runnable catalog, which is what resolve-default-suites.sh requires (E72_S08_T06).
BASE_CFG='{"commit_scope_map_file":"project/scope-map.json","test_default_suite_set":"beta/*.bats"}'

# cfg_floor <policy> <floor value>: BASE_CFG with test_run_task and a replacement floor, for the refusal cases.
cfg_floor() {
  set_cfg "$(printf '%s' "$BASE_CFG" | jq -c --arg p "$1" --arg f "$2"     '. + {test_run_task: $p, test_default_suite_set: $f}')"
}

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
  # E72_S07_T02 made skills/j-test/scripts/lib/glob-defs.jq a HARD dependency of
  # map-scope.sh and narrow-suites.sh (both die when it is absent), and the *.sh
  # glob above cannot see it. Copy the whole lib/ tree rather than a second glob,
  # so the next asset that is not a .jq cannot repeat the same omission.
  mkdir -p "$PKG/skills/j-test/scripts/lib"
  cp -R "$REPO_ROOT"/skills/j-test/scripts/lib/. "$PKG/skills/j-test/scripts/lib/"
  cp "$REPO_ROOT/scripts/resolve-root.sh" "$PKG/scripts/"
  cp "$REPO_ROOT/templates/test-scope-map.json" "$PKG/templates/"
  # The level-2 baseline template is a SHIPPED asset: baseline-permissions.sh
  # resolves it from the PACKAGE root, not from the consuming project (which
  # never carries templates/ — see that script's PATH CLASSIFICATION block). The
  # fixture below is a consuming-project tree by design, so the template has to
  # live here in $PKG or every scoped and every full case exit-3s on
  # "nothing was verified". Same fixture-gap class as the lib/ omission above.
  mkdir -p "$PKG/templates/permission-levels"
  cp "$REPO_ROOT/templates/permission-levels/level-2-guarded.json" "$PKG/templates/permission-levels/"
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

@test "without the board files the id prefix finds the same commits for an epic, and they select the whole catalog" {
  # E72_S08_T03 FLIPPED THIS CASE'S OUTCOME, legitimately. The prefix has no epic membership list, so S03 (docs) and S04
  # (delta) join and the change set maps to all four areas: that is the entire runnable catalog, which a scoped gate now
  # refuses instead of running. The case still pins what its title says (the prefix finds the commits of the whole epic),
  # through the derivation line, and the board-listed epic above is the strict-subset counterpart.
  rm -rf "$REPO/project/board"
  cfg_with test_run_epic scoped
  gate --scope epic --id E99 --json
  [ "$status" -eq 3 ]
  jq_ok '.refusal == "scoped-equals-full" and .suites_run == 0'
  assert_contains "$stderr" "commit(s) of E99"
  assert_contains "$stderr" "src/alpha/a.sh"
  [ "$(marks)" = "none" ]
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

# ---- scoped: nothing mapped (the bounded default set) and no commits (the explicit non-pass) ------------------------
#
# E72_S08_T02. Neither of these escalates to the full catalog any more. The gate under test is read directly in one of
# the cases below, because "no scoped path can run the full catalog" is a property of the script, not of one run.

@test "zero mapped suites runs the bounded default suite set, not the full catalog and not nothing" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S03_T01
  [ "$status" -eq 0 ]
  assert_output_contains "scoped policy: no suite maps to the changed files; running the bounded default suite set instead (never the full catalog)"
  assert_output_contains "bounded default suite set: bats:beta"
  assert_output_contains "running 1 suite(s): beta tests (unit)"
  # The floor, and nothing else. The behaviour this replaced ran all four.
  [ "$(marks)" = "beta" ]
}

# The source-text guard on run_full's call sites was REMOVED on 2026-11-02, deliberately, and is
# not to be reinstated in this form. It counted only a bare `run_full` alone on its own line, which
# made it wrong in both directions:
#   - FALSE NEGATIVE: `run_full || true` placed in the scoped path is syntactically clean, leaves
#     this count at 1, and still reintroduces the scoped-to-full escalation. Proved reachable with
#     a `die 99` probe inside run_full(), which fired.
#   - FALSE POSITIVE: renaming an unrelated variable (MAP_FILE_OUT -> MAP_RESULT) left behaviour
#     identical (64/64 green) and turned this case red.
# Hardening the regex to match compound forms is an arms race against bash syntax that still cannot
# see a call reached through a variable, an alias or `eval`. The durable instrument is a runtime
# assertion on what the gate DOES, which is blind to spelling.
# See project/rapports/problems/E72_S08-removed-error-generating-guards.md.
@test "the scoped-to-full escalation string is gone from the gate" {
  local gate_src="$REPO_ROOT/skills/j-test/scripts/scope-test-gate.sh"
  run grep -c "falling back to the full catalog" "$gate_src"
  [ "$output" = "0" ]
}

@test "an id with no commits at all is an explicit non-pass: exit 3, nothing run, its own message" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S09_T09
  [ "$status" -eq 3 ]
  assert_output_contains "scoped policy: no commits found for E99_S09_T09; nothing could be derived, so nothing was verified (not a pass)"
  assert_output_not_contains "no suite maps to the changed files"
  assert_output_not_contains "bounded default suite set"
  [ "$(marks)" = "none" ]
}

@test "a scoped run never exits 0 having executed nothing" {
  cfg_with test_run_task scoped
  # nothing mapped: the floor runs, so a 0 exit is backed by a suite that really ran
  gate --scope task --id E99_S03_T01
  [ "$status" -eq 0 ]
  [ "$(marks)" != "none" ]
  # no commits: nothing runs, so the exit is not 0
  rm -f "$RUN_MARK"
  gate --scope task --id E99_S09_T09
  [ "$status" -ne 0 ]
  [ "$(marks)" = "none" ]
}

@test "an empty change set behaves as the no-mapped-suites case" {
  cfg_with test_run_task scoped
  # A well-formed range from a commit to itself: no changed file at all.
  gate --scope task --id E99_S01_T01 --range "$SHA_ALPHA..$SHA_ALPHA"
  [ "$status" -eq 0 ]
  assert_output_contains "no suite maps to the changed files; running the bounded default suite set instead"
  [ "$(marks)" = "beta" ]
}

@test "an empty discovery leaves the bounded default suite set nothing to run: exit 3, never a pass" {
  printf '%s' '{"suites":[],"warnings":[]}' > "$DISC_STUB_JSON"
  cfg_with test_run_task scoped
  gate --scope task --id E99_S03_T01
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "resolves to no runnable test file"
  assert_contains "$stderr" "nothing was verified, so this is not a pass"
  [ "$(marks)" = "none" ]
}

@test "an unconfigured bounded default suite set is exit 3 naming the key, never a pass" {
  cfg_floor scoped ""
  gate --scope task --id E99_S03_T01
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "the bounded default suite set is not configured (test_default_suite_set"
  [ "$(marks)" = "none" ]
}

@test "a bounded default suite set equal to the whole catalog is refused, not run" {
  cfg_floor scoped "alpha/*.bats,beta/*.bats,delta/*.bats,gamma/*.bats"
  gate --scope task --id E99_S03_T01
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "resolves to the ENTIRE runnable catalog"
  assert_contains "$stderr" "a scoped gate must never amount to a full one"
  [ "$(marks)" = "none" ]
}

@test "an invalid bounded default suite set value is exit 3, never a silent substitution" {
  cfg_floor scoped "beta/*.bats,,delta/*.bats"
  gate --scope task --id E99_S03_T01
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "the configured bounded default suite set is invalid"
  [ "$(marks)" = "none" ]
}

# ---- full ------------------------------------------------------------------------------------------------------------

@test "policy full runs the whole catalog" {
  cfg_with test_run_epic full
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
  cfg_with test_run_epic full
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
  cfg_with test_run_epic full
  gate --scope epic --id E99
  [ "$status" -eq 1 ]
}

# ---- configuration -----------------------------------------------------------------------------------------------------

@test "absent keys use the defaults: task none, story scoped, epic none" {
  gate --scope task --id E99_S01_T01
  [ "$output" = "no suite run (policy none)" ]
  gate --scope story --id E99_S01
  assert_output_contains "policy scoped"
  gate --scope epic --id E99
  [ "$output" = "no suite run (policy none)" ]
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

@test "--json prints one object that parses and reports effective_mode default-set when the floor ran" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S03_T01 --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
  jq_ok '.scope == "task" and .id == "E99_S03_T01" and .mode == "scoped" and .effective_mode == "default-set"'
  jq_ok '.fallback_reason == "no-mapped-suites" and .suites_run == 1 and .passed == 1 and .failed == 0'
  jq_ok '.exit_code == 0 and .suites == ["beta tests (unit)"]'
}

@test "--json after the no-commits non-pass names that reason, reports exit_code 3 and ran nothing" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S09_T09 --json
  [ "$status" -eq 3 ]
  # The object IS printed for this exit 3: it is a verdict about the scope, not a broken gate.
  [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
  jq_ok '.mode == "scoped" and .effective_mode == "scoped" and .fallback_reason == "no-commits"'
  jq_ok '.suites_run == 0 and .suites == [] and .passed == 0 and .failed == 0 and .exit_code == 3'
  [ "$(marks)" = "none" ]
}

@test "--json tells all three outcomes apart from the object alone, and neither cause reports full" {
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --json            # a mapped selection ran
  jq_ok '.effective_mode == "scoped" and .fallback_reason == null'
  gate --scope task --id E99_S03_T01 --json            # nothing mapped, so the floor ran
  jq_ok '.effective_mode == "default-set" and .fallback_reason == "no-mapped-suites"'
  jq_ok '.effective_mode != "full"'
  gate --scope task --id E99_S09_T09 --json            # no commits: the non-pass
  jq_ok '.effective_mode != "full"'
  cfg_with test_run_task full
  gate --scope task --id E99_S01_T01 --json            # the full catalog ran
  jq_ok '.effective_mode == "full" and .fallback_reason == null'
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

# ---- a declared map omission, and the path that supersedes it (E72_S07_T03, fix round 3) --------------------------------
#
# The map DECLARES delta/d.bats as a deliberate omission and drops the delta rule, so delta is never mapped. On the
# scoped path the gate must report it as kept out; on the fallback to the full catalog the delta suite RUNS, so the gate
# must NOT report it as "NOT verified, and NOT a pass" — the defect these four cases pin. The two paths get two
# mutually exclusive messages and two separate JSON keys, and map_excluded_test_files never names a file that ran.

EXCL_MAP='{"map_version":1,
  "excluded_tests":[{"file":"delta/d.bats","reason":"a declared fixture omission, so the deliberate case is visible"}],
  "rules":[
  {"source":"src/alpha/*.sh","tests":["alpha/*.bats"]},
  {"source":"src/beta/*.sh","tests":["beta/*.bats"]},
  {"source":"src/gamma/*.sh","tests":["gamma/*.bats"]}]}'

set_excl_map() { put project/scope-map.json "$EXCL_MAP"; }

@test "a declared map omission on the scoped path is reported as kept out" {
  set_excl_map
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01
  [ "$status" -eq 0 ]
  assert_output_contains "deliberately not selected by the scope map (NOT verified, and NOT a pass):"
  assert_output_contains "delta/d.bats"
  assert_output_not_contains "NOT in force on this path"
  # The exclusion really is in force: only the mapped alpha suite ran.
  [ "$(marks)" = "alpha" ]
}

@test "the bounded default set does not run the declared omission, so it stays kept out and nothing is superseded" {
  # E72_S08_T02 requirement (b), and the DIRECTION is the whole point. Until this task this path ran the full catalog,
  # which really did execute delta/d.bats, so the declaration genuinely WAS superseded and was announced as WILL RUN.
  # The floor runs only beta/*.bats, so the declaration is back IN FORCE: announcing it as superseded would claim
  # "WILL RUN and WILL be verified" about a file the run never executes — the mirror image of, and the same defect as,
  # the claim fix round 3 of E72_S07_T03 removed.
  set_excl_map
  cfg_with test_run_task scoped
  gate --scope task --id E99_S03_T01
  [ "$status" -eq 0 ]
  assert_output_contains "running the bounded default suite set instead"
  assert_output_contains "deliberately not selected by the scope map (NOT verified, and NOT a pass):"
  assert_output_contains "delta/d.bats"
  assert_output_not_contains "WILL RUN and WILL be verified"
  assert_output_not_contains "NOT in force"
  # And it genuinely did not run, which is what makes "kept out" the true statement here.
  [ "$(marks)" = "beta" ]
}

@test "--json on the no-mapped-suites path keeps map-scope's reporting and reports map_exclusions_superseded []" {
  set_excl_map
  cfg_with test_run_task scoped
  gate --scope task --id E99_S03_T01 --json
  [ "$status" -eq 0 ]
  jq_ok '.effective_mode == "default-set" and .fallback_reason == "no-mapped-suites"'
  # (a) map-scope.sh's two reporting keys survive the new path: neither is emptied, relocated or re-derived.
  jq_ok '[.map_excluded_test_files[].file] == ["delta/d.bats"]'
  jq_ok '.map_excluded_test_files[0].reason | length > 0'
  jq_ok '.map_exclusion_conflicts == []'
  # (b) nothing is superseded, because the floor runs none of the declared files.
  jq_ok '.map_exclusions_superseded == []'
  [ "$(marks)" = "beta" ]
}

@test "a declared omission the bounded default set DOES run is superseded and leaves map_excluded_test_files" {
  # The converse, so the sense of the key is pinned in BOTH directions rather than by a constant []. The floor is
  # configured independently of the scope map, so it CAN name a declared file; when it does, that file really runs and
  # must not be reported as kept out.
  set_excl_map
  cfg_floor scoped "delta/*.bats"
  gate --scope task --id E99_S03_T01 --json
  [ "$status" -eq 0 ]
  jq_ok '.effective_mode == "default-set" and .fallback_reason == "no-mapped-suites"'
  jq_ok '.map_excluded_test_files == []'
  jq_ok '[.map_exclusions_superseded[].file] == ["delta/d.bats"]'
  jq_ok '.map_exclusions_superseded[0].reason | length > 0'
  jq_ok '.map_exclusion_conflicts == []'
  assert_contains "$stderr" "WILL RUN and WILL be verified"
  [ "$(marks)" = "delta" ]
}

@test "--json on the scoped path keeps the declaration in map_excluded_test_files and supersedes nothing" {
  set_excl_map
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 0 ]
  jq_ok '.effective_mode == "scoped" and .fallback_reason == null'
  jq_ok '[.map_excluded_test_files[].file] == ["delta/d.bats"]'
  jq_ok '.map_exclusions_superseded == []'
}

@test "policy full consults no map, so neither exclusion key is populated and nothing is claimed" {
  # Documented, not changed: under `full` the map exclusion has no effect at all and no notice is printed. The declared
  # file simply runs. That is silent rather than false, and it is the epic default — see
  # project/documentation/test-runner.md, "A declared map omission under policy full".
  set_excl_map
  cfg_with test_run_task full
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 0 ]
  jq_ok '.mode == "full" and .map_excluded_test_files == [] and .map_exclusions_superseded == []'
  assert_not_contains "$stderr" "deliberately not selected by the scope map"
  assert_not_contains "$stderr" "NOT in force on this path"
  [ "$(marks)" = "alpha,beta,delta,gamma" ]
}

@test "the no-commits non-pass consults no map either, so both exclusion keys stay empty" {
  set_excl_map
  cfg_with test_run_task scoped
  gate --scope task --id E99_S09_T09 --json
  [ "$status" -eq 3 ]
  jq_ok '.fallback_reason == "no-commits" and .map_excluded_test_files == [] and .map_exclusions_superseded == []'
  assert_not_contains "$stderr" "deliberately not selected by the scope map"
  assert_not_contains "$stderr" "NOT in force"
  [ "$(marks)" = "none" ]
}

# ---- the standing invariant: a scoped run is never the whole catalog (E72_S08_T03) -------------------------------------
#
# Every case here RUNS the gate against a fixture and asserts on its exit code, its output and what actually executed.
# None reads the gate's source text: such guards were removed in c65b228f as wrong in both directions, and the previous
# attempt at this task died by writing a checker and a test that matched only each other.
#
# What "the same as a full run" means is ONE definition (see the gate's header): the units of a catalog are the test files
# its `bats` entries expand to, plus the command text of every entry that cannot be expanded. The test files are what is
# compared whenever the full run has any (an opaque suite such as shellcheck cannot be selected by a scope map, so
# requiring it would make the invariant vacuous); an all-opaque catalog is compared on its commands. A scoped run is
# refused iff its compared units contain every one of the catalog a `full` policy would run. So the routes below are all
# the same refusal reached through different data, and the controls beside each pin the opposite verdict:
#   - a coarse rule, with the narrowed command spelled differently from the full one
#   - an npm twin of a bats suite, resolved through package.json
#   - an opaque suite selected as well, and one that is not and cannot be
#   - a floor that equals the full run only AFTER the level-2 baseline exclusion
#   - a catalog of opaque suites only
# `bats` is a recording shim on PATH, so "which files ran" is the content of one file and no real bats ever runs.

use_bats_shim() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  BATS_ARGS_LOG="$BATS_TEST_TMPDIR/bats-args"
  export BATS_ARGS_LOG
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$BATS_ARGS_LOG"' > "$BATS_TEST_TMPDIR/bin/bats"
  chmod +x "$BATS_TEST_TMPDIR/bin/bats"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# bats_ran: the arguments of the one `bats` call, or "none" when bats never ran.
bats_ran() {
  if [ -f "$BATS_ARGS_LOG" ]; then cat "$BATS_ARGS_LOG"; else printf 'none'; fi
}

# One bats suite over the four areas. Its command is a GLOB, so a narrowed run is spelled differently (explicit files).
BATS_ALL='{"id":"bats:all","name":"all tests","type":"unit","ecosystem":"bats","command":"bats alpha/*.bats beta/*.bats delta/*.bats gamma/*.bats","paths":["alpha/*.bats","beta/*.bats","delta/*.bats","gamma/*.bats"]}'
# An opaque suite: no paths, so no file universe can say what it runs. A .js test file maps to it by extension.
NPM_OPAQUE='{"id":"npm:unit","name":"npm unit","type":"unit","ecosystem":"npm","command":"echo npm >> \"$RUN_MARK\"","paths":[]}'

set_disc() { printf '{"suites":[%s],"warnings":[]}' "$1" > "$DISC_STUB_JSON"; }

# set_rule_map <json array of test globs>: one rule, a change to src/alpha/*.sh selects those tests.
set_rule_map() {
  put project/scope-map.json "$(jq -cn --argjson t "$1" '{map_version:1, rules:[{source:"src/alpha/*.sh", tests:$t}]}')"
}

# tests_fixture: three test files under tests/ (the only place a baseline-marked file is looked for), one suite over them.
tests_fixture() {
  put tests/one.bats '@test one { true; }'
  put tests/two.bats '@test two { true; }'
  put tests/three.bats "# jenga:requires-baseline-permissions: needs the level-2 baseline
x three"
  set_disc '{"id":"bats:tests","name":"tests","type":"unit","ecosystem":"bats","command":"bats tests/*.bats","paths":["tests/*.bats"]}'
}

# elevate: the session sits off the level-2 baseline, so the marked file cannot pass and is excluded from every run.
elevate() {
  mkdir -p "$REPO/.claude"
  cp "$REPO_ROOT/templates/permission-levels/level-5-unrestricted.json" "$REPO/.claude/settings.json"
}

@test "a coarse rule selecting every test file is refused: nothing runs, exit 3, and the cause is named" {
  use_bats_shim
  set_disc "$BATS_ALL"
  set_rule_map '["alpha/*.bats","beta/*.bats","delta/*.bats","gamma/*.bats"]'
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 3 ]
  jq_ok '.suites_run == 0 and .suites == [] and .passed == 0 and .failed == 0'
  jq_ok '.mode == "scoped" and .effective_mode == "scoped" and .exit_code == 3'
  jq_ok '.refusal == "scoped-equals-full" and .fallback_reason == null'
  [ "$(bats_ran)" = "none" ]
  [ "$(marks)" = "none" ]
  # Said in words, with the cause pointing at the rule and the suite definition, not just stating a fact.
  assert_contains "$stderr" "REFUSED"
  assert_contains "$stderr" "rule 1: src/alpha/*.sh"
  assert_contains "$stderr" "bats:all"
  assert_contains "$stderr" "test_run_task"
  # The refusal is reached without a second discovery pass.
  [ "$(discovery_calls)" = "1" ]
}

@test "the same refusal in the human output: stdout carries the verdict and the gate does not claim satisfaction" {
  use_bats_shim
  set_disc "$BATS_ALL"
  set_rule_map '["alpha/*.bats","beta/*.bats","delta/*.bats","gamma/*.bats"]'
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01
  [ "$status" -eq 3 ]
  assert_output_contains "REFUSED"
  assert_output_not_contains "scope test gate: satisfied"
  [ "$(bats_ran)" = "none" ]
}

@test "a scoped selection that is a strict subset of the files is unaffected: same files, exit 0, refusal null" {
  use_bats_shim
  set_disc "$BATS_ALL"
  set_rule_map '["alpha/*.bats","beta/*.bats","delta/*.bats"]'
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 0 ]
  jq_ok 'has("refusal") and .refusal == null'
  jq_ok '.effective_mode == "scoped" and .suites_run == 1 and .exit_code == 0'
  [ "$(bats_ran)" = "alpha/a.bats beta/b.bats delta/d.bats" ]
}

@test "policy full is never subject to the invariant: the same coarse map, the whole catalog runs" {
  use_bats_shim
  set_disc "$BATS_ALL"
  set_rule_map '["alpha/*.bats","beta/*.bats","delta/*.bats","gamma/*.bats"]'
  cfg_with test_run_task full
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 0 ]
  jq_ok '.mode == "full" and .effective_mode == "full" and .refusal == null and .suites_run == 1'
  [ "$(bats_ran)" = "alpha/a.bats beta/b.bats delta/d.bats gamma/g.bats" ]
}

@test "an opaque suite selected together with every test file is the whole catalog and is refused" {
  use_bats_shim
  put js/a.test.js 'x'
  set_disc "$BATS_ALL,$NPM_OPAQUE"
  set_rule_map '["alpha/*.bats","beta/*.bats","delta/*.bats","gamma/*.bats","js/a.test.js"]'
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 3 ]
  jq_ok '.refusal == "scoped-equals-full" and .suites_run == 0 and .effective_mode == "scoped"'
  [ "$(bats_ran)" = "none" ]
  [ "$(marks)" = "none" ]
}

@test "every test file selected is refused even though an unselectable opaque suite never ran: the files are the measure" {
  # This repository's own shape: bats:tests plus shellcheck:all. No scope-map rule can select shellcheck:all (it has no
  # test files), so a comparison that required the opaque suite too would make the invariant vacuous here, and a rule
  # selecting every test file would pass as "smaller" while being the hour-long run this story exists to remove.
  # Refusing is the safe direction, and it is what the task's own example describes.
  use_bats_shim
  set_disc "$BATS_ALL"',{"id":"shellcheck:all","name":"shellcheck","type":"sast","ecosystem":"shellcheck","command":"echo shellcheck >> \"$RUN_MARK\"","paths":[]}'
  set_rule_map '["alpha/*.bats","beta/*.bats","delta/*.bats","gamma/*.bats"]'
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 3 ]
  jq_ok '.refusal == "scoped-equals-full" and .suites_run == 0'
  assert_contains "$stderr" "4 test file(s)"
  [ "$(bats_ran)" = "none" ]
  [ "$(marks)" = "none" ]
}

@test "an all-opaque catalog is compared on its commands: selecting every one is refused, leaving one out is not" {
  # With no test file in the reference there is nothing else to compare. Two npm suites are selected together by the
  # .js -> npm extension fallback; a third suite of another ecosystem cannot be selected by any rule.
  put js/a.test.js 'x'
  local npm_a npm_b other
  npm_a='{"id":"npm:a","name":"npm a","type":"unit","ecosystem":"npm","command":"echo a >> \"$RUN_MARK\"","paths":[]}'
  npm_b='{"id":"npm:b","name":"npm b","type":"unit","ecosystem":"npm","command":"echo b >> \"$RUN_MARK\"","paths":[]}'
  other='{"id":"make:c","name":"make c","type":"unit","ecosystem":"make","command":"echo c >> \"$RUN_MARK\"","paths":[]}'
  set_rule_map '["js/a.test.js"]'
  cfg_with test_run_task scoped
  set_disc "$npm_a,$npm_b"
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 3 ]
  jq_ok '.refusal == "scoped-equals-full" and .suites_run == 0'
  assert_contains "$stderr" "2 opaque suite command(s)"
  [ "$(marks)" = "none" ]
  set_disc "$npm_a,$npm_b,$other"
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 0 ]
  jq_ok '.refusal == null and .suites_run == 2'
  [ "$(marks)" = "a,b" ]
}

@test "an npm twin is the same files as the bats suite it runs, so selecting them all is refused" {
  # `npm test` is opaque text, but its package.json body is the bats command. Compared as text the full run would have
  # one unit the narrowed run can never contain, and the whole catalog would pass as a subset.
  use_bats_shim
  printf '%s\n' '{"scripts":{"test":"bats alpha/*.bats beta/*.bats delta/*.bats gamma/*.bats"}}' > "$REPO/package.json"
  set_disc "$BATS_ALL,"'{"id":"npm:test","name":"npm test","type":"unit","ecosystem":"npm","command":"npm test","paths":[]}'
  set_rule_map '["alpha/*.bats","beta/*.bats","delta/*.bats","gamma/*.bats"]'
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 3 ]
  jq_ok '.refusal == "scoped-equals-full" and .suites_run == 0'
  [ "$(bats_ran)" = "none" ]
}

@test "a floor that is the whole catalog only AFTER the baseline exclusion is refused, naming test_default_suite_set" {
  # Before exclusion the floor is 2 of 3 files, a strict subset, so the floor resolver accepts it. The session is off the
  # level-2 baseline, tests/three.bats is marked and excluded from every run, and what is left IS what a full run
  # executes. Nothing special-cases this: it is data (a config value, a marked file, a settings file).
  use_bats_shim
  tests_fixture
  elevate
  cfg_floor scoped "tests/one.bats,tests/two.bats"
  gate --scope task --id E99_S03_T01 --json
  [ "$status" -eq 3 ]
  jq_ok '.refusal == "scoped-equals-full" and .suites_run == 0 and .effective_mode == "scoped"'
  jq_ok '.fallback_reason == "no-mapped-suites"'
  assert_contains "$stderr" "test_default_suite_set"
  assert_not_contains "$stderr" "rule 1"
  [ "$(bats_ran)" = "none" ]
}

@test "the same floor with the baseline satisfied is a strict subset of the 3 files a full run executes and runs" {
  use_bats_shim
  tests_fixture
  cfg_floor scoped "tests/one.bats,tests/two.bats"
  gate --scope task --id E99_S03_T01 --json
  [ "$status" -eq 0 ]
  jq_ok '.refusal == null and .effective_mode == "default-set" and .suites_run == 1'
  [ "$(bats_ran)" = "tests/one.bats tests/two.bats" ]
}

@test "an opaque suite the full run had to disable cannot hide a run that covers every test file" {
  # Off the baseline a full run has to disable the opaque suite (it cannot honour the exclusion), but a scoped run that
  # never touches the marked file keeps it. The scoped run then contains everything the full run does, and more.
  use_bats_shim
  tests_fixture
  put js/a.test.js 'x'
  set_disc "$(jq -c '.suites[0]' "$DISC_STUB_JSON"),$NPM_OPAQUE"
  elevate
  set_rule_map '["tests/one.bats","tests/two.bats","js/a.test.js"]'
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 3 ]
  jq_ok '.refusal == "scoped-equals-full" and .suites_run == 0'
  [ "$(bats_ran)" = "none" ]
  [ "$(marks)" = "none" ]
}

@test "a catalog with exactly one test file cannot be scoped: refused with the remedy, and policy full still runs it" {
  # Decision: no exemption. scoped == full is unavoidable here, and the floor resolver refuses an entire-catalog floor
  # whatever the catalog's size, so the same answer is given on both paths. `full` is the deliberate way to run it.
  use_bats_shim
  set_disc '{"id":"bats:alpha","name":"alpha","type":"unit","ecosystem":"bats","command":"bats alpha/*.bats","paths":["alpha/*.bats"]}'
  set_rule_map '["alpha/*.bats"]'
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 3 ]
  jq_ok '.refusal == "scoped-equals-full" and .suites_run == 0'
  assert_contains "$stderr" "exactly one test file"
  assert_contains "$stderr" "set test_run_task to full"
  [ "$(bats_ran)" = "none" ]
  cfg_with test_run_task full
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 0 ]
  jq_ok '.effective_mode == "full" and .refusal == null'
  [ "$(bats_ran)" = "alpha/a.bats" ]
}

@test "a bats command the gate cannot expand safely fails closed: exit 3, stdout empty, nothing runs" {
  use_bats_shim
  set_disc '{"id":"bats:dyn","name":"dyn","type":"unit","ecosystem":"bats","command":"bats $(echo alpha/*.bats)","paths":["alpha/*.bats"]},'"$NPM_OPAQUE"
  set_rule_map '["alpha/*.bats"]'
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01
  [ "$status" -eq 3 ]
  assert_output_not_contains "satisfied"
  assert_contains "$stderr" "cannot prove the scoped run is smaller than a full run"
  [ "$(bats_ran)" = "none" ]
}

@test "the refusal still reports the map's declared omission as kept out, and keeps both map keys consistent" {
  # The kept-out notice is printed before the catalog is reached. A refusal runs nothing, so the declared file is
  # genuinely not verified and the statement stays true; this pins that the refusal path does not drop it.
  use_bats_shim
  set_disc "$BATS_ALL"
  put project/scope-map.json '{"map_version":1,
    "excluded_tests":[{"file":"nowhere/x.bats","reason":"a declared omission outside the catalog"}],
    "rules":[{"source":"src/alpha/*.sh","tests":["alpha/*.bats","beta/*.bats","delta/*.bats","gamma/*.bats"]}]}'
  cfg_with test_run_task scoped
  gate --scope task --id E99_S01_T01 --json
  [ "$status" -eq 3 ]
  jq_ok '.refusal == "scoped-equals-full"'
  jq_ok '[.map_excluded_test_files[].file] == ["nowhere/x.bats"] and .map_exclusion_conflicts == [] and .map_exclusions_superseded == []'
  assert_contains "$stderr" "deliberately not selected by the scope map"
}

@test "a refusal is a verdict about the scope: it never touches the board and leaves no scratch directory" {
  use_bats_shim
  set_disc "$BATS_ALL"
  set_rule_map '["alpha/*.bats","beta/*.bats","delta/*.bats","gamma/*.bats"]'
  cfg_with test_run_task scoped
  local before
  before="$(board_snapshot)"
  gate --scope task --id E99_S01_T01
  [ "$status" -eq 3 ]
  [ "$before" = "$(board_snapshot)" ]
  [ -z "$(ls -A "$TMPDIR")" ]
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
