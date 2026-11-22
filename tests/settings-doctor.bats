#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E100_S05_T02: scripts/settings-doctor.sh (E100_S05_T01).
#
# Isolation: the doctor runs from a fixture package ($BATS_TEST_TMPDIR/pkg) holding fixture fragments, and --project-dir
# and --home point at $BATS_TEST_TMPDIR, so neither the shipped fragments nor the real ~/.claude are read, except in the
# one test that says so. Paths are canonicalised with pwd -P (macOS /var is a symlink). Written without being executed by
# its author; the tester runs it.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"

# make_pkg <dir>: a minimal package with the doctor and three fixture fragments.
make_pkg() {
  local p="$1"
  mkdir -p "$p/scripts" "$p/templates" "$p/skills/index/scripts" "$p/skills/j-alpha" "$p/skills/j-beta" "$p/hooks"
  cp "$REPO_ROOT/scripts/settings-doctor.sh" "$p/scripts/settings-doctor.sh"
  cp "$REPO_ROOT/skills/index/scripts/package-root.sh" "$p/skills/index/scripts/package-root.sh"
  : > "$p/scripts/resolve-root.sh"
  cat > "$p/skills/j-alpha/settings-fragment.json" <<'JSON'
{"id":"alpha","version":1,"hooks":{"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"exec \"$P/hooks/on_fixture_step.sh\""}]}]}}
JSON
  cat > "$p/skills/j-beta/settings-fragment.json" <<'JSON'
{"id":"beta","version":1,"env":{"FIXTURE_FLAG":"on"},"permissions":{"allow":[{"rule":"Bash(fixture *)","optIn":true}]}}
JSON
  cat > "$p/hooks/gamma.fragment.json" <<'JSON'
{"id":"gamma","version":1,"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"on_gamma_end.sh"}]}]}}
JSON
}

setup() {
  PKG="$BATS_TEST_TMPDIR/pkg"; PROJ="$BATS_TEST_TMPDIR/proj"; HOMED="$BATS_TEST_TMPDIR/home"
  mkdir -p "$PROJ/.claude" "$PROJ/.agents" "$HOMED/.claude"
  make_pkg "$PKG"
  PROJ="$(cd "$PROJ" && pwd -P)"; HOMED="$(cd "$HOMED" && pwd -P)"; PKG="$(cd "$PKG" && pwd -P)"
  ALPHA_JSON='{"hooks":{"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"exec \"$P/hooks/on_fixture_step.sh\""}]}]}}'
  BETA_JSON='{"env":{"FIXTURE_FLAG":"on"},"permissions":{"allow":["Bash(fixture *)"]}}'
  GAMMA_JSON='{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"on_gamma_end.sh"}]}]}}'
}

doctor() { bash "$PKG/scripts/settings-doctor.sh" --project-dir "$PROJ" --home "$HOMED" "$@"; }

@test "active: the hook is in .claude/settings.json; exit 0, active, names that file" {
  printf '%s' "$ALPHA_JSON" > "$PROJ/.claude/settings.json"
  run doctor --fragment alpha
  [ "$status" -eq 0 ]
  assert_output_contains "alpha: hooks.UserPromptSubmit[0]: active ($PROJ/.claude/settings.json)"
}

@test "inactive: no layer holds it; exit 1, inactive, carries the fix and the restart note" {
  run doctor --fragment alpha
  [ "$status" -eq 1 ]
  assert_output_contains "alpha: hooks.UserPromptSubmit[0]: inactive"
  assert_output_contains "npx jenga sync"
  assert_output_contains "restart Claude Code"
}

@test "found in .claude/settings.local.json only: active, names that layer" {
  printf '%s' "$ALPHA_JSON" > "$PROJ/.claude/settings.local.json"
  run doctor --fragment alpha
  [ "$status" -eq 0 ]
  assert_output_contains "active ($PROJ/.claude/settings.local.json)"
}

@test "found in the home .claude/settings.json only: active, names that layer" {
  printf '%s' "$ALPHA_JSON" > "$HOMED/.claude/settings.json"
  run doctor --fragment alpha
  [ "$status" -eq 0 ]
  assert_output_contains "active ($HOMED/.claude/settings.json)"
}

@test "a hook only in .agents/settings.json is inactive" {
  printf '%s' "$ALPHA_JSON" > "$PROJ/.agents/settings.json"
  run doctor --fragment alpha
  [ "$status" -eq 1 ]
  assert_output_contains "alpha: hooks.UserPromptSubmit[0]: inactive"
}

@test "a hook only in the repository-root settings.json is inactive" {
  printf '%s' "$ALPHA_JSON" > "$PROJ/settings.json"
  run doctor --fragment alpha
  [ "$status" -eq 1 ]
  assert_output_contains "alpha: hooks.UserPromptSubmit[0]: inactive"
}

@test "a hook matches by file name when the command text differs" {
  printf '%s' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/x/y/on_fixture_step.sh"}]}]}}' > "$PROJ/.claude/settings.json"
  run doctor --fragment alpha
  [ "$status" -eq 0 ]
  assert_output_contains "active ($PROJ/.claude/settings.json)"
}

@test "env and allow rule: active in .claude/settings.json" {
  printf '%s' "$BETA_JSON" > "$PROJ/.claude/settings.json"
  run doctor --fragment beta
  [ "$status" -eq 0 ]
  assert_output_contains "beta: env.FIXTURE_FLAG: active ($PROJ/.claude/settings.json)"
  assert_output_contains "beta: permissions.allow: Bash(fixture *): active ($PROJ/.claude/settings.json)"
}

@test "env and allow rule: inactive, the allow fix says it is opt-in" {
  run doctor --fragment beta
  [ "$status" -eq 1 ]
  assert_output_contains "beta: env.FIXTURE_FLAG: inactive"
  assert_output_contains "beta: permissions.allow: Bash(fixture *): inactive"
  assert_output_contains "opt-in"
}

@test "env with a different value is inactive while the allow rule stays active" {
  printf '%s' '{"env":{"FIXTURE_FLAG":"off"},"permissions":{"allow":["Bash(fixture *)"]}}' > "$PROJ/.claude/settings.json"
  run doctor --fragment beta
  [ "$status" -eq 1 ]
  assert_output_contains "beta: env.FIXTURE_FLAG: inactive"
  assert_output_contains "beta: permissions.allow: Bash(fixture *): active"
}

@test "env and allow rule: found in the local and the home layers" {
  printf '%s' '{"env":{"FIXTURE_FLAG":"on"}}' > "$PROJ/.claude/settings.local.json"
  printf '%s' '{"permissions":{"allow":["Bash(fixture *)"]}}' > "$HOMED/.claude/settings.json"
  run doctor --fragment beta
  [ "$status" -eq 0 ]
  assert_output_contains "env.FIXTURE_FLAG: active ($PROJ/.claude/settings.local.json)"
  assert_output_contains "Bash(fixture *): active ($HOMED/.claude/settings.json)"
}

@test "mixed run: one active and one inactive requirement give both lines and exit 1" {
  printf '%s' "$ALPHA_JSON" > "$PROJ/.claude/settings.json"
  run doctor
  [ "$status" -eq 1 ]
  assert_output_contains "alpha: hooks.UserPromptSubmit[0]: active"
  assert_output_contains "gamma: hooks.SessionEnd[0]: inactive"
}

@test "an invalid-JSON layer does not abort the run and provides nothing" {
  printf '%s' '{ not json' > "$PROJ/.claude/settings.json"
  printf '%s' "$ALPHA_JSON" > "$PROJ/.claude/settings.local.json"
  run doctor --fragment alpha
  [ "$status" -eq 0 ]
  assert_output_contains "active ($PROJ/.claude/settings.local.json)"
  assert_output_contains "not valid JSON"
}

@test "--fragment checks only that fragment" {
  run doctor --fragment gamma
  [ "$status" -eq 1 ]
  assert_output_contains "gamma:"
  assert_output_not_contains "alpha:"
  assert_output_not_contains "beta:"
}

@test "--skill checks only the fragment of that skill" {
  run doctor --skill j-beta
  [ "$status" -eq 1 ]
  assert_output_contains "beta:"
  assert_output_not_contains "alpha:"
  assert_output_not_contains "gamma:"
}

@test "--quiet prints only inactive requirements" {
  printf '%s' "$ALPHA_JSON" > "$PROJ/.claude/settings.json"
  run doctor --quiet
  [ "$status" -eq 1 ]
  assert_output_contains "gamma: hooks.SessionEnd[0]: inactive"
  assert_output_not_contains "alpha:"
}

@test "--json prints one valid object per requirement with the documented fields" {
  printf '%s' "$ALPHA_JSON" > "$PROJ/.claude/settings.json"
  run doctor --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 4 ]
  printf '%s\n' "$output" | jq -e -s 'all(.[]; has("fragment") and has("owner") and has("kind") and has("requirement") and has("status") and has("layer") and has("fix") and has("restart"))' >/dev/null
  printf '%s\n' "$output" | jq -e -s --arg l "$PROJ/.claude/settings.json" 'any(.[]; .fragment=="alpha" and .status=="active" and .layer==$l)' >/dev/null
  printf '%s\n' "$output" | jq -e -s 'any(.[]; .fragment=="gamma" and .status=="inactive" and .layer==null)' >/dev/null
}

@test "an unknown fragment id exits 2" {
  run doctor --fragment nope
  [ "$status" -eq 2 ]
  assert_output_contains "unknown fragment id 'nope'"
}

@test "an unknown skill exits 2" {
  run doctor --skill j-nope
  [ "$status" -eq 2 ]
  assert_output_contains "unknown skill"
}

@test "an unknown argument exits 2 and --help exits 0" {
  run doctor --bogus
  [ "$status" -eq 2 ]
  run doctor --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage:"
}

@test "read-only: settings files and the package fixture tree are unchanged afterwards" {
  printf '%s' "$ALPHA_JSON" > "$PROJ/.claude/settings.json"
  printf '%s' "$BETA_JSON" > "$PROJ/.claude/settings.local.json"
  printf '%s' '{ broken' > "$HOMED/.claude/settings.json"
  printf '%s' "$GAMMA_JSON" > "$PROJ/.agents/settings.json"
  snap() { (cd "$BATS_TEST_TMPDIR" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "$f"; cksum < "$f"; done); }
  before="$(snap)"
  run doctor
  run doctor --json
  run doctor --quiet
  after="$(snap)"
  [ "$before" = "$after" ]
}

@test "the real script reports the shipped recorder fragment as inactive in an empty project" {
  run bash "$REPO_ROOT/scripts/settings-doctor.sh" --fragment workflow-recorder --project-dir "$PROJ" --home "$HOMED"
  [ "$status" -eq 1 ]
  assert_output_contains "workflow-recorder: hooks.UserPromptSubmit[0]: inactive"
}

@test "consumer layout: the script runs from node_modules/@jenga-ai/agent and finds its fragments there" {
  CONS="$BATS_TEST_TMPDIR/consumer"
  make_pkg "$CONS/node_modules/@jenga-ai/agent"
  mkdir -p "$CONS/.claude"
  CONS="$(cd "$CONS" && pwd -P)"
  printf '%s' "$ALPHA_JSON" > "$CONS/.claude/settings.json"
  run bash "$CONS/node_modules/@jenga-ai/agent/scripts/settings-doctor.sh" --project-dir "$CONS" --home "$HOMED" --fragment alpha
  [ "$status" -eq 0 ]
  assert_output_contains "alpha: hooks.UserPromptSubmit[0]: active ($CONS/.claude/settings.json)"
}
