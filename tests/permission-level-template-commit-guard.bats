#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Backstop invariant for the permission-level switch (E100_S04_T03).
#
# The old invariant (E15_S04_T01)
# --------------------------------
# All five templates/permission-levels/level-*.json files had to carry the install-worktree-commit-guard.sh
# invocation in their WorktreeCreate hook, byte-identical, because scripts/jenga-permission-level-switch.sh used to
# overwrite .claude/settings.json and .agents/settings.json whole from the template, so a template missing the guard
# stripped it on every switch (and one missing the PreToolUse pre-flight entry stripped the backstop, E89_S06_T12).
#
# Why it is replaced (E100_S04)
# ------------------------------
# E100_S04_T01 made the switch a key-level merge of the owned keys only (defaultMode, permissions.deny,
# permissions.ask, autoMode) and E100_S04_T02 slimmed the templates to exactly those keys, so a template can no
# longer carry or drop a hook. Asserting hooks inside the templates would now fail for the right reason. The
# invariant is restated where it now lives:
#   1. root settings.json registers the WorktreeCreate guard and the PreToolUse pre-flight entry;
#   2. no template carries hooks;
#   3. for every level 1-5 the switch leaves both of those entries in .claude/ and .agents/ settings.json equal to
#      the root's (jq -S);
#   4. at level 5 (unrestricted) the registered hook still REFUSES a gated operation while a block-enforcement item
#      is unsatisfied, and that decision does not depend on the level file.
# Everything runs in a git-init sandbox; the repository's own .jenga-permission-level.json is never touched.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TEMPLATES_DIR="$REPO_ROOT/templates/permission-levels"
SWITCH="$REPO_ROOT/scripts/jenga-permission-level-switch.sh"
MARKER="$REPO_ROOT/scripts/checklist-marker.sh"
GUARD_INVOCATION="install-worktree-commit-guard.sh"
# SWITCH_SCRIPT lets a test point the sandbox runs at a different switch implementation (negative control).
switch_script() { printf '%s' "${SWITCH_SCRIPT:-$SWITCH}"; }

# preflight_entry <settings-file>: the PreToolUse entries that run hooks/on_preflight_check.sh, compact JSON.
preflight_entry() {
  jq -S -c '[.hooks.PreToolUse[]? | select(any(.hooks[]?; (.command // "") | contains("hooks/on_preflight_check.sh")))]' "$1"
}

# guard_entry <settings-file>: the WorktreeCreate entries that invoke the commit guard, compact JSON.
guard_entry() {
  jq -S -c --arg g "$GUARD_INVOCATION" '[.hooks.WorktreeCreate[]? | select(any(.hooks[]?; (.command // "") | contains($g)))]' "$1"
}

make_sandbox() {
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.claude" "$SANDBOX/.agents"
  git init -q "$SANDBOX"
  cp "$REPO_ROOT/settings.json" "$SANDBOX/.claude/settings.json"
  cp "$REPO_ROOT/settings.json" "$SANDBOX/.agents/settings.json"
}

switch_level() {
  run bash -c 'cd "$1" && bash "$2" "$3"' _ "$SANDBOX" "$(switch_script)" "$1"
  [ "$status" -eq 0 ] || { echo "level switch to $1 failed ($status): $output" >&2; return 1; }
}

# assert_backstop_held <label>: both sandbox settings files still equal the root's PreToolUse backstop and guard.
assert_backstop_held() {
  local f root_pre root_guard
  root_pre="$(preflight_entry "$REPO_ROOT/settings.json")"
  root_guard="$(guard_entry "$REPO_ROOT/settings.json")"
  [ "$(jq 'length' <<<"$root_pre")" -ge 1 ] || { echo "root settings.json has no PreToolUse backstop" >&2; return 1; }
  [ "$(jq 'length' <<<"$root_guard")" -ge 1 ] || { echo "root settings.json has no WorktreeCreate guard" >&2; return 1; }
  for f in "$SANDBOX/.claude/settings.json" "$SANDBOX/.agents/settings.json"; do
    [ "$(preflight_entry "$f")" = "$root_pre" ] || { echo "$1: PreToolUse backstop lost or changed in $f" >&2; return 1; }
    [ "$(guard_entry "$f")" = "$root_guard" ] || { echo "$1: WorktreeCreate guard lost or changed in $f" >&2; return 1; }
  done
}

# -----------------------------------------------------------------------------
# 1. root settings.json holds the registrations
# -----------------------------------------------------------------------------

@test "root settings.json registers the WorktreeCreate commit guard" {
  run guard_entry "$REPO_ROOT/settings.json"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -ge 1 ]
}

@test "root settings.json registers the PreToolUse pre-flight backstop for Bash, Task and Agent" {
  [ -x "$REPO_ROOT/hooks/on_preflight_check.sh" ]
  run preflight_entry "$REPO_ROOT/settings.json"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -ge 1 ]
  matcher="$(jq -r '.[0].matcher' <<<"$output")"
  for tool in Bash Task Agent; do
    [[ "|$matcher|" == *"|$tool|"* ]] || { echo "matcher '$matcher' does not cover $tool" >&2; return 1; }
  done
}

# -----------------------------------------------------------------------------
# 2. no template carries hooks
# -----------------------------------------------------------------------------

@test "no permission-level template carries hooks" {
  local count=0 f
  for f in "$TEMPLATES_DIR"/level-*.json; do
    [ -f "$f" ] || continue
    count=$((count + 1))
    [ "$(jq 'has("hooks")' "$f")" = "false" ] || { echo "template carries hooks: $f" >&2; return 1; }
  done
  [ "$count" -ge 5 ] || { echo "expected at least 5 level templates, found $count" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# 3. the switch keeps both registrations at every level
# -----------------------------------------------------------------------------

@test "level 1: the switch keeps the PreToolUse backstop and WorktreeCreate guard in both settings files" {
  make_sandbox; switch_level 1; assert_backstop_held "level 1"
}

@test "level 2: the switch keeps the PreToolUse backstop and WorktreeCreate guard in both settings files" {
  make_sandbox; switch_level 2; assert_backstop_held "level 2"
}

@test "level 3: the switch keeps the PreToolUse backstop and WorktreeCreate guard in both settings files" {
  make_sandbox; switch_level 3; assert_backstop_held "level 3"
}

@test "level 4: the switch keeps the PreToolUse backstop and WorktreeCreate guard in both settings files" {
  make_sandbox; switch_level 4; assert_backstop_held "level 4"
}

@test "level 5: the switch keeps the PreToolUse backstop and WorktreeCreate guard in both settings files" {
  make_sandbox; switch_level 5; assert_backstop_held "level 5"
}

@test "switching through all five levels in sequence still holds both registrations" {
  make_sandbox
  for n in 1 2 3 4 5 1; do
    switch_level "$n"
    assert_backstop_held "after level $n"
  done
}

# -----------------------------------------------------------------------------
# 4. level 5: the backstop still refuses
# -----------------------------------------------------------------------------

# A throwaway project root with a failing block-enforcement pre-commit item and an active pre-commit marker.
make_failing_project() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs"
  cat > "$PROJ/project/configs/workflow.json" <<'JSON'
{
  "paths": {
    "queue": "project/queue",
    "configs": "project/configs"
  }
}
JSON
  printf '{\n  "marker_ttl_minutes": 60\n}\n' > "$PROJ/project/configs/scope-thresholds.json"
  REGISTRY="$BATS_TEST_TMPDIR/checklists.json"
  write_registry false
  export JENGA_PROJECT_ROOT="$PROJ" JENGA_CHECKLISTS_FILE="$REGISTRY" \
    JENGA_CHECKLISTS_DEFAULT_FILE="$BATS_TEST_TMPDIR/no-default.json" \
    JENGA_CHECKLIST_STATE_DIR="$BATS_TEST_TMPDIR/state" CLAUDE_CODE_SESSION_ID="sess-guard"
  unset JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_MARKER_DIR JENGA_CHECKLIST_NOW \
    JENGA_PREFLIGHT_HOOK_SCRIPT_DIR JENGA_CHECKLIST_RUN_ID
  bash "$MARKER" write --situation pre-commit --run run-guard --skill j.commit >/dev/null
}

# write_registry <verify-command>: one machine item enforced as block at pre-commit.
write_registry() {
  jq -n --arg v "$1" '{checklist_version: 1, situations: [], items: [{id: "must-pass", text: "Must pass.",
    situations: ["pre-commit"], kind: "machine", enforcement: "block", tick_scope: "run", verify: $v}]}' > "$REGISTRY"
}

# run_registered_hook <settings-file>: run the hook command that file registers, the way the harness does.
run_registered_hook() {
  local cmd payload
  cmd="$(jq -r '[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | contains("on_preflight_check.sh")) | .command][0] // empty' "$1")"
  [ -n "$cmd" ] || { echo "no registered pre-flight command in $1" >&2; return 1; }
  payload="$(jq -nc '{tool_name: "Bash", tool_input: {command: "git commit -m x"}}')"
  run --separate-stderr env CLAUDE_PROJECT_DIR="$REPO_ROOT" bash -c "$cmd" <<<"$payload"
}

@test "level 5: after the switch the registered pre-flight hook still refuses a gated operation" {
  real_before="$(cat "$REPO_ROOT/.jenga-permission-level.json" 2>/dev/null || echo absent)"
  make_failing_project
  make_sandbox
  switch_level 5
  [ "$(jq -r '.session_level' "$SANDBOX/.jenga-permission-level.json")" = "5" ]
  [ "$(jq -r '.defaultMode' "$SANDBOX/.claude/settings.json")" = "$(jq -r '.defaultMode' "$TEMPLATES_DIR/level-5-unrestricted.json")" ]

  for f in "$SANDBOX/.claude/settings.json" "$SANDBOX/.agents/settings.json"; do
    run_registered_hook "$f"
    [ "$status" -eq 2 ] || { echo "$f: hook exited $status, expected 2 (refuse). stdout: $output stderr: $stderr" >&2; return 1; }
    assert_contains "$stderr" must-pass
    assert_contains "$stderr" pre-commit
    [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  done

  # Control: with the item satisfied the same registered command allows the call.
  write_registry true
  run_registered_hook "$SANDBOX/.claude/settings.json"
  [ "$status" -eq 0 ]
  assert_not_contains "$output" '"deny"'

  [ "$(cat "$REPO_ROOT/.jenga-permission-level.json" 2>/dev/null || echo absent)" = "$real_before" ]
}

@test "level 5: the refusal does not depend on the level file (same refusal at level 1 and with the level file removed)" {
  make_failing_project
  make_sandbox
  switch_level 5
  rm -f "$SANDBOX/.jenga-permission-level.json"
  run_registered_hook "$SANDBOX/.claude/settings.json"
  [ "$status" -eq 2 ]
  switch_level 1
  run_registered_hook "$SANDBOX/.claude/settings.json"
  [ "$status" -eq 2 ]
}

@test "level 5: removing the backstop entry from the switched settings makes the refusal disappear (the test can fail)" {
  make_failing_project
  make_sandbox
  switch_level 5
  jq 'del(.hooks.PreToolUse)' "$SANDBOX/.claude/settings.json" > "$SANDBOX/stripped.json"
  run run_registered_hook "$SANDBOX/stripped.json"
  [ "$status" -ne 0 ]
  assert_contains "$output" "no registered pre-flight command"
}
