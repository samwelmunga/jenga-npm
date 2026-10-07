#!/usr/bin/env bats
#
# Coverage for the situation marker and the enforcing pre-flight hook (E67_S04_T03).
#
# Contract under test:
#   - scripts/checklist-marker.sh   header comment: write, clear, read, session keying, nesting, stale recovery
#   - hooks/on_preflight_check.sh   header comment: the decision table, the fast path, the fail-open rule
#   - project/documentation/preflight-checklists.md   "Situation marker" and "The enforcing hook"
#
# Isolation. Everything runs in a temp project root ($PROJ) reached through JENGA_PROJECT_ROOT: a workflow.json that
# names the queue and configs directories, a scope-thresholds.json that carries marker_ttl_minutes, and a registry
# generated per test. So the marker directory, the TTL lookup and the hook's pure-bash directory probe all resolve the
# way they do in a real project, rather than through JENGA_CHECKLIST_MARKER_DIR. The real project's marker directory,
# registry, tick store and .jenga-permission-level.json are never read or written. The hook is run exactly as the
# harness runs it: one JSON payload on stdin, the session key taken from CLAUDE_CODE_SESSION_ID.
#
# What a "session" is here. Nothing in a script can observe which session it runs in, so a session is its key:
# `as_session <key> <command...>` runs a command with CLAUDE_CODE_SESSION_ID set to <key>, which is the normal source
# of the key in production. Two sessions are therefore two different keys driving the real scripts, and the tests
# that need two (concurrency) really do run both.
#
# Expiry. The stale-marker test uses an ACTUALLY expired frame: the frame is written with the clock seam
# (JENGA_CHECKLIST_NOW) set years in the past, so its stored expires_at is long gone by the real clock, and it is
# then read with NO clock override. The expiry check itself is never bypassed or stubbed.
#
# Level 5. The test that the hook blocks under the unrestricted permission template does what the E67_S04_T02
# developer did, as a real test: in a git-init sandbox it runs the real level switch (which overwrites the sandbox's
# own .claude/ and .agents/ settings.json from the real template), extracts the registered hook command from the
# SANDBOX settings, and runs that command against a failing fixture. The repository's own
# .jenga-permission-level.json is never touched, and the test asserts that.
#
# Re-entry semantics (settled by the E67_S04_T01 reopening, 2026-10-04): write is a PURE PUSH - every call adds a frame
# with a new token - and refresh --token extends exactly one frame in place (exit 3 when the token names no live
# frame). The earlier "refresh the matching frame" behaviours (top-only, then anywhere) were guesses and are retired;
# the tests below pin the push/refresh split, including the non-adjacent pre-commit -> pre-task -> pre-commit shape.
#
# Deliberately NOT pinned (so a later decision about it is not blocked by this file):
#   - The wording of the refusal reason beyond the item id and the phase name, and the exact warning text of a
#     fail-open beyond "exited <n>" and "NOT active".
#   - Timing. The no-marker cost claims (milliseconds) are measurements recorded in the documentation, not
#     behaviour, and a timing assertion would be flaky on a loaded machine.
#
# Not run here, on purpose: the claim that the Claude Code HARNESS honours a PreToolUse exit 2 while in a permissive
# mode. That is documented harness behaviour; what this suite can and does pin is that the hook REFUSES (exit 2 and
# a reason on stderr) with the unrestricted template in effect, and that the registration survives the level switch.
#
# Exit 4 and 5 of the checker cannot be produced through the real checker without breaking the toolchain the hook
# itself needs (the marker read already needs python3, and 5 is a bug-only branch), so those two fail-open cases use
# a stub checker behind JENGA_PREFLIGHT_HOOK_SCRIPT_DIR; the real marker script is still the one that runs. Exit 1
# and 2 use the real checker (an invalid registry; a bad timeout override).

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MARKER="$REPO_ROOT/scripts/checklist-marker.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
HOOK="$REPO_ROOT/hooks/on_preflight_check.sh"
SWITCH="$REPO_ROOT/scripts/jenga-permission-level-switch.sh"
TEMPLATE_DIR="$REPO_ROOT/templates/permission-levels"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  F="$T/checklists.json"
  STATE="$T/state"
  MARKER_DIR="$PROJ/project/queue/checklist-markers"
  mkdir -p "$PROJ/project/configs"
  # Pretty-printed on purpose, so the hook's pure-bash probe of paths.queue (one key per line) can read it.
  cat > "$PROJ/project/configs/workflow.json" <<'EOF'
{
  "paths": {
    "queue": "project/queue",
    "configs": "project/configs"
  }
}
EOF
  cat > "$PROJ/project/configs/scope-thresholds.json" <<'EOF'
{
  "marker_ttl_minutes": 60
}
EOF
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_FILE="$F"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$T/no-default-checklists.json"
  export JENGA_CHECKLIST_STATE_DIR="$STATE"
  export CLAUDE_CODE_SESSION_ID="sess-main"
  unset JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_MARKER_DIR JENGA_CHECKLIST_MARKER_TTL_MINUTES
  unset JENGA_SCOPE_THRESHOLDS_FILE JENGA_CHECKLIST_NOW JENGA_PREFLIGHT_HOOK_SCRIPT_DIR JENGA_PREFLIGHT_HOOK_DEBUG
  unset JENGA_CHECKLIST_RUN_ID JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES JENGA_CHECKLIST_VERIFY_TIMEOUT
}

# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------

# item <id> <kind> <enforcement> <tick_scope> [verify]   -> one registry item as JSON on stdout.
# situations default to ["pre-commit"] (override with SIT='["pre-task"]'). A verify is only emitted for machine items.
item() {
  local sit='["pre-commit"]'
  sit="${SIT:-$sit}"
  jq -n --arg id "$1" --arg kind "$2" --arg enf "$3" --arg scope "$4" --arg verify "${5:-}" \
    --arg text "Item $1." --argjson sit "$sit" \
    '{id: $id, text: $text, situations: $sit, kind: $kind, enforcement: $enf, tick_scope: $scope}
     + (if $kind == "machine" then {verify: $verify} else {} end)'
}

# write_registry <item-json>...   -> the project registry at $F, declaring no extension situations.
write_registry() {
  printf '%s\n' "$@" | jq -s '{checklist_version: 1, situations: [], items: .}' > "$F"
}

# A registry whose only item is a machine item that always fails, enforced as $1 at pre-commit.
failing_item_registry() {
  write_registry "$(item "$2" machine "$1" run false)"
}

# -----------------------------------------------------------------------------
# Runners
# -----------------------------------------------------------------------------

# as_session <key> <command...>: run a command as the session with that key.
as_session() {
  local key="$1"
  shift
  CLAUDE_CODE_SESSION_ID="$key" "$@"
}

# without_session <command...>: run a command (a function is fine) where NO session key can be resolved. It must stay
# in the current shell, not a subshell, so that a `run` inside the command still sets $status, $output and $stderr.
without_session() {
  local saved="$CLAUDE_CODE_SESSION_ID" rc
  unset CLAUDE_CODE_SESSION_ID JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID
  "$@"
  rc=$?
  export CLAUDE_CODE_SESSION_ID="$saved"
  return "$rc"
}

# payload <tool> [command]: the hook payload the harness sends.
payload() {
  jq -nc --arg t "$1" --arg c "${2:-}" '{tool_name: $t, tool_input: {command: $c}}'
}

# run_hook <tool> [command]: run the hook on that tool call; $output is stdout, $stderr is stderr, $status the exit code.
run_hook() {
  local p
  p="$(payload "$1" "${2:-}")"
  run --separate-stderr bash "$HOOK" <<<"$p"
}

# run_hook_bash <command>: run the hook on a Bash call.
run_hook_bash() { run_hook Bash "$1"; }

# enter <situation> [run-id]: the gating skill's phase entry, in the current session. Prints the frame's token.
enter() {
  if [ -n "${2:-}" ]; then
    bash "$MARKER" write --situation "$1" --run "$2" --skill j.test
  else
    bash "$MARKER" write --situation "$1" --skill j.test
  fi
}

# assert_allowed: the last hook run let the call through (exit 0, and no deny decision on stdout).
assert_allowed() {
  [ "$status" -eq 0 ] || { echo "hook exited $status, expected 0 (allow). stdout: $output stderr: $stderr" >&2; return 1; }
  assert_not_contains "$output" '"deny"'
}

# assert_denied <item-id> <phase>: the last hook run refused the call, named the item and the phase on stderr, and
# said so in the deny JSON too.
assert_denied() {
  [ "$status" -eq 2 ] || { echo "hook exited $status, expected 2 (refuse). stdout: $output stderr: $stderr" >&2; return 1; }
  assert_contains "$stderr" "$1"
  assert_contains "$stderr" "$2"
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ] \
    || { echo "stdout is not a deny decision: $output" >&2; return 1; }
}

# registered_hook_entry <settings-file>: the PreToolUse entry that registers this hook, as compact JSON.
registered_hook_entry() {
  jq -c '[.hooks.PreToolUse[]? | select(any(.hooks[]?; (.command // "") | contains("on_preflight_check.sh")))]' "$1"
}

# registered_hook_command <settings-file>: the shell command that entry runs.
registered_hook_command() {
  jq -r '[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | contains("on_preflight_check.sh")) | .command][0] // empty' "$1"
}

# make_sandbox: a git-init directory that the level-switch script will treat as the repository root.
make_sandbox() {
  SANDBOX="$T/sandbox"
  mkdir -p "$SANDBOX"
  git init -q "$SANDBOX"
}

# switch_level <n>: run the real level-switch script against the sandbox.
switch_level() {
  run bash -c 'cd "$1" && bash "$2" "$3"' _ "$SANDBOX" "$SWITCH" "$1"
  [ "$status" -eq 0 ] || { echo "level switch to $1 failed ($status): $output" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# AC1, behaviour 1: the marker is written on phase entry and cleared on exit
# -----------------------------------------------------------------------------

@test "marker: written on phase entry and cleared on phase exit" {
  # Entry: write prints the frame's token, and read then reports the phase that was entered.
  run bash "$MARKER" write --situation pre-commit --run run-123 --skill j.commit
  [ "$status" -eq 0 ]
  token="$output"
  [ -n "$token" ]
  [ "$(printf '%s\n' "$token" | wc -l | tr -d ' ')" -eq 1 ]

  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ "$(jq -r '.situation' <<<"$output")" = "pre-commit" ]
  [ "$(jq -r '.run_id' <<<"$output")" = "run-123" ]
  [ "$(jq -r '.skill' <<<"$output")" = "j.commit" ]
  [ "$(jq -r '.token' <<<"$output")" = "$token" ]
  [ "$(jq -r '.depth' <<<"$output")" = "1" ]

  run bash "$MARKER" read --field situation
  [ "$status" -eq 0 ]
  [ "$output" = "pre-commit" ]

  # Exit: clear by token, after which no phase is active and read prints nothing.
  run bash "$MARKER" clear --token "$token"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "marker: entering a phase arms the hook and leaving it disarms the hook" {
  failing_item_registry block must-pass

  run_hook_bash "git commit -m x"
  assert_allowed

  token="$(enter pre-commit run-1)"
  run_hook_bash "git commit -m x"
  assert_denied must-pass pre-commit

  bash "$MARKER" clear --token "$token"
  run_hook_bash "git commit -m x"
  assert_allowed
}

@test "marker: clear is idempotent and never an error, and does not create the marker directory" {
  run bash "$MARKER" clear --situation pre-commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$MARKER" clear --all
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER_DIR" ]

  # Clearing a frame that was already cleared is also a silent success.
  token="$(enter pre-commit)"
  bash "$MARKER" clear --token "$token"
  run bash "$MARKER" clear --token "$token"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "marker: write with no resolvable session key is refused (exit 7) and writes nothing" {
  run --separate-stderr without_session bash "$MARKER" write --situation pre-commit
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  [ ! -e "$MARKER_DIR" ] || [ -z "$(ls -A "$MARKER_DIR")" ]
}

# -----------------------------------------------------------------------------
# Re-entry (write always pushes, refresh --token extends one frame) and nesting
# -----------------------------------------------------------------------------

@test "marker: write always pushes - repeating a write grows the stack and mints a distinct token each time" {
  first="$(enter pre-commit run-1)"
  second="$(enter pre-commit run-1)"
  third="$(enter pre-commit run-1)"
  [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ]
  [ "$first" != "$second" ]
  [ "$second" != "$third" ]
  [ "$first" != "$third" ]

  # The stack really grew: the active frame is the newest one, at depth 3, and the file holds three frames.
  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ "$(jq -r '.token' <<<"$output")" = "$third" ]
  [ "$(jq -r '.depth' <<<"$output")" = "3" ]
  file="$(bash "$MARKER" path)"
  [ "$(jq -r '.stack | length' "$file")" = "3" ]
  [ "$(jq -r '[.stack[].token] | join(",")' "$file")" = "$first,$second,$third" ]

  # Each token clears exactly its own frame (and what is above it): the newest first leaves the older two.
  bash "$MARKER" clear --token "$third"
  [ "$(bash "$MARKER" read --field depth)" = "2" ]
  [ "$(bash "$MARKER" read --field token)" = "$second" ]
  bash "$MARKER" clear --token "$first"
  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "marker: refresh --token extends exactly that frame and keeps its token, position and depth" {
  # 12:00 an outer pre-task phase, 12:50 an inner pre-commit nested on it, 12:55 the outer one refreshes itself.
  outer="$(JENGA_CHECKLIST_NOW=2026-10-04T12:00:00Z enter pre-task run-outer)"
  inner="$(JENGA_CHECKLIST_NOW=2026-10-04T12:50:00Z enter pre-commit run-inner)"
  file="$(bash "$MARKER" path)"
  [ "$(jq -r '.stack[0].expires_at' "$file")" = "2026-10-04T13:00:00Z" ]
  [ "$(jq -r '.stack[1].expires_at' "$file")" = "2026-10-04T13:50:00Z" ]

  run env JENGA_CHECKLIST_NOW=2026-10-04T12:55:00Z bash "$MARKER" refresh --token "$outer"
  [ "$status" -eq 0 ]
  [ "$output" = "$outer" ]

  # Same two frames, same order, same tokens - nothing pushed - and only the named frame's expiry moved.
  [ "$(jq -r '.stack | length' "$file")" = "2" ]
  [ "$(jq -r '.stack[0].token' "$file")" = "$outer" ]
  [ "$(jq -r '.stack[1].token' "$file")" = "$inner" ]
  [ "$(jq -r '.stack[0].expires_at' "$file")" = "2026-10-04T13:55:00Z" ]
  [ "$(jq -r '.stack[0].written_at' "$file")" = "2026-10-04T12:55:00Z" ]
  [ "$(jq -r '.stack[1].expires_at' "$file")" = "2026-10-04T13:50:00Z" ]
  [ "$(jq -r '.stack[0].run_id' "$file")" = "run-outer" ]

  # Refreshing the buried outer frame did not change the active phase: it is still the inner one.
  run env JENGA_CHECKLIST_NOW=2026-10-04T12:56:00Z bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ "$(jq -r '.situation' <<<"$output")" = "pre-commit" ]
  [ "$(jq -r '.token' <<<"$output")" = "$inner" ]
  [ "$(jq -r '.depth' <<<"$output")" = "2" ]

  # The refresh achieved something: after the inner phase leaves at 13:30 the outer frame is still live, although
  # its ORIGINAL expiry (13:00) has passed - and it is dead again once the REFRESHED expiry (13:55) passes.
  JENGA_CHECKLIST_NOW=2026-10-04T13:30:00Z bash "$MARKER" clear --token "$inner"
  run env JENGA_CHECKLIST_NOW=2026-10-04T13:31:00Z bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ "$(jq -r '.token' <<<"$output")" = "$outer" ]
  [ "$(jq -r '.depth' <<<"$output")" = "1" ]
  run env JENGA_CHECKLIST_NOW=2026-10-04T13:56:00Z bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "marker: refresh with an unknown token fails loudly with exit 3, says so, and changes nothing" {
  token="$(JENGA_CHECKLIST_NOW=2026-10-04T12:00:00Z enter pre-task run-1)"
  file="$(bash "$MARKER" path)"
  before="$(cat "$file")"

  run --separate-stderr env JENGA_CHECKLIST_NOW=2026-10-04T12:30:00Z bash "$MARKER" refresh --token pre-task-0000000000000000
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" "no live frame"
  [ "$(cat "$file")" = "$before" ]

  # The real frame's expiry was not touched by the failed attempt: it still dies at 13:00.
  run env JENGA_CHECKLIST_NOW=2026-10-04T13:00:00Z bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(JENGA_CHECKLIST_NOW=2026-10-04T12:59:00Z bash "$MARKER" read --field token)" = "$token" ]

  # A cleared frame's token is an unknown token too; so is refresh with no marker file at all, and neither creates
  # the marker directory.
  bash "$MARKER" clear --token "$token"
  run --separate-stderr bash "$MARKER" refresh --token "$token"
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "no live frame"
  rm -rf "$MARKER_DIR"
  run --separate-stderr bash "$MARKER" refresh --token "$token"
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "no live frame"
  [ ! -e "$MARKER_DIR" ]
}

@test "marker: refresh of an EXPIRED frame fails with exit 3 and does not resurrect it" {
  failing_item_registry block must-pass
  # Written 2020-01-01 00:00, 60 minute TTL: dead since 01:00 that day, by the real clock.
  token="$(JENGA_CHECKLIST_NOW=2020-01-01T00:00:00Z enter pre-commit run-old)"

  run --separate-stderr bash "$MARKER" refresh --token "$token"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  assert_contains "$stderr" "no live frame"

  # Not resurrected: nothing is active, and the hook does not gate.
  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_hook_bash "git commit -m x"
  assert_allowed

  # Also when the clock seam places "now" exactly at the expiry instant: at or past expires_at is expired.
  live_token="$(JENGA_CHECKLIST_NOW=2026-10-04T12:00:00Z enter pre-task)"
  run --separate-stderr env JENGA_CHECKLIST_NOW=2026-10-04T13:00:00Z bash "$MARKER" refresh --token "$live_token"
  [ "$status" -eq 3 ]
  [ -z "$(JENGA_CHECKLIST_NOW=2026-10-04T13:00:00Z bash "$MARKER" read)" ]

  # The documented recovery: the caller branches on exit 3 and writes again, which yields a fresh LIVE frame with a
  # NEW token (the expired frame stays gone).
  bash "$MARKER" clear --all
  fresh="$(enter pre-commit run-new)"
  [ "$fresh" != "$token" ]
  [ "$(bash "$MARKER" read --field token)" = "$fresh" ]
  [ "$(bash "$MARKER" read --field depth)" = "1" ]
  run_hook_bash "git commit -m x"
  assert_denied must-pass pre-commit
}

@test "marker: refresh validates its arguments and needs a session key" {
  run --separate-stderr bash "$MARKER" refresh
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "--token"
  run --separate-stderr bash "$MARKER" refresh --token 'bad token!'
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$MARKER" refresh --token abc --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr without_session bash "$MARKER" refresh --token abc
  [ "$status" -eq 7 ]
  [ ! -e "$MARKER_DIR" ]
}

@test "marker: a situation re-entered non-adjacently gets its own frame, and the inner clear leaves the enclosing phase gated" {
  # pre-commit -> pre-task -> pre-commit: the shape that refresh-anywhere got wrong (the inner write returned the
  # OUTER frame's token, read reported pre-task, and the inner clear popped the still-running pre-task frame).
  write_registry \
    "$(item commit-gate machine block run false)" \
    "$(SIT='["pre-task"]' item task-gate machine block run false)"

  outer_commit="$(enter pre-commit run-a)"
  task="$(enter pre-task run-b)"
  inner_commit="$(enter pre-commit run-c)"
  [ "$inner_commit" != "$outer_commit" ]
  [ "$inner_commit" != "$task" ]

  # The active phase is the innermost frame - the inner pre-commit - and it carries the INNER caller's token.
  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ "$(jq -r '.situation' <<<"$output")" = "pre-commit" ]
  [ "$(jq -r '.token' <<<"$output")" = "$inner_commit" ]
  [ "$(jq -r '.run_id' <<<"$output")" = "run-c" ]
  [ "$(jq -r '.depth' <<<"$output")" = "3" ]
  run_hook_bash "git commit -m x"
  assert_denied commit-gate pre-commit

  # The inner caller clears its own token. Only the inner frame goes: the enclosing pre-task frame is still on the
  # stack, is the active phase again, and still gates (a subagent dispatch is refused; a commit is not its business).
  bash "$MARKER" clear --token "$inner_commit"
  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ "$(jq -r '.situation' <<<"$output")" = "pre-task" ]
  [ "$(jq -r '.token' <<<"$output")" = "$task" ]
  [ "$(jq -r '.depth' <<<"$output")" = "2" ]
  run_hook Task
  assert_denied task-gate pre-task
  run_hook_bash "git commit -m x"
  assert_allowed

  # And the outermost pre-commit frame survives beneath it, under its own token.
  bash "$MARKER" clear --token "$task"
  [ "$(bash "$MARKER" read --field token)" = "$outer_commit" ]
  [ "$(bash "$MARKER" read --field depth)" = "1" ]
  run_hook_bash "git commit -m x"
  assert_denied commit-gate pre-commit
  bash "$MARKER" clear --token "$outer_commit"
  run bash "$MARKER" read
  [ -z "$output" ]
}

@test "marker: nested distinct phases report the innermost, and leaving the inner phase restores the outer" {
  outer="$(enter pre-task run-outer)"
  inner="$(enter pre-commit run-inner)"
  [ "$inner" != "$outer" ]

  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ "$(jq -r '.situation' <<<"$output")" = "pre-commit" ]
  [ "$(jq -r '.depth' <<<"$output")" = "2" ]

  # The inner phase leaving must NOT delete the outer phase's marker (the silent hole the stack exists to prevent).
  bash "$MARKER" clear --token "$inner"
  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ "$(jq -r '.situation' <<<"$output")" = "pre-task" ]
  [ "$(jq -r '.run_id' <<<"$output")" = "run-outer" ]
  [ "$(jq -r '.depth' <<<"$output")" = "1" ]

  bash "$MARKER" clear --token "$outer"
  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# -----------------------------------------------------------------------------
# AC1, behaviour 2: an expired marker is treated as absent (an ACTUALLY expired frame)
# -----------------------------------------------------------------------------

@test "marker: an actually-expired marker is treated as absent by read and by the hook" {
  failing_item_registry block must-pass

  # Written as if on 2020-01-01 with the configured 60 minute TTL, so its stored expires_at is 01:00 that day. It is
  # read below with NO clock override, against the real clock.
  run env JENGA_CHECKLIST_NOW=2020-01-01T00:00:00Z bash "$MARKER" write --situation pre-commit --run run-old --skill j.commit
  [ "$status" -eq 0 ]

  # It really is on disk, with the expiry the config's TTL implies - so what follows is the expiry check doing the
  # work, not the marker being missing.
  run bash "$MARKER" path
  [ "$status" -eq 0 ]
  file="$output"
  [ -f "$file" ]
  [ "$(jq -r '.stack | length' "$file")" = "1" ]
  [ "$(jq -r '.stack[0].situation' "$file")" = "pre-commit" ]
  [ "$(jq -r '.stack[0].expires_at' "$file")" = "2020-01-01T01:00:00Z" ]

  run bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$MARKER" read --field situation
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # The hook treats it as absent too: a failing block item and a gated command, and the call is allowed, silently.
  run_hook_bash "git commit -m x"
  assert_allowed
  [ -z "$output" ]

  # Control: the same registry and command ARE refused once the phase is entered afresh, so the allow above was
  # the expiry, not a gate that could not fire.
  enter pre-commit run-new >/dev/null
  run_hook_bash "git commit -m x"
  assert_denied must-pass pre-commit
}

# -----------------------------------------------------------------------------
# AC1, behaviour 3: no marker at all -> the hook is a silent no-op
# -----------------------------------------------------------------------------

@test "hook: with no marker at all it is a silent no-op (no output, exit 0)" {
  failing_item_registry block must-pass

  # No marker directory exists at all - the ordinary session.
  [ ! -e "$MARKER_DIR" ]
  run_hook_bash "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  run_hook Task
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  run_hook_bash "git push origin main"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  # The hook creates nothing.
  [ ! -e "$MARKER_DIR" ]

  # The marker directory exists but holds no marker (a phase was entered and left): still silent.
  token="$(enter pre-commit)"
  bash "$MARKER" clear --token "$token"
  run_hook_bash "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# -----------------------------------------------------------------------------
# AC1, behaviours 4 and 5: block refuses (exit 2, item named); advisory does not
# -----------------------------------------------------------------------------

@test "hook: a failed block item refuses the gated command (exit 2) and names the item on stderr" {
  failing_item_registry block no-dirty-tree
  enter pre-commit run-1 >/dev/null

  run_hook_bash "git commit -m x"
  assert_denied no-dirty-tree pre-commit
  assert_contains "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" "no-dirty-tree"

  # Control: the same item, passing, lets the same command through - so the refusal is the failed item.
  write_registry "$(item no-dirty-tree machine block run true)"
  run_hook_bash "git commit -m x"
  assert_allowed
  [ -z "$stderr" ]
}

@test "hook: a compound command containing a commit is refused too" {
  failing_item_registry block no-dirty-tree
  enter pre-commit run-1 >/dev/null

  run_hook_bash 'cd x && git -C /p commit -m "msg"'
  assert_denied no-dirty-tree pre-commit

  run_hook_bash 'echo start && git add -A && git commit -m "msg" && echo done'
  assert_denied no-dirty-tree pre-commit
}

@test "hook: a failed advisory item does not block" {
  failing_item_registry advisory nice-to-have
  enter pre-commit run-1 >/dev/null

  run_hook_bash "git commit -m x"
  assert_allowed

  # Control: add a failing block item next to it, and the same command is refused - the advisory-only allow above
  # was the advisory item not blocking, not a gate that never ran.
  write_registry "$(item nice-to-have machine advisory run false)" "$(item must-pass machine block run false)"
  run_hook_bash "git commit -m x"
  assert_denied must-pass pre-commit
}

@test "hook: a confirm item gives ask, exit 0, with the decision on stdout" {
  failing_item_registry confirm needs-a-human
  enter pre-commit run-1 >/dev/null

  run_hook_bash "git commit -m x"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "ask" ]
  assert_contains "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" "needs-a-human"
  assert_not_contains "$output" '"deny"'
}

@test "hook: the run id in the marker makes run-scoped ticks visible to the hook" {
  write_registry "$(item confirmed-by-user judgment block run)"

  # Entered with --run: unticked, refused; ticked under that run, allowed.
  enter pre-commit run-A >/dev/null
  run_hook_bash "git commit -m x"
  assert_denied confirmed-by-user pre-commit
  run bash "$CHECKLIST" tick confirmed-by-user --run run-A --by "agent:test"
  [ "$status" -eq 0 ]
  run_hook_bash "git commit -m x"
  assert_allowed

  # A phase entered under a DIFFERENT run id does not see run-A's tick.
  bash "$MARKER" clear --all
  enter pre-commit run-B >/dev/null
  run_hook_bash "git commit -m x"
  assert_denied confirmed-by-user pre-commit
}

@test "hook: gates only the active phase's own operation, so remediation is never wedged" {
  failing_item_registry block must-pass
  enter pre-commit run-1 >/dev/null

  # Commands that are not pre-commit's irreversible operation go through, including the ones remediation needs.
  run_hook_bash "ls -la"
  assert_allowed
  run_hook_bash "git status"
  assert_allowed
  run_hook_bash "bash scripts/checklist.sh tick must-pass --run run-1"
  assert_allowed
  run_hook_bash "git push origin main"
  assert_allowed
  run_hook Task
  assert_allowed
  bash "$MARKER" clear --all

  # pre-task gates subagent dispatch and worktree creation, and not a commit.
  write_registry "$(SIT='["pre-task"]' item task-gate machine block run false)"
  enter pre-task run-2 >/dev/null
  run_hook Task
  assert_denied task-gate pre-task
  run_hook Agent
  assert_denied task-gate pre-task
  run_hook_bash "git worktree add ../wt -b wt"
  assert_denied task-gate pre-task
  run_hook_bash "git commit -m x"
  assert_allowed
}

# -----------------------------------------------------------------------------
# AC1, behaviour 6 (AC4): two concurrent sessions in different phases never read each other's marker
# -----------------------------------------------------------------------------

@test "marker and hook: two sessions in different phases never read each other's marker" {
  write_registry \
    "$(item commit-gate machine block run false)" \
    "$(SIT='["pre-task"]' item task-gate machine block run false)"

  # Two sessions, entering their phases at the same time (really concurrent writers).
  as_session sess-A bash "$MARKER" write --situation pre-commit --run run-A --skill j.commit > "$T/token-A" &
  pid_a=$!
  as_session sess-B bash "$MARKER" write --situation pre-task --run run-B --skill j.do > "$T/token-B" &
  pid_b=$!
  wait "$pid_a"
  wait "$pid_b"
  [ -s "$T/token-A" ]
  [ -s "$T/token-B" ]

  # They wrote two different files, and each sees only its own phase.
  path_a="$(as_session sess-A bash "$MARKER" path)"
  path_b="$(as_session sess-B bash "$MARKER" path)"
  [ "$path_a" != "$path_b" ]
  [ -f "$path_a" ]
  [ -f "$path_b" ]
  [ "$(as_session sess-A bash "$MARKER" read --field situation)" = "pre-commit" ]
  [ "$(as_session sess-A bash "$MARKER" read --field run_id)" = "run-A" ]
  [ "$(as_session sess-B bash "$MARKER" read --field situation)" = "pre-task" ]
  [ "$(as_session sess-B bash "$MARKER" read --field run_id)" = "run-B" ]

  # The hook honours that. A is in pre-commit: its commit is refused, its worktree creation is not gated.
  as_session sess-A run_hook_bash "git commit -m x"
  assert_denied commit-gate pre-commit
  as_session sess-A run_hook_bash "git worktree add ../wt -b wt"
  assert_allowed

  # B is in pre-task: the very same commit is NOT refused (it never reads A's pre-commit marker), while B's own
  # gated operation is.
  as_session sess-B run_hook_bash "git commit -m x"
  assert_allowed
  as_session sess-B run_hook_bash "git worktree add ../wt -b wt"
  assert_denied task-gate pre-task

  # A third session that never entered a phase, in a directory that now holds two other sessions' markers, is
  # unaffected by both.
  as_session sess-C run_hook_bash "git commit -m x"
  assert_allowed
  as_session sess-C run_hook_bash "git worktree add ../wt -b wt"
  assert_allowed
  [ -z "$(as_session sess-C bash "$MARKER" read)" ]

  # One session leaving its phase does not disturb the other's.
  as_session sess-A bash "$MARKER" clear --token "$(cat "$T/token-A")"
  [ -z "$(as_session sess-A bash "$MARKER" read)" ]
  as_session sess-A run_hook_bash "git commit -m x"
  assert_allowed
  [ "$(as_session sess-B bash "$MARKER" read --field situation)" = "pre-task" ]
  as_session sess-B run_hook_bash "git worktree add ../wt -b wt"
  assert_denied task-gate pre-task
}

@test "marker: a marker file copied under another session's name is treated as absent" {
  failing_item_registry block must-pass
  enter pre-commit run-1 >/dev/null
  src="$(bash "$MARKER" path)"
  dest="$(as_session sess-other bash "$MARKER" path)"
  [ "$src" != "$dest" ]
  cp "$src" "$dest"

  # The copy sits under sess-other's file name but records sess-main as its session, so sess-other must not act on it.
  run --separate-stderr as_session sess-other bash "$MARKER" read
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  as_session sess-other run_hook_bash "git commit -m x"
  assert_allowed

  # The original is untouched and still gates its own session.
  run_hook_bash "git commit -m x"
  assert_denied must-pass pre-commit
}

# -----------------------------------------------------------------------------
# Session-key mismatch: a hook that cannot resolve the writer's key reads "no phase active"
# -----------------------------------------------------------------------------

@test "hook: a hook that resolves a different session key than the writer's sees no active phase" {
  failing_item_registry block must-pass
  enter pre-commit run-1 >/dev/null

  # Control: with the writer's own key it refuses.
  run_hook_bash "git commit -m x"
  assert_denied must-pass pre-commit

  # A different key: no phase is active for it, so the call is allowed (fail-open, never a gate on the wrong session).
  as_session sess-not-the-writer run_hook_bash "git commit -m x"
  assert_allowed
  assert_not_contains "$stderr" "must-pass"
}

@test "hook: a hook that cannot resolve any session key sees no active phase" {
  failing_item_registry block must-pass
  enter pre-commit run-1 >/dev/null

  without_session run_hook_bash "git commit -m x"
  assert_allowed
  assert_not_contains "$stderr" "must-pass"

  # The same is true of the JENGA_SESSION_ID fallback naming a different session than the writer's.
  p="$(payload Bash "git commit -m x")"
  run --separate-stderr without_session env JENGA_SESSION_ID=some-other-session bash "$HOOK" <<<"$p"
  assert_allowed
}

# -----------------------------------------------------------------------------
# Fail-open: a checker setup error is allowed, loudly
# -----------------------------------------------------------------------------

# assert_fails_open <exit-code>: the last hook run allowed the call and said, on stderr, that enforcement is not active.
assert_fails_open() {
  [ "$status" -eq 0 ] || { echo "hook exited $status, expected 0 (fail open). stderr: $stderr" >&2; return 1; }
  assert_not_contains "$output" '"deny"'
  assert_contains "$stderr" "exited $1"
  assert_contains "$stderr" "NOT active"
}

# stub_checker <exit-code>: a script directory whose checker always exits <exit-code>, with the REAL marker script.
stub_checker() {
  mkdir -p "$T/stub"
  printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$MARKER" > "$T/stub/checklist-marker.sh"
  printf '#!/usr/bin/env bash\necho "stub checker: simulated failure" >&2\nexit %s\n' "$1" > "$T/stub/checklist.sh"
  export JENGA_PREFLIGHT_HOOK_SCRIPT_DIR="$T/stub"
}

@test "hook: checker exit 1 (invalid registry) fails open with a stderr warning" {
  printf '{ this is not json' > "$F"
  enter pre-commit run-1 >/dev/null
  run bash "$CHECKLIST" check pre-commit
  [ "$status" -eq 1 ]
  run_hook_bash "git commit -m x"
  assert_fails_open 1
}

@test "hook: checker exit 2 (usage error) fails open with a stderr warning" {
  failing_item_registry block must-pass
  enter pre-commit run-1 >/dev/null
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=not-a-number
  run bash "$CHECKLIST" check pre-commit
  [ "$status" -eq 2 ]
  run_hook_bash "git commit -m x"
  assert_fails_open 2
}

@test "hook: checker exit 4 (no python3) fails open with a stderr warning" {
  failing_item_registry block must-pass
  enter pre-commit run-1 >/dev/null
  stub_checker 4
  run_hook_bash "git commit -m x"
  assert_fails_open 4
}

@test "hook: checker exit 5 (internal error) fails open with a stderr warning" {
  failing_item_registry block must-pass
  enter pre-commit run-1 >/dev/null
  stub_checker 5
  run_hook_bash "git commit -m x"
  assert_fails_open 5
}

# -----------------------------------------------------------------------------
# AC2: the hook blocks at permission level 5 (unrestricted)
# -----------------------------------------------------------------------------

@test "hook: blocks with the level-5 (unrestricted) permission template in effect" {
  # The repository's own level file must survive this test untouched.
  real_before="$(cat "$REPO_ROOT/.jenga-permission-level.json" 2>/dev/null || echo absent)"

  failing_item_registry block must-pass
  enter pre-commit run-5 >/dev/null

  make_sandbox
  switch_level 5

  # The switch really did put the unrestricted template in force in the sandbox, and recorded level 5.
  [ "$(jq -r '.session_level' "$SANDBOX/.jenga-permission-level.json")" = "5" ]
  cmp "$SANDBOX/.claude/settings.json" "$TEMPLATE_DIR/level-5-unrestricted.json"
  cmp "$SANDBOX/.agents/settings.json" "$TEMPLATE_DIR/level-5-unrestricted.json"

  # The hook command the sandbox's level-5 settings register, run the way the harness runs it.
  cmd="$(registered_hook_command "$SANDBOX/.claude/settings.json")"
  [ -n "$cmd" ]
  p="$(payload Bash "git commit -m x")"
  run --separate-stderr env CLAUDE_PROJECT_DIR="$REPO_ROOT" bash -c "$cmd" <<<"$p"
  assert_denied must-pass pre-commit

  # The same command out of the .agents settings behaves identically.
  cmd_agents="$(registered_hook_command "$SANDBOX/.agents/settings.json")"
  [ "$cmd_agents" = "$cmd" ]

  # Control: with the item passing, the same registered command lets the same call through.
  write_registry "$(item must-pass machine block run true)"
  run --separate-stderr env CLAUDE_PROJECT_DIR="$REPO_ROOT" bash -c "$cmd" <<<"$p"
  assert_allowed

  # The repository's real permission level was never touched.
  real_after="$(cat "$REPO_ROOT/.jenga-permission-level.json" 2>/dev/null || echo absent)"
  [ "$real_after" = "$real_before" ]
}

# -----------------------------------------------------------------------------
# The registration: identical everywhere the level switch could copy it from, and surviving a switch
# -----------------------------------------------------------------------------

@test "registration: the PreToolUse entry is byte-identical across root, all five templates and both mirrors" {
  [ -x "$HOOK" ]
  root_entry="$(registered_hook_entry "$REPO_ROOT/settings.json")"
  [ "$(jq 'length' <<<"$root_entry")" -ge 1 ]
  [ "$(jq -r '.[0].matcher' <<<"$root_entry")" = "Bash|Task|Agent" ]

  templates=0
  for f in "$TEMPLATE_DIR"/level-*.json; do
    templates=$((templates + 1))
    [ "$(registered_hook_entry "$f")" = "$root_entry" ] || { echo "registration differs in $f" >&2; return 1; }
    [ "$(registered_hook_command "$f")" = "$(registered_hook_command "$REPO_ROOT/settings.json")" ] \
      || { echo "registered command differs in $f" >&2; return 1; }
  done
  [ "$templates" -eq 5 ]

  for f in "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/.agents/settings.json"; do
    [ "$(registered_hook_entry "$f")" = "$root_entry" ] || { echo "registration differs in $f" >&2; return 1; }
  done
}

@test "registration: survives a level switch from level 1 up to level 5" {
  make_sandbox
  root_entry="$(registered_hook_entry "$REPO_ROOT/settings.json")"
  [ "$(jq 'length' <<<"$root_entry")" -ge 1 ]

  for n in 1 2 3 4 5; do
    switch_level "$n"
    [ "$(jq -r '.session_level' "$SANDBOX/.jenga-permission-level.json")" = "$n" ]
    [ "$(registered_hook_entry "$SANDBOX/.claude/settings.json")" = "$root_entry" ] \
      || { echo "registration lost or changed in .claude/settings.json after switching to level $n" >&2; return 1; }
    [ "$(registered_hook_entry "$SANDBOX/.agents/settings.json")" = "$root_entry" ] \
      || { echo "registration lost or changed in .agents/settings.json after switching to level $n" >&2; return 1; }
  done
}
