#!/usr/bin/env bats
#
# Coverage for the secret-looking-file skip in skills/j-uncharted/scripts/import-source.sh, path mode (E85_S04_T08).
# The shared name list lives in secret-files.sh (E85_S04_T05); this suite proves the importer applies it to a local
# directory copy: a secret-looking file is never copied, never opened and never present in staging, the skip is
# reported (stderr notice + additive JSON key), a single secret-looking file is refused, and for a source WITHOUT such
# files the staged tree is exactly what the old blanket `cp -R src/. dest/` produced.
#
# SAFETY / NO CREDENTIAL MATERIAL: nothing secret-looking is committed. Every fixture file is created at run time
# under $BATS_TEST_TMPDIR (outside the repo, as the importer requires) and holds only the literal string
# FIXTURE_NOT_A_SECRET; the secret-looking part is the file NAME.
#
# "Old behaviour" is computed in the test: `cp -R "$src/." "$expected/"` followed by the same `chmod a-x` the script
# applies to every staged file, so no baseline files are stored.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-uncharted/scripts/import-source.sh"
CONTENT="FIXTURE_NOT_A_SECRET"
SECRET_NAMES=".env .npmrc credentials.json id_rsa deploy/server.pem"

setup() {
  SRC="$BATS_TEST_TMPDIR/src"
  STAGE="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$SRC"
  # The importer canonicalises paths; resolve ours the same way so string comparisons hold on macOS (/var -> /private/var).
  SRC="$(cd "$SRC" && pwd -P)"
}

teardown() {
  # chmod 000 fixtures must be removable by bats' own cleanup.
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# put <root> <relative-name>...: create each file holding $CONTENT (parent directories included).
put() {
  local root="$1" n
  shift
  for n in "$@"; do
    mkdir -p "$root/$(dirname "$n")"
    printf '%s\n' "$CONTENT" >"$root/$n"
  done
}

# make_tree <root> <with-secrets 0|1>: the same normal content either way (so the secret-free twin is the expected
# result of importing the other), plus, when asked, the five secret-looking names, a symlink and a directory with
# secret-looking names.
make_tree() {
  local root="$1" with="$2" n
  mkdir -p "$root/nested/deep/er" "$root/empty-dir" "$root/with space" "$root/d750" "$root/dir.pem"
  put "$root" .gitignore .env.example README.md src/app.py src/util.py nested/deep/er/x.txt \
    "with space/odd'name \"q\" \$x [1].txt" d750/z.txt dir.pem/ok.txt m640.txt run.sh
  chmod 750 "$root/d750"
  chmod 640 "$root/m640.txt"
  chmod 755 "$root/run.sh"
  ln -s m640.txt "$root/link-to-file"
  ln -s does-not-exist "$root/dangling"
  ln -s nested "$root/link-to-dir"
  if [ "$with" = 1 ]; then
    for n in $SECRET_NAMES; do put "$root" "$n"; done
  fi
}

# expected_tree <src> <dest>: what the importer produced before this task, minus nothing: cp -R plus the script's chmod a-x.
expected_tree() {
  mkdir -p "$2"
  cp -R "$1/." "$2/"
  find "$2" -type f -exec chmod a-x {} +
}

# modes_of <root>: sorted "mode type name" lines for everything under <root> (GNU and BSD stat).
modes_of() {
  (
    cd "$1"
    if stat --version >/dev/null 2>&1; then
      find . -exec stat -c '%a %F %n' {} + | sort
    else
      find . -exec stat -f '%Lp %HT %N' {} + | sort
    fi
  )
}

# links_of <root>: sorted "link -> target" lines for every symlink under <root>.
links_of() {
  (
    cd "$1"
    find . -type l | LC_ALL=C sort | while IFS= read -r l; do printf '%s -> %s\n' "$l" "$(readlink "$l")"; done
  )
}

# same_tree <expected-root> <actual-root>: content, modes, file types and symlink targets are all identical.
same_tree() {
  # diff -r complains about a dangling symlink present on both sides; that is not a difference.
  [ -z "$(diff -r "$1" "$2" 2>&1 | grep -v 'No such file or directory')" ]
  [ "$(modes_of "$1")" = "$(modes_of "$2")" ]
  [ "$(links_of "$1")" = "$(links_of "$2")" ]
}

# nojq_bin: a PATH directory holding every tool the importer uses except jq (to exercise the printf fallback).
nojq_bin() {
  local bin="$BATS_TEST_TMPDIR/nojq-bin" t p
  mkdir -p "$bin"
  for t in bash env basename dirname git sed awk tr sort wc ls find cp mkdir mktemp rm cat stat chmod readlink head uniq ln rmdir true; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$p" ] && [ -x "$p" ] && ln -sf "$p" "$bin/$t"
  done
  printf '%s' "$bin"
}

# --- the five secret-looking names ----------------------------------------------------------------------------------

@test "directory with .env, .npmrc, credentials.json, id_rsa and nested deploy/server.pem: only normal files are staged, structure and dotfiles intact" {
  make_tree "$SRC" 1
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  C="$STAGE/source"
  for n in $SECRET_NAMES; do
    [ ! -e "$C/$n" ]
    [ ! -L "$C/$n" ]
  done
  [ -f "$C/.gitignore" ]
  [ -f "$C/.env.example" ]
  [ -f "$C/src/app.py" ]
  [ -f "$C/nested/deep/er/x.txt" ]
  # deploy/ held only a secret-looking file: the directory is still created, empty, as cp -R would for a dir tree.
  [ -d "$C/deploy" ]
  [ -z "$(ls -A "$C/deploy")" ]
  [ -d "$C/empty-dir" ]
}

@test "the notice reports 5 skipped with every name and the phrase \"contents never read\"; stdout stays JSON" {
  make_tree "$SRC" 1
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"5 secret-looking file(s) skipped (names listed, contents never read): "* ]]
  for n in $SECRET_NAMES; do
    [[ "$stderr" == *"$n"* ]]
  done
  [[ "$output" != *"contents never read"* ]]
  printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "JSON summary carries secret_files_skipped {count, paths} (jq path) and file_count counts staged files only" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  make_tree "$SRC" 1
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.secret_files_skipped.count')" = "5" ]
  [ "$(printf '%s' "$output" | jq -r '.secret_files_skipped.paths | join(" ")')" = ".env .npmrc credentials.json deploy/server.pem id_rsa" ]
  staged="$(find "$STAGE/source" -type f | wc -l | tr -d ' ')"
  [ "$(printf '%s' "$output" | jq -r '.file_count')" = "$staged" ]
}

@test "JSON summary carries secret_files_skipped and stays valid JSON without jq (printf fallback)" {
  make_tree "$SRC" 1
  bin="$(nojq_bin)"
  [ ! -e "$bin/jq" ]
  run --separate-stderr env PATH="$bin" bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["secret_files_skipped"]["count"] == 5, d
assert d["secret_files_skipped"]["paths"] == [".env", ".npmrc", "credentials.json", "deploy/server.pem", "id_rsa"], d
assert d["git_ref"] is None
'
}

@test ".env.example and the other conventional templates are copied, not skipped" {
  put "$SRC" .env.example .env.sample .env.template .env.dist src/a.py
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  for n in .env.example .env.sample .env.template .env.dist src/a.py; do [ -f "$STAGE/source/$n" ]; done
  [ -z "$stderr" ]
  [ "$(printf '%s' "$output" | grep -c secret_files_skipped)" = "0" ]
}

@test "upper-case variants and names with spaces in the directory are still caught; a directory called server.pem is traversed" {
  put "$SRC" "my dir/.ENV" "my dir/SERVER.PEM" "my dir/ok.txt" server.pem/inside.txt
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  [ ! -e "$STAGE/source/my dir/.ENV" ]
  [ ! -e "$STAGE/source/my dir/SERVER.PEM" ]
  [ -f "$STAGE/source/my dir/ok.txt" ]
  [ -f "$STAGE/source/server.pem/inside.txt" ]
  [[ "$stderr" == *"2 secret-looking file(s) skipped"* ]]
}

@test "a symlink with a secret-looking name is skipped by name; other symlinks stay links (dangling and to directories too)" {
  put "$SRC" real.txt nested/a.txt
  ln -s real.txt "$SRC/credentials"
  ln -s nested "$SRC/linkdir"
  ln -s nowhere "$SRC/dangling"
  ln -s nested "$SRC/keys.pem"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  C="$STAGE/source"
  [ ! -e "$C/credentials" ] && [ ! -L "$C/credentials" ]
  [ ! -L "$C/keys.pem" ] && [ ! -e "$C/keys.pem" ]
  [ -L "$C/linkdir" ] && [ "$(readlink "$C/linkdir")" = "nested" ]
  [ -L "$C/dangling" ] && [ "$(readlink "$C/dangling")" = "nowhere" ]
  [[ "$stderr" == *"2 secret-looking file(s) skipped"* ]]
}

# --- never copied, never opened, never in staging --------------------------------------------------------------------

@test "a cp shim sees no secret-looking path, so nothing secret is ever copied (not even to be removed later)" {
  make_tree "$SRC" 1
  shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  real_cp="$(command -v cp)"
  printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$*\" >> \"$BATS_TEST_TMPDIR/cp.log\"" "exec \"$real_cp\" \"\$@\"" >"$shim/cp"
  chmod +x "$shim/cp"
  run --separate-stderr env PATH="$shim:$PATH" bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/cp.log" ]
  if grep -E '(^|[ /])(\.env|\.npmrc|credentials\.json|id_rsa|server\.pem)( |$)' "$BATS_TEST_TMPDIR/cp.log"; then false; fi
  grep -q 'app.py' "$BATS_TEST_TMPDIR/cp.log"
}

@test "an unreadable (chmod 000) secret-looking file does not break the import: it is never opened" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: chmod 000 does not make a file unreadable"
  put "$SRC" src/a.py .env deploy/server.pem
  chmod 000 "$SRC/.env" "$SRC/deploy/server.pem"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  [ -f "$STAGE/source/src/a.py" ]
  [ ! -e "$STAGE/source/.env" ]
  [[ "$stderr" == *"2 secret-looking file(s) skipped"* ]]
}

@test "the secret's content never reaches stdout, stderr or staging" {
  make_tree "$SRC" 1
  printf 'SENTINEL_VALUE_XYZ\n' >"$SRC/.env"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" "$SRC"
  [ "$status" -eq 0 ]
  [[ "$output" != *SENTINEL_VALUE_XYZ* ]]
  [[ "$stderr" != *SENTINEL_VALUE_XYZ* ]]
  if grep -rq SENTINEL_VALUE_XYZ "$STAGE"; then false; fi
}

@test "the script has no copy-then-delete step for the filtered copy: no rm, mv, rmdir or unlink between its markers" {
  region="$(sed -n '/^  # --- begin filtered copy/,/^  # --- end filtered copy/p' "$SCRIPT")"
  [ -n "$region" ]
  [[ "$region" == *'cp -R -P'* ]]
  if printf '%s\n' "$region" | grep -E '(^|[^[:alnum:]_])(rm|mv|rmdir|unlink|shred)([^[:alnum:]_]|$)'; then false; fi
  # Nor does any rm in the path-mode block take a path built from a secret match.
  block="$(sed -n '/^  path)$/,/^  snippet)$/p' "$SCRIPT")"
  [ -n "$block" ]
  if printf '%s\n' "$block" | grep -E 'rm .*(\$rel|\$p|SECRET_)'; then false; fi
}

# --- single-file source ----------------------------------------------------------------------------------------------

@test "a single-file path source that is itself secret-looking is refused: exit 4, clear message, nothing copied, no staging left" {
  put "$SRC" .env
  tmp="$BATS_TEST_TMPDIR/tmpdir"
  mkdir -p "$tmp"
  run --separate-stderr env TMPDIR="$tmp" bash "$SCRIPT" --json-only "$SRC/.env"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"refusing '$SRC/.env'"* ]]
  [[ "$stderr" == *"looks like a secret"* ]]
  [[ "$stderr" == *"contents never read"* ]]
  [ -z "$output" ]
  [ -z "$(ls -A "$tmp")" ]
}

@test "single-file refusal with an explicit --staging-dir creates no staging directory" {
  put "$SRC" deploy/server.pem
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" "$SRC/deploy/server.pem"
  [ "$status" -eq 4 ]
  [ ! -e "$STAGE" ]
}

@test "a symlink to a normal file called like a secret, and a secret-named file behind a normal link, are both refused" {
  put "$SRC" notes.txt .npmrc
  ln -s notes.txt "$SRC/id_rsa"
  ln -s .npmrc "$SRC/innocent.txt"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" "$SRC/id_rsa"
  [ "$status" -eq 4 ]
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" "$SRC/innocent.txt"
  [ "$status" -eq 4 ]
  [ ! -e "$STAGE" ]
}

@test "a normal single file and a .env.example single file are still imported" {
  put "$SRC" app.py .env.example
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC/app.py"
  [ "$status" -eq 0 ]
  [ -f "$STAGE/source/app.py" ]
  [ -z "$stderr" ]
  rm -rf "$STAGE"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC/.env.example"
  [ "$status" -eq 0 ]
  [ -f "$STAGE/source/.env.example" ]
}

# --- a directory holding only secret-looking files ---------------------------------------------------------------------

@test "a directory whose only contents are secret-looking files: the notice is printed, then the existing no-content exit 4" {
  put "$SRC" .env id_rsa
  tmp="$BATS_TEST_TMPDIR/tmpdir"
  mkdir -p "$tmp"
  run --separate-stderr env TMPDIR="$tmp" bash "$SCRIPT" --json-only "$SRC"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"2 secret-looking file(s) skipped (names listed, contents never read): .env, id_rsa"* ]]
  [[ "$stderr" == *"acquisition produced no content for source"* ]]
  [ -z "$(ls -A "$tmp")" ]
}

# --- behaviour for a source WITHOUT secret-looking files is unchanged --------------------------------------------------

@test "no secret-looking files: staged tree equals the old cp -R result (content, modes, symlink targets), no notice" {
  make_tree "$SRC" 0
  expected_tree "$SRC" "$BATS_TEST_TMPDIR/expected"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  same_tree "$BATS_TEST_TMPDIR/expected" "$STAGE/source"
}

@test "no secret-looking files: the JSON summary has no secret_files_skipped key and the same keys in the same order as before" {
  make_tree "$SRC" 0
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  keys="$(printf '%s' "$output" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).keys()))')"
  [ "$keys" = "source_type source staging_path content_path file_count total_size_bytes total_size_human symlink_count git_ref" ]
}

@test "no secret-looking files, no jq: the printf fallback JSON is the old shape exactly" {
  make_tree "$SRC" 0
  bin="$(nojq_bin)"
  run --separate-stderr env PATH="$bin" bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  [[ "$output" == '{"source_type":"path","source":"'* ]]
  [[ "$output" == *',"symlink_count":3,"git_ref":null}' ]]
}

@test "secret-looking files present: the staged tree equals the old cp -R result of the same tree without them, plus the empty deploy/ dir" {
  make_tree "$SRC" 1
  make_tree "$BATS_TEST_TMPDIR/twin" 0
  mkdir "$BATS_TEST_TMPDIR/twin/deploy"
  expected_tree "$BATS_TEST_TMPDIR/twin" "$BATS_TEST_TMPDIR/expected"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  same_tree "$BATS_TEST_TMPDIR/expected" "$STAGE/source"
}

@test "a source with its own .git directory still has it stripped, with and without secret-looking names" {
  put "$SRC" a.txt
  mkdir -p "$SRC/.git"
  printf 'x\n' >"$SRC/.git/HEAD"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  [ ! -e "$STAGE/source/.git" ]
  put "$SRC" .env
  run --separate-stderr bash "$SCRIPT" --staging-dir "$BATS_TEST_TMPDIR/stage2" --json-only "$SRC"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/stage2/source/.git" ]
}

@test "the importer behaves the same under the system /bin/bash (3.2 on macOS)" {
  [ -x /bin/bash ] || skip "/bin/bash not present"
  make_tree "$SRC" 1
  run --separate-stderr /bin/bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 0 ]
  [ ! -e "$STAGE/source/.env" ]
  [[ "$stderr" == *"5 secret-looking file(s) skipped"* ]]
}

# --- failure behaviour ---------------------------------------------------------------------------------------------------

@test "copy failure still exits 4 with the existing message (source with no secret-looking files)" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: chmod 000 does not make a directory unreadable"
  put "$SRC" ok.txt locked/inner.txt
  chmod 000 "$SRC/locked"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"failed to copy source directory: $SRC"* ]]
  [ ! -e "$STAGE" ] || [ ! -e "$STAGE/source/ok.txt" ]
}

@test "copy failure still exits 4 with the existing message (source that also holds secret-looking files)" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: chmod 000 does not make a directory unreadable"
  put "$SRC" ok.txt .env locked/inner.txt
  chmod 000 "$SRC/locked"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"failed to copy source directory: $SRC"* ]]
}

@test "an unreadable NON-secret file still fails the copy with exit 4 (only secret-looking names are exempt from being opened)" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: chmod 000 does not make a file unreadable"
  put "$SRC" ok.txt .env hidden.txt
  chmod 000 "$SRC/hidden.txt"
  run --separate-stderr bash "$SCRIPT" --staging-dir "$STAGE" --json-only "$SRC"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"failed to copy source directory: $SRC"* ]]
}

# --- other modes untouched -------------------------------------------------------------------------------------------------

@test "snippet mode is untouched: a secret-looking snippet name is still written as before and no secret key appears" {
  run --separate-stderr bash -c 'printf "%s\n" FIXTURE_NOT_A_SECRET | bash "$0" --staging-dir "$1" --json-only --type snippet --name notes.txt -' "$SCRIPT" "$STAGE"
  [ "$status" -eq 0 ]
  [ -f "$STAGE/source/notes.txt" ]
  [ "$(printf '%s' "$output" | grep -c secret_files_skipped)" = "0" ]
  [ -z "$stderr" ]
}
