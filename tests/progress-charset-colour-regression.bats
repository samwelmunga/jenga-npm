#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S08_T08: the two problems that started story E92_S08, kept as regression tests.
#
# 1. ASCII and no colour. The bash renderers chose glyphs from LC_ALL/LC_CTYPE/LANG and colour from "stdout is a TTY",
#    and the agent's Bash tool has LANG="" and a pipe on stdout, so it always got ASCII. The Node renderer makes both an
#    explicit choice: with LANG, LC_ALL and LC_CTYPE empty and stdout a pipe, the DEFAULT output is UTF-8 (no --charset
#    given), `--charset ascii` is pure ASCII, and `--color always` emits ANSI even with NO_COLOR set. Checked through
#    every entry point a skill or a user runs: lib/progress/cli.js, skills/j-status/scripts/resolve-status-mode.sh
#    render (j.status) and skills/j-break/scripts/run-progress.sh (j.do, j.dooo, j.jenga, j.break).
# 2. Output hidden in a collapsed tool-call row. The SKILL.md of j-status, j-do, j-dooo, jenga and j-break tell the agent
#    to copy the rendering into the reply as a fenced code block, run with --charset utf8 --color never, and none still
#    says "print its stdout unchanged". The text is compared with line breaks folded to spaces: the old j-status wording
#    was split over two lines, which a line-based grep never sees (the control below proves the fold finds it).
#
# The fixture board is tests/helpers/progress-fixture.bash (read-only here); the real board is never read.

bats_require_minimum_version 1.5.0

load helpers/progress-fixture

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CLI="$REPO_ROOT/lib/progress/cli.js"
RESOLVER="$REPO_ROOT/skills/j-status/scripts/resolve-status-mode.sh"
RP="$REPO_ROOT/skills/j-break/scripts/run-progress.sh"
SKILLS=(j-status j-do j-dooo jenga j-break)

setup() {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  pf_setup
  export JENGA_PROJECT_ROOT="$PF_ROOT"
  unset NO_COLOR JENGA_PROGRESS_CHARSET JENGA_PROGRESS_COLOR JENGA_PROGRESS_LANG JENGA_PROGRESS_RENDERER COLUMNS
}

# The command, with no locale at all, stdout through a pipe (cat), stderr kept apart. Sets $output and $stderr.
no_locale() {
  run --separate-stderr env LANG= LC_ALL= LC_CTYPE= bash -c '"$@" | cat' _ "$@"
}

# Number of bytes >= 0x80 in $output.
high_bytes() { printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' '; }
has_esc() { printf '%s' "$output" | LC_ALL=C grep -q $'\033'; }
valid_utf8() { printf '%s' "$output" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; }

# The default output: UTF-8 glyphs, valid UTF-8, no ANSI, no warning.
assert_utf8_default() {
  [ "$status" -eq 0 ]
  [ -z "$stderr" ] || { echo "stderr: $stderr"; false; }
  [ -n "$output" ]
  [ "$(high_bytes)" -gt 0 ] || { echo "no UTF-8 glyph in: $output"; false; }
  valid_utf8
  ! has_esc
}

assert_pure_ascii() {
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(high_bytes)" -eq 0 ] || { echo "non-ASCII byte in: $output"; false; }
}

# ---- problem 1: charset and colour are explicit, never a locale or TTY guess ------------------------------------------

@test "cli.js: LANG, LC_ALL, LC_CTYPE empty and a pipe: the default is UTF-8 with no colour, --charset ascii is pure ASCII" {
  no_locale node "$CLI" --cols 80 bar --story E01_S02
  assert_utf8_default
  no_locale node "$CLI" --cols 80 --charset ascii bar --story E01_S02
  assert_pure_ascii
}

@test "j.status (resolve-status-mode.sh render), no locale and a pipe: the default is UTF-8, --charset ascii is pure ASCII" {
  # no --charset: the UTF-8 default is the renderer's own, not a flag the skill happens to pass
  no_locale bash "$RESOLVER" render --cols 80 --root "$PF_ROOT"
  assert_utf8_default
  no_locale bash "$RESOLVER" render E01 --cols 80 --charset ascii --root "$PF_ROOT"
  assert_pure_ascii
}

@test "run-progress.sh (j.do, j.dooo, j.jenga, j.break), no locale and a pipe: the default is UTF-8, --charset ascii is pure ASCII" {
  no_locale bash "$RP" --scope story --task E01_S02_T01 --cols 80
  assert_utf8_default
  no_locale bash "$RP" --scope story --task E01_S02_T01 --cols 80 --charset ascii
  assert_pure_ascii
}

@test "the reported problem, reproduced where it still lives: the --legacy bash path guesses ASCII from the empty locale, the default does not" {
  no_locale bash "$RP" --scope story --task E01_S02_T01 --cols 80 --legacy
  assert_pure_ascii
  no_locale bash "$RESOLVER" render --legacy E01 --cols 80 --root "$PF_ROOT"
  assert_pure_ascii
  # the same calls without --legacy are UTF-8 (the tests above), so the default really changed
  no_locale bash "$RP" --scope story --task E01_S02_T01 --cols 80
  assert_utf8_default
}

@test "the same default with LANG=C as with a UTF-8 locale: the locale does not choose the glyphs (cli.js)" {
  run --separate-stderr env LANG=C LC_ALL=C node "$CLI" --cols 80 --color never bar --story E01_S02
  [ "$status" -eq 0 ]
  local c="$output"
  run --separate-stderr env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 node "$CLI" --cols 80 --color never bar --story E01_S02
  [ "$status" -eq 0 ]
  [ "$output" = "$c" ]
  [ "$(high_bytes)" -gt 0 ]
}

@test "--color always emits ANSI over NO_COLOR and a pipe, through cli.js, j.status and run-progress.sh" {
  no_locale env NO_COLOR=1 node "$CLI" --cols 80 --color always bar --story E01_S02
  [ "$status" -eq 0 ]; has_esc
  no_locale env NO_COLOR=1 bash "$RESOLVER" render E01 --cols 80 --color always --root "$PF_ROOT"
  [ "$status" -eq 0 ]; has_esc
  no_locale env NO_COLOR=1 bash "$RP" --scope story --task E01_S02_T01 --cols 80 --color always
  [ "$status" -eq 0 ]; has_esc
}

@test "colour auto stays off on a pipe and with NO_COLOR, so the copy into the reply is never coloured" {
  no_locale node "$CLI" --cols 80 bar --story E01_S02
  [ "$status" -eq 0 ]; ! has_esc
  no_locale env NO_COLOR=1 node "$CLI" --cols 80 --color auto bar --story E01_S02
  [ "$status" -eq 0 ]; ! has_esc
}

# ---- problem 2: the rendering is copied into the reply as a fenced code block ----------------------------------------

# The SKILL.md text with line breaks folded to single spaces.
folded() { tr '\n' ' ' < "$1" | tr -s ' '; }

@test "the five SKILL.md files tell the agent to copy the rendering into the reply as a fenced code block, run with --charset utf8 --color never" {
  local s f
  for s in "${SKILLS[@]}"; do
    f="$REPO_ROOT/skills/$s/SKILL.md"
    [ -f "$f" ]
    folded "$f" | grep -qiF 'into your reply as a fenced code block' || { echo "$s: no copy-into-the-reply instruction"; false; }
    folded "$f" | grep -qF -- '--charset utf8 --color never' || { echo "$s: no --charset utf8 --color never"; false; }
  done
}

@test "none of the five SKILL.md files still says \"print its stdout unchanged\" (line breaks folded)" {
  local s f
  for s in "${SKILLS[@]}"; do
    f="$REPO_ROOT/skills/$s/SKILL.md"
    run bash -c 'tr "\n" " " < "$1" | tr -s " " | grep -ciF "print its stdout unchanged"' _ "$f"
    [ "$output" = "0" ] || { echo "$s still says print its stdout unchanged"; false; }
  done
}

@test "control: the folded search finds the old j-status wording, which was split over two lines (skipped without that commit)" {
  git -C "$REPO_ROOT" cat-file -e 8d380c6e:skills/j-status/SKILL.md 2>/dev/null || skip "commit 8d380c6e is not in this history"
  local old="$BATS_TEST_TMPDIR/old-SKILL.md"
  git -C "$REPO_ROOT" show 8d380c6e:skills/j-status/SKILL.md > "$old"
  # a line-based grep misses it ...
  run grep -ciF 'print its stdout unchanged' "$old"
  [ "$output" = "0" ]
  # ... the fold does not
  [ "$(folded "$old" | grep -ciF 'print its stdout unchanged')" -ge 1 ]
}
