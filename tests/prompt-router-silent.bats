#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# hooks/prompt_router.sh + hooks/prompt_router_helper.js (E89_S06_T07).
#
# Under Claude Code a UserPromptSubmit hook's stdout is injected into model context. The helper used
# to echo the whole JSON prompt payload back on stdout, so every prompt of every scaffolded project
# carried that payload into the conversation. The route taken: the stub is retired (it does nothing)
# and `jenga init` no longer registers it; the shipped script stays as a silent no-op so projects
# already registered stop leaking on package upgrade.
#
# Modelled on tests/workflow-recorder-observation.bats' stdout guard: stdout is asserted EMPTY on
# every path and exit is asserted 0 on every path.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SH="$REPO_ROOT/hooks/prompt_router.sh"
HELPER="$REPO_ROOT/hooks/prompt_router_helper.js"

# Run $1 (a script) with $2 on stdin; stdout and stderr captured separately.
run_split() {
  OUT="$BATS_TEST_TMPDIR/out"; ERR="$BATS_TEST_TMPDIR/err"
  set +e
  if [ "$1" = "sh" ]; then printf '%s' "$2" | bash "$SH" >"$OUT" 2>"$ERR"; STATUS=$?
  else printf '%s' "$2" | node "$HELPER" >"$OUT" 2>"$ERR"; STATUS=$?; fi
  set -e
}

assert_silent() {
  [ "$STATUS" -eq 0 ] || { echo "exit $STATUS"; return 1; }
  [ ! -s "$OUT" ] || { echo "stdout leaked: $(cat "$OUT")"; return 1; }
}

@test "shell hook: a normal prompt payload produces no stdout" {
  run_split sh '{"session_id":"s1","prompt":"hello there"}'
  assert_silent
}

@test "helper: a normal prompt payload produces no stdout" {
  run_split helper '{"session_id":"s1","prompt":"hello there"}'
  assert_silent
}

@test "helper: Copilot userPromptSubmitted payload produces no stdout" {
  run_split helper '{"sessionId":"s","timestamp":1,"cwd":"/x","prompt":"hi"}'
  assert_silent
}

@test "helper: empty prompt, empty stdin, malformed JSON and a router PID file all stay silent" {
  run_split helper '{"prompt":""}';     assert_silent
  run_split helper '';                  assert_silent
  run_split helper 'not json {{{';      assert_silent
  run_split sh 'not json {{{';          assert_silent
  # A live-looking router PID file used to take a different branch; it must not matter now.
  mkdir -p "$REPO_ROOT/mcp/router"
  if [ -e "$REPO_ROOT/mcp/router/.pid" ]; then skip "a real router pid file exists"; fi
  echo $$ > "$REPO_ROOT/mcp/router/.pid"
  run_split helper '{"prompt":"with a live pid"}'
  rm -f "$REPO_ROOT/mcp/router/.pid"
  assert_silent
}

@test "shell hook stays silent even if the helper were to write to stdout" {
  d="$BATS_TEST_TMPDIR/hooks"; mkdir -p "$d"
  cp "$SH" "$d/prompt_router.sh"
  echo 'process.stdout.write("LEAK")' > "$d/prompt_router_helper.js"
  run bash "$d/prompt_router.sh" <<<'{"prompt":"x"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "jenga init no longer registers the prompt_router UserPromptSubmit hook" {
  proj="$BATS_TEST_TMPDIR/proj"; mkdir -p "$proj"
  # runInit is interactive: answer every prompt with its default, paced so readline sees each line.
  (for i in 1 2 3 4 5 6; do echo; sleep 0.4; done) \
    | node -e "import('$REPO_ROOT/lib/commands/init.js').then(m => m.runInit([], '$proj'))" >/dev/null 2>&1
  [ -f "$proj/jenga.cli.json" ]
  if [ -f "$proj/.claude/settings.json" ]; then
    run grep -c "prompt_router" "$proj/.claude/settings.json"
    [ "$output" = "0" ]
  fi
  [ ! -e "$proj/.claude/settings.json" ] || ! grep -q UserPromptSubmit "$proj/.claude/settings.json"
}
