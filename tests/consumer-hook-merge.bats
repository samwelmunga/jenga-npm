#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# scripts/merge-settings.sh and its call from `jenga sync` (E100_S03_T08; ported from the E89_S06_T20 suite that pinned
# the script this one replaces; design: project/documentation/e100-s03-merge-design.md).
#
# What this suite pins:
#   1. A PRE-E89 settings.json (only WorktreeCreate, WorktreeRemove, SessionEnd plus one user-written hook) gains the
#      recorder's UserPromptSubmit hook and the PreToolUse preflight hook, and every user-written entry and other key
#      survives.
#   2. A SECOND RUN CHANGES NOTHING: byte-identical file, "unchanged" reported.
#   3. NON-CLOBBERING: a consumer's own hook on an event Jenga also uses is kept; an invalid settings.json is refused and
#      left untouched.
#   4. NEVER ACTS ON THE PACKAGE ITSELF (this repository included), and --dry-run writes nothing.
#   5. `jenga sync` calls it: a consumer with a pre-E89 settings.json gets the hook, and a second sync is a no-op.
#   6. THE E89_S06_T20 CASE end to end, on a settings file written by Jenga before the recorder existed: sync registers the
#      recorder hook with no conflict, user hooks and keys survive, a second sync and a second script run are no-ops.
#   7. SAME RESULT from the consumer layout (node_modules/@jenga-ai/agent/scripts/) and from the monorepo.
#
# Deliberate differences from the replaced script (design note, section 4; the assertions below follow the NEW behaviour):
#   - "already registered" is JSON-normalised equality with a shipped entry, not a command substring: a consumer's own
#     SessionEnd entry that is not Jenga's no longer blocks Jenga's, which is added next to it.
#   - WorktreeCreate/WorktreeRemove replace Claude's default handling: when either holds an entry that is not Jenga's,
#     Jenga's is not added, "conflict hooks.<Event>" is reported and the run ends with exit 6 (every run, so a second run
#     is byte-identical but is not silent).
#   - the source of the entries is the shipped fragments, not the root settings.json; both settings files are written.

load helpers/assertions
load helpers/sync-fixture

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MERGE="$REPO_ROOT/scripts/merge-settings.sh"

setup_file() {
  sync_make_package
}

setup() {
  sync_make_consumer
  mkdir -p "$CONSUMER/.claude"
  cat > "$CONSUMER/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls)"] },
  "customKey": { "keep": true },
  "hooks": {
    "WorktreeCreate": [ { "hooks": [ { "type": "command", "command": "echo wt-create" } ] } ],
    "WorktreeRemove": [ { "hooks": [ { "type": "command", "command": "echo wt-remove" } ] } ],
    "SessionEnd": [ { "hooks": [ { "type": "command", "command": "\"$X\"/.claude/hooks/on_session_end.sh" } ] } ],
    "PostToolUse": [ { "matcher": "Edit", "hooks": [ { "type": "command", "command": "echo user-hook" } ] } ]
  }
}
JSON
}

settings() { printf '%s' "$CONSUMER/.claude/settings.json"; }

@test "merge: adds the recorder UserPromptSubmit hook and the preflight hook to a pre-E89 file" {
  run bash "$MERGE" --consumer-root "$CONSUMER" --package-root "$REPO_ROOT"
  # exit 6, not 0: the consumer's own WorktreeCreate/WorktreeRemove are a reported conflict (design note, section 4)
  [ "$status" -eq 6 ]
  assert_output_contains "added UserPromptSubmit"
  assert_output_contains "added PreToolUse"
  assert_output_contains "added SessionEnd"
  assert_output_contains "conflict hooks.WorktreeCreate"
  assert_output_contains "conflict hooks.WorktreeRemove"
  run jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | join(" ")' "$(settings)"
  assert_output_contains "on_recording_step.sh"
  run jq -r '.hooks.UserPromptSubmit[0].hooks[0].timeout' "$(settings)"
  [ "$output" = "10" ]
}

@test "merge: user-written hooks and every other key survive untouched" {
  run bash "$MERGE" --consumer-root "$CONSUMER" --package-root "$REPO_ROOT"
  [ "$status" -eq 6 ]
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$(settings)"
  [ "$output" = "echo user-hook" ]
  run jq -r '.hooks.WorktreeCreate[0].hooks[0].command, .hooks.WorktreeRemove[0].hooks[0].command' "$(settings)"
  [ "${lines[0]}" = "echo wt-create" ]
  [ "${lines[1]}" = "echo wt-remove" ]
  run jq -c '.permissions, .customKey' "$(settings)"
  [ "${lines[0]}" = '{"allow":["Bash(ls)"]}' ]
  [ "${lines[1]}" = '{"keep":true}' ]
  # The consumer's own WorktreeCreate/WorktreeRemove are not joined by Jenga's (they would create a worktree twice). Their
  # SessionEnd entry is not equal to the shipped one, so Jenga's is added next to it (was "1,1,1" with the substring rule);
  # the consumer's own entry stays first and untouched.
  run jq -r '[.hooks.WorktreeCreate, .hooks.WorktreeRemove, .hooks.SessionEnd | length] | join(",")' "$(settings)"
  [ "$output" = "1,1,2" ]
  run jq -r '.hooks.SessionEnd[0].hooks[0].command' "$(settings)"
  [ "$output" = '"$X"/.claude/hooks/on_session_end.sh' ]
}

@test "merge: a second run is byte-identical and says unchanged (the worktree conflict is reported again, exit 6)" {
  run bash "$MERGE" --consumer-root "$CONSUMER" --package-root "$REPO_ROOT"
  [ "$status" -eq 6 ]
  local before
  before="$(file_hash "$(settings)")"
  run bash "$MERGE" --consumer-root "$CONSUMER" --package-root "$REPO_ROOT"
  # was: status 0 and output exactly "unchanged"; the foreign worktree handler is now loud on every run
  [ "$status" -eq 6 ]
  assert_output_contains "unchanged"
  assert_output_contains "conflict hooks.WorktreeCreate"
  assert_output_not_contains "added UserPromptSubmit"
  assert_output_not_contains "added PreToolUse"
  assert_output_not_contains "added SessionEnd"
  [ "$before" = "$(file_hash "$(settings)")" ]
}

@test "merge: --dry-run reports what it would add and writes nothing" {
  local before
  before="$(file_hash "$(settings)")"
  run bash "$MERGE" --consumer-root "$CONSUMER" --package-root "$REPO_ROOT" --dry-run
  [ "$status" -eq 6 ]
  assert_output_contains "would add UserPromptSubmit"
  [ "$before" = "$(file_hash "$(settings)")" ]
  # nothing else is written either: no second settings file and no manifest
  [ ! -e "$CONSUMER/.agents" ]
  [ ! -e "$CONSUMER/.claude/jenga-settings-manifest.json" ]
}

@test "merge: a consumer with no settings.json gets one holding every shipped hook" {
  rm -f "$(settings)"
  run bash "$MERGE" --consumer-root "$CONSUMER" --package-root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  run jq -r '.hooks | keys | join(",")' "$(settings)"
  [ "$output" = "PreToolUse,SessionEnd,UserPromptSubmit,WorktreeCreate,WorktreeRemove" ]
  # the new script writes the same content to .agents/settings.json
  [ "$(file_hash "$(settings)")" = "$(file_hash "$CONSUMER/.agents/settings.json")" ]
}

@test "merge: an invalid settings.json is refused (exit 4) and left untouched" {
  printf '{ not json' > "$(settings)"
  run bash "$MERGE" --consumer-root "$CONSUMER" --package-root "$REPO_ROOT"
  [ "$status" -eq 4 ]
  [ "$(cat "$(settings)")" = "{ not json" ]
}

@test "merge: does nothing when the consumer root is the package itself (this repository)" {
  local before
  before="$(file_hash "$REPO_ROOT/.claude/settings.json")"
  run bash "$MERGE" --consumer-root "$REPO_ROOT" --package-root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  assert_output_contains "skipped"
  [ "$before" = "$(file_hash "$REPO_ROOT/.claude/settings.json")" ]
}

@test "merge: the recorder entry comes from the recorder fragment (the single source), and the root settings.json carries the same entry" {
  # was: read from the root settings.json; the shipped fragments are the source now (design note, section 3)
  run jq -c '.hooks.UserPromptSubmit' "$REPO_ROOT/skills/j-workflow-recorder/settings-fragment.json"
  local expected="$output"
  run bash "$MERGE" --consumer-root "$CONSUMER" --package-root "$REPO_ROOT"
  [ "$status" -eq 6 ]
  run jq -c '.hooks.UserPromptSubmit' "$(settings)"
  [ "$output" = "$expected" ]
  run jq -c '.hooks.UserPromptSubmit' "$REPO_ROOT/settings.json"
  [ "$output" = "$expected" ]
}

@test "sync: jenga sync registers the recorder hook in a pre-E89 settings.json, and a second sync is a no-op" {
  run jenga sync
  [ "$status" -eq 0 ]
  # the consumer's own worktree handlers are a warning, not a failure (exit stays 0)
  assert_output_contains "conflict(s)"
  run jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | join(" ")' "$(settings)"
  assert_output_contains "on_recording_step.sh"
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$(settings)"
  [ "$output" = "echo user-hook" ]

  local before
  before="$(tree_hash "$CONSUMER")"
  run jenga sync
  [ "$status" -eq 0 ]
  assert_output_contains "Nothing changed"
  [ "$before" = "$(tree_hash "$CONSUMER")" ]
}

@test "sync: --dry-run reports the hook registration and leaves settings.json alone" {
  local before
  before="$(file_hash "$(settings)")"
  run jenga sync --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "hooks would be registered"
  [ "$before" = "$(file_hash "$(settings)")" ]
  [ ! -e "$CONSUMER/.agents/settings.json" ]
}

# ---------------------------------------------------------------------------------------------------------------------
# The E89_S06_T20 case, end to end, and the two layouts (E100_S03_T08).
# ---------------------------------------------------------------------------------------------------------------------

# pre_recorder_settings <file>: a settings file as Jenga wrote it before the recorder hook existed: the shipped worktree and
# session-end entries (verbatim from the fragments), one user hook and two user keys, no UserPromptSubmit, no PreToolUse.
pre_recorder_settings() {
  mkdir -p "$(dirname "$1")"
  jq -n --slurpfile w "$REPO_ROOT/hooks/worktree.fragment.json" --slurpfile s "$REPO_ROOT/hooks/on_session_end.fragment.json" '
    { permissions: { allow: ["Bash(ls)"] }, customKey: { keep: true },
      hooks: ($w[0].hooks + $s[0].hooks
              + { PostToolUse: [ { matcher: "Edit", hooks: [ { type: "command", command: "echo user-hook" } ] } ] }) }' > "$1"
}

@test "E89_S06_T20: a settings file that predates the recorder gets the hook through jenga sync, a second sync is a no-op, user hooks and keys survive" {
  pre_recorder_settings "$(settings)"
  run jq -r '.hooks | has("UserPromptSubmit"), has("PreToolUse")' "$(settings)"
  [ "${lines[0]}" = "false" ]
  [ "${lines[1]}" = "false" ]

  run jenga sync
  [ "$status" -eq 0 ]
  assert_output_contains "hooks registered"
  assert_output_not_contains "conflict(s)"
  run jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | join(" ")' "$(settings)"
  assert_output_contains "on_recording_step.sh"
  run jq -r '.hooks.UserPromptSubmit[0].hooks[0].timeout' "$(settings)"
  [ "$output" = "10" ]
  run jq -r '.hooks.PreToolUse[0].matcher' "$(settings)"
  [ "$output" = "Bash|Task|Agent" ]

  # the user's own hook and keys, and the shipped entries that were already there, are untouched and not doubled
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$(settings)"
  [ "$output" = "echo user-hook" ]
  run jq -c '.permissions, .customKey' "$(settings)"
  [ "${lines[0]}" = '{"allow":["Bash(ls)"]}' ]
  [ "${lines[1]}" = '{"keep":true}' ]
  run jq -r '[.hooks.WorktreeCreate, .hooks.WorktreeRemove, .hooks.SessionEnd | length] | join(",")' "$(settings)"
  [ "$output" = "1,1,1" ]

  local before
  before="$(tree_hash "$CONSUMER")"
  run jenga sync
  [ "$status" -eq 0 ]
  assert_output_contains "Nothing changed"
  assert_output_not_contains "hooks registered"
  [ "$before" = "$(tree_hash "$CONSUMER")" ]
}

@test "E89_S06_T20: the script itself, on a settings file that predates the recorder, adds the hooks (exit 0) and a second run prints exactly unchanged" {
  pre_recorder_settings "$(settings)"
  run bash "$MERGE" --consumer-root "$CONSUMER" --package-root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  assert_output_contains "added UserPromptSubmit"
  assert_output_contains "added PreToolUse"
  assert_output_not_contains "conflict"
  local before
  before="$(tree_hash "$CONSUMER")"
  run bash "$MERGE" --consumer-root "$CONSUMER" --package-root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
  [ "$before" = "$(tree_hash "$CONSUMER")" ]
}

@test "layouts: the script run from node_modules/@jenga-ai/agent/scripts/ and from the monorepo give the same result" {
  local nm="$BATS_TEST_TMPDIR/consumer-nm" repo="$BATS_TEST_TMPDIR/consumer-repo" out_nm status_nm
  mkdir -p "$nm/node_modules/@jenga-ai" "$repo"
  cp -R "$PKG" "$nm/node_modules/@jenga-ai/agent"
  pre_recorder_settings "$nm/.claude/settings.json"
  pre_recorder_settings "$repo/.claude/settings.json"

  # consumer layout: no --package-root, so the package root is derived from the script's own place in node_modules
  run bash "$nm/node_modules/@jenga-ai/agent/scripts/merge-settings.sh" --consumer-root "$nm"
  status_nm="$status"; out_nm="$output"
  [ "$status_nm" -eq 0 ]
  assert_output_contains "added UserPromptSubmit"

  # monorepo layout: likewise derived (here: this repository)
  run bash "$MERGE" --consumer-root "$repo"
  [ "$status" -eq "$status_nm" ]
  [ "$output" = "$out_nm" ]

  local f
  for f in .claude/settings.json .agents/settings.json .claude/jenga-settings-manifest.json .agents/jenga-settings-manifest.json; do
    [ -f "$nm/$f" ] || { echo "missing in the consumer layout result: $f"; false; }
    [ "$(file_hash "$nm/$f")" = "$(file_hash "$repo/$f")" ] || { echo "differs between layouts: $f"; false; }
  done
  # and a second run from either layout is a no-op
  run bash "$nm/node_modules/@jenga-ai/agent/scripts/merge-settings.sh" --consumer-root "$nm"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
}
