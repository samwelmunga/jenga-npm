#!/usr/bin/env bats
#
# Regression coverage for the idea_manager.sh / todo_manager.sh TEMPLATE=
# path-resolution fix (E46_S06_T01).
#
# Both scripts.md declared TEMPLATE= as a literal, cwd-relative string with no
# self-relative resolution at all -- not a "../../../" climb (E46_S02's
# defect shape) and not a bare-reference-in-prose case (E46_S05's defect
# shape), but a third, distinct defect shape in the same E46 family: on a real
# consumer install, cwd is the consumer's own project root, so `$TEMPLATE`
# never resolved and the very first `/idea add` / `/todo add` invocation
# failed unconditionally.
#
# Fixed by deriving PACKAGE_ROOT from BASH_SOURCE (the same pattern already
# proven correct in scripts/jenga-permission-level-switch.sh), with a
# defensive node_modules/@jenga-ai/agent/-relative fallback matching the
# PKG_ROOT convention documented in docs/skill-authoring.md.
#
# Fixture pattern follows tests/consumer-path-fallback.bats's own
# mirror_as_npm_consumer helper (which -- unlike tests/init.bats's narrower
# version -- already copies scripts/ into the mirrored node_modules install,
# since it specifically exists to exercise scripts/ call sites). Extended
# here to also stage the two skills/j-idea, skills/j-todo asset directories
# the TEMPLATE= fallback needs.
#
# Every test below runs against a throwaway $BATS_TEST_TMPDIR, never against
# this repository's own contents.
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  CONSUMER_DIR="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER_DIR/project"
}

# Stages a real (copied, not symlinked) node_modules/@jenga-ai/agent/ mirror
# containing scripts/ (both manager scripts live there) plus the skills/j-idea
# and skills/j-todo asset directories the TEMPLATE= fallback resolves against.
# Models the real npm-consumer layout: a consumer's own project root has no
# bare scripts/ or skills/ at all -- postinstall.js never mirrors either.
mirror_as_npm_consumer() {
  mkdir -p "$CONSUMER_DIR/node_modules/@jenga-ai/agent/skills"
  cp -R "$REPO_ROOT/scripts" "$CONSUMER_DIR/node_modules/@jenga-ai/agent/"
  cp -R "$REPO_ROOT/skills/j-idea" "$CONSUMER_DIR/node_modules/@jenga-ai/agent/skills/"
  cp -R "$REPO_ROOT/skills/j-todo" "$CONSUMER_DIR/node_modules/@jenga-ai/agent/skills/"
}

# ---------------------------------------------------------------------------
# Primary path: PACKAGE_ROOT (BASH_SOURCE-derived) resolution.
#
# Invokes each manager script from its real mirrored location
# (node_modules/@jenga-ai/agent/scripts/<script>.sh, with its sibling
# skills/j-idea or skills/j-todo one level up), cwd = the consumer's own
# project root -- exactly how a real consumer's /idea or /todo invocation
# runs. PACKAGE_ROOT/BASH_SOURCE resolution alone must find the template;
# the node_modules-relative fallback is never reached in this scenario.
# ---------------------------------------------------------------------------

@test "idea_manager.sh add succeeds against a simulated fresh consumer install (PACKAGE_ROOT resolution)" {
  mirror_as_npm_consumer
  [ ! -f "$CONSUMER_DIR/project/ideas.md" ]

  cd "$CONSUMER_DIR"
  run bash node_modules/@jenga-ai/agent/scripts/idea_manager.sh add "first idea on a fresh install"
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER_DIR/project/ideas.md" ]

  run cat "$CONSUMER_DIR/project/ideas.md"
  assert_output_contains "first idea on a fresh install"
}

@test "todo_manager.sh add succeeds against a simulated fresh consumer install (PACKAGE_ROOT resolution)" {
  mirror_as_npm_consumer
  [ ! -f "$CONSUMER_DIR/project/todo.md" ]

  cd "$CONSUMER_DIR"
  run bash node_modules/@jenga-ai/agent/scripts/todo_manager.sh add "first todo on a fresh install"
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER_DIR/project/todo.md" ]

  run cat "$CONSUMER_DIR/project/todo.md"
  assert_output_contains "first todo on a fresh install"
}

# ---------------------------------------------------------------------------
# Fallback path: node_modules/@jenga-ai/agent/-relative resolution.
#
# Copies each manager script standalone (no sibling skills/ directory one
# level up), so PACKAGE_ROOT-derived resolution deliberately cannot find the
# template. cwd is a consumer project root that DOES have a real mirrored
# node_modules/@jenga-ai/agent/skills/... -- forcing the script down its
# fallback branch, which resolves the template relative to cwd instead.
# ---------------------------------------------------------------------------

@test "idea_manager.sh add falls back to node_modules/@jenga-ai/agent/... when PACKAGE_ROOT resolution fails" {
  mirror_as_npm_consumer
  STANDALONE="$BATS_TEST_TMPDIR/standalone"
  mkdir -p "$STANDALONE"
  cp "$REPO_ROOT/scripts/idea_manager.sh" "$STANDALONE/"

  cd "$CONSUMER_DIR"
  run bash "$STANDALONE/idea_manager.sh" add "fallback-resolved idea"
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER_DIR/project/ideas.md" ]

  run cat "$CONSUMER_DIR/project/ideas.md"
  assert_output_contains "fallback-resolved idea"
}

@test "todo_manager.sh add falls back to node_modules/@jenga-ai/agent/... when PACKAGE_ROOT resolution fails" {
  mirror_as_npm_consumer
  STANDALONE="$BATS_TEST_TMPDIR/standalone"
  mkdir -p "$STANDALONE"
  cp "$REPO_ROOT/scripts/todo_manager.sh" "$STANDALONE/"

  cd "$CONSUMER_DIR"
  run bash "$STANDALONE/todo_manager.sh" add "fallback-resolved todo"
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER_DIR/project/todo.md" ]

  run cat "$CONSUMER_DIR/project/todo.md"
  assert_output_contains "fallback-resolved todo"
}

# ---------------------------------------------------------------------------
# Negative case: neither resolution path finds the template -- errors
# loudly rather than silently succeeding or resolving to the wrong file.
# ---------------------------------------------------------------------------

@test "idea_manager.sh add errors clearly when neither PACKAGE_ROOT nor the node_modules fallback resolves" {
  STANDALONE="$BATS_TEST_TMPDIR/standalone-no-fallback"
  mkdir -p "$STANDALONE"
  cp "$REPO_ROOT/scripts/idea_manager.sh" "$STANDALONE/"

  cd "$CONSUMER_DIR"
  run bash "$STANDALONE/idea_manager.sh" add "should never be written"
  [ "$status" -ne 0 ]
  assert_output_contains "template not found"
  [ ! -f "$CONSUMER_DIR/project/ideas.md" ]
}
