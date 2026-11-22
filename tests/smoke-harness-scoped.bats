#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E95_S01_T01: scripts/smoke-harness.sh never infers a runner.
#
# On 2026-11-15 the harness saw a package.json `test` script, ran `npm test`, and in this repository that is the
# whole bats suite (394 files, about 3 h) for a two-file change. The harness now runs only scripts/smoke.sh or the
# project's own scope map, and otherwise says "nothing verified" and exits 3. E95_S01_T03 added the third test: a
# mapped run in which every command is skipped also exits 3, never "passed" with nothing run.
#
# All tests run in a throwaway fixture git repository under $BATS_TEST_TMPDIR. The fixture's package.json `test`
# script, and stub `npm`, `pytest` and `go` commands placed first on PATH, all write a marker file, so any inferred
# runner leaves evidence. Neither test runs this repository's suite or nests bats in bats.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HARNESS="$REPO_ROOT/scripts/smoke-harness.sh"

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  MARKER="$BATS_TEST_TMPDIR/runner-was-invoked"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$FIXTURE/src" "$STUBS"

  for runner in npm pytest go; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$runner" "$MARKER" > "$STUBS/$runner"
    chmod +x "$STUBS/$runner"
  done

  git -C "$FIXTURE" init -q
  printf '{"name":"fixture","scripts":{"test":"echo npm-test >> %s"}}\n' "$MARKER" > "$FIXTURE/package.json"
  printf 'module.exports = 1;\n' > "$FIXTURE/src/app.js"
  printf '# Fixture\n' > "$FIXTURE/README.md"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" -c user.email=test@example.com -c user.name=Test commit -q -m "fixture: init"
}

run_harness() {
  cd "$FIXTURE"
  run env -u JENGA_PROJECT_ROOT PATH="$STUBS:$PATH" TMPDIR="$BATS_TEST_TMPDIR" /bin/bash "$HARNESS" "$@"
}

@test "smoke-harness: a non-docs change with no opt-in runs nothing and exits 3, even with an npm test script" {
  run_harness src/app.js
  echo "$output"
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -q '^smoke-harness: nothing verified (no opt-in)$'
  [ ! -e "$MARKER" ]
}

@test "smoke-harness: a docs-only change runs nothing and exits 0" {
  run_harness README.md notes.txt
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "smoke-harness: docs-only change, no suite run" ]
  [ ! -e "$MARKER" ]
}

@test "smoke-harness: a scope-mapped run whose every command is skipped exits 3, never a pass with nothing run" {
  # E95_S01_T03: the scope map opts in, but the only narrowed command is not `bats ...`, so the belt skips it.
  # resolve_helper looks in the checkout first, so the stub helpers below stand in for the real ones and emit
  # canned JSON; nothing real is discovered, mapped or run.
  mkdir -p "$FIXTURE/scripts" "$FIXTURE/skills/j-test/scripts" "$FIXTURE/project/configs"
  printf '{"commit_scope_map_file":"project/configs/test-scope-map.json"}\n' > "$FIXTURE/project/configs/test-config.json"
  printf '{"rules":[]}\n' > "$FIXTURE/project/configs/test-scope-map.json"
  printf '#!/bin/sh\necho "$(pwd)/project/configs"\n' > "$FIXTURE/scripts/resolve-root.sh"
  printf '#!/bin/sh\necho %s\n' "'{\"suites\":[{\"id\":\"x\",\"command\":\"x\"}]}'" \
    > "$FIXTURE/skills/j-test/scripts/discover-tests.sh"
  printf '#!/bin/sh\necho %s\n' "'{\"mapped_suites\":[\"x\"],\"mapped_tests\":{\"x\":[\"tests/a.bats\"]}}'" \
    > "$FIXTURE/skills/j-test/scripts/map-scope.sh"
  cat > "$FIXTURE/skills/j-test/scripts/narrow-suites.sh" <<STUB
#!/bin/sh
while [ \$# -gt 0 ]; do
  [ "\$1" = "--report" ] && printf '{"narrowed":[{"id":"x","emptied":false}],"excluded":[]}\n' > "\$2"
  shift
done
printf '{"suites":[{"id":"x","command":"echo skipped-command-ran >> $MARKER"}]}\n'
STUB

  run_harness src/app.js
  echo "$output"
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -q '^smoke-harness: not run (not a narrowed bats command): x$'
  printf '%s\n' "$output" | grep -q '^smoke-harness: nothing verified (no runnable mapped command)$'
  [[ "$output" != *"mapped tests passed"* ]]
  [ ! -e "$MARKER" ]
}
