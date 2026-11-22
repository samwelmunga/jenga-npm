#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# skills/j-workflow-capture/scripts/extract-steps.sh (epic E103, task E103_S02_T02): the user prompts of a resolved
# source are listed numbered with timestamps, and the range the user picks becomes a candidate-steps file in
# render-review-table.sh's format, one step per prompt with tool calls and assistant text attached as evidence only.
#
# Covered: list (text and --json), range (stdout and --out), the prompt rule on a real-shaped transcript (meta lines,
# local-command output, task notifications, sidechains, tool results, slash commands, bash input, embedded system
# reminders), the current-session cut (Skill call and slash-command markers, no marker, nothing before it), the four
# layout checks (exit 4-7) with nothing written, pasted text (numbered items and one step per line), redaction of
# secret-looking values, range bounds, and usage errors.
#
# Isolation: every output and scratch file lives under $BATS_TEST_TMPDIR; only shipped paths are read
# (skills/j-workflow-capture/, tests/fixtures/workflow-capture/). No real transcript is read.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
XS="$REPO_ROOT/skills/j-workflow-capture/scripts/extract-steps.sh"
RT="$REPO_ROOT/skills/j-workflow-capture/scripts/render-review-table.sh"
FX="$REPO_ROOT/tests/fixtures/workflow-capture"
CUR="$FX/current-session-transcript.jsonl"
OLD="$FX/session-transcript.jsonl"

setup() {
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/tmp" "$T/out"
  export TMPDIR="$T/tmp"
}

xs() { run --separate-stderr bash "$XS" "$@"; }
field() { printf '%s\n' "$output" | jq -r "$1"; }
# assert_nothing_written: stdout empty and no file under the output directory.
assert_nothing_written() {
  [ -z "$output" ]
  [ -z "$(ls -A "$T/out")" ]
}

# --- help and usage -----------------------------------------------------------------------------------------------

@test "help: exits 0 and documents both sub-commands and every exit code" {
  xs --help
  [ "$status" -eq 0 ]
  assert_output_contains "extract-steps.sh list"
  assert_output_contains "extract-steps.sh range"
  run grep -E '^#[[:space:]]+(0|2|3|4-7|8|9|1[01])[[:space:]]' "$XS"
  [ "$(printf '%s\n' "$output" | grep -c .)" -ge 8 ]
}

@test "usage: no sub-command, an unknown one, a bad bound, from after to and stray options exit 2" {
  xs; [ "$status" -eq 2 ]
  xs frobnicate "$CUR"; [ "$status" -eq 2 ]
  xs range 0 2 "$CUR"; [ "$status" -eq 2 ]
  xs range a 2 "$CUR"; [ "$status" -eq 2 ]
  xs range 3 2 "$CUR"; [ "$status" -eq 2 ]
  xs range 1 2 "$CUR" extra; [ "$status" -eq 2 ]
  xs list --out "$T/out/x.json" "$CUR"; [ "$status" -eq 2 ]
  xs range 1 2 --json "$CUR"; [ "$status" -eq 2 ]
  xs list --kind weird "$CUR"; [ "$status" -eq 2 ]
  [ -z "$(ls -A "$T/out")" ]
}

@test "environment: a missing file exits 3" {
  xs list "$T/nope.jsonl"
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "no such file"
}

# --- list ----------------------------------------------------------------------------------------------------------

@test "list: the prompts of a real-shaped transcript, numbered with timestamps, nothing else counted as a prompt" {
  xs list "$CUR"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 6 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "  1  2026-11-19T10:00:01Z  /j-checkout release/2.0" ]
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = "  3  2026-11-19T10:03:00Z  Deploy the release to staging" ]
  [ "$(printf '%s\n' "$output" | sed -n 4p)" = "  4  2026-11-19T10:04:00Z  ! git status" ]
  [ "$(printf '%s\n' "$output" | sed -n 6p)" = "  6  2026-11-19T10:05:30Z  1" ]
  # meta lines, local-command output, task notifications, sidechains, tool results and bash output are not prompts
  assert_output_not_contains "Caveat"
  assert_output_not_contains "Perceived branch"
  assert_output_not_contains "background task"
  assert_output_not_contains "Sidechain"
  assert_output_not_contains "migrations applied"
  assert_output_not_contains "nothing to commit"
  assert_output_not_contains "reminder text"
  assert_output_not_contains "Base directory"
  assert_contains "$stderr" "6 prompt(s)"
}

@test "list --json: an array of {n, timestamp, text}; an older transcript without origin fields works too" {
  xs list --json "$OLD"
  [ "$status" -eq 0 ]
  [ "$(field 'length')" -eq 2 ]
  [ "$(field '.[0] | keys | join(",")')" = "n,text,timestamp" ]
  [ "$(field '.[0].text')" = "Create a new release branch named release/1.4 from main" ]
  [ "$(field '.[1].timestamp')" = "2026-11-19T09:01:00.000Z" ]
}

# --- range ---------------------------------------------------------------------------------------------------------

@test "range: emits a candidate-steps file that render-review-table.sh accepts, renumbered from 1" {
  xs range 2 3 "$CUR"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$T/c.json"
  run bash "$RT" --check "$T/c.json"
  [ "$status" -eq 0 ]
  run jq -r '[.candidate_steps_version, (.steps | length), .steps[0].n, .steps[0].prompt, .steps[1].n, .steps[1].prompt, .range.from, .range.to] | map(tostring) | join(" ")' "$T/c.json"
  [ "$output" = "1 2 1 2 2 3 2 3" ]
  [ "$(jq -r '.steps[1].text' "$T/c.json")" = "Deploy the release to staging" ]
  [ "$(jq -r '.steps[1].timestamp' "$T/c.json")" = "2026-11-19T10:03:00.000Z" ]
}

@test "range: tool calls are evidence only, never steps; tool results are not carried" {
  xs range 1 6 "$CUR"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$T/c.json"
  # no step text is a tool call
  [ "$(jq '[.steps[].text | select(test("npm run migrate|deploy.sh|README.md"))] | length' "$T/c.json")" -eq 0 ]
  run jq -r '.steps[1].evidence[]' "$T/c.json"
  assert_output_contains "assistant: Running the migrations against staging."
  assert_output_contains "tool Bash: npm run migrate -- --env staging"
  assert_output_contains "tool Read: /work/demo-project/db/migrations/README.md"
  assert_output_not_contains "3 migrations applied"
  [ "$(jq -r '.steps[2].evidence[0]' "$T/c.json")" = "tool Bash: ./deploy.sh staging" ]
  [ "$(jq -r '.steps[4].evidence[0]' "$T/c.json")" = "tool Skill: j-workflow-capture" ]
}

@test "range --out: written atomically with mode 600, the same bytes as stdout" {
  xs range 1 2 --out "$T/out/candidates.json" "$CUR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$T/out/candidates.json" ]
  [ "$(stat -c '%a' "$T/out/candidates.json" 2>/dev/null || stat -f '%Lp' "$T/out/candidates.json")" = "600" ]
  [ "$(ls -A "$T/out" | grep -c .)" -eq 1 ]
  xs range 1 2 "$CUR"
  [ "$output" = "$(cat "$T/out/candidates.json")" ]
}

@test "range: a bound beyond the prompt count exits 9 naming the count, nothing written" {
  xs range 2 7 --out "$T/out/c.json" "$CUR"
  [ "$status" -eq 9 ]
  assert_contains "$stderr" "outside 1..6"
  assert_nothing_written
}

@test "range --out: a missing output directory exits 11 and creates nothing" {
  xs range 1 2 --out "$T/missing/c.json" "$CUR"
  [ "$status" -eq 11 ]
  [ -z "$output" ]
  [ ! -e "$T/missing" ]
}

# --- the current session --------------------------------------------------------------------------------------------

@test "current: the capture invocation (a Skill call) and everything after it are never candidates" {
  xs list --current "$CUR"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 4 ]
  assert_output_not_contains "make a workflow"
  assert_contains "$stderr" "prompt 5 (the capture invocation) and the 1 prompt(s) after it are excluded"
  xs range 1 4 --current "$CUR"
  [ "$status" -eq 0 ]
  [ "$(field '[.steps[].text | select(test("make a workflow") or . == "1")] | length')" -eq 0 ]
  [ "$(field '[.steps[].evidence[] | select(test("Skill|extract-steps|Where should"))] | length')" -eq 0 ]
  xs range 1 5 --current "$CUR"
  [ "$status" -eq 9 ]
}

@test "current: a /j-workflow-capture slash command is the invocation too, and the last invocation wins" {
  jq -c 'if .uuid == "u-13" then .message.content = "<command-message>j-workflow-capture</command-message>\n<command-name>/j-workflow-capture</command-name>" elif .uuid == "a-04" then .message.content = [{"type":"text","text":"Starting the capture."}] else . end' "$CUR" >"$T/slash.jsonl"
  xs list --current "$T/slash.jsonl"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 4 ]
  assert_output_not_contains "/j-workflow-capture"
  # an earlier capture run in the same session does not move the cut: the last invocation decides
  { sed -n 1,3p "$CUR"; printf '%s\n' '{"type":"user","uuid":"e-1","origin":{"kind":"human"},"timestamp":"2026-11-19T09:59:00.000Z","message":{"role":"user","content":"j.workflow-capture from session 0b6f2c1e-7d4a-4e55-9a61-2c8f0d4b7e13"}}'; sed -n '4,$p' "$CUR"; } >"$T/twice.jsonl"
  xs list --current "$T/twice.jsonl"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 5 ]
}

@test "current: no capture invocation in the transcript exits 10; the end of the process is never guessed" {
  xs list --current "$OLD"
  [ "$status" -eq 10 ]
  [ -z "$output" ]
  assert_contains "$stderr" "no capture invocation"
  xs range 1 1 --current --out "$T/out/c.json" "$OLD"
  [ "$status" -eq 10 ]
  assert_nothing_written
}

@test "current: an invocation with no prompt before it exits 8" {
  sed -n '18,$p' "$CUR" >"$T/only-capture.jsonl"
  xs list --current "$T/only-capture.jsonl"
  [ "$status" -eq 8 ]
  [ -z "$output" ]
}

@test "current: refused for pasted text" {
  xs list --current "$FX/pasted-steps.md"
  [ "$status" -eq 2 ]
}

# --- layout checks --------------------------------------------------------------------------------------------------

@test "layout: the malformed fixture (prompts not under message.content) exits 6 and writes nothing" {
  xs range 1 1 --out "$T/out/c.json" "$FX/malformed-transcript.jsonl"
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "unrecognised transcript layout: line 2"
  assert_nothing_written
}

@test "layout: a line that is not a JSON object exits 4, even after valid lines" {
  { cat "$OLD"; printf 'this is not json\n'; } >"$T/bad4.jsonl"
  xs range 1 2 --out "$T/out/c.json" "$T/bad4.jsonl"
  [ "$status" -eq 4 ]
  assert_contains "$stderr" "line 6 is not a JSON object"
  assert_nothing_written
  { cat "$OLD"; printf '[1,2]\n'; } >"$T/bad4b.jsonl"
  xs list "$T/bad4b.jsonl"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

@test "layout: a line without a string type exits 5" {
  { cat "$OLD"; printf '%s\n' '{"kind":"user","message":{"content":"x"}}'; } >"$T/bad5.jsonl"
  xs list "$T/bad5.jsonl"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  assert_contains "$stderr" "line 6 has no string \"type\""
}

@test "layout: no user line, a user line without a timestamp, or content items without a type exit 6" {
  printf '%s\n' '{"type":"summary","summary":"x"}' >"$T/nouser.jsonl"
  xs list --kind transcript "$T/nouser.jsonl"
  [ "$status" -eq 6 ]
  assert_contains "$stderr" "no line of type \"user\""
  jq -c 'del(.timestamp)' "$OLD" >"$T/nots.jsonl"
  xs list "$T/nots.jsonl"
  [ "$status" -eq 6 ]
  printf '%s\n' '{"type":"user","timestamp":"2026-11-19T09:00:00Z","message":{"content":["bare string item"]}}' >"$T/untyped.jsonl"
  xs list "$T/untyped.jsonl"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
}

@test "layout: an assistant line whose content is an object exits 7" {
  jq -c 'if .type == "assistant" then .message.content = {"text": "x"} else . end' "$OLD" >"$T/bad7.jsonl"
  xs list "$T/bad7.jsonl"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  assert_contains "$stderr" "assistant line"
}

@test "layout: --kind transcript forces the checks on a file auto would read as pasted text" {
  xs list --kind transcript "$FX/pasted-lines.txt"
  [ "$status" -eq 4 ]
}

# --- pasted text -----------------------------------------------------------------------------------------------------

@test "pasted: numbered items are steps, continuation lines join their item, the preamble is evidence of step 1" {
  xs list "$FX/pasted-steps.md"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 4 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "  1  -  Create the branch release/1.4 from main." ]
  xs range 1 4 "$FX/pasted-steps.md"
  [ "$status" -eq 0 ]
  [ "$(field '.steps[1].text')" = "$(printf 'Bump the version in package.json to 1.4.0\nand commit it with the message "chore: 1.4.0".')" ]
  [ "$(field '.steps[0].evidence[0]')" = "context: How to cut a release (from the team wiki):" ]
  [ "$(field '.steps[3].text')" = "Tag the release v1.4.0 and push the tag." ]
  [ "$(field '[.steps[].timestamp] | unique | .[0]')" = "null" ]
  printf '%s\n' "$output" >"$T/p.json"
  run bash "$RT" --check "$T/p.json"
  [ "$status" -eq 0 ]
}

@test "pasted: without numbered items each non-blank line is a step, bullets removed" {
  xs list --json "$FX/pasted-lines.txt"
  [ "$status" -eq 0 ]
  [ "$(field '[.[].text] | join("|")')" = "Open the project settings|Turn on branch protection for main|Add the CI status check as required|Invite the release team as reviewers" ]
}

@test "pasted: blank text exits 8" {
  printf '\n   \n' >"$T/blank.txt"
  xs list "$T/blank.txt"
  [ "$status" -eq 8 ]
}

# --- secrets ---------------------------------------------------------------------------------------------------------

@test "secrets: a secret-looking value never reaches the list or the candidate-steps file, and the step is flagged" {
  xs list "$CUR"
  assert_output_not_contains "hunter2staging"
  xs range 2 2 "$CUR"
  [ "$status" -eq 0 ]
  assert_output_not_contains "hunter2staging"
  [ "$(field '.steps[0].text')" = "Run the database migrations for staging with DB_PASSWORD=<redacted>" ]
  assert_contains "$(field '.steps[0].evidence[0]')" "replaced by <redacted>"
  xs range 3 3 "$FX/pasted-steps.md"
  assert_output_not_contains "npm_abcdefghijklmnop1234"
  printf '%s\n' 'Call the API with Authorization: Bearer abcdef0123456789xyz' 'Clone https://bob:s3cretpw@git.example.com/r.git' 'Use key sk-ABCDEFGHIJKLMNOPQRSTUV' >"$T/s.txt"
  xs range 1 3 "$T/s.txt"
  [ "$status" -eq 0 ]
  assert_output_not_contains "abcdef0123456789xyz"
  assert_output_not_contains "s3cretpw"
  assert_output_not_contains "sk-ABCDEFGHIJKLMNOPQRSTUV"
}

@test "secrets: evidence from tool calls is redacted too" {
  jq -c 'if .uuid == "a-03" then .message.content[0].input.command = "API_TOKEN=tok_live_998877 ./deploy.sh staging" else . end' "$CUR" >"$T/ev.jsonl"
  xs range 3 3 "$T/ev.jsonl"
  [ "$status" -eq 0 ]
  assert_output_not_contains "tok_live_998877"
  [ "$(field '.steps[0].evidence[0]')" = "tool Bash: API_TOKEN=<redacted> ./deploy.sh staging" ]
}

# --- isolation -------------------------------------------------------------------------------------------------------

@test "the extractor never names the recorder's pointer script" {
  run grep -cE 'active-recording\.sh|active-recording["'"'"']?[[:space:]]+(set|clear|refresh)' "$XS"
  [ "$output" = "0" ]
}
