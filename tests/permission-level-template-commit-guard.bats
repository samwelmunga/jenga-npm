#!/usr/bin/env bats
#
# Regression coverage for E15_S04_T01.
#
# Why this file exists
# ---------------------
# All 5 templates/permission-levels/level-*.json files were found missing the
# install-worktree-commit-guard.sh invocation from their WorktreeCreate hook's
# command string. scripts/jenga-permission-level-switch.sh performs a
# whole-file overwrite of .claude/settings.json and .agents/settings.json from
# whichever template matches the requested level (see that script's own
# header comment), so every /jenga-permission-level switch silently stripped
# the commit-guard hook installed by scripts/install-worktree-commit-guard.sh
# (see that script's own header for why the guard exists: preventing a tester
# from committing a task's verification to the wrong branch from inside an
# isolated worktree).
#
# skills/jenga-permission-level/SKILL.md documents an explicit invariant:
# "All 5 templates carry byte-identical defaultMode, env, hooks, and
# permissions.allow" -- this suite locks that invariant in for the
# WorktreeCreate hook specifically, plus asserts the guard invocation itself
# is present, so a future template edit that silently drops the line (or
# desyncs one template from the other four) fails loudly instead of only
# surfacing the next time a real /jenga-permission-level switch is observed.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TEMPLATES_DIR="$REPO_ROOT/templates/permission-levels"
GUARD_INVOCATION="install-worktree-commit-guard.sh"

worktree_create_command() {
  jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$1"
}

@test "level-1-locked.json's WorktreeCreate hook invokes install-worktree-commit-guard.sh" {
  run worktree_create_command "$TEMPLATES_DIR/level-1-locked.json"
  [ "$status" -eq 0 ]
  assert_output_contains "$GUARD_INVOCATION"
}

@test "level-2-guarded.json's WorktreeCreate hook invokes install-worktree-commit-guard.sh" {
  run worktree_create_command "$TEMPLATES_DIR/level-2-guarded.json"
  [ "$status" -eq 0 ]
  assert_output_contains "$GUARD_INVOCATION"
}

@test "level-3-standard.json's WorktreeCreate hook invokes install-worktree-commit-guard.sh" {
  run worktree_create_command "$TEMPLATES_DIR/level-3-standard.json"
  [ "$status" -eq 0 ]
  assert_output_contains "$GUARD_INVOCATION"
}

@test "level-4-elevated.json's WorktreeCreate hook invokes install-worktree-commit-guard.sh" {
  run worktree_create_command "$TEMPLATES_DIR/level-4-elevated.json"
  [ "$status" -eq 0 ]
  assert_output_contains "$GUARD_INVOCATION"
}

@test "level-5-unrestricted.json's WorktreeCreate hook invokes install-worktree-commit-guard.sh" {
  run worktree_create_command "$TEMPLATES_DIR/level-5-unrestricted.json"
  [ "$status" -eq 0 ]
  assert_output_contains "$GUARD_INVOCATION"
}

@test "all 5 templates' WorktreeCreate hook command strings are byte-identical" {
  local first
  first="$(worktree_create_command "$TEMPLATES_DIR/level-1-locked.json")"
  for level in 2-guarded 3-standard 4-elevated 5-unrestricted; do
    run worktree_create_command "$TEMPLATES_DIR/level-${level}.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
  done
}

@test "all 5 templates' WorktreeCreate hook command matches root settings.json's" {
  local root_cmd
  root_cmd="$(worktree_create_command "$REPO_ROOT/settings.json")"
  for level in 1-locked 2-guarded 3-standard 4-elevated 5-unrestricted; do
    run worktree_create_command "$TEMPLATES_DIR/level-${level}.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$root_cmd" ]
  done
}

@test "WorktreeRemove hook is unaffected -- still byte-identical across all 5 templates" {
  local first
  first="$(jq -c '.hooks.WorktreeRemove' "$TEMPLATES_DIR/level-1-locked.json")"
  for level in 2-guarded 3-standard 4-elevated 5-unrestricted; do
    run jq -c '.hooks.WorktreeRemove' "$TEMPLATES_DIR/level-${level}.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
  done
}

@test "SessionEnd hook is unaffected -- still byte-identical across all 5 templates" {
  local first
  first="$(jq -c '.hooks.SessionEnd' "$TEMPLATES_DIR/level-1-locked.json")"
  for level in 2-guarded 3-standard 4-elevated 5-unrestricted; do
    run jq -c '.hooks.SessionEnd' "$TEMPLATES_DIR/level-${level}.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
  done
}
