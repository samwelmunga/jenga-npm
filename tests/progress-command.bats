#!/usr/bin/env bats
#
# Coverage for the `jenga progress` command (E92_S08_T10): lib/commands/progress.js and its registration in
# bin/jenga.js. The command is a thin forwarder to lib/progress/cli.js (E92_S08_T03) that adds `--color always` unless
# the caller passed `--color`, so these cases cover help, the default colour, the explicit override, the flag
# outranking `progress_color` in dashboard-config.json, flag forwarding, and exit-code pass-through.
#
# The cases use cli.js's own `info` sub-command (it prints the resolved colour setting and paints the glyph table), so
# they do not depend on the run-bar or overview renderers of E92_S08_T04 and E92_S08_T05. Every case runs with stdout
# captured by bats, i.e. a pipe, with no colour or locale variable inherited, and builds its own scratch project under
# $BATS_TEST_TMPDIR (this repo's project/ is never touched). No model call and no network are involved.
#
# Not tested, on purpose: running under Node 14 (the package engines floor); no Node 14 is available to the suite, so a
# static scan of the new files for post-14 APIs stands in for it.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
JENGA="$REPO_ROOT/bin/jenga.js"
CLI="$REPO_ROOT/lib/progress/cli.js"
CMD="$REPO_ROOT/lib/commands/progress.js"
ESC="$(printf '\033')"

setup() {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs" "$PROJ/project/board/epics" "$PROJ/project/board/stories" "$PROJ/project/board/tasks"
  printf '{}\n' >"$PROJ/project/configs/workflow.json"
  unset JENGA_PROGRESS_COLOR JENGA_PROGRESS_CHARSET JENGA_PROGRESS_LANG JENGA_PROJECT_ROOT NO_COLOR COLUMNS
  cd "$BATS_TEST_TMPDIR"
}

# config <json>: write the scratch project's dashboard-config.json.
config() {
  printf '%s\n' "$1" >"$PROJ/project/configs/dashboard-config.json"
}

# no_ansi <text>: the text contains no escape character (an explicit failure, never a bare `!`, which errexit ignores).
no_ansi() {
  if has_ansi "$1"; then
    printf 'unexpected ANSI in: %s\n' "$1" >&2
    return 1
  fi
}

# has_ansi <text>: the text contains an escape character.
has_ansi() {
  case "$1" in *"$ESC"*) return 0 ;; *) return 1 ;; esac
}

@test "jenga --help lists the progress command next to config" {
  run --separate-stderr node "$JENGA" --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^  jenga progress  Show board progress in the terminal (colour on; see also: jenga progress --help)$'
  local cfg_line prog_line
  cfg_line="$(printf '%s\n' "$output" | grep -n '^  jenga config ' | cut -d: -f1)"
  prog_line="$(printf '%s\n' "$output" | grep -n '^  jenga progress ' | cut -d: -f1)"
  [ "$prog_line" -gt "$cfg_line" ]
}

@test "jenga progress --help prints the usage of cli.js with its sub-commands and exits 0" {
  run --separate-stderr node "$JENGA" progress --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^usage: '
  printf '%s\n' "$output" | grep -q '^commands:$'
  printf '%s\n' "$output" | grep -q '^  info '
  [ "$output" = "$(node "$CLI" --help)" ]
}

@test "without --color the command adds --color always: the output is coloured although stdout is a pipe" {
  run --separate-stderr node "$JENGA" progress info
  [ "$status" -eq 0 ]
  has_ansi "$output"
  printf '%s\n' "$output" | grep -q '^color=always enabled=true source=flag$'
  # the same call to cli.js is uncoloured on a pipe, so the colour comes from the command
  run --separate-stderr node "$CLI" info
  [ "$status" -eq 0 ]
  no_ansi "$output"
}

@test "--color never given by the user is forwarded and the output has no ANSI at all" {
  run --separate-stderr node "$JENGA" progress --color never info
  [ "$status" -eq 0 ]
  no_ansi "$output"
  printf '%s\n' "$output" | grep -q '^color=never enabled=false source=flag$'
}

@test "--color=never (the = form) and a --color placed after the sub-command are also the user's choice" {
  run --separate-stderr node "$JENGA" progress --color=never info
  [ "$status" -eq 0 ]
  no_ansi "$output"
  run --separate-stderr node "$JENGA" progress info --color never
  [ "$status" -eq 0 ]
  no_ansi "$output"
}

@test "--color auto given by the user is respected too (a pipe is not a terminal, so no ANSI)" {
  run --separate-stderr node "$JENGA" progress --color auto info
  [ "$status" -eq 0 ]
  no_ansi "$output"
  printf '%s\n' "$output" | grep -q '^color=auto enabled=false source=flag$'
}

@test "progress_color: never in dashboard-config.json does not switch the command's colour off, but cli.js obeys it" {
  config '{ "progress_color": "never" }'
  run --separate-stderr node "$JENGA" progress --root "$PROJ" info
  [ "$status" -eq 0 ]
  has_ansi "$output"
  printf '%s\n' "$output" | grep -q '^color=always enabled=true source=flag$'
  run --separate-stderr node "$CLI" --root "$PROJ" info
  [ "$status" -eq 0 ]
  no_ansi "$output"
  printf '%s\n' "$output" | grep -q '^color=never enabled=false source=config$'
}

@test "JENGA_PROGRESS_COLOR=never in the environment does not switch it off either: a flag outranks the environment" {
  JENGA_PROGRESS_COLOR=never run --separate-stderr node "$JENGA" progress info
  [ "$status" -eq 0 ]
  has_ansi "$output"
}

@test "every other flag is forwarded unchanged: output equals cli.js with the same flags and --color always" {
  config '{ "progress_charset": "utf8" }'
  run --separate-stderr node "$JENGA" progress --charset ascii --cols 55 --lang sv --root "$PROJ" info
  [ "$status" -eq 0 ]
  local via_cli
  via_cli="$(node "$CLI" --color always --charset ascii --cols 55 --lang sv --root "$PROJ" info)"
  [ "$output" = "$via_cli" ]
  printf '%s\n' "$output" | grep -q '^charset=ascii source=flag$'
  printf '%s\n' "$output" | grep -q '^cols=55 source=flag$'
  printf '%s\n' "$output" | grep -q '^lang=sv$'
}

@test "the data sub-command is forwarded with its own arguments" {
  run --separate-stderr node "$JENGA" progress --root "$PROJ" data --summary
  [ "$status" -eq 0 ]
  [ "$output" = "$(node "$CLI" --color always --root "$PROJ" data --summary)" ]
}

@test "exit code 0 passes through, including the never-fail warning on stderr (a bad --root still exits 0)" {
  run --separate-stderr node "$JENGA" progress --root "$BATS_TEST_TMPDIR/nowhere" data --summary
  [ "$status" -eq 0 ]
  node "$CLI" --root "$BATS_TEST_TMPDIR/nowhere" data --summary 2>/dev/null
}

@test "exit code 2 passes through for a usage error: unknown sub-command, unknown flag, bad value, no sub-command" {
  local args
  for args in "nosuchcommand" "--nosuchflag info" "--color purple info" "--cols 0 info" ""; do
    # shellcheck disable=SC2086
    run --separate-stderr node "$JENGA" progress $args
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    printf '%s\n' "$stderr" | grep -q '^usage: '
    # shellcheck disable=SC2086
    run --separate-stderr node "$CLI" $args
    [ "$status" -eq 2 ]
  done
}

@test "the command is agentless: its module spawns no process, calls no network API and no model" {
  run grep -n -E "child_process|spawn|exec(Sync|File)?\(|fetch\(|https?://|require\(|from \"(http|https|net)\"" "$CMD"
  [ "$status" -eq 1 ]
}

@test "Node-14 safe: no replaceAll, .at(, ??=, ||=, &&=, Object.hasOwn, structuredClone, node:test or fetch in the new module" {
  local re
  for re in '\.replaceAll\(' '\.at\(' '\?\?=' '\|\|=' '&&=' 'Object\.hasOwn' 'structuredClone' 'node:test' '(^|[^.[:alnum:]_])fetch\('; do
    run grep -v -E '^[[:space:]]*(//|/?\*)' "$CMD"
    if printf '%s\n' "$output" | grep -q -E "$re"; then false; fi
  done
  # the scan bites: a planted line is caught by the same patterns
  printf '%s\n' 'xs.at(-1)' | grep -q -E '\.at\('
}

@test "the bin registers the command in the switch and the new module is a real file under lib/commands" {
  grep -q 'case "progress"' "$JENGA"
  grep -q 'lib/commands/progress.js\|\.\./lib/commands/progress.js' "$JENGA"
  [ -f "$CMD" ]
}
