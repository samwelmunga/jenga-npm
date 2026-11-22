#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# skills/j-workflow-capture/scripts/resolve-source.sh (epic E103, task E103_S02_T01): a session reference becomes
# one readable source file plus its recording provenance, printed as one line of JSON; every form it cannot
# resolve exits with its own documented code and a message naming what was tried.
#
# Covered: the four MVP forms (current session, session UUID, transcript .jsonl path, pasted text and pasted file),
# the two best-effort forms (claude.ai/code URL, desktop local_... id, exit 4), missing / unreadable / empty /
# ambiguous transcripts (exit 5), a host without a Claude transcript directory (exit 6, paste still works), an
# unresolvable current session id (exit 7), rejected content (exit 8), the source_ref refusal reused from the
# recorder's format contract (exit 2), usage errors, and "list" delegating to scripts/task-usage.sh.
#
# Isolation: every projects directory, transcript, HOME and TMPDIR lives under $BATS_TEST_TMPDIR, and the ambient
# session variables are unset in setup, so the suite never reads the real ~/.claude/projects. Only shipped paths
# are read (skills/j-workflow-capture/, skills/j-workflow-recorder/, scripts/, tests/fixtures/workflow-capture/).

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RS="$REPO_ROOT/skills/j-workflow-capture/scripts/resolve-source.sh"
FIXTURE="$REPO_ROOT/tests/fixtures/workflow-capture/session-transcript.jsonl"
UUID="0b6f2c1e-7d4a-4e55-9a61-2c8f0d4b7e13"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/projects"
  SLUG_DIR="$PROJ/-work-demo-project"
  OUT="$T/out"
  mkdir -p "$SLUG_DIR" "$PROJ/-work-other-project" "$T/tmp" "$T/home"
  cp "$FIXTURE" "$SLUG_DIR/$UUID.jsonl"
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID JENGA_CAPTURE_SESSION_ID JENGA_PROJECTS_DIR JENGA_CAPTURE_OUT_DIR
  export TMPDIR="$T/tmp" HOME="$T/home"
}

# rs <args...>: run the script with stdout and stderr separated.
rs() { run --separate-stderr bash "$RS" "$@"; }
# rs_env <VAR=value...> -- <args...>
rs_env() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  run --separate-stderr env "${envs[@]}" bash "$RS" "$@"
}
# rs_stdin <file> <args...>: run with <file> on stdin.
rs_stdin() {
  local f="$1"; shift
  run --separate-stderr bash -c 'f="$1"; shift; bash "$@" < "$f"' _ "$f" "$RS" "$@"
}
field() { printf '%s\n' "$output" | jq -r "$1"; }

# --- the four MVP forms ---------------------------------------------------------------------------------------------

@test "help: exits 0 and documents every sub-command and exit code" {
  rs --help
  [ "$status" -eq 0 ]
  assert_output_contains "resolve-source.sh resolve"
  assert_output_contains "resolve-source.sh host"
  assert_output_contains "resolve-source.sh list"
  for code in 0 2 3 4 5 6 7 8; do assert_output_contains "  $code "; done
}

@test "current session: the id from CLAUDE_CODE_SESSION_ID resolves to its transcript as session-transcript" {
  rs_env CLAUDE_CODE_SESSION_ID="$UUID" -- resolve --projects-dir "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(field .form)" = "current" ]
  [ "$(field .source)" = "session-transcript" ]
  [ "$(field .source_ref)" = "$UUID" ]
  [ "$(field .session_id)" = "$UUID" ]
  [ "$(field .path)" = "$(cd "$SLUG_DIR" && pwd -P)/$UUID.jsonl" ]
}

@test "current session: JENGA_CAPTURE_SESSION_ID wins over CLAUDE_CODE_SESSION_ID, JENGA_SESSION_ID is the last fallback" {
  rs_env JENGA_CAPTURE_SESSION_ID="$UUID" CLAUDE_CODE_SESSION_ID="aaaaaaaa-0000-4000-8000-000000000000" -- resolve --projects-dir "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(field .session_id)" = "$UUID" ]
  rs_env JENGA_SESSION_ID="$UUID" -- resolve --projects-dir "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(field .form)" = "current" ]
}

@test "current session: the transcript content is never printed" {
  rs_env CLAUDE_CODE_SESSION_ID="$UUID" -- resolve --projects-dir "$PROJ"
  [ "$status" -eq 0 ]
  assert_output_not_contains "release/1.4"
  [[ "$stderr" != *"release/1.4"* ]]
}

@test "current session: no session id at all exits 7 naming every variable tried, stdout empty" {
  rs resolve --projects-dir "$PROJ"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  [[ "$stderr" == *JENGA_CAPTURE_SESSION_ID* ]]
  [[ "$stderr" == *CLAUDE_CODE_SESSION_ID* ]]
  [[ "$stderr" == *JENGA_SESSION_ID* ]]
}

@test "current session: a malformed session id exits 7 and is never used as a path" {
  rs_env CLAUDE_CODE_SESSION_ID="../$UUID" -- resolve --projects-dir "$PROJ"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  [[ "$stderr" == *malformed* ]]
}

@test "session UUID: resolves to its transcript as form session-id" {
  rs resolve --projects-dir "$PROJ" "$UUID"
  [ "$status" -eq 0 ]
  [ "$(field .form)" = "session-id" ]
  [ "$(field .source)" = "session-transcript" ]
  [ "$(field .source_ref)" = "$UUID" ]
  [ "$(field .session_id)" = "$UUID" ]
  [ -f "$(field .path)" ]
}

@test "session UUID: a session from another project directory is found too" {
  mv "$SLUG_DIR/$UUID.jsonl" "$PROJ/-work-other-project/$UUID.jsonl"
  rs resolve --projects-dir "$PROJ" "$UUID"
  [ "$status" -eq 0 ]
  [[ "$(field .path)" == */-work-other-project/"$UUID".jsonl ]]
}

@test "session UUID: JENGA_PROJECTS_DIR is used when no option is given, and the option beats it" {
  rs_env JENGA_PROJECTS_DIR="$PROJ" -- resolve "$UUID"
  [ "$status" -eq 0 ]
  rs_env JENGA_PROJECTS_DIR="$PROJ" -- resolve --projects-dir "$T/empty-projects" "$UUID"
  [ "$status" -eq 6 ]
}

@test "session UUID: not found exits 5 naming the glob searched and the number of project directories" {
  rs resolve --projects-dir "$PROJ" "99999999-2222-4333-8444-555555555555"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$PROJ/*/99999999-2222-4333-8444-555555555555.jsonl"* ]]
  [[ "$stderr" == *"2 project directories"* ]]
}

@test "session UUID: two transcripts for one id exit 5 listing both, none is picked" {
  cp "$FIXTURE" "$PROJ/-work-other-project/$UUID.jsonl"
  rs resolve --projects-dir "$PROJ" "$UUID"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [[ "$stderr" == *"-work-demo-project/$UUID.jsonl"* ]]
  [[ "$stderr" == *"-work-other-project/$UUID.jsonl"* ]]
}

@test "session UUID: an empty transcript exits 5, a non-transcript exits 8" {
  : > "$SLUG_DIR/$UUID.jsonl"
  rs resolve --projects-dir "$PROJ" "$UUID"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *empty* ]]
  printf 'plain text, not json\n' > "$SLUG_DIR/$UUID.jsonl"
  rs resolve --projects-dir "$PROJ" "$UUID"
  [ "$status" -eq 8 ]
  [[ "$stderr" == *"not a Claude Code session transcript"* ]]
}

@test "transcript path: an explicit .jsonl resolves as transcript-path with its absolute path as source_ref" {
  rs resolve "$SLUG_DIR/$UUID.jsonl"
  [ "$status" -eq 0 ]
  local abs; abs="$(cd "$SLUG_DIR" && pwd -P)/$UUID.jsonl"
  [ "$(field .form)" = "transcript-path" ]
  [ "$(field .source)" = "session-transcript" ]
  [ "$(field .source_ref)" = "$abs" ]
  [ "$(field .path)" = "$abs" ]
  [ "$(field .session_id)" = "$UUID" ]
}

@test "transcript path: works with no Claude transcript directory, and a non-UUID file name has a null session_id" {
  cp "$FIXTURE" "$T/exported.jsonl"
  rs resolve --projects-dir "$T/no-such-dir" "$T/exported.jsonl"
  [ "$status" -eq 0 ]
  [ "$(field .form)" = "transcript-path" ]
  [ "$(field .session_id)" = "null" ]
}

@test "transcript path: a leading ~/ is expanded against HOME" {
  cp "$FIXTURE" "$HOME/exported.jsonl"
  rs resolve "~/exported.jsonl"
  [ "$status" -eq 0 ]
  [ "$(field .path)" = "$(cd "$HOME" && pwd -P)/exported.jsonl" ]
}

@test "transcript path: missing exits 5 naming the path, nothing else is guessed" {
  rs resolve "$T/missing.jsonl"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$T/missing.jsonl"* ]]
  [[ "$stderr" == *"nothing else is guessed"* ]]
}

@test "transcript path: not a transcript exits 8; empty exits 5" {
  printf 'not json\n' > "$T/bad.jsonl"
  rs resolve "$T/bad.jsonl"
  [ "$status" -eq 8 ]
  : > "$T/empty.jsonl"
  rs resolve "$T/empty.jsonl"
  [ "$status" -eq 5 ]
}

@test "transcript path: an unreadable transcript exits 5 saying it is not readable" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  cp "$FIXTURE" "$T/locked.jsonl"
  chmod 000 "$T/locked.jsonl"
  rs resolve "$T/locked.jsonl"
  chmod 600 "$T/locked.jsonl"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"not readable"* ]]
}

@test "a directory exits 5" {
  rs resolve "$SLUG_DIR"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"is a directory"* ]]
}

@test "pasted text: stdin is normalised (CR removed, final newline) into a private file named by its digest" {
  printf 'step one\r\nstep two' > "$T/paste.in"
  rs_stdin "$T/paste.in" resolve --out-dir "$OUT" -
  [ "$status" -eq 0 ]
  [ "$(field .form)" = "pasted-text" ]
  [ "$(field .source)" = "pasted" ]
  [ "$(field .session_id)" = "null" ]
  local p ref; p="$(field .path)"; ref="$(field .source_ref)"
  [[ "$ref" =~ ^sha256:[0-9a-f]{12}$ ]]
  [ "$p" = "$(cd "$OUT" && pwd -P)/pasted-${ref#sha256:}.txt" ]
  [ "$(cat "$p")" = "$(printf 'step one\nstep two')" ]
  [ "$(tail -c 1 "$p" | od -An -c | tr -d ' ')" = '\n' ]
  [ -z "$(env LC_ALL=C tr -cd '\r' < "$p")" ]
  [[ "$(ls -l "$p")" == "-rw-------"* ]]
  [ -z "$(find "$OUT" -name '.*' -type f)" ]
}

@test "pasted text: the same text resolves to the same file; without --out-dir a fresh private directory is used" {
  printf 'only step\n' > "$T/paste.in"
  rs_stdin "$T/paste.in" resolve --out-dir "$OUT" -
  local first; first="$(field .path)"
  rs_stdin "$T/paste.in" resolve --out-dir "$OUT" -
  [ "$(field .path)" = "$first" ]
  rs_stdin "$T/paste.in" resolve -
  [ "$status" -eq 0 ]
  [[ "$(field .path)" == "$(cd "$T/tmp" && pwd -P)"/jenga-capture.* ]]
}

@test "pasted text: JENGA_CAPTURE_OUT_DIR is used when --out-dir is not given" {
  printf 'only step\n' > "$T/paste.in"
  run --separate-stderr bash -c 'JENGA_CAPTURE_OUT_DIR="$1" bash "$2" resolve - < "$3"' _ "$OUT" "$RS" "$T/paste.in"
  [ "$status" -eq 0 ]
  [[ "$(printf '%s\n' "$output" | jq -r .path)" == "$(cd "$OUT" && pwd -P)"/pasted-* ]]
}

@test "pasted text: blank input exits 5 and NUL bytes exit 8, leaving no file behind" {
  printf '  \n\t\n' > "$T/blank.in"
  rs_stdin "$T/blank.in" resolve --out-dir "$OUT" -
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  printf 'a\000b\n' > "$T/nul.in"
  rs_stdin "$T/nul.in" resolve --out-dir "$OUT" -
  [ "$status" -eq 8 ]
  [ -z "$(find "$OUT" -type f)" ]
}

@test "pasted file: a non-.jsonl file is copied, normalised, and recorded with its own absolute path" {
  printf 'install the CLI\r\nlog in\r\n' > "$T/steps.md"
  rs resolve --out-dir "$OUT" "$T/steps.md"
  [ "$status" -eq 0 ]
  [ "$(field .form)" = "pasted-file" ]
  [ "$(field .source)" = "pasted" ]
  [ "$(field .source_ref)" = "$(cd "$T" && pwd -P)/steps.md" ]
  [[ "$(field .path)" == "$(cd "$OUT" && pwd -P)"/pasted-*.txt ]]
  [ "$(cat "$(field .path)")" = "$(printf 'install the CLI\nlog in')" ]
  [ "$(cat "$T/steps.md")" = "$(printf 'install the CLI\r\nlog in\r')" ]
}

@test "pasted file: a binary file exits 8" {
  printf 'a\000b' > "$T/blob.bin"
  rs resolve --out-dir "$OUT" "$T/blob.bin"
  [ "$status" -eq 8 ]
}

@test "pasted file: a path the recorder refuses as a source_ref exits 2 with the recorder's reason" {
  printf 'a step\n' > "$T/notes?token=abc.txt"
  rs resolve --out-dir "$OUT" "$T/notes?token=abc.txt"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"cannot be recorded as a source_ref"* ]]
  [ ! -e "$OUT" ] || [ -z "$(find "$OUT" -type f)" ]
}

# --- best-effort forms ----------------------------------------------------------------------------------------------

@test "claude.ai/code session URL: exits 4 naming the export-then-path route and the paste fallback" {
  local u
  for u in "https://claude.ai/code/session_01AbCdEf" "claude.ai/code/session_01AbCdEf" "HTTPS://Claude.AI/code"; do
    rs resolve --projects-dir "$PROJ" "$u"
    [ "$status" -eq 4 ]
    [ -z "$output" ]
    [[ "$stderr" == *"best effort"* ]]
    [[ "$stderr" == *export* ]]
    [[ "$stderr" == *path* ]]
    [[ "$stderr" == *paste* ]]
  done
}

@test "desktop local_ id: exits 4 naming the export-then-path route and the paste fallback" {
  rs resolve --projects-dir "$PROJ" "local_3f2a9c1e0b7d"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *"best effort"* ]]
  [[ "$stderr" == *export* ]]
  [[ "$stderr" == *paste* ]]
}

@test "best-effort forms exit 4 even on a host without a Claude transcript directory" {
  rs resolve --projects-dir "$T/no-such-dir" "local_abc"
  [ "$status" -eq 4 ]
  rs resolve --projects-dir "$T/no-such-dir" "https://claude.ai/code/session_x"
  [ "$status" -eq 4 ]
}

@test "any other URL exits 2: it belongs to the external source, not to a session" {
  rs resolve "https://example.com/setup-guide"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"external source"* ]]
}

@test "an unrecognised word exits 2 listing the accepted forms" {
  rs resolve --projects-dir "$PROJ" "yesterday"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"session UUID"* ]]
  [[ "$stderr" == *"pasted text"* ]]
}

# --- a host without Claude transcripts ------------------------------------------------------------------------------

@test "no Claude transcript directory: host exits 6 saying only pasted text or a file is supported" {
  rs host --projects-dir "$T/no-such-dir"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  [[ "$stderr" == *"only pasted text or a file is supported"* ]]
}

@test "no Claude transcript directory: current session and a UUID exit 6, pasted text still resolves" {
  rs_env CLAUDE_CODE_SESSION_ID="$UUID" -- resolve --projects-dir "$T/no-such-dir"
  [ "$status" -eq 6 ]
  [[ "$stderr" == *"only pasted text or a file is supported"* ]]
  rs resolve --projects-dir "$T/no-such-dir" "$UUID"
  [ "$status" -eq 6 ]
  printf 'a step\n' > "$T/paste.in"
  rs_stdin "$T/paste.in" resolve --projects-dir "$T/no-such-dir" --out-dir "$OUT" -
  [ "$status" -eq 0 ]
  [ "$(field .form)" = "pasted-text" ]
}

@test "the default projects directory is ~/.claude/projects (HOME is the sandbox here)" {
  rs host
  [ "$status" -eq 6 ]
  [[ "$stderr" == *"$HOME/.claude/projects"* ]]
  mkdir -p "$HOME/.claude/projects"
  rs host
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'claude-transcripts\t%s' "$(cd "$HOME/.claude/projects" && pwd -P)")" ]
}

# --- list (reuses scripts/task-usage.sh) ----------------------------------------------------------------------------

@test "list: delegates to task-usage.sh --list-transcripts and keeps only session transcripts" {
  mkdir -p "$SLUG_DIR/$UUID/subagents"
  printf '{"type":"user","message":{"role":"user","content":"sub"}}\n' > "$SLUG_DIR/$UUID/subagents/agent-a1.jsonl"
  printf '{"agentType":"developer","name":"E01_S01_T01"}\n' > "$SLUG_DIR/$UUID/subagents/agent-a1.meta.json"
  rs list --projects-dir "$PROJ" --project-dir "/work/demo-project"
  [ "$status" -eq 0 ]
  [ "$(field 'length')" -eq 1 ]
  [ "$(field '.[0].session_id')" = "$UUID" ]
  [[ "$(field '.[0].path')" == */-work-demo-project/"$UUID".jsonl ]]
}

@test "list: no Claude transcript directory exits 6" {
  rs list --projects-dir "$T/no-such-dir"
  [ "$status" -eq 6 ]
}

# --- usage ----------------------------------------------------------------------------------------------------------

@test "usage errors exit 2 with nothing on stdout" {
  rs
  [ "$status" -eq 2 ]
  rs frobnicate
  [ "$status" -eq 2 ]
  rs resolve --no-such-option
  [ "$status" -eq 2 ]
  rs host "$UUID"
  [ "$status" -eq 2 ]
  rs resolve --project-dir /x "$UUID"
  [ "$status" -eq 2 ]
  rs resolve --projects-dir= "$UUID"
  [ "$status" -eq 2 ]
  rs resolve a b
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "the script never refers to the recorder's pointer script" {
  run grep -Eq 'active-recording' "$RS"
  [ "$status" -eq 1 ]
}
