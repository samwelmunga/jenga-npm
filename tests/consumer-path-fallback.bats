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

# ---------------------------------------------------------------------------
# Intra-script sibling resolution (E32_S15 follow-up).
#
# The two tests above pin the *doc-level* idiom -- a SKILL.md or agent .md
# reaching into scripts/. They never covered a shipped script reaching for a
# sibling script, which is how acquire/release-concurrency-slot.sh shipped
# hardcoding "$PROJECT_DIR/scripts/with-lock.sh": the skill layer correctly
# fell back to node_modules/ to reach the slot script, which then looked for
# with-lock.sh in a directory postinstall.js never populates, and died 5 on
# every consumer install.
# ---------------------------------------------------------------------------

@test "acquire-concurrency-slot.sh resolves with-lock.sh from a consumer install with no project-local scripts/ (E32_S15)" {
  mirror_as_npm_consumer
  mkdir -p "$CONSUMER_DIR/project/configs"
  cp "$REPO_ROOT/project/configs/scope-thresholds.json" "$CONSUMER_DIR/project/configs/"

  # The defining condition of the bug: the consumer has no scripts/ at its root.
  [ ! -d "$CONSUMER_DIR/scripts" ]

  run env JENGA_PROJECT_DIR="$CONSUMER_DIR" \
    "$CONSUMER_DIR/node_modules/@jenga-ai/agent/scripts/acquire-concurrency-slot.sh" \
    developer holderA sessA
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER_DIR/project/queue/concurrency-slots-sessA.json" ]
  run jq -r '.developer.holders.holderA' "$CONSUMER_DIR/project/queue/concurrency-slots-sessA.json"
  [ "$output" != "null" ]
}

@test "release-concurrency-slot.sh resolves with-lock.sh from the same consumer install (E32_S15)" {
  mirror_as_npm_consumer
  mkdir -p "$CONSUMER_DIR/project/configs"
  cp "$REPO_ROOT/project/configs/scope-thresholds.json" "$CONSUMER_DIR/project/configs/"
  PKG="$CONSUMER_DIR/node_modules/@jenga-ai/agent/scripts"

  run env JENGA_PROJECT_DIR="$CONSUMER_DIR" "$PKG/acquire-concurrency-slot.sh" developer holderA sessB
  [ "$status" -eq 0 ]
  run env JENGA_PROJECT_DIR="$CONSUMER_DIR" "$PKG/release-concurrency-slot.sh" developer holderA sessB
  [ "$status" -eq 0 ]

  # Slot actually freed, not just a silent exit 0.
  run jq -r '.developer.holders | length' "$CONSUMER_DIR/project/queue/concurrency-slots-sessB.json"
  [ "$output" -eq 0 ]
}

@test "the cap is still enforced through the node_modules-resolved lock (E32_S15)" {
  mirror_as_npm_consumer
  mkdir -p "$CONSUMER_DIR/project/configs"
  cp "$REPO_ROOT/project/configs/scope-thresholds.json" "$CONSUMER_DIR/project/configs/"
  PKG="$CONSUMER_DIR/node_modules/@jenga-ai/agent/scripts"
  cap="$(jq -r '.max_concurrent_developers' "$CONSUMER_DIR/project/configs/scope-thresholds.json")"

  for i in $(seq 1 "$cap"); do
    run env JENGA_PROJECT_DIR="$CONSUMER_DIR" "$PKG/acquire-concurrency-slot.sh" developer "h$i" sessC
    [ "$status" -eq 0 ]
  done

  # One past cap must be denied with exit 3 -- proving the lock/counter path
  # really ran rather than short-circuiting somewhere benign.
  run env JENGA_PROJECT_DIR="$CONSUMER_DIR" "$PKG/acquire-concurrency-slot.sh" developer overflow sessC
  [ "$status" -eq 3 ]
}
