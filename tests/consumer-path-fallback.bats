#!/usr/bin/env bats
#
# Regression coverage for the scripts/ and templates/ node_modules-fallback
# idiom (E46_S05).
#
# postinstall.js only mirrors skills/ and agents/ into a consumer's .claude/
# and .agents/ -- scripts/ and templates/ stay inside
# node_modules/@jenga-ai/agent/ and must be reached via a fallback idiom
# documented in docs/skill-authoring.md. A real consumer on a published
# version hit "scripts/jenga-permission-level-switch.sh doesn't exist"
# because that exact call site had no fallback (E46_S05_T01); templates/ had
# the identical problem with no fallback idiom ever written for it at all
# (E46_S05_T02). This suite pins two representative sites -- one scripts/,
# one templates/ -- against a real mirrored npm-consumer layout so a future
# regression back to a bare reference is caught.
#
# Every test below runs against a throwaway $BATS_TEST_TMPDIR, never against
# this repository's own contents.
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  CONSUMER_DIR="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER_DIR"
}

# Mirrors skills/ and agents/ into .claude/ and .agents/ via the real
# postinstall.js entry point, then stages a real (copied, not symlinked)
# node_modules/@jenga-ai/agent/{scripts,templates,lib} plus package.json --
# matching what `npm install` produces for a consumer. Includes scripts/,
# unlike tests/init.bats's own mirror_as_npm_consumer helper, since that
# helper predates the scripts/ fallback fixes and this suite specifically
# needs to resolve a scripts/ call site.
mirror_as_npm_consumer() {
  INIT_CWD="$CONSUMER_DIR" node "$REPO_ROOT/scripts/postinstall.js" >/dev/null
  mkdir -p "$CONSUMER_DIR/node_modules/@jenga-ai/agent"
  cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/lib" "$REPO_ROOT/templates" "$REPO_ROOT/package.json" \
    "$CONSUMER_DIR/node_modules/@jenga-ai/agent/"
}

@test "skills/jenga-permission-level/SKILL.md's scripts/ fallback idiom resolves to a real file in a mirrored npm-consumer install (E46_S05_T01)" {
  mirror_as_npm_consumer

  # Pin the idiom's presence in the mirrored doc -- catches a future revert to
  # a bare `scripts/jenga-permission-level-switch.sh` reference.
  run cat "$CONSUMER_DIR/.claude/skills/jenga-permission-level/SKILL.md"
  [ "$status" -eq 0 ]
  assert_output_contains 'scripts/jenga-permission-level-switch.sh ] && echo scripts/jenga-permission-level-switch.sh || echo node_modules/@jenga-ai/agent/scripts/jenga-permission-level-switch.sh'

  # The consumer install has no bare scripts/ at its root (postinstall.js
  # never mirrors it) -- the idiom must fall through to node_modules/.
  cd "$CONSUMER_DIR" || return 1
  resolved="$([ -f scripts/jenga-permission-level-switch.sh ] && echo scripts/jenga-permission-level-switch.sh || echo node_modules/@jenga-ai/agent/scripts/jenga-permission-level-switch.sh)"
  [ "$resolved" = "node_modules/@jenga-ai/agent/scripts/jenga-permission-level-switch.sh" ]
  [ -f "$resolved" ]
}

@test "agents/developer.md's templates/ fallback idiom resolves to a real file in a mirrored npm-consumer install (E46_S05_T02)" {
  mirror_as_npm_consumer

  # Pin the idiom's presence in the mirrored doc -- catches a future revert to
  # a bare `templates/EXECUTION_SUMMARY_TEMPLATE.md` reference.
  run cat "$CONSUMER_DIR/.claude/agents/developer.md"
  [ "$status" -eq 0 ]
  assert_output_contains 'templates/EXECUTION_SUMMARY_TEMPLATE.md ] && echo templates/EXECUTION_SUMMARY_TEMPLATE.md || echo node_modules/@jenga-ai/agent/templates/EXECUTION_SUMMARY_TEMPLATE.md'

  # The consumer install has no bare templates/ at its root (postinstall.js
  # never mirrors it) -- the idiom must fall through to node_modules/.
  cd "$CONSUMER_DIR" || return 1
  resolved="$([ -f templates/EXECUTION_SUMMARY_TEMPLATE.md ] && echo templates/EXECUTION_SUMMARY_TEMPLATE.md || echo node_modules/@jenga-ai/agent/templates/EXECUTION_SUMMARY_TEMPLATE.md)"
  [ "$resolved" = "node_modules/@jenga-ai/agent/templates/EXECUTION_SUMMARY_TEMPLATE.md" ]
  [ -f "$resolved" ]
}
