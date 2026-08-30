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
# E46_S03: a second, related real bug report — a consumer whose very first
# action was a Copilot slash command (before ever running the separate
# `jenga init` CLI wizard) got a generic .github/copilot-instructions.md with
# no Jenga routing at all. Root cause: that file was only ever written by the
# interactive `jenga init` CLI wizard (lib/commands/init.js), never by
# scripts/postinstall.js, which runs unconditionally and non-interactively on
# every `npm install`. Fixed by extracting the generation logic into
# lib/generate-copilot-instructions.js (E46_S03_T01) and calling it
# unconditionally from postinstall.js right after the mirror step.
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

# Re-runs the exact function lib/commands/init.js calls to (re)generate
# .github/copilot-instructions.md — generateCopilotInstructions(projectRoot,
# packageRoot, skillsDir) from lib/generate-copilot-instructions.js — with a
# different skillsDir, modeling `jenga init`'s refinement pass after
# postinstall has already bootstrapped the file (E46_S03_T01).
#
# This calls the shared function directly rather than driving
# lib/commands/init.js's interactive readline wizard end-to-end: Node's
# readline, given a non-TTY input stream that already holds every answer line
# up front, drains and closes the stream before a later sequential
# rl.question() call is even registered, so only the first prompt of a
# piped-stdin multi-prompt wizard ever resolves. That is a general Node
# readline limitation independent of this test — not a gap in coverage, since
# the function below is the exact code path both scripts/postinstall.js and
# lib/commands/init.js call for this file.
refine_copilot_instructions_as_jenga_init() {
  cd "$CONSUMER_DIR" || return 1
  node -e "
    import('$REPO_ROOT/lib/generate-copilot-instructions.js').then((m) => {
      const result = m.generateCopilotInstructions(process.cwd(), '$REPO_ROOT', '.claude/skills');
      if (!result.written) { console.error('generateCopilotInstructions did not write'); process.exit(1); }
    }).catch((e) => { console.error(e.stack || e.message); process.exit(1); });
  "
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

@test "postinstall bootstraps a routable .github/copilot-instructions.md before jenga init has ever run (E46_S03_T01)" {
  mirror_as_npm_consumer
  local f="$CONSUMER_DIR/.github/copilot-instructions.md"
  [ -f "$f" ]

  run cat "$f"
  [ "$status" -eq 0 ]
  # JENGA managed-block markers present
  [[ "$output" == *"<!-- JENGA:START -->"* ]]
  [[ "$output" == *"<!-- JENGA:END -->"* ]]
  # The /skill-name routing convention text is present, not just a generic file
  [[ "$output" == *'Skills are invoked by typing `/skill-name`'* ]]
  # Skill list is populated from .agents/skills/ (mirrored by the same
  # postinstall run) rather than falling back to the empty-list placeholder
  [[ "$output" != *"_No skills found._"* ]]
  [[ "$output" == *"- **init**"* ]]
}

@test "a jenga-init-equivalent refinement pass after postinstall does not duplicate the JENGA block or corrupt content outside it (E46_S03_T01 idempotency)" {
  mirror_as_npm_consumer
  local f="$CONSUMER_DIR/.github/copilot-instructions.md"
  [ -f "$f" ]

  local before before_marker_count
  before="$(cat "$f")"
  before_marker_count="$(grep -c 'JENGA:START' "$f")"
  [ "$before_marker_count" -eq 1 ]

  run refine_copilot_instructions_as_jenga_init
  [ "$status" -eq 0 ]

  local after after_marker_count
  after="$(cat "$f")"
  after_marker_count="$(grep -c 'JENGA:START' "$f")"

  [ "$after_marker_count" -eq 1 ]
  # .claude/skills and .agents/skills are mirrored from the same source, so a
  # refinement pass using .claude/skills instead of .agents/skills produces a
  # byte-identical file — content outside (and inside) the markers is unchanged.
  [ "$after" = "$before" ]
}
