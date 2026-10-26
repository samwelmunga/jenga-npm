#!/usr/bin/env bats
#
# E80_S06_T08: scripts/workflow/check-doc-refs.sh verifies that every relative markdown link and every
# repo-path backtick token in a documentation page points at an existing file or script.
#
# Fixture-tree convention: each case builds a throwaway tree under $BATS_TEST_TMPDIR and passes it with --root.
# stdout and stderr land in $BATS_TEST_TMPDIR/{out,err}, the exit status in $status.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/check-doc-refs.sh"

# Runs the script; extra arguments are passed through.
run_check() {
  run bash -c 'bash "$0" "$@" >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err"' "$SCRIPT" "$@"
}

setup() {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/scripts" "$TREE/docs" "$TREE/templates"
  : > "$TREE/scripts/run.sh"
  chmod +x "$TREE/scripts/run.sh"
  : > "$TREE/templates/note.md"
  : > "$TREE/docs/sibling.md"
  DOC="$TREE/docs/page.md"
}

out_has() { grep -qxF -- "$1" "$BATS_TEST_TMPDIR/out"; }

# --- header / syntax ---------------------------------------------------------------------------

@test "check-doc-refs.sh exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the header documents usage, both reference kinds, the ignore marker and the exit codes" {
  grep -q "check-doc-refs.sh <doc.md> \[--root <dir>\]" "$SCRIPT"
  grep -q "Markdown link targets" "$SCRIPT"
  grep -q "Backtick-quoted tokens" "$SCRIPT"
  grep -qF "<!-- check-doc-refs: ignore -->" "$SCRIPT"
  grep -q "^#   0 " "$SCRIPT"
  grep -q "^#   1 " "$SCRIPT"
  grep -q "^#   2 " "$SCRIPT"
}

# --- all present ---------------------------------------------------------------------------------

@test "all references present: exit 0, empty stdout, summary on stderr" {
  cat > "$DOC" <<'MD'
# Page
See [sibling](sibling.md) and [titled](sibling.md "A title") and [frag](sibling.md#part).
Run `scripts/run.sh` with `templates/note.md` and `scripts/run.sh init <id>`.
MD
  run_check "$DOC" --root "$TREE"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  grep -qxF "checked 6 references, 0 missing" "$BATS_TEST_TMPDIR/err"
}

# --- missing -------------------------------------------------------------------------------------

@test "a missing markdown link and a missing backtick path exit 1 with MISSING lines and line numbers" {
  cat > "$DOC" <<'MD'
# Page

A [broken link](gone/away.md) here.

And a `scripts/absent.sh` token, plus `templates/note.md` which exists.
MD
  run_check "$DOC" --root "$TREE"
  [ "$status" -eq 1 ]
  out_has "MISSING gone/away.md (line 3)"
  out_has "MISSING scripts/absent.sh (line 5)"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out" | tr -d ' ')" -eq 2 ]
  grep -qxF "checked 3 references, 2 missing" "$BATS_TEST_TMPDIR/err"
}

@test "a relative link resolves against the doc's directory, not the root" {
  : > "$TREE/root-only.md"
  printf '[x](root-only.md)\n' > "$DOC"
  run_check "$DOC" --root "$TREE"
  [ "$status" -eq 1 ]
  out_has "MISSING root-only.md (line 1)"
}

# --- never reported ------------------------------------------------------------------------------

@test "http, mailto and anchor-only links are never reported" {
  cat > "$DOC" <<'MD'
[a](http://example.invalid/x) [b](https://example.invalid/y) [c](mailto:someone@example.invalid) [d](#section)
MD
  run_check "$DOC" --root "$TREE"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  grep -qxF "checked 0 references, 0 missing" "$BATS_TEST_TMPDIR/err"
}

@test "glob and placeholder tokens are never reported" {
  cat > "$DOC" <<'MD'
Globs `scripts/*.sh`, `skills/j-*/SKILL.md` and `tests/{a,b}.bats`; placeholders `project/<epic>/file.md` and `scripts/<name>.sh`.
MD
  run_check "$DOC" --root "$TREE"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  grep -qxF "checked 0 references, 0 missing" "$BATS_TEST_TMPDIR/err"
}

@test "a line carrying the ignore marker is never reported, the next line still is" {
  cat > "$DOC" <<'MD'
Future file `scripts/future.sh` and [later](later.md) <!-- check-doc-refs: ignore -->
Real problem `scripts/other-missing.sh`.
MD
  run_check "$DOC" --root "$TREE"
  [ "$status" -eq 1 ]
  out_has "MISSING scripts/other-missing.sh (line 2)"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out" | tr -d ' ')" -eq 1 ]
  grep -qxF "checked 1 references, 1 missing" "$BATS_TEST_TMPDIR/err"
}

@test "backtick tokens that do not start with a repo directory are not checked" {
  printf 'Use `npm install` and `docs/missing.md` and `src/main.js`.\n' > "$DOC"
  run_check "$DOC" --root "$TREE"
  [ "$status" -eq 0 ]
  grep -qxF "checked 0 references, 0 missing" "$BATS_TEST_TMPDIR/err"
}

# --- NOT-EXECUTABLE ------------------------------------------------------------------------------

@test "an existing non-executable scripts/ token is NOT-EXECUTABLE; .md and .json paths are not" {
  : > "$TREE/scripts/plain.sh"
  chmod -x "$TREE/scripts/plain.sh"
  : > "$TREE/scripts/readme.md"
  : > "$TREE/scripts/data.json"
  chmod -x "$TREE/scripts/readme.md" "$TREE/scripts/data.json"
  cat > "$DOC" <<'MD'
`scripts/plain.sh`
`scripts/readme.md`
`scripts/data.json`
`scripts/run.sh`
MD
  run_check "$DOC" --root "$TREE"
  [ "$status" -eq 1 ]
  out_has "NOT-EXECUTABLE scripts/plain.sh (line 1)"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out" | tr -d ' ')" -eq 1 ]
  grep -qxF "checked 4 references, 0 missing" "$BATS_TEST_TMPDIR/err"
}

# --- exit 2 --------------------------------------------------------------------------------------

@test "no arguments: exit 2, stderr message, empty stdout" {
  run_check
  [ "$status" -eq 2 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  [ -s "$BATS_TEST_TMPDIR/err" ]
}

@test "an unknown option and a --root without a value exit 2 with empty stdout" {
  printf 'x\n' > "$DOC"
  run_check "$DOC" --bogus
  [ "$status" -eq 2 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  [ -s "$BATS_TEST_TMPDIR/err" ]
  run_check "$DOC" --root
  [ "$status" -eq 2 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  [ -s "$BATS_TEST_TMPDIR/err" ]
}

@test "an unreadable doc (nonexistent path) exits 2 with a stderr message and empty stdout" {
  run_check "$TREE/docs/does-not-exist.md" --root "$TREE"
  [ "$status" -eq 2 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  grep -q "cannot read doc" "$BATS_TEST_TMPDIR/err"
}

@test "a doc path that is a directory exits 2 with empty stdout" {
  run_check "$TREE/docs" --root "$TREE"
  [ "$status" -eq 2 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  [ -s "$BATS_TEST_TMPDIR/err" ]
}

@test "a --root that is not a directory exits 2 with empty stdout" {
  printf 'x\n' > "$DOC"
  run_check "$DOC" --root "$TREE/nope"
  [ "$status" -eq 2 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  [ -s "$BATS_TEST_TMPDIR/err" ]
}

@test "-h prints usage on stdout and exits 0" {
  run_check -h
  [ "$status" -eq 0 ]
  grep -q "check-doc-refs.sh <doc.md>" "$BATS_TEST_TMPDIR/out"
}
