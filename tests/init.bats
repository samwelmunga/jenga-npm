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

# Every candidate path an init.sh consumer might need to check: the bare
# skills/init/ form (guaranteed on the private monorepo) and its skills/j-init/
# twin (the only form that ships on a public mirror checkout, since E28_S09/
# E28_S10 blocklist the canonical bare-name dir for every j-<name>-twinned
# skill — E28_S12 follow-up, 2026-09-06). Bare form checked first so the
# private monorepo's own layout is preferred when both exist.
INIT_SCRIPT_CANDIDATES=(
  .claude/skills/init/scripts/init.sh
  .claude/skills/j-init/scripts/init.sh
  .agents/skills/init/scripts/init.sh
  .agents/skills/j-init/scripts/init.sh
  skills/init/scripts/init.sh
  skills/j-init/scripts/init.sh
)

# Resolves init.sh exactly the way skills/init/SKILL.md step 3 instructs an
# agent to (the .claude/ / .agents/ / bare-skills/ candidate search, plus the
# j-init twin fallback above), then runs it. Defined as a function (not an
# inline string) so `run` can invoke it directly and bats' quoting stays sane.
run_init_as_consumer() {
  cd "$CONSUMER_DIR" || return 1
  local script=""
  for candidate in "${INIT_SCRIPT_CANDIDATES[@]}"; do
    [[ -f "$candidate" ]] && { script="$candidate"; break; }
  done
  [[ -n "$script" ]] || { echo "no init.sh found under .claude/, .agents/, or skills/ (bare or j-init form)" >&2; return 1; }
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

# Renders CLAUDE.md/AGENTS.md into $CONSUMER_DIR via the exact code path both
# skills/init/scripts/init.sh and lib/commands/init.js call for these files —
# generateAgentContext(projectRoot, packageRoot) from
# lib/generate-agent-context.js — modeling a consumer install rather than
# reimplementing the render logic inline. Mirrors
# refine_copilot_instructions_as_jenga_init's node -e dynamic-import pattern.
generate_agent_context_as_consumer() {
  cd "$CONSUMER_DIR" || return 1
  node -e "
    import('$REPO_ROOT/lib/generate-agent-context.js').then((m) => {
      const result = m.generateAgentContext(process.cwd(), '$REPO_ROOT');
      if (result.skipped || !result.written || result.written.length === 0) {
        console.error('generateAgentContext did not write'); process.exit(1);
      }
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
  local init_script="$REPO_ROOT/skills/init/scripts/init.sh"
  [[ -f "$init_script" ]] || init_script="$REPO_ROOT/skills/j-init/scripts/init.sh"
  run bash -c "cd '$CONSUMER_DIR' && bash '$init_script' --visibility visible"
  [ "$status" -eq 0 ]
  assert_full_scaffold "$CONSUMER_DIR"
}

@test "SKILL.md's documented init.sh candidate paths resolve to a real file in a mirrored npm-consumer install" {
  mirror_as_npm_consumer
  cd "$CONSUMER_DIR"
  local_script=""
  for candidate in "${INIT_SCRIPT_CANDIDATES[@]}"; do
    [[ -f "$candidate" ]] && { local_script="$candidate"; break; }
  done
  [[ "$local_script" == ".claude/skills/init/scripts/init.sh" || "$local_script" == ".claude/skills/j-init/scripts/init.sh" ]]
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
  # Accepts either the bare "init" entry (private monorepo) or "j-init" (a
  # public mirror checkout, where only the twin ships — E28_S12 follow-up)
  [[ "$output" == *"- **init**"* || "$output" == *"- **j-init**"* ]]
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

# E46_S04_T01 rewrote the "Skill Routing" section in both
# templates/copilot-instructions.md.tpl and templates/agent-context.md.tpl to
# spell out a mechanical open-SKILL.md-read-it-execute-it procedure, replacing
# the old "invoke the skill immediately using the slash-command syntax"
# wording that told an agent WHEN to route but never HOW. That gap was
# invisible for Claude Code (native /skill-name interception at the harness
# level) but load-bearing for GitHub Copilot/Codex, which have no equivalent
# and depend entirely on this prose — confirmed by a real repro where Copilot
# read the routing file correctly yet still improvised a response instead of
# opening .agents/skills/init/SKILL.md.
#
# IMPORTANT — coverage floor, not a behavioral guarantee: the two tests below
# only assert that the new mechanical instruction text renders correctly into
# the generated output files. They CANNOT assert that a real Copilot or Codex
# agent actually reads and follows that instruction differently than before —
# that depends on how reliably an LLM follows a more explicit imperative
# instruction, which no unit test in this repo can exercise. A future reader
# should not mistake "these tests pass" for "the underlying Copilot bug is
# confirmed fixed." Real-agent verification is tracked separately in
# project/instructions/E46_S04_INSTRUCTIONS.md (E46_S04_T02) and must be
# performed manually against a live Copilot (and ideally Codex) session.
@test "rendered .github/copilot-instructions.md contains the mechanical open-read-execute routing instruction, not the old slash-command-only wording (E46_S04_T01)" {
  mirror_as_npm_consumer
  local f="$CONSUMER_DIR/.github/copilot-instructions.md"
  [ -f "$f" ]

  run cat "$f"
  [ "$status" -eq 0 ]
  # New mechanical instruction present: open the target SKILL.md, read it in
  # full, execute it as written.
  [[ "$output" == *"SKILL.md"* ]]
  [[ "$output" == *"read it"* ]]
  [[ "$output" == *"execute its instructions exactly as written"* ]]
  [[ "$output" == *"Do not substitute your own judgment"* ]]
  # The old vague wording (route decision without an execution mechanism)
  # must be gone — asserting its absence is what actually catches a
  # regression back to the pre-E46_S04_T01 prose.
  [[ "$output" != *"invoke the skill immediately using the slash-command syntax"* ]]
}

@test "rendered CLAUDE.md and AGENTS.md contain the mechanical open-read-execute routing instruction with the correct per-target discovery path (E46_S04_T01)" {
  mirror_as_npm_consumer
  run generate_agent_context_as_consumer
  [ "$status" -eq 0 ]

  local claude_md="$CONSUMER_DIR/CLAUDE.md"
  local agents_md="$CONSUMER_DIR/AGENTS.md"
  [ -f "$claude_md" ]
  [ -f "$agents_md" ]

  run cat "$claude_md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"execute its instructions exactly as written"* ]]
  [[ "$output" == *"Do not substitute your own judgment"* ]]
  [[ "$output" != *"invoke the skill immediately using the slash-command syntax"* ]]
  # CLAUDE.md's discovery path is .claude/skills/ per generate-agent-context.js's TARGETS table
  [[ "$output" == *".claude/skills/<skill-name>/SKILL.md"* ]]

  run cat "$agents_md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"execute its instructions exactly as written"* ]]
  [[ "$output" == *"Do not substitute your own judgment"* ]]
  [[ "$output" != *"invoke the skill immediately using the slash-command syntax"* ]]
  # AGENTS.md's discovery path is .agents/skills/ per generate-agent-context.js's TARGETS table
  [[ "$output" == *".agents/skills/<skill-name>/SKILL.md"* ]]
}
