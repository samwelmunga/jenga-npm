#!/usr/bin/env bats
#
# E69_S05_T05: can the pre-commit checklist phase see the commit message that is about to be written?
#
# This suite is the evidence behind the "Pre-commit timing finding (E69_S05_T05)" subsection of
# project/documentation/project-conventions.md. It runs the REAL scripts/checklist.sh check pre-commit and the REAL
# hooks/on_preflight_check.sh, in a scratch git repository, with a machine item whose `verify` command is a probe
# that tries to read the pending message in every way available to it: the environment, .git/COMMIT_EDITMSG,
# `git log -1`, its own arguments, and the working directory. It then asserts what is and what is not visible.
#
# What "pending message" means here. The message is a unique token that appears ONLY in the `git commit -m "<token>"`
# command line the hook is shown (the PreToolUse payload) and in the commit that is made afterwards. Nothing else in
# the scratch project mentions it, so any appearance of the token in the probe's observations would prove that
# pre-commit can see the message.
#
# Findings pinned (the expected result, per the task): a verify command cannot see the message being committed.
#   - checklist.sh check runs verify as `bash -c <verify>` from the project root with stdin from /dev/null, no
#     arguments, and the caller's environment; it never learns what is being committed.
#   - .git/COMMIT_EDITMSG holds the PREVIOUS commit's message until git writes the new one, which git does after the
#     hook-time check; `git log -1` shows the previous commit.
#   - hooks/on_preflight_check.sh is shown the full `git commit -m "<message>"` command in its payload, but uses it
#     only to match the gated operation (a glob on git*commit*); it does not hand it to checklist.sh.
# Consequence (documented, applied through data only): a commit-message regex machine item would test the wrong
# message, so commit-format stays judgment / advisory and its regex alternative stays disabled.
#
# Everything runs under $BATS_TEST_TMPDIR (a scratch repo, registry, tick store and marker directory) through
# JENGA_PROJECT_ROOT and the checklist seams; nothing here touches this repository's project/configs/ or its git state.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
MARKER="$REPO_ROOT/scripts/checklist-marker.sh"
HOOK="$REPO_ROOT/hooks/on_preflight_check.sh"
MAP="$REPO_ROOT/templates/conventions-checklist-map.json"
REAL_CONFIGS="$REPO_ROOT/project/configs"

PREVIOUS="previous commit subject"
PENDING="PENDING-MESSAGE-TOKEN-7f3a91"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  OBS="$T/observed.txt"
  PROBE="$T/probe.sh"
  mkdir -p "$PROJ/project/configs"
  cat > "$PROJ/project/configs/workflow.json" <<'JSON'
{
  "paths": {
    "queue": "project/queue",
    "configs": "project/configs"
  }
}
JSON
  printf '{"marker_ttl_minutes": 60}\n' > "$PROJ/project/configs/scope-thresholds.json"
  git init -q "$PROJ"
  git -C "$PROJ" config user.email t@example.com
  git -C "$PROJ" config user.name t
  git -C "$PROJ" config commit.gpgsign false
  printf 'x\n' > "$PROJ/a.txt"
  git -C "$PROJ" add a.txt
  git -C "$PROJ" commit -q -m "$PREVIOUS"

  # The probe tries every channel a verify command has and records what it saw.
  cat > "$PROBE" <<PROBE_EOF
#!/usr/bin/env bash
{
  echo "argc=\$#"
  echo "cwd=\$(pwd)"
  if [ -f .git/COMMIT_EDITMSG ]; then echo "editmsg=\$(head -n1 .git/COMMIT_EDITMSG)"; else echo "editmsg=<absent>"; fi
  echo "log1=\$(git log -1 --format=%s 2>/dev/null)"
  echo "env_token_hits=\$(env | grep -c '$PENDING')"
  echo "env_git_sum=\$(env | grep '^GIT_' | sort | cksum)"
  echo "args_token_hits=\$(printf '%s\n' "\$@" | grep -c '$PENDING')"
  echo "stdin_bytes=\$(cat | wc -c | tr -d ' ')"
} > "$OBS"
exit 0
PROBE_EOF

  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_FILE="$T/checklists.json"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$T/no-default-checklists.json"
  export JENGA_CHECKLIST_STATE_DIR="$T/state"
  export CLAUDE_CODE_SESSION_ID="sess-timing"
  unset JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_MARKER_DIR JENGA_CHECKLIST_RUN_ID
  unset JENGA_PREFLIGHT_HOOK_SCRIPT_DIR JENGA_PREFLIGHT_HOOK_DEBUG JENGA_CHECKLIST_NOW
  jq -n --arg v "bash $PROBE" '{checklist_version: 1, situations: [], items: [
    {id: "probe-message", text: "Probe what a verify can see of the commit message.", situations: ["pre-commit"],
     kind: "machine", verify: $v, enforcement: "block", tick_scope: "run"}]}' > "$JENGA_CHECKLISTS_FILE"
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# observed <key>: the value the probe recorded for <key>.
observed() { sed -n "s/^$1=//p" "$OBS" | head -n 1; }

# run_hook_bash <command>: the hook as the harness runs it (one JSON payload on stdin).
run_hook_bash() {
  local p
  p="$(jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')"
  run --separate-stderr bash "$HOOK" <<<"$p"
}

# --- the checker --------------------------------------------------------------------------------------------

@test "checklist.sh check pre-commit runs the probe, and the probe sees the PREVIOUS commit, not a pending message" {
  run --separate-stderr bash "$CHECKLIST" check pre-commit --run r1
  [ "$status" -eq 0 ]
  [ -f "$OBS" ]
  # git has already written COMMIT_EDITMSG for the previous commit; it is the previous message, not the pending one
  [ "$(observed editmsg)" = "$PREVIOUS" ]
  [ "$(observed log1)" = "$PREVIOUS" ]
  [ "$(observed editmsg)" != "$PENDING" ]
}

@test "the probe receives no arguments, no stdin, and no environment variable carrying a message" {
  run --separate-stderr bash "$CHECKLIST" check pre-commit --run r1
  [ "$status" -eq 0 ]
  [ "$(observed argc)" = "0" ]
  [ "$(observed args_token_hits)" = "0" ]
  [ "$(observed stdin_bytes)" = "0" ]
  [ "$(observed env_token_hits)" = "0" ]
  # the checker injects no GIT_* variable (GIT_COMMIT_MESSAGE, ...): the probe sees exactly the GIT_* variables
  # the caller already had (for example a GIT_EDITOR set by the harness), no more and no fewer
  [ "$(observed env_git_sum)" = "$(env | grep '^GIT_' | sort | cksum)" ]
}

@test "the probe runs from the project root, which is where .git/COMMIT_EDITMSG lives" {
  run --separate-stderr bash "$CHECKLIST" check pre-commit --run r1
  [ "$status" -eq 0 ]
  [ "$(observed cwd)" = "$(cd "$PROJ" && pwd -P)" ] || [ "$(observed cwd)" = "$PROJ" ]
}

@test "git writes the new message only AFTER the check: before the commit COMMIT_EDITMSG is the previous message, after it is the new one" {
  run --separate-stderr bash "$CHECKLIST" check pre-commit --run r1
  [ "$status" -eq 0 ]
  [ "$(observed editmsg)" = "$PREVIOUS" ]
  printf 'y\n' >> "$PROJ/a.txt"
  git -C "$PROJ" add a.txt
  git -C "$PROJ" commit -q -m "$PENDING"
  [ "$(head -n 1 "$PROJ/.git/COMMIT_EDITMSG")" = "$PENDING" ]
  [ "$(git -C "$PROJ" log -1 --format=%s)" = "$PENDING" ]
  # a check run now sees the commit that has just been made, i.e. a message that is no longer pending
  run --separate-stderr bash "$CHECKLIST" check pre-commit --run r2
  [ "$(observed log1)" = "$PENDING" ]
}

# --- the hook ---------------------------------------------------------------------------------------------

@test "the hook is shown 'git commit -m <message>' and runs the checker, but the message never reaches the verify" {
  bash "$MARKER" write --situation pre-commit --run r1 --skill j.test >/dev/null
  run_hook_bash "git commit -m \"$PENDING\""
  [ "$status" -eq 0 ]
  # the hook did run the checker (the probe left its observations) ...
  [ -f "$OBS" ]
  # ... and nothing the probe could look at carried the pending message
  [ "$(observed editmsg)" = "$PREVIOUS" ]
  [ "$(observed log1)" = "$PREVIOUS" ]
  [ "$(observed env_token_hits)" = "0" ]
  [ "$(observed args_token_hits)" = "0" ]
  [ "$(observed argc)" = "0" ]
}

@test "the hook matches git commit by a glob on the command, including a message with spaces and a chained command" {
  bash "$MARKER" write --situation pre-commit --run r1 --skill j.test >/dev/null
  run_hook_bash "cd /tmp && git -C \"$PROJ\" commit -m \"fix: $PENDING with spaces\""
  [ "$status" -eq 0 ]
  [ -f "$OBS" ]
  [ "$(observed log1)" = "$PREVIOUS" ]
}

@test "the hook does not run the checker for a command that is not git commit" {
  bash "$MARKER" write --situation pre-commit --run r1 --skill j.test >/dev/null
  run_hook_bash "ls -la"
  [ "$status" -eq 0 ]
  [ ! -e "$OBS" ]
}

@test "the hook's own source never forwards the command to the checker (it is used only to match the gated operation)" {
  # the single invocation of checklist.sh check passes only the phase and the run id
  run grep -n 'checklist.sh" check' "$HOOK"
  [ "$status" -eq 0 ]
  assert_not_contains "$output" 'PF_CMD'
  assert_not_contains "$output" '-m'
  # and PF_CMD is only ever an argument of the gated-operation matcher
  uses="$(grep -n 'PF_CMD' "$HOOK" | grep -v 'pf_is_gated_operation' | grep -v 'PF_CMD=' | grep -v '^[0-9]*:#' | wc -l | tr -d ' ')"
  [ "$uses" -eq 0 ]
}

# --- the consequence, through data only ---------------------------------------------------------------------

@test "consequence: commit-format stays judgment/advisory and its message-regex alternative stays disabled" {
  [ "$(jq -r '.categories["commit-format"] | .kind + "/" + .enforcement' "$MAP")" = "judgment/advisory" ]
  [ "$(jq -r '.categories["commit-format"].alternatives[0] | .id + "/" + (.enabled | tostring)' "$MAP")" = "message-regex-confirm/false" ]
}

@test "consequence: the disabled alternative's note records why (the finding), pointing at the documentation" {
  note="$(jq -r '.categories["commit-format"].alternatives[0].note' "$MAP")"
  assert_contains "$note" "E69_S05_T05"
  assert_contains "$note" "cannot see"
  assert_contains "$note" "project-conventions.md"
  assert_contains "$note" "Pre-commit timing finding"
}

@test "the finding is recorded in project/documentation/project-conventions.md" {
  doc="$REPO_ROOT/project/documentation/project-conventions.md"
  run grep -c '^### Pre-commit timing finding (E69_S05_T05)$' "$doc"
  [ "$status" -eq 0 ]
  sec="$(awk '/^### Pre-commit timing finding \(E69_S05_T05\)$/ { on = 1; next } on && /^##/ { exit } on { print }' "$doc")"
  assert_contains "$sec" "COMMIT_EDITMSG"
  assert_contains "$sec" "git log -1"
  assert_contains "$sec" "on_preflight_check.sh"
  assert_contains "$sec" "judgment"
  assert_contains "$sec" "advisory"
}

@test "scripts/checklist.sh and hooks/on_preflight_check.sh are not modified by this task (out of scope for the epic)" {
  # this task's whole contribution is evidence and data; the two scripts stay as they were on main
  base="$(git -C "$REPO_ROOT" merge-base HEAD main 2>/dev/null || true)"
  if [ -z "$base" ]; then skip "no main to compare against"; fi
  run git -C "$REPO_ROOT" diff --stat "$base" -- scripts/checklist.sh hooks/on_preflight_check.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
