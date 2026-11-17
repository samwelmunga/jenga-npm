#!/usr/bin/env bats
#
# E92_S06_T26: skills/j-status/scripts/resolve-status-mode.sh - the deterministic argument handling behind `j.status`:
# `--legacy`, `--all`, one epic or story id, `--root`, `--cols`, `--color`, in any order, an unknown flag exits 2.
#
# `mode` and `plan` are checked without running a renderer; `render` is checked against the real renderers on the
# throwaway board of tests/helpers/progress-fixture.bash (passed as --root, the live project/board/ is never read): what
# the resolver prints must be byte-for-byte what the chosen renderer prints when called directly.
#
# E92_S08_T06: the default modes (overview, scope) now run the Node renderer `node lib/progress/cli.js overview|scope`;
# --legacy stays on the bash renderers; with `node` missing from PATH, render falls back to the legacy renderer with one
# stderr warning and exit 0 (checked with a stub PATH that holds every command of the real PATH except node).

bats_require_minimum_version 1.5.0

load helpers/progress-fixture

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  D="$REPO/skills/j-status/scripts"
  M="$D/resolve-status-mode.sh"
  CLI="$REPO/lib/progress/cli.js"
  unset NO_COLOR JENGA_PROGRESS_LANG LC_CTYPE COLUMNS JENGA_BOARD_PROGRESS JENGA_PROGRESS_LABELS JENGA_RENDER_PROGRESS_BAR
  export LANG="en_US.UTF-8"
  unset LC_ALL
  pf_setup
}

mode() { bash "$M" mode "$@"; }
plan() { bash "$M" plan "$@"; }

@test "no argument is the overview mode and runs the Node overview renderer" {
  [ "$(mode)" = "overview" ]
  [ "$(plan)" = "node lib/progress/cli.js overview" ]
}

@test "an epic id or a story id is the scope mode and runs the Node scope renderer with the id" {
  [ "$(mode E92)" = "scope" ]
  [ "$(plan E92)" = "node lib/progress/cli.js scope E92" ]
  [ "$(plan E92_S06)" = "node lib/progress/cli.js scope E92_S06" ]
}

@test "--legacy without an id selects render-status-bars.sh, with an id render-status-scope.sh" {
  [ "$(mode --legacy)" = "legacy" ]
  [ "$(plan --legacy)" = "render-status-bars.sh" ]
  [ "$(mode --legacy E92_S06)" = "legacy-scope" ]
  [ "$(plan --legacy E92_S06)" = "render-status-scope.sh E92_S06" ]
}

@test "--all without an id is the full list: the legacy overview path, and --all is not passed to a legacy renderer" {
  [ "$(mode --all)" = "legacy" ]
  [ "$(plan --all)" = "render-status-bars.sh" ]
}

@test "--all with an id is the Node scope view, which always lists every story: --all is accepted and not forwarded" {
  [ "$(mode E92 --all)" = "scope" ]
  [ "$(plan E92 --all)" = "node lib/progress/cli.js scope E92" ]
  [ "$(plan --all E92_S06)" = "node lib/progress/cli.js scope E92_S06" ]
}

@test "--legacy wins over --all, with and without an id" {
  [ "$(plan --legacy --all)" = "render-status-bars.sh" ]
  [ "$(plan --all --legacy E92)" = "render-status-scope.sh E92" ]
}

@test "the order of the arguments does not matter" {
  want="node lib/progress/cli.js scope E03_S05 --charset utf8 --cols 60 --color never --root /x"
  [ "$(plan E03_S05 --all --cols 60 --color never --charset utf8 --root /x)" = "$want" ]
  [ "$(plan --root /x --charset utf8 --color never --cols 60 --all E03_S05)" = "$want" ]
  [ "$(plan --cols 60 E03_S05 --root /x --all --color never --charset utf8)" = "$want" ]
  want="render-status-scope.sh E03 --cols 60 --root /x"
  [ "$(plan --legacy E03 --cols 60 --root /x)" = "$want" ]
  [ "$(plan E03 --root /x --cols 60 --legacy)" = "$want" ]
  [ "$(plan --root /x --legacy --cols 60 E03)" = "$want" ]
}

@test "--flag=value is accepted for --root, --cols, --color and --charset" {
  [ "$(plan --root=/x --cols=60 --color=never --charset=ascii)" = "node lib/progress/cli.js overview --charset ascii --cols 60 --color never --root /x" ]
}

@test "--root, --cols and --color are forwarded to every renderer" {
  [ "$(plan --root /r)" = "node lib/progress/cli.js overview --root /r" ]
  [ "$(plan --legacy --root /r)" = "render-status-bars.sh --root /r" ]
  [ "$(plan --all --cols 90 --color always)" = "render-status-bars.sh --cols 90 --color always" ]
  [ "$(plan E01 --root /r --cols 55)" = "node lib/progress/cli.js scope E01 --cols 55 --root /r" ]
}

@test "--charset is forwarded to the Node renderer only, never to a legacy renderer, and is not forced when absent" {
  [ "$(plan --charset utf8 --color never)" = "node lib/progress/cli.js overview --charset utf8 --color never" ]
  [ "$(plan E01 --charset ascii)" = "node lib/progress/cli.js scope E01 --charset ascii" ]
  [ "$(plan --legacy --charset utf8 --color never)" = "render-status-bars.sh --color never" ]
  [ "$(plan --all --charset ascii)" = "render-status-bars.sh" ]
  [ "$(plan --legacy E01 --charset utf8)" = "render-status-scope.sh E01" ]
  [[ "$(plan)" != *"--charset"* ]]
}

@test "an id is accepted in any width and any case, and passed on unchanged" {
  [ "$(plan E3_S5)" = "node lib/progress/cli.js scope E3_S5" ]
  [ "$(plan e03)" = "node lib/progress/cli.js scope e03" ]
}

@test "an unknown flag exits 2 in every sub-command, with one stderr line and nothing on stdout" {
  for sub in mode plan render; do
    run --separate-stderr bash "$M" "$sub" --bogus
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"unknown argument: --bogus"* ]]
    run --separate-stderr bash "$M" "$sub" E92 --legacy -x
    [ "$status" -eq 2 ]
  done
}

@test "a flag without a value, a second id, a task id, a malformed id, a bad --color or --cols exit 2" {
  for args in "--root" "--cols" "--color" "E92 E93" "E92_S06_T26" "banana" "E92x" "--color red" "--charset latin1" "--charset" "--charset=" "--cols abc" "--cols 0" "--cols=" "--root=" "--color=" "--root "; do
    run bash "$M" mode $args
    [ "$status" -eq 2 ] || { echo "args: $args -> $status"; return 1; }
  done
}

@test "a missing or unknown sub-command exits 2, --help prints the usage and exits 0" {
  run bash "$M"
  [ "$status" -eq 2 ]
  run bash "$M" explode
  [ "$status" -eq 2 ]
  run bash "$M" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolve-status-mode.sh mode"* ]]
  [[ "$output" != *"MODES AND RENDERERS"* ]]
}

@test "mode and plan read no board and write nothing: they work with no project at all" {
  mkdir "$BATS_TEST_TMPDIR/empty"
  cd "$BATS_TEST_TMPDIR/empty"
  [ "$(mode --legacy E01)" = "legacy-scope" ]
  [ "$(plan E01 --all)" = "node lib/progress/cli.js scope E01" ]
  [ -z "$(ls -A)" ]
}

@test "render with no argument prints, byte for byte, what the Node overview renderer prints" {
  command -v node >/dev/null 2>&1 || skip "node is not on PATH"
  want="$(node "$CLI" overview --charset utf8 --color never --cols 80 --root "$PF_ROOT")"
  [ -n "$want" ]
  run bash "$M" render --cols 80 --color never --charset utf8 --root "$PF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  [ "$output" != "$(bash "$D/render-status-bars.sh" --color never --cols 80 --root "$PF_ROOT")" ]
}

@test "render with an id prints, byte for byte, what the Node scope renderer prints, also with --all" {
  command -v node >/dev/null 2>&1 || skip "node is not on PATH"
  want="$(node "$CLI" scope E01_S02 --charset utf8 --color never --cols 80 --root "$PF_ROOT")"
  [ -n "$want" ]
  run bash "$M" render E01_S02 --root "$PF_ROOT" --cols 80 --color never --charset utf8
  [ "$output" = "$want" ]
  wantall="$(node "$CLI" scope E01 --charset utf8 --color never --cols 80 --root "$PF_ROOT")"
  [ -n "$wantall" ]
  run bash "$M" render --all E01 --color never --cols 80 --charset utf8 --root "$PF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$wantall" ]
}

@test "render --charset utf8 prints UTF-8 glyphs with an empty LANG, --charset ascii prints pure ASCII" {
  command -v node >/dev/null 2>&1 || skip "node is not on PATH"
  run env LANG= LC_ALL= bash "$M" render --charset utf8 --color never --cols 80 --root "$PF_ROOT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' ')" -gt 0 ]
  run env LANG= LC_ALL= bash "$M" render E01 --charset ascii --color never --cols 80 --root "$PF_ROOT"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' ')" -eq 0 ]
}

@test "render --legacy prints, byte for byte, what render-status-bars.sh prints, and --all prints the same" {
  want="$(bash "$D/render-status-bars.sh" --color never --cols 80 --root "$PF_ROOT")"
  [ -n "$want" ]
  run bash "$M" render --legacy --root "$PF_ROOT" --cols 80 --color never
  [ "$output" = "$want" ]
  run bash "$M" render --all --root "$PF_ROOT" --cols 80 --color never
  [ "$output" = "$want" ]
  run bash "$M" render --all --legacy --root "$PF_ROOT" --cols 80 --color never
  [ "$output" = "$want" ]
}

@test "render --legacy <id> prints, byte for byte, what render-status-scope.sh prints" {
  want="$(bash "$D/render-status-scope.sh" E01 --color never --cols 80 --root "$PF_ROOT")"
  [ -n "$want" ]
  run bash "$M" render --legacy E01 --root "$PF_ROOT" --cols 80 --color never
  [ "$output" = "$want" ]
  run bash "$M" render E01 --legacy --all --root "$PF_ROOT" --cols 80 --color never
  [ "$output" = "$want" ]
}

@test "render passes the renderer's own usage error through (a task id is refused before any renderer runs)" {
  run bash "$M" render E01_S01_T01 --root "$PF_ROOT"
  [ "$status" -eq 2 ]
}

# A PATH that holds every command of the real PATH except node (the first one of each name wins, as PATH lookup does).
nodeless_path() {
  local stub="$BATS_TEST_TMPDIR/nodeless-bin" dir f n
  mkdir -p "$stub"
  local IFS=:
  for dir in $PATH; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      n="${f##*/}"
      [ "$n" != "node" ] && [ -x "$f" ] && [ ! -e "$stub/$n" ] && ln -s "$f" "$stub/$n"
    done
  done
  printf '%s' "$stub"
}

@test "with node missing from PATH, render prints the legacy overview, one stderr warning, and exits 0" {
  want="$(bash "$D/render-status-bars.sh" --color never --cols 80 --root "$PF_ROOT")"
  [ -n "$want" ]
  stub="$(nodeless_path)"
  run env PATH="$stub" bash -c 'command -v node'
  [ "$status" -ne 0 ]
  run --separate-stderr env PATH="$stub" bash "$M" render --charset utf8 --color never --cols 80 --root "$PF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
  [[ "$stderr" == *"node not found on PATH"*"render-status-bars.sh"* ]]
}

@test "with node missing from PATH, render <id> prints the legacy scope block, one stderr warning, and exits 0" {
  want="$(bash "$D/render-status-scope.sh" E01 --color never --cols 80 --root "$PF_ROOT")"
  [ -n "$want" ]
  stub="$(nodeless_path)"
  run --separate-stderr env PATH="$stub" bash "$M" render E01 --all --color never --cols 80 --root "$PF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
  [[ "$stderr" == *"node not found on PATH"*"render-status-scope.sh"* ]]
}

@test "with node missing from PATH, --legacy runs the legacy renderer with no warning at all" {
  stub="$(nodeless_path)"
  run --separate-stderr env PATH="$stub" bash "$M" render --legacy --color never --cols 80 --root "$PF_ROOT"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -z "$stderr" ]
}

@test "the skill's command is not blocked at the Guarded level: Bash(*) is allowed and no deny rule matches it" {
  G="$REPO/templates/permission-levels/level-2-guarded.json"
  [ "$(jq -r '.permissions.allow | index("Bash(*)") != null' "$G")" = "true" ]
  # The skill runs `bash <resolver> render ...`, which execs node inside the script; neither word starts a deny rule.
  [ "$(jq -r '[.permissions.deny[] | select(test("^Bash\\((bash|node)( |\\*|\\))"))] | length' "$G")" = "0" ]
}

@test "render of a missing renderer warns once on stderr and exits 0 with nothing on stdout" {
  mkdir -p "$BATS_TEST_TMPDIR/copy"
  cp "$M" "$BATS_TEST_TMPDIR/copy/resolve-status-mode.sh"
  run --separate-stderr bash "$BATS_TEST_TMPDIR/copy/resolve-status-mode.sh" render
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"renderer not found"* ]]
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
}

@test "the legacy renderers are not changed by the mode switch: usage and --all behaviour of the old scripts are intact" {
  run bash "$D/render-status-bars.sh" --all
  [ "$status" -eq 2 ]
  run bash "$D/render-status-scope.sh" E01 --all
  [ "$status" -eq 2 ]
}
