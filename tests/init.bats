#!/usr/bin/env bats
#
# Regression coverage for the /init clean-room scaffold flow.
#
# Added after a real npm install + /init produced only .claude/ and .agents/
# (from postinstall) with no project/ scaffold, no CLAUDE.md/AGENTS.md, and no
# git commit — on both Claude Code and GitHub Copilot. Root causes, both fixed
# alongside this test:
#   1. skills/init/SKILL.md told the agent to run a script path
#      ("skills/init/scripts/init.sh", relative to the project root) that only
#      exists in this monorepo checkout. A consumer install only has
#      .claude/skills/init/scripts/init.sh and .agents/skills/init/scripts/init.sh
#      — postinstall.js never mirrors a bare skills/ into the consumer root.
#   2. init.sh itself located templates/ and lib/ via a fixed "../../../" climb
#      from its own script directory. That climb only lands on templates/ and
#      lib/ when init.sh runs from its monorepo location — postinstall.js never
#      mirrors templates/ or lib/ at all (they're meant to be read from
#      node_modules/@jenga-ai/agent/ at runtime), so the same climb from a
#      mirrored copy resolves to nowhere and the scaffold aborted mid-run.
#
# Every test below runs against a throwaway $BATS_TEST_TMPDIR, never against
# this repository's own contents.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  CONSUMER_DIR="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER_DIR"
}

# Mirrors skills/ and agents/ into .claude/ and .agents/ via the real
# postinstall.js entry point (not a hand-rolled cp), so this test tracks
# actual mirroring behavior rather than a parallel reimplementation of it.
# Also stages a real (copied, not symlinked) node_modules/@jenga-ai/agent/
# lib+templates, matching what `npm install` produces for a consumer.
mirror_as_npm_consumer() {
  INIT_CWD="$CONSUMER_DIR" node "$REPO_ROOT/scripts/postinstall.js" >/dev/null
  mkdir -p "$CONSUMER_DIR/node_modules/@jenga-ai/agent"
  cp -R "$REPO_ROOT/lib" "$REPO_ROOT/templates" "$REPO_ROOT/package.json" \
    "$CONSUMER_DIR/node_modules/@jenga-ai/agent/"
}

# Resolves init.sh exactly the way skills/init/SKILL.md step 3 instructs an
# agent to (the .claude/ / .agents/ / bare-skills/ candidate search), then
# runs it. Defined as a function (not an inline string) so `run` can invoke
# it directly and bats' quoting stays sane.
run_init_as_consumer() {
  cd "$CONSUMER_DIR" || return 1
  local script=""
  for candidate in .claude/skills/init/scripts/init.sh .agents/skills/init/scripts/init.sh skills/init/scripts/init.sh; do
    [[ -f "$candidate" ]] && { script="$candidate"; break; }
  done
  [[ -n "$script" ]] || { echo "no init.sh found under .claude/, .agents/, or skills/" >&2; return 1; }
  bash "$script" --visibility visible
}

# Every artifact skills/init/scripts/init.sh's 13 steps are documented to produce.
assert_full_scaffold() {
  local dir="$1"
  [ -d "$dir/.git" ]
  [ -f "$dir/.gitignore" ]
  [ -f "$dir/project/PROJECT_SUMMARY.md" ]
  [ -f "$dir/project/configs/workflow.json" ]
  [ -f "$dir/project/configs/test-config.json" ]
  [ -f "$dir/project/data/baselines.json" ]
  [ -f "$dir/project/logs/events.json" ]
  [ -f "$dir/docs/STRATEGY.md" ]
  [ -f "$dir/CHANGELOG.md" ]
  [ -f "$dir/jenga.config.json" ]
  [ -f "$dir/CLAUDE.md" ]
  [ -f "$dir/AGENTS.md" ]

  run git -C "$dir" log --oneline
  [ "$status" -eq 0 ]
  [[ "$output" == *"init: scaffold project structure and workflow config"* ]]
}

@test "init.sh scaffolds a complete project when run directly against an empty directory" {
  run bash -c "cd '$CONSUMER_DIR' && bash '$REPO_ROOT/skills/init/scripts/init.sh' --visibility visible"
  [ "$status" -eq 0 ]
  assert_full_scaffold "$CONSUMER_DIR"
}

@test "SKILL.md's documented init.sh candidate paths resolve to a real file in a mirrored npm-consumer install" {
  mirror_as_npm_consumer
  cd "$CONSUMER_DIR"
  local_script=""
  for candidate in .claude/skills/init/scripts/init.sh .agents/skills/init/scripts/init.sh skills/init/scripts/init.sh; do
    [[ -f "$candidate" ]] && { local_script="$candidate"; break; }
  done
  [ "$local_script" = ".claude/skills/init/scripts/init.sh" ]
}

@test "init.sh scaffolds a complete project from a mirrored npm-consumer install (.claude/ + node_modules)" {
  mirror_as_npm_consumer
  run run_init_as_consumer
  [ "$status" -eq 0 ]
  assert_full_scaffold "$CONSUMER_DIR"
}

@test "init.sh fails loudly, not silently, when no package root (monorepo templates/ or node_modules/@jenga-ai/agent) can be found" {
  # No mirror_as_npm_consumer call: only .claude/ + .agents/ exist (from
  # postinstall), templates/ and node_modules/ are both absent.
  INIT_CWD="$CONSUMER_DIR" node "$REPO_ROOT/scripts/postinstall.js" >/dev/null
  run run_init_as_consumer
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not locate the jenga-agent package root"* ]]
}
