#!/usr/bin/env bats
#
# E80_S04_T02: scripts/workflow/resolve-compute-command.sh confines a compute step's `command` to the
# allow-listed script roots. It prints the absolute real path of the script, never runs it, creates no file.
#
# Every case builds its own throwaway tree under $BATS_TEST_TMPDIR and anchors it with JENGA_PROJECT_ROOT, so
# nothing here reads this repository's board or any private path.
#
# Mirror safety: this file ships to the public mirror and runs there in a mirror-shaped tree. It depends only on
# scripts/workflow/resolve-compute-command.sh, scripts/resolve-root.sh and fixtures it builds. The "project/..."
# strings below are registry-layout directory names written into scratch trees only, never reads of this repo.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/workflow/resolve-compute-command.sh"

# The script is bash 3.2 compatible; run it under the system bash (3.2 on macOS) when there is one.
BASH_BIN="bash"
if [ -x /bin/bash ]; then BASH_BIN="/bin/bash"; fi

setup() {
  unset JENGA_PROJECT_ROOT JENGA_WORKFLOWS_TEST_ROOT
  ROOT="$BATS_TEST_TMPDIR/root"
  MARKER="$BATS_TEST_TMPDIR/marker"
  make_tree "$ROOT" project
  # Physical path of the fixture ($BATS_TEST_TMPDIR may sit behind a symlink, as /var does on macOS).
  RROOT="$(cd -P "$ROOT" && pwd -P)"
}

# Builds fixture tree $1/$2 with a registry whose paths map is $3 (default empty).
make_tree() {
  local paths="${3:-}"
  [ -n "$paths" ] || paths='{}'
  mkdir -p "$1/$2/configs"
  printf '{"paths":%s}\n' "$paths" > "$1/$2/configs/workflow.json"
}

# Writes an executable script at $ROOT/$1 that would write $MARKER if it were ever run.
make_script() {
  mkdir -p "$(dirname "$ROOT/$1")"
  printf '#!/bin/sh\necho ran > "%s"\n' "$MARKER" > "$ROOT/$1"
  chmod +x "$ROOT/$1"
}

# Runs the resolver with stdout in $output and stderr in $stderr, anchored at $ROOT.
resolve() {
  run --separate-stderr env JENGA_PROJECT_ROOT="$ROOT" "$BASH_BIN" "$SCRIPT" "$@"
}

# Asserts a rejection: exit 1, nothing on stdout, one stderr line matching $1.
assert_rejected() {
  [ "$status" -eq 1 ] || { echo "status=$status stdout=[$output] stderr=[$stderr]"; return 1; }
  [ -z "$output" ] || { echo "stdout not empty: [$output]"; return 1; }
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ] || { echo "stderr not one line: [$stderr]"; return 1; }
  case "$stderr" in
    *"$1"*) ;;
    *) echo "stderr [$stderr] does not contain [$1]"; return 1 ;;
  esac
}

# ---- the script itself --------------------------------------------------------------------------------------

@test "script exists, is executable and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  bash -n "$SCRIPT"
}

@test "script header documents usage, the allow-listed roots and the exit codes" {
  run grep -c -E '^# (USAGE|ALLOW-LISTED ROOTS|EXIT CODES)' "$SCRIPT"
  [ "$output" -eq 3 ]
  run grep -E '^#   (scripts/|skills/<name>/scripts/|<workflows>/scripts/|node_modules/@jenga-ai/agent/scripts/)' "$SCRIPT"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -ge 4 ]
  run grep -E '^#   [0-3]  ' "$SCRIPT"
  [ "$(printf '%s\n' "$output" | grep -c 'resolved\|rejected\|usage error\|cannot be resolved')" -ge 4 ]
}

@test "-h and --help print usage on stdout and exit 0" {
  run --separate-stderr "$BASH_BIN" "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == Usage:* ]]
  [ -z "$stderr" ]
  run --separate-stderr "$BASH_BIN" "$SCRIPT" -h
  [ "$status" -eq 0 ]
}

@test "no argument is a usage error (exit 2) with nothing on stdout" {
  run --separate-stderr env JENGA_PROJECT_ROOT="$ROOT" "$BASH_BIN" "$SCRIPT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == Usage:* ]]
}

# ---- accepted: one case per allow-listed root ---------------------------------------------------------------

@test "resolves a script under scripts/" {
  make_script scripts/a.sh
  resolve scripts/a.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/scripts/a.sh" ]
  [ -z "$stderr" ]
}

@test "resolves a script nested below scripts/" {
  make_script scripts/sub/deeper/a.sh
  resolve scripts/sub/deeper/a.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/scripts/sub/deeper/a.sh" ]
}

@test "resolves a script under skills/<name>/scripts/" {
  make_script skills/demo/scripts/b.sh
  resolve skills/demo/scripts/b.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/skills/demo/scripts/b.sh" ]
}

@test "resolves a script under the workflows scripts directory (default key)" {
  make_script project/.workflows/scripts/c.sh
  resolve project/.workflows/scripts/c.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/project/.workflows/scripts/c.sh" ]
}

@test "resolves a script under node_modules/@jenga-ai/agent/scripts/" {
  make_script node_modules/@jenga-ai/agent/scripts/d.sh
  resolve node_modules/@jenga-ai/agent/scripts/d.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/node_modules/@jenga-ai/agent/scripts/d.sh" ]
}

@test "resolves a script under node_modules/@jenga-ai/agent/skills/<name>/scripts/" {
  make_script node_modules/@jenga-ai/agent/skills/demo/scripts/e.sh
  resolve node_modules/@jenga-ai/agent/skills/demo/scripts/e.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/node_modules/@jenga-ai/agent/skills/demo/scripts/e.sh" ]
}

@test "a leading ./ is accepted" {
  make_script scripts/a.sh
  resolve ./scripts/a.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/scripts/a.sh" ]
}

@test "the workflows root follows the registry's workflows key, not a literal" {
  rm -rf "$ROOT"
  make_tree "$ROOT" project '{"workflows":"custom/wf"}'
  make_script custom/wf/scripts/f.sh
  make_script project/.workflows/scripts/g.sh
  resolve custom/wf/scripts/f.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/custom/wf/scripts/f.sh" ]
  # The default location is no longer a root once the key points elsewhere.
  resolve project/.workflows/scripts/g.sh
  assert_rejected "outside the allow-listed script roots"
}

@test "a relocated .project tree resolves its own workflows scripts directory" {
  rm -rf "$ROOT"
  make_tree "$ROOT" .project
  make_script .project/.workflows/scripts/h.sh
  resolve .project/.workflows/scripts/h.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/.project/.workflows/scripts/h.sh" ]
}

@test "the anchor is found by the upward search when JENGA_PROJECT_ROOT is unset" {
  make_script scripts/a.sh
  mkdir -p "$ROOT/some/sub"
  cd "$ROOT/some/sub"
  run --separate-stderr "$BASH_BIN" "$SCRIPT" scripts/a.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/scripts/a.sh" ]
}

@test "a symlink to another script inside the roots is accepted and resolves to its real path" {
  make_script scripts/real.sh
  ln -s real.sh "$ROOT/scripts/alias.sh"
  resolve scripts/alias.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/scripts/real.sh" ]
}

@test "a symlinked package directory is a valid root (its real path is judged, not its link)" {
  mkdir -p "$BATS_TEST_TMPDIR/pkgsrc/scripts" "$ROOT/node_modules/@jenga-ai"
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/pkgsrc/scripts/p.sh"
  chmod +x "$BATS_TEST_TMPDIR/pkgsrc/scripts/p.sh"
  ln -s "$BATS_TEST_TMPDIR/pkgsrc" "$ROOT/node_modules/@jenga-ai/agent"
  resolve node_modules/@jenga-ai/agent/scripts/p.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd -P "$BATS_TEST_TMPDIR/pkgsrc" && pwd -P)/scripts/p.sh" ]
}

# ---- rejection 1: not a single path token -------------------------------------------------------------------

@test "rejects an inline shell string and never runs any part of it" {
  make_script scripts/ok.sh
  resolve "echo hi; rm -rf x"
  assert_rejected "single path token"
  resolve "scripts/ok.sh; touch $BATS_TEST_TMPDIR/injected"
  assert_rejected "single path token"
  [ ! -e "$BATS_TEST_TMPDIR/injected" ]
  [ ! -e "$MARKER" ]
}

@test "rejects arguments, whitespace, metacharacters, globs and a newline (each in its own run)" {
  make_script scripts/ok.sh
  local bad
  for bad in "scripts/ok.sh --flag" "scripts/ok.sh arg" " scripts/ok.sh" "scripts/ok.sh " \
             "scripts/ok.sh;ls" "scripts/ok.sh|cat" "scripts/ok.sh&" 'scripts/$HOME' 'scripts/`id`' \
             "scripts/ok.sh<in" "scripts/ok.sh>out" "scripts/(ok).sh" "scripts/ok.sh)" \
             "scripts/*.sh" "scripts/o?.sh" "scripts/[o]k.sh" "scripts/{ok,no}.sh" "scripts/'ok'.sh" \
             'scripts/"ok".sh' 'scripts/ok\.sh' "~/scripts/ok.sh" "scripts/ok.sh#x" "scripts/ok.sh!" \
             $'scripts/ok.sh\nls' $'scripts/ok.sh\tx' $'scripts/ok.sh\r'; do
    resolve "$bad"
    assert_rejected "single path token" || { echo "case: [$bad]"; return 1; }
  done
}

@test "rejects more than one argument as not a single path token" {
  make_script scripts/ok.sh
  resolve scripts/ok.sh extra
  assert_rejected "single path token"
}

# ---- rejection 2: absolute path or '..' ---------------------------------------------------------------------

@test "rejects an absolute path, including one that points at a real allow-listed script" {
  make_script scripts/ok.sh
  resolve /bin/sh
  assert_rejected "absolute paths and '..' segments"
  resolve "$RROOT/scripts/ok.sh"
  assert_rejected "absolute paths and '..' segments"
}

@test "rejects a .. segment anywhere in the path" {
  make_script scripts/ok.sh
  local bad
  for bad in ../x scripts/../../x scripts/../scripts/ok.sh .. scripts/.. scripts/sub/../ok.sh; do
    resolve "$bad"
    assert_rejected "absolute paths and '..' segments" || { echo "case: [$bad]"; return 1; }
  done
}

# ---- rejection 3: real path outside the roots ---------------------------------------------------------------

@test "rejects a symlink inside scripts/ that points at /bin/sh" {
  mkdir -p "$ROOT/scripts"
  ln -s /bin/sh "$ROOT/scripts/sh"
  resolve scripts/sh
  assert_rejected "outside the allow-listed script roots"
}

@test "rejects a symlink inside scripts/ that points at an executable outside every root" {
  make_script elsewhere/evil.sh
  mkdir -p "$ROOT/scripts"
  ln -s "$ROOT/elsewhere/evil.sh" "$ROOT/scripts/evil.sh"
  resolve scripts/evil.sh
  assert_rejected "outside the allow-listed script roots"
}

@test "rejects a relative symlink escape" {
  make_script elsewhere/evil.sh
  mkdir -p "$ROOT/scripts"
  ln -s ../elsewhere/evil.sh "$ROOT/scripts/rel.sh"
  resolve scripts/rel.sh
  assert_rejected "outside the allow-listed script roots"
}

@test "rejects a script reached through a symlinked directory that leaves the root" {
  make_script elsewhere/evil.sh
  mkdir -p "$ROOT/scripts"
  ln -s "$ROOT/elsewhere" "$ROOT/scripts/linkdir"
  resolve scripts/linkdir/evil.sh
  assert_rejected "outside the allow-listed script roots"
}

@test "rejects an executable that exists but is not under a root" {
  make_script elsewhere/x.sh
  make_script skills/demo/other/y.sh
  make_script skills/z.sh
  make_script skills/scripts/w.sh
  make_script project/data/v.sh
  local bad
  for bad in elsewhere/x.sh skills/demo/other/y.sh skills/z.sh skills/scripts/w.sh project/data/v.sh \
             project/configs/workflow.json; do
    resolve "$bad"
    assert_rejected "outside the allow-listed script roots" || { echo "case: [$bad]"; return 1; }
  done
}

@test "rejects the root directories themselves" {
  mkdir -p "$ROOT/scripts" "$ROOT/skills/demo/scripts"
  resolve scripts
  assert_rejected "outside the allow-listed script roots"
  resolve skills/demo/scripts
  assert_rejected "outside the allow-listed script roots"
}

# ---- rejection 4: missing or not a regular file -------------------------------------------------------------

@test "rejects a path that does not exist" {
  mkdir -p "$ROOT/scripts"
  resolve scripts/missing.sh
  assert_rejected "does not exist or is not a regular file"
  resolve nothing/at/all.sh
  assert_rejected "does not exist or is not a regular file"
}

@test "rejects a directory inside a root" {
  mkdir -p "$ROOT/scripts/adir"
  resolve scripts/adir
  assert_rejected "does not exist or is not a regular file"
}

@test "rejects a dangling symlink and a symlink loop" {
  mkdir -p "$ROOT/scripts"
  ln -s "$ROOT/scripts/nowhere" "$ROOT/scripts/dangling.sh"
  ln -s loop-b "$ROOT/scripts/loop-a"
  ln -s loop-a "$ROOT/scripts/loop-b"
  resolve scripts/dangling.sh
  assert_rejected "does not exist or is not a regular file"
  resolve scripts/loop-a
  assert_rejected "does not exist or is not a regular file"
}

# ---- rejection 5: not executable ----------------------------------------------------------------------------

@test "rejects a regular file inside a root that is not executable" {
  make_script scripts/plain.sh
  chmod 644 "$ROOT/scripts/plain.sh"
  resolve scripts/plain.sh
  assert_rejected "not executable"
}

@test "rejects a symlink inside a root whose in-root target is not executable" {
  make_script scripts/plain.sh
  chmod 644 "$ROOT/scripts/plain.sh"
  ln -s plain.sh "$ROOT/scripts/alias.sh"
  resolve scripts/alias.sh
  assert_rejected "not executable"
}

# ---- rejection 6: empty -------------------------------------------------------------------------------------

@test "rejects an empty string" {
  resolve ""
  assert_rejected "empty"
}

# ---- cross-cutting ------------------------------------------------------------------------------------------

@test "the six rejections each print a distinct one-line message" {
  make_script scripts/ok.sh
  make_script elsewhere/x.sh
  mkdir -p "$ROOT/scripts"
  ln -s ../elsewhere/x.sh "$ROOT/scripts/out.sh"
  printf '#!/bin/sh\n' > "$ROOT/scripts/plain.sh"
  local msgs="" arg
  for arg in "echo hi; rm" "/bin/sh" "scripts/out.sh" "scripts/missing.sh" "scripts/plain.sh" ""; do
    resolve "$arg"
    [ "$status" -eq 1 ] || { echo "case [$arg]: status=$status"; return 1; }
    [ -z "$output" ] || { echo "case [$arg]: stdout [$output]"; return 1; }
    msgs="$msgs$stderr"$'\n'
  done
  [ "$(printf '%s' "$msgs" | grep -c .)" -eq 6 ]
  [ "$(printf '%s' "$msgs" | grep . | sort -u | wc -l | tr -d ' ')" -eq 6 ]
}

@test "a successful resolve never executes the file (a marker script leaves no marker)" {
  make_script scripts/a.sh
  make_script skills/demo/scripts/b.sh
  make_script project/.workflows/scripts/c.sh
  make_script node_modules/@jenga-ai/agent/scripts/d.sh
  local p
  for p in scripts/a.sh skills/demo/scripts/b.sh project/.workflows/scripts/c.sh \
           node_modules/@jenga-ai/agent/scripts/d.sh; do
    resolve "$p"
    [ "$status" -eq 0 ]
  done
  [ ! -e "$MARKER" ]
  # Sanity: the fixture really does write the marker when it is run, so the absence above proves something.
  "$ROOT/scripts/a.sh"
  [ -e "$MARKER" ]
}

@test "a rejection never executes the file either" {
  make_script scripts/a.sh
  chmod 644 "$ROOT/scripts/a.sh"
  resolve scripts/a.sh
  assert_rejected "not executable"
  [ ! -e "$MARKER" ]
}

@test "creates no file or directory, on success or on rejection" {
  make_script scripts/a.sh
  find "$ROOT" | sort > "$BATS_TEST_TMPDIR/before"
  resolve scripts/a.sh
  [ "$status" -eq 0 ]
  resolve scripts/missing.sh
  [ "$status" -eq 1 ]
  resolve "a b"
  [ "$status" -eq 1 ]
  find "$ROOT" | sort > "$BATS_TEST_TMPDIR/after"
  cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

@test "runs with an almost empty environment under set -u" {
  make_script scripts/a.sh
  run --separate-stderr env -i PATH="$PATH" JENGA_PROJECT_ROOT="$ROOT" "$BASH_BIN" -u "$SCRIPT" scripts/a.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$RROOT/scripts/a.sh" ]
  [ -z "$stderr" ]
}

@test "an unresolvable anchor exits 3 with the resolver's message and nothing on stdout" {
  mkdir -p "$BATS_TEST_TMPDIR/noregistry"
  run --separate-stderr env JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/noregistry" "$BASH_BIN" "$SCRIPT" scripts/a.sh
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"has no registry"* ]]
}

@test "lexical rejections do not need a resolvable anchor" {
  mkdir -p "$BATS_TEST_TMPDIR/noregistry"
  run --separate-stderr env JENGA_PROJECT_ROOT="$BATS_TEST_TMPDIR/noregistry" "$BASH_BIN" "$SCRIPT" "a b"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
