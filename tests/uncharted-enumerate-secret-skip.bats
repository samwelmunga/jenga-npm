#!/usr/bin/env bats
#
# Coverage for the secret-looking-file skip in skills/j-uncharted/scripts/enumerate-target.sh (E85_S04_T06).
# The shared name list lives in secret-files.sh (E85_S04_T05); this suite proves the enumerator applies it:
# a secret-looking file is never opened, counted or listed, the skip is reported (JSON key + stderr notice),
# and the output for a tree WITHOUT such files is byte-identical to what the script printed before the skip.
#
# SAFETY / NO CREDENTIAL MATERIAL: nothing secret-looking is committed. Every fixture file is created at run
# time under $BATS_TEST_TMPDIR and holds only the literal string FIXTURE_NOT_A_SECRET; the secret-looking part
# is the file NAME. The byte-identical baselines under tests/fixtures/uncharted-enumerate-secret-skip/ were
# generated from the script as it was BEFORE this task, on the secret-free tree built by make_plain_tree.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-uncharted/scripts/enumerate-target.sh"
BASELINES="$REPO_ROOT/tests/fixtures/uncharted-enumerate-secret-skip"
CONTENT="FIXTURE_NOT_A_SECRET"
SECRET_NAMES=".env .npmrc credentials.json id_rsa server.pem"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  command -v git >/dev/null 2>&1 || skip "git not available"
  ROOT="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$ROOT"
  # Resolved like the script resolves it, so expected "target" strings match on macOS (/var -> /private/var).
  ROOT="$(cd "$ROOT" && pwd -P)"
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

# make_plain_tree <root> <git|nogit>: the secret-free tree the byte-identical baselines were generated from.
make_plain_tree() {
  local root="$1"
  mkdir -p "$root/src/lib" "$root/docs" "$root/ignored"
  printf '%s\n' "$CONTENT" "$CONTENT" >"$root/src/main.py"
  printf '%s\n' "$CONTENT" >"$root/src/lib/util.js"
  printf '%s\n' "$CONTENT" >"$root/docs/README.md"
  printf '%s\n' "$CONTENT" >"$root/.env.example"
  printf '%s\n' "$CONTENT" >"$root/ignored/skipme.txt"
  printf 'ignored/\n' >"$root/.gitignore"
  if [ "$2" = git ]; then git -C "$root" init -q; fi
}

# make_secret_tree <root> <git|nogit>: normal sources plus the five secret-looking names and a template.
make_secret_tree() {
  local root="$1" n
  put "$root" src/app.py src/util.py README.md .env.example
  for n in $SECRET_NAMES; do put "$root" "$n"; done
  if [ "$2" = git ]; then git -C "$root" init -q; fi
}

# jget <python-expression over d>: evaluate against the JSON in $output and print the result.
jget() {
  printf '%s' "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# listed_paths: every path the JSON could hand a downstream step as something to read, one per line.
listed_paths() {
  jget "'\n'.join([t['path'] for t in d['tree']] + [f['path'] for f in d['largest_files']])"
}

# normalised <file>: the baseline with its @TARGET@ placeholder replaced by this run's resolved root.
normalised() {
  sed "s#@TARGET@#$ROOT#g" "$1"
}

# --- the five secret-looking names -------------------------------------------------------------------------

@test "outside a git tree: only the normal sources are listed and 5 secret-looking files are reported by name" {
  make_secret_tree "$ROOT" nogit
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['listing_source']")" = "find" ]
  # README.md, src/app.py, src/util.py and the .env.example template; nothing secret-looking.
  [ "$(jget "d['total_files']")" = "4" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "5" ]
  [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = ".env .npmrc credentials.json id_rsa server.pem" ]
  paths="$(listed_paths)"
  for n in $SECRET_NAMES; do
    ! printf '%s\n' "$paths" | grep -qxF "$n"
  done
}

@test "inside a git tree: same result, with the files untracked" {
  make_secret_tree "$ROOT" git
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['listing_source']")" = "git-ls-files" ]
  [ "$(jget "d['total_files']")" = "4" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "5" ]
  [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = ".env .npmrc credentials.json id_rsa server.pem" ]
}

@test "inside a git tree: tracked secret-looking files are skipped too" {
  make_secret_tree "$ROOT" git
  git -C "$ROOT" add -f -A
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['total_files']")" = "4" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "5" ]
}

@test "the stderr notice names every skipped file and says contents were never read" {
  make_secret_tree "$ROOT" nogit
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"5 secret-looking file(s) skipped (names listed, contents never read): "* ]]
  for n in $SECRET_NAMES; do
    [[ "$stderr" == *"$n"* ]]
  done
  # stdout stays pure JSON: the notice is not mixed into it.
  [[ "$output" != *"contents never read"* ]]
  printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "nested secret-looking files are reported by their relative path" {
  put "$ROOT" src/app.py config/.npmrc keys/deploy/id_rsa
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['total_files']")" = "1" ]
  [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = "config/.npmrc keys/deploy/id_rsa" ]
  [[ "$stderr" == *"config/.npmrc"* ]]
}

@test "upper-case variants and names with spaces in the directory are still caught" {
  put "$ROOT" "my dir/.ENV" "my dir/SERVER.PEM" "my dir/ok.txt"
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['total_files']")" = "1" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "2" ]
}

# --- templates, gitignore and --no-gitignore ---------------------------------------------------------------------

@test ".env.example is not secret-looking: still enumerated, not reported" {
  put "$ROOT" .env.example .env.sample .env.template .env.dist src/a.py
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['total_files']")" = "5" ]
  [ "$(printf '%s' "$output" | grep -c secret_files_skipped)" = "0" ]
  [ -z "$stderr" ]
}

@test "git tree: a .gitignore'd secret-looking file is not listed by git so it is not reported; an unignored one is" {
  put "$ROOT" src/a.py .env server.pem
  printf 'server.pem\n' >"$ROOT/.gitignore"
  git -C "$ROOT" init -q
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['listing_source']")" = "git-ls-files" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "1" ]
  [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = ".env" ]
  # src/a.py and .gitignore are what remain.
  [ "$(jget "d['total_files']")" = "2" ]
}

@test "--no-gitignore: ignored and unignored secret-looking files are both skipped, never opened" {
  put "$ROOT" src/a.py .env server.pem
  printf 'server.pem\n' >"$ROOT/.gitignore"
  git -C "$ROOT" init -q
  run --separate-stderr bash "$SCRIPT" --no-gitignore "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['listing_source']")" = "find" ]
  [ "$(jget "d['gitignore_respected']")" = "False" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "2" ]
  [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = ".env server.pem" ]
  [ "$(jget "d['total_files']")" = "2" ]
}

@test "ignored-target fallback: secret-looking files inside an ignored directory are skipped" {
  put "$ROOT" vendor/lib.js vendor/.npmrc vendor/keys/tls.key
  printf 'vendor/\n' >"$ROOT/.gitignore"
  git -C "$ROOT" init -q
  run --separate-stderr bash "$SCRIPT" "$ROOT/vendor"
  [ "$status" -eq 0 ]
  [ "$(jget "d['ignored_target']")" = "True" ]
  [ "$(jget "d['listing_source']")" = "find" ]
  [ "$(jget "d['total_files']")" = "1" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "2" ]
  [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = ".npmrc keys/tls.key" ]
}

# --- all-secret directory and single-file targets ----------------------------------------------------------------

@test "an all-secret directory enumerates nothing but still reports the skipped count (non-git)" {
  put "$ROOT" .env id_rsa
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['total_files']")" = "0" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "2" ]
  [ "$(jget "d['ignored_target']")" = "False" ]
  [[ "$stderr" == *"2 secret-looking file(s) skipped"* ]]
}

@test "an all-secret directory enumerates nothing but still reports the skipped count (git, no ignored_target)" {
  put "$ROOT" .env id_rsa
  git -C "$ROOT" init -q
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['listing_source']")" = "git-ls-files" ]
  [ "$(jget "d['total_files']")" = "0" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "2" ]
  [ "$(jget "d['ignored_target']")" = "False" ]
}

@test "single-file target that IS secret-looking: 1 skipped, nothing enumerated" {
  put "$ROOT" .env
  run --separate-stderr bash "$SCRIPT" "$ROOT/.env"
  [ "$status" -eq 0 ]
  [ "$(jget "d['target_type']")" = "file" ]
  [ "$(jget "d['total_files']")" = "0" ]
  [ "$(jget "d['total_lines']")" = "0" ]
  [ "$(jget "d['tree']")" = "[]" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "1" ]
  [ "$(jget "d['secret_files_skipped']['paths'][0]")" = ".env" ]
  [[ "$stderr" == *"1 secret-looking file(s) skipped (names listed, contents never read): .env"* ]]
}

@test "single-file target inside a git tree: same, and a normal single file is still enumerated" {
  put "$ROOT" id_rsa app.py
  git -C "$ROOT" init -q
  run --separate-stderr bash "$SCRIPT" "$ROOT/id_rsa"
  [ "$status" -eq 0 ]
  [ "$(jget "d['total_files']")" = "0" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "1" ]
  run --separate-stderr bash "$SCRIPT" "$ROOT/app.py"
  [ "$status" -eq 0 ]
  [ "$(jget "d['total_files']")" = "1" ]
  [ -z "$stderr" ]
  [ "$(printf '%s' "$output" | grep -c secret_files_skipped)" = "0" ]
}

# --- never opened -------------------------------------------------------------------------------------------------

@test "an unreadable (chmod 000) secret-looking file does not make the script fail: it is never opened" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: chmod 000 does not make a file unreadable"
  put "$ROOT" src/a.py .env server.pem
  chmod 000 "$ROOT/.env" "$ROOT/server.pem"
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['total_files']")" = "1" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "2" ]
  # An unreadable NON-secret file is still reported under "unreadable" (existing behaviour unchanged), and
  # the secret-looking ones are not: that difference is what shows the secret-looking ones were never opened.
  [ "$(printf '%s' "$output" | grep -c '"unreadable"')" = "0" ]
  put "$ROOT" src/b.py
  chmod 000 "$ROOT/src/b.py"
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['skipped']['unreadable']['paths'][0]")" = "src/b.py" ]
}

@test "the skipped file's content never reaches stdout or stderr" {
  make_secret_tree "$ROOT" nogit
  printf 'SENTINEL_VALUE_XYZ\n' >"$ROOT/.env"
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *SENTINEL_VALUE_XYZ* ]]
  [[ "$stderr" != *SENTINEL_VALUE_XYZ* ]]
}

# --- behaviour for non-secret trees is unchanged -------------------------------------------------------------------

@test "no secret-looking files, outside git: byte-identical to the pre-change baseline, no notice" {
  make_plain_tree "$ROOT" nogit
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(normalised "$BASELINES/expected-nogit-default.json")" ]
}

@test "no secret-looking files, inside git: byte-identical to the pre-change baseline, no notice" {
  make_plain_tree "$ROOT" git
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(normalised "$BASELINES/expected-git-default.json")" ]
}

@test "no secret-looking files, flags and --no-gitignore: byte-identical to the pre-change baseline, no notice" {
  make_plain_tree "$ROOT" git
  run --separate-stderr bash "$SCRIPT" --max-depth 1 --top 3 --no-gitignore "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(normalised "$BASELINES/expected-git-nogitignore-d1.json")" ]
}

@test "adding secret-looking files changes only the additive key: the rest of the JSON equals the secret-free run" {
  make_plain_tree "$ROOT" nogit
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  before="$output"
  put "$ROOT" .env id_rsa
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  after="$output"
  python3 - "$before" "$after" <<'PY'
import json, sys
b, a = json.loads(sys.argv[1]), json.loads(sys.argv[2])
extra = a.pop("secret_files_skipped")
assert extra == {"count": 2, "paths": [".env", "id_rsa"]}, extra
assert a == b, "everything except secret_files_skipped must be unchanged"
PY
}

@test "every pre-existing top-level key that other j-uncharted scripts read is still present on a tree holding secret-looking files" {
  make_secret_tree "$ROOT" git
  run --separate-stderr bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
  for key in target target_type base_dir listing_source total_files total_lines extensions tree largest_files skipped; do
    [ "$(jget "'$key' in d")" = "True" ]
  done
}
