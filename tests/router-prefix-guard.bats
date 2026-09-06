#!/usr/bin/env bats
#
# Regression coverage for the Jenga Router's Stage 1 invocation-prefix guard
# (E50_S07_T02).
#
# Why this file exists
# --------------------
# E50_S02_T03 added an anti-masquerading allow-list guard to
# `mcp/router/index.js`'s `route_prompt`: a prompt shaped like a deliberate
# Jenga invocation is only auto-trusted as passthrough if the identifier after
# the prefix names a real skill. E50_S07_T01 then changed the canonical
# separator from `j:` to `j.` across every skill's frontmatter — but the guard's
# trigger condition still read `if (text.startsWith("j:"))`.
#
# The result was a fail-open on exactly the identifier the framework advertises.
# Reproduced against the pre-fix code through the real MCP server over stdio:
#
#   j:notaskill …  ->  {"action":"unrecognized", …}          (guarded)
#   j.notaskill …  ->  {"error":"_pipe is not a function"}    (never entered
#                       the guard block at all; fell through to Stage 2 and
#                       died in the embedder — checkAllowList was never called)
#
# Full analysis:
#   project/rapports/problems/E50_S07_T01-router-guard-fail-open.md
#
# The trap the fix had to avoid: changing `startsWith("j:")` to
# `startsWith("j.")` is *strictly worse than the bug*. It closes the `j.` hole
# and opens an identical one on `j:`, which is a permanent, never-deprecated
# alias per E50 Decision 2 — the unguarded form would simply move. So the gate
# was widened to accept both separators, and `test j: is still guarded` below is
# the assertion that pins that down: it fails under a naive swap.
#
# Design
# ------
# `mcp/router/index.js` cannot be imported by a test — it starts an MCP server
# and loads an embedding model at import time. That untestability is why the
# fail-open survived two implementations and a tester pass. E50_S07_T02 moved
# the Stage 1 decision into `routeDirectInvocation()` in
# `mcp/router/allow-list-guard.js`, which depends only on Node built-ins, and
# these tests drive it through `tests/helpers/router-route.mjs`. No npm install,
# no network, no model.
#
# Every test runs against a synthetic skills tree in $BATS_TEST_TMPDIR, never
# this repository's own `skills/`, and writes nothing into tracked files.

# Shared assertion helpers. A bare `[[ ... ]]` does NOT fail a bats test unless
# it is the body's final statement -- `[[` is a shell keyword and never fires
# bats' ERR trap -- so every assertion below goes through a helper function,
# which is an ordinary simple command and does abort on failure. See the header
# of tests/helpers/assertions.bash (E50_S07_T08).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$REPO_ROOT/tests/helpers/router-route.mjs"

# Builds a throwaway skills tree covering all three frontmatter forms the
# normalizer has to cope with simultaneously:
#   status/       name: j.status     -- canonical, post-E50_S07_T01
#   commit/       name: j:commit     -- legacy E50_S01 form, still supported
#   j-brainstorm/ name: j.j-brainstorm -- an E50_S05 collision-safe twin, whose
#                                       bare name itself starts with "j-"
setup() {
  SKILLS_DIR="$BATS_TEST_TMPDIR/skills"
  mkdir -p "$SKILLS_DIR/status" "$SKILLS_DIR/commit" "$SKILLS_DIR/j-brainstorm"

  cat > "$SKILLS_DIR/status/SKILL.md" <<'SKILL'
---
name: j.status
description: Print a human-readable summary of the scrum board.
---

# status
SKILL

  cat > "$SKILLS_DIR/commit/SKILL.md" <<'SKILL'
---
name: j:commit
description: Commit implemented work using the EST naming convention.
---

# commit
SKILL

  cat > "$SKILLS_DIR/j-brainstorm/SKILL.md" <<'SKILL'
---
name: j.j-brainstorm
description: Collision-safe twin of the brainstorm skill.
---

# j-brainstorm
SKILL
}

route() {
  node "$HELPER" route "$SKILLS_DIR" "$1"
}

# buildSkillIndex() logs "[jenga-router] Indexed N skills in Xms" to stderr, and bats's `run`
# merges stderr into $output. These wrappers drop it so the assertions can compare $output
# against the exact JSON the helper printed.
index_names() {
  node "$HELPER" index "$SKILLS_DIR" 2>/dev/null
}

emit() {
  node "$HELPER" emit "$SKILLS_DIR" "$1" "$2" 2>/dev/null
}

# Extracts a top-level string field from the helper's single-line JSON output
# without needing jq (not assumed present — none of the other suites use it).
json_field() {
  node -e 'const o=JSON.parse(process.argv[1]);const v=o===null?null:o[process.argv[2]];process.stdout.write(String(v))' "$1" "$2"
}

# --------------------------------------------------------------
# The regression gate. This is the test that fails against pre-fix
# code, and the reason this task was escalated to crucial_level: gated.
# --------------------------------------------------------------

@test "j. — an unknown identifier in the canonical form is caught by the guard" {
  run route "j.notaskill do something"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" action)" = "unrecognized" ]
}

@test "j. — the unrecognized result carries a message for the caller to surface" {
  run route "j.notaskill do something"
  [ "$status" -eq 0 ]
  assert_contains "$(json_field "$output" message)" "is not a recognized Jenga skill"
}

# --------------------------------------------------------------
# Widened, not swapped. If someone "fixes" the gate by changing
# startsWith("j:") to startsWith("j."), the bug moves rather than
# closing and this test goes red.
# --------------------------------------------------------------

@test "j: — the legacy separator is STILL guarded, proving the gate was widened not swapped" {
  run route "j:notaskill do something"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" action)" = "unrecognized" ]
}

@test "the unrecognized message echoes the separator the user actually typed, not the canonical one" {
  # The prefix is taken from the regex match rather than sliced off the front of
  # the prompt by a hard-coded length, so this stays correct if a separator ever
  # becomes more than one character. See mcp/router/prefix.js's
  # matchJengaInvocation().
  run route "j:notaskill do something"
  [ "$status" -eq 0 ]
  assert_starts_with "$(json_field "$output" message)" '"j:notaskill"'
  assert_contains "$(json_field "$output" message)" 'omit the "j:" prefix'

  run route "j.notaskill do something"
  [ "$status" -eq 0 ]
  assert_starts_with "$(json_field "$output" message)" '"j.notaskill"'
  assert_contains "$(json_field "$output" message)" 'omit the "j." prefix'
}

# --------------------------------------------------------------
# Genuine skills keep working, in every accepted input form.
# --------------------------------------------------------------

@test "j. — a known skill is trusted as passthrough" {
  run route "j.status what's the board status?"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" action)" = "passthrough" ]
  [ "$(json_field "$output" transformed)" = "j.status what's the board status?" ]
}

@test "j: — a known skill in the legacy form is still accepted as input" {
  run route "j:status what's the board status?"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" action)" = "passthrough" ]
}

@test "j. — an E50_S05 j-<name> twin resolves (identifier class allows the hyphen)" {
  run route "j.j-brainstorm let's plan"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" action)" = "passthrough" ]
}

@test "the bare /<name> alias is passed through untouched and is not allow-list checked" {
  # Per E50 Decision 2 this form is permanent and deliberately outside the
  # guard — it is the host tool's own slash-command namespace.
  run route "/notaskill do something"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" action)" = "passthrough" ]
  [ "$(json_field "$output" transformed)" = "/notaskill do something" ]
}

@test "a prefix with no parseable identifier falls back to passthrough, not a new failure mode" {
  run route "j. "
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" action)" = "passthrough" ]
}

@test "a free-form prompt is not a direct invocation and continues to Stage 2" {
  run route "what is the board status"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "the prompt gate is case-sensitive, so J. is ordinary free text" {
  # Deliberate: matching case-insensitively would newly grant trusted
  # passthrough to J.status, expanding the auto-trusted surface to a shape the
  # framework never advertises. See mcp/router/prefix.js's header.
  run route "J.status what's the board status?"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

# --------------------------------------------------------------
# The second, independent defect: skill-index.js's normalizer stopped
# stripping once frontmatter became j.<name>, so skill.name kept its
# prefix and index.js emitted the doubled, malformed "j:j.status …".
# --------------------------------------------------------------

@test "skill-index strips the canonical j. prefix from frontmatter names" {
  run index_names
  [ "$status" -eq 0 ]
  assert_output_contains '{"name":"status"}'
  assert_output_not_contains 'j.status'
}

@test "skill-index strips the legacy j: prefix too" {
  run index_names
  [ "$status" -eq 0 ]
  assert_output_contains '{"name":"commit"}'
  assert_output_not_contains 'j:commit'
}

@test "Stage 2 emits j.status, not the doubled j:j.status" {
  run emit status "what's the board status?"
  [ "$status" -eq 0 ]
  [ "$output" = '"j.status what'"'"'s the board status?"' ]
  assert_output_not_contains 'j:j.status'
  assert_output_not_contains 'j.j.status'
}

@test "the allow-list is normalized to bare identifiers regardless of frontmatter form" {
  run node "$HELPER" allow-list "$SKILLS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = '["commit","j-brainstorm","status"]' ]
}
