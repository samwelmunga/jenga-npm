#!/usr/bin/env bats
#
# Regression coverage for mcp/help's directory-scan logic against a twin-only skills
# tree (E50_S12_T06).
#
# Why this file exists
# --------------------
# mcp/help/index.js's `help` tool does a pure readdirSync/statSync scan of
# .claude/skills or .agents/skills and returns whatever folder names it finds,
# verbatim. E50_S12's Context flagged it as "expected to need no code change, but must
# be confirmed rather than assumed." This file is that confirmation: it drives the real
# scan logic (not a re-implementation of it) against a synthetic tree containing ONLY
# twin-shaped directories, and asserts the returned list matches exactly.
#
# Why mcp/help/scan.js exists
# ----------------------------
# mcp/help/index.js instantiates an McpServer and ends with a top-level
# `await server.connect(transport)`, which blocks on stdin — importing that file as a
# whole would hang any test that tried it. E50_S12_T06 split the pure scan logic
# (resolveSkillsDir / candidateSkillsDirs / listSkillFolders) into mcp/help/scan.js, a
# plain Node-built-ins-only module with no side effects at import time, mirroring the
# exact precedent mcp/router/allow-list-guard.js already set for the same reason
# (E50_S07_T02). index.js's tool handler now just calls into scan.js; the scanning
# behavior itself is byte-for-byte unchanged.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$REPO_ROOT/tests/helpers/help-scan.mjs"

setup() {
  PROJECT_ROOT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_ROOT/.claude/skills/j-status" \
    "$PROJECT_ROOT/.claude/skills/j-commit" \
    "$PROJECT_ROOT/.claude/skills/jenga"
  # A stray non-directory entry must never be reported as a skill folder.
  echo "not a skill" > "$PROJECT_ROOT/.claude/skills/README.md"
}

@test "resolves .claude/skills when present" {
  run node "$HELPER" resolve "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT_ROOT/.claude/skills" ]
}

@test "falls back to .agents/skills when .claude/skills is absent" {
  local project_b="$BATS_TEST_TMPDIR/project-b"
  mkdir -p "$project_b/.agents/skills/j-status"
  run node "$HELPER" resolve "$project_b"
  [ "$status" -eq 0 ]
  [ "$output" = "$project_b/.agents/skills" ]
}

@test "twin-only tree: returned folder list matches exactly what's on disk, no skill dropped or mangled" {
  run node "$HELPER" list "$PROJECT_ROOT/.claude/skills"
  [ "$status" -eq 0 ]
  local names
  names=$(node -e 'JSON.parse(process.argv[1]).sort().forEach(x=>console.log(x))' "$output")
  [ "$names" = "$(printf 'j-commit\nj-status\njenga')" ]
}

@test "twin-only tree: a non-directory entry alongside skill folders is not reported as a folder" {
  run node "$HELPER" list "$PROJECT_ROOT/.claude/skills"
  [ "$status" -eq 0 ]
  assert_output_not_contains "README.md"
}

@test "an empty skills directory reports zero folders (matches index.js's own empty-case message trigger)" {
  local project_c="$BATS_TEST_TMPDIR/project-c"
  mkdir -p "$project_c/.claude/skills"
  run node "$HELPER" list "$project_c/.claude/skills"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
