#!/usr/bin/env bats
#
# skills/j-workflow-recorder/scripts/recording-path.sh — slug derivation, the whole-filename limit,
# collision handling and destination resolution (E89, task E89_S01_T01).
#
# What this suite pins, and why each one is here rather than left to review:
#
#   1. THE 100-CHARACTER LIMIT IS A WHOLE-FILENAME LIMIT. The epic settles this (user-confirmed
#      2026-11-01): slug + "_RECORDING" + ".md" ≤ 100 in total, not "the slug is ≤ 100". The three
#      boundary tests below (under, exactly at, over) are the mechanical statement of that reading,
#      so a later change that quietly reinterprets it as a slug limit turns this file red.
#   2. THE DISCRIMINATOR IS PAID OUT OF THE BUDGET. A collision on a name that is already at the
#      ceiling must still produce a ≤ 100-character filename, which is only true if the slug is
#      re-truncated per candidate. Asserted directly on the worst case.
#   3. STDOUT IS A CONSUMABLE PATH. Every other script in the epic reads this one through a command
#      substitution, so "exactly one line, absolute, nothing else" is a contract and not a nicety.
#   4. THE DESTINATION IS READ, NOT ASSUMED. The resolution test points JENGA_PROJECT_ROOT at a
#      fixture whose paths.documentation is a NON-DEFAULT value, so a script that hardcoded the
#      conventional location would pass a weaker test and fails this one.
#   5. NO PATH LITERAL. The task's acceptance criteria grep the script for the two forbidden
#      strings; that grep is run here rather than by hand.
#
# Isolation: every test that touches the filesystem writes only inside $BATS_TEST_TMPDIR, via --dir
# or a fixture JENGA_PROJECT_ROOT. No real documentation directory is read or written, and the
# script creates nothing in any case — which is itself asserted.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-workflow-recorder/scripts/recording-path.sh"

# The two constants the script derives its budget from, restated here so the expectations below are
# independent of the script's own arithmetic.
SUFFIX="_RECORDING.md"
MAX_FILENAME=100

setup() {
  T="$BATS_TEST_TMPDIR"
  DEST="$T/dest"
  mkdir -p "$DEST"
  unset JENGA_RECORDING_DIR JENGA_PROJECT_ROOT
}

# Prints $2 repetitions of the single character $1. bash 3.2 safe, no seq, no brace ranges.
rep() {
  printf "%${2}s" '' | tr ' ' "$1"
}

# -----------------------------------------------------------------------------
# Shape of the script itself
# -----------------------------------------------------------------------------

@test "recording-path.sh exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "recording-path.sh contains no documentation-root path literal" {
  run grep -n 'project/documentation' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -n 'docs/' "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "recording-path.sh --help prints usage on stdout and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "recording-path.sh"
}

# -----------------------------------------------------------------------------
# Stdout is a consumable path
# -----------------------------------------------------------------------------

@test "prints exactly one absolute path on stdout and nothing else" {
  run --separate-stderr bash "$SCRIPT" --dir "$DEST" "Set up the release pipeline"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$stderr" = "" ]
  assert_starts_with "$output" "/"
  [ "$output" = "$DEST/set-up-the-release-pipeline$SUFFIX" ]
}

@test "the printed filename ends in _RECORDING.md" {
  run bash "$SCRIPT" --dir "$DEST" "Anything at all"
  [ "$status" -eq 0 ]
  case "$output" in
    *"$SUFFIX") : ;;
    *) echo "expected the path to end in $SUFFIX, got: $output" >&2; return 1 ;;
  esac
}

@test "a relative --dir is made absolute" {
  cd "$T"
  mkdir -p relative-dest
  run bash "$SCRIPT" --dir relative-dest "Some name"
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "/"
  [ "$output" = "$(cd "$T/relative-dest" && pwd)/some-name$SUFFIX" ]
}

@test "the script creates nothing" {
  run bash "$SCRIPT" --dir "$DEST" "Nothing should appear on disk"
  [ "$status" -eq 0 ]
  [ ! -e "$output" ]
  [ -z "$(ls -A "$DEST")" ]
}

# -----------------------------------------------------------------------------
# Slug derivation
# -----------------------------------------------------------------------------

@test "the slug is lowercased, non-alphanumerics collapse to one hyphen, and no hyphen is left at either end" {
  run bash "$SCRIPT" --slug-only --dir "$DEST" '  ***Fix THE  Login/Logout bug (again)!!  '
  [ "$status" -eq 0 ]
  [ "$output" = "fix-the-login-logout-bug-again" ]
}

@test "digits survive slug derivation" {
  run bash "$SCRIPT" --slug-only --dir "$DEST" "Bump E89 to v2.1"
  [ "$status" -eq 0 ]
  [ "$output" = "bump-e89-to-v2-1" ]
}

@test "a multi-word name may be passed as separate arguments" {
  run bash "$SCRIPT" --slug-only --dir "$DEST" Set up the release pipeline
  [ "$status" -eq 0 ]
  [ "$output" = "set-up-the-release-pipeline" ]
}

# -----------------------------------------------------------------------------
# The whole-filename limit: under, exactly at, over
# -----------------------------------------------------------------------------

@test "a name well under the limit is not truncated at all" {
  local name slug base
  name="$(rep a 50)"
  run bash "$SCRIPT" --dir "$DEST" "$name"
  [ "$status" -eq 0 ]
  base="$(basename "$output")"
  [ "$base" = "$name$SUFFIX" ]
  [ "${#base}" -eq $(( 50 + ${#SUFFIX} )) ]
}

@test "a name exactly at the boundary yields a 100-character filename and is not truncated further" {
  local budget name base
  budget=$(( MAX_FILENAME - ${#SUFFIX} ))
  name="$(rep a "$budget")"
  run bash "$SCRIPT" --dir "$DEST" "$name"
  [ "$status" -eq 0 ]
  base="$(basename "$output")"
  [ "${#base}" -eq "$MAX_FILENAME" ]
  # The whole slug survived: the filename is the full name plus the suffix, byte for byte.
  [ "$base" = "$name$SUFFIX" ]
}

@test "a name far over the limit yields a filename of exactly 100 characters" {
  local base
  run bash "$SCRIPT" --dir "$DEST" "$(rep a 400)"
  [ "$status" -eq 0 ]
  base="$(basename "$output")"
  [ "${#base}" -eq "$MAX_FILENAME" ]
}

@test "truncation never leaves a trailing hyphen before the suffix" {
  # The slug is (budget - 1) a's, a hyphen, then a b — so the cut lands exactly on the hyphen and
  # the strip is what keeps the filename well-formed. Without it the name would end "a-_RECORDING".
  local budget name base stem
  budget=$(( MAX_FILENAME - ${#SUFFIX} ))
  name="$(rep a $(( budget - 1 ))) b"
  run bash "$SCRIPT" --dir "$DEST" "$name"
  [ "$status" -eq 0 ]
  base="$(basename "$output")"
  stem="${base%"$SUFFIX"}"
  [ "${#base}" -le "$MAX_FILENAME" ]
  assert_not_contains "$base" "-$SUFFIX"
  case "$stem" in
    *-) echo "slug ends in a hyphen: $stem" >&2; return 1 ;;
    *) : ;;
  esac
}

@test "truncation cuts mid-word rather than dropping the final word" {
  # The board's own task filenames are the precedent. The slug below ends in a long final word that
  # straddles the budget; the result must still contain the start of that word.
  local budget name base
  budget=$(( MAX_FILENAME - ${#SUFFIX} ))
  name="$(rep a $(( budget - 4 ))) supercalifragilistic"
  run bash "$SCRIPT" --dir "$DEST" "$name"
  [ "$status" -eq 0 ]
  base="$(basename "$output")"
  [ "${#base}" -eq "$MAX_FILENAME" ]
  assert_contains "$base" "-sup"
}

# -----------------------------------------------------------------------------
# Collision handling
# -----------------------------------------------------------------------------

@test "an existing recording's path is never returned, and the existing file is not modified" {
  local first before after
  first="$(bash "$SCRIPT" --dir "$DEST" "My process")"
  printf 'original content\n' > "$first"
  before="$(cksum < "$first")"

  run bash "$SCRIPT" --dir "$DEST" "My process"
  [ "$status" -eq 0 ]
  [ "$output" != "$first" ]
  [ ! -e "$output" ]

  after="$(cksum < "$first")"
  [ "$before" = "$after" ]
  [ "$(cat "$first")" = "original content" ]
}

@test "successive creations walk the discriminator deterministically: -2 then -3" {
  local p1 p2 p3
  p1="$(bash "$SCRIPT" --dir "$DEST" "My process")"
  [ "$(basename "$p1")" = "my-process$SUFFIX" ]
  touch "$p1"

  p2="$(bash "$SCRIPT" --dir "$DEST" "My process")"
  [ "$(basename "$p2")" = "my-process-2$SUFFIX" ]
  touch "$p2"

  p3="$(bash "$SCRIPT" --dir "$DEST" "My process")"
  [ "$(basename "$p3")" = "my-process-3$SUFFIX" ]
}

@test "a collision discriminator never pushes the filename past 100 characters" {
  # Worst case: the uncollided name is already AT the ceiling, so the discriminator can only fit if
  # it is spent out of the slug budget rather than added on top of it.
  local budget name p1 p2 base2 p3 base3
  budget=$(( MAX_FILENAME - ${#SUFFIX} ))
  name="$(rep a "$budget")"

  p1="$(bash "$SCRIPT" --dir "$DEST" "$name")"
  [ "${#p1}" -gt 0 ]
  [ "$(basename "$p1")" = "$name$SUFFIX" ]
  touch "$p1"

  p2="$(bash "$SCRIPT" --dir "$DEST" "$name")"
  base2="$(basename "$p2")"
  [ "${#base2}" -le "$MAX_FILENAME" ]
  [ "$base2" != "$(basename "$p1")" ]
  assert_contains "$base2" "-2$SUFFIX"
  touch "$p2"

  p3="$(bash "$SCRIPT" --dir "$DEST" "$name")"
  base3="$(basename "$p3")"
  [ "${#base3}" -le "$MAX_FILENAME" ]
  [ "$base3" != "$base2" ]
  assert_contains "$base3" "-3$SUFFIX"
}

@test "a two-digit discriminator still fits inside the limit" {
  local budget name i p base
  budget=$(( MAX_FILENAME - ${#SUFFIX} ))
  name="$(rep a "$budget")"
  touch "$DEST/$name$SUFFIX"
  i=2
  while [ "$i" -le 12 ]; do
    p="$(bash "$SCRIPT" --dir "$DEST" "$name")"
    base="$(basename "$p")"
    [ "${#base}" -le "$MAX_FILENAME" ]
    [ ! -e "$p" ]
    touch "$p"
    i=$(( i + 1 ))
  done
  base="$(basename "$p")"
  assert_contains "$base" "-12$SUFFIX"
  [ "${#base}" -le "$MAX_FILENAME" ]
}

# -----------------------------------------------------------------------------
# Destination resolution
# -----------------------------------------------------------------------------

@test "the destination comes from workflow.json's paths.documentation" {
  local proj
  proj="$T/proj"
  mkdir -p "$proj/project/configs"
  printf '%s\n' '{"paths":{"documentation":"a-deliberately-unconventional/doc-root"}}' \
    > "$proj/project/configs/workflow.json"

  JENGA_PROJECT_ROOT="$proj" run bash "$SCRIPT" "Resolved from the registry"
  [ "$status" -eq 0 ]
  [ "$output" = "$proj/a-deliberately-unconventional/doc-root/resolved-from-the-registry$SUFFIX" ]
}

@test "paths.documentation may be absolute" {
  local proj
  proj="$T/proj-abs"
  mkdir -p "$proj/project/configs" "$T/elsewhere"
  printf '{"paths":{"documentation":"%s"}}\n' "$T/elsewhere" \
    > "$proj/project/configs/workflow.json"

  JENGA_PROJECT_ROOT="$proj" run bash "$SCRIPT" "Absolute root"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/elsewhere/absolute-root$SUFFIX" ]
}

@test "JENGA_RECORDING_DIR overrides the resolved root, and --dir overrides that" {
  local other
  other="$T/other"
  mkdir -p "$other"

  JENGA_RECORDING_DIR="$other" run bash "$SCRIPT" "Env seam"
  [ "$status" -eq 0 ]
  [ "$output" = "$other/env-seam$SUFFIX" ]

  JENGA_RECORDING_DIR="$other" run bash "$SCRIPT" --dir "$DEST" "Env seam"
  [ "$status" -eq 0 ]
  [ "$output" = "$DEST/env-seam$SUFFIX" ]
}

@test "a destination directory that does not exist yet still yields an absolute path, and is not created" {
  local missing
  missing="$T/not-created-yet"
  run bash "$SCRIPT" --dir "$missing" "Future home"
  [ "$status" -eq 0 ]
  [ "$output" = "$missing/future-home$SUFFIX" ]
  [ ! -e "$missing" ]
}

# -----------------------------------------------------------------------------
# Usage errors
# -----------------------------------------------------------------------------

@test "no descriptive name exits 2" {
  run bash "$SCRIPT" --dir "$DEST"
  [ "$status" -eq 2 ]
}

@test "a name with no alphanumeric character exits 2 and prints nothing on stdout" {
  run --separate-stderr bash "$SCRIPT" --dir "$DEST" '!!! ???'
  [ "$status" -eq 2 ]
  [ "$output" = "" ]
  assert_contains "$stderr" "no alphanumeric"
}

@test "an unknown option exits 2" {
  run bash "$SCRIPT" --no-such-option "A name"
  [ "$status" -eq 2 ]
}

@test "--max below the suffix length exits 2" {
  run bash "$SCRIPT" --max 5 --dir "$DEST" "A name"
  [ "$status" -eq 2 ]
}

@test "--max is honoured as a whole-filename limit" {
  local base
  run bash "$SCRIPT" --max 30 --dir "$DEST" "$(rep a 100)"
  [ "$status" -eq 0 ]
  base="$(basename "$output")"
  [ "${#base}" -eq 30 ]
}
