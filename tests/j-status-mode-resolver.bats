#!/usr/bin/env bats
#
# E92_S06_T26: skills/j-status/scripts/resolve-status-mode.sh - the deterministic argument handling behind `j.status`:
# `--legacy`, `--all`, one epic or story id, `--root`, `--cols`, `--color`, in any order, an unknown flag exits 2.
#
# `mode` and `plan` are checked without running a renderer; `render` is checked against the real renderers on the
# throwaway board of tests/helpers/progress-fixture.bash (passed as --root, the live project/board/ is never read): what
# the resolver prints must be byte-for-byte what the chosen renderer prints when called directly.

bats_require_minimum_version 1.5.0

load helpers/progress-fixture

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  D="$REPO/skills/j-status/scripts"
  M="$D/resolve-status-mode.sh"
  unset NO_COLOR JENGA_PROGRESS_LANG LC_CTYPE COLUMNS JENGA_BOARD_PROGRESS JENGA_PROGRESS_LABELS JENGA_RENDER_PROGRESS_BAR
  export LANG="en_US.UTF-8"
  unset LC_ALL
  pf_setup
}

mode() { bash "$M" mode "$@"; }
plan() { bash "$M" plan "$@"; }

@test "no argument is the overview mode and runs the T24 renderer" {
  [ "$(mode)" = "overview" ]
  [ "$(plan)" = "render-status-overview.sh" ]
}

@test "an epic id or a story id is the scope mode and runs the T25 renderer with the id" {
  [ "$(mode E92)" = "scope" ]
  [ "$(plan E92)" = "render-status-scope-view.sh E92" ]
  [ "$(plan E92_S06)" = "render-status-scope-view.sh E92_S06" ]
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

@test "--all with an id is the new scope view with every story shown: --all is passed through" {
  [ "$(mode E92 --all)" = "scope" ]
  [ "$(plan E92 --all)" = "render-status-scope-view.sh E92 --all" ]
  [ "$(plan --all E92_S06)" = "render-status-scope-view.sh E92_S06 --all" ]
}

@test "--legacy wins over --all, with and without an id" {
  [ "$(plan --legacy --all)" = "render-status-bars.sh" ]
  [ "$(plan --all --legacy E92)" = "render-status-scope.sh E92" ]
}

@test "the order of the arguments does not matter" {
  want="render-status-scope-view.sh E03_S05 --all --cols 60 --color never --root /x"
  [ "$(plan E03_S05 --all --cols 60 --color never --root /x)" = "$want" ]
  [ "$(plan --root /x --color never --cols 60 --all E03_S05)" = "$want" ]
  [ "$(plan --cols 60 E03_S05 --root /x --all --color never)" = "$want" ]
  want="render-status-scope.sh E03 --cols 60 --root /x"
  [ "$(plan --legacy E03 --cols 60 --root /x)" = "$want" ]
  [ "$(plan E03 --root /x --cols 60 --legacy)" = "$want" ]
  [ "$(plan --root /x --legacy --cols 60 E03)" = "$want" ]
}

@test "--flag=value is accepted for --root, --cols and --color" {
  [ "$(plan --root=/x --cols=60 --color=never)" = "render-status-overview.sh --cols 60 --color never --root /x" ]
}

@test "--root, --cols and --color are forwarded to every renderer" {
  [ "$(plan --root /r)" = "render-status-overview.sh --root /r" ]
  [ "$(plan --legacy --root /r)" = "render-status-bars.sh --root /r" ]
  [ "$(plan --all --cols 90 --color always)" = "render-status-bars.sh --cols 90 --color always" ]
  [ "$(plan E01 --root /r --cols 55)" = "render-status-scope-view.sh E01 --cols 55 --root /r" ]
}

@test "an id is accepted in any width and any case, and passed on unchanged" {
  [ "$(plan E3_S5)" = "render-status-scope-view.sh E3_S5" ]
  [ "$(plan e03)" = "render-status-scope-view.sh e03" ]
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
  for args in "--root" "--cols" "--color" "E92 E93" "E92_S06_T26" "banana" "E92x" "--color red" "--cols abc" "--cols 0" "--cols=" "--root=" "--color=" "--root "; do
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
  [ "$(plan E01 --all)" = "render-status-scope-view.sh E01 --all" ]
  [ -z "$(ls -A)" ]
}

@test "render with no argument prints what the overview renderer prints" {
  want="$(bash "$D/render-status-overview.sh" --color never --cols 80 --root "$PF_ROOT")"
  [ -n "$want" ]
  run bash "$M" render --cols 80 --color never --root "$PF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "render with an id prints what the scope renderer prints, and --all is passed to it" {
  want="$(bash "$D/render-status-scope-view.sh" E01_S02 --color never --cols 80 --root "$PF_ROOT")"
  [ -n "$want" ]
  run bash "$M" render E01_S02 --root "$PF_ROOT" --cols 80 --color never
  [ "$output" = "$want" ]
  wantall="$(bash "$D/render-status-scope-view.sh" E01 --all --color never --cols 80 --root "$PF_ROOT")"
  run bash "$M" render --all E01 --color never --cols 80 --root "$PF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$wantall" ]
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

@test "render of a missing renderer warns once on stderr and exits 0 with nothing on stdout" {
  mkdir -p "$BATS_TEST_TMPDIR/copy"
  cp "$M" "$BATS_TEST_TMPDIR/copy/resolve-status-mode.sh"
  run --separate-stderr bash "$BATS_TEST_TMPDIR/copy/resolve-status-mode.sh" render
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"renderer not found"* ]]
}

@test "the legacy renderers are not changed by the mode switch: usage and --all behaviour of the old scripts are intact" {
  run bash "$D/render-status-bars.sh" --all
  [ "$status" -eq 2 ]
  run bash "$D/render-status-scope.sh" E01 --all
  [ "$status" -eq 2 ]
}
