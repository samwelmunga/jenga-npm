#!/usr/bin/env bats
#
# Coverage for skills/j-uncharted/scripts/secret-files.sh (E85_S04_T05): the one shared list of file names that
# j-uncharted treats as secret-looking, and the helpers that apply it.
#
# SAFETY / NO CREDENTIAL MATERIAL: nothing secret-looking is committed. Every fixture file is created at run time
# under $BATS_TEST_TMPDIR and holds only the literal string FIXTURE_NOT_A_SECRET. The helper matches names, so a
# name is all a test needs; the content is there so the "never prints a file's content" tests have something to
# catch. The script is invoked through `bash`, so the tests do not depend on its executable bit.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-uncharted/scripts/secret-files.sh"
CONTENT="FIXTURE_NOT_A_SECRET"

# Every name the policy must catch, grouped as the script groups them.
ENV_NAMES=".env .env.local .env.production staging.env"
AUTH_NAMES=".npmrc .yarnrc.yml .netrc _netrc .pypirc .dockercfg credentials credentials.json credentials.yml secrets.json secrets.yml secrets.yaml service-account.json service-account-prod.json .git-credentials .htpasswd .pgpass"
KEY_NAMES="id_rsa id_dsa id_ecdsa id_ed25519 server.pem tls.key bundle.p12 bundle.pfx store.jks app.keystore putty.ppk"
TEMPLATE_NAMES=".env.example .env.sample .env.template .env.dist"
PLAIN_NAMES="README.md package.json src/key.js keyboard.txt pem.md environment.ts notes.asc id_rsa.pub .envrc"

# make_tree <root>: a fixture tree with one file per name above, each holding $CONTENT.
make_tree() {
  local root="$1" n
  mkdir -p "$root/src" "$root/conf"
  for n in $ENV_NAMES $AUTH_NAMES $KEY_NAMES $TEMPLATE_NAMES $PLAIN_NAMES; do
    mkdir -p "$root/$(dirname "$n")"
    printf '%s\n' "$CONTENT" >"$root/$n"
  done
}

# in_file_patterns: the quoted entries of SECRET_FILES_PATTERNS, read straight from the script text.
in_file_patterns() {
  awk '/^SECRET_FILES_PATTERNS=\(/ {on=1; next} on && /^\)/ {exit} on' "$SCRIPT" | sed -n "s/^  '\([^']*\)'.*/\1/p"
}

in_file_templates() {
  awk '/^SECRET_FILES_TEMPLATES=\(/ {on=1; next} on && /^\)/ {exit} on' "$SCRIPT" | sed -n "s/^  '\([^']*\)'.*/\1/p"
}

# --- the list --------------------------------------------------------------------------------------------------

@test "environment files match, including the dot-env star rule and a name.env file" {
  local n
  for n in $ENV_NAMES; do
    run bash "$SCRIPT" is-secret "$n"
    [ "$status" -eq 0 ] || { echo "expected secret: $n"; return 1; }
  done
}

@test "auth and credential files match" {
  local n
  for n in $AUTH_NAMES; do
    run bash "$SCRIPT" is-secret "$n"
    [ "$status" -eq 0 ] || { echo "expected secret: $n"; return 1; }
  done
}

@test "private keys and key material match by name" {
  local n
  for n in $KEY_NAMES; do
    run bash "$SCRIPT" is-secret "$n"
    [ "$status" -eq 0 ] || { echo "expected secret: $n"; return 1; }
  done
}

@test "matching is case-insensitive" {
  local n
  for n in .ENV .Env.Local ID_RSA Id_Ed25519 SERVER.PEM Credentials.JSON .NPMRC SERVICE-ACCOUNT-X.JSON; do
    run bash "$SCRIPT" is-secret "$n"
    [ "$status" -eq 0 ] || { echo "expected secret: $n"; return 1; }
  done
}

@test "matching is on the base name only, whatever directory the file is in" {
  run bash "$SCRIPT" is-secret "deep/nested/dir/.env"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" is-secret "/abs/path/to/ID_RSA"
  [ "$status" -eq 0 ]
  # a secret-looking DIRECTORY name does not make a file inside it secret
  run bash "$SCRIPT" is-secret "certs.pem/readme.txt"
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" is-secret ".env/readme.txt"
  [ "$status" -eq 1 ]
}

@test "the four conventional template names are not secret, in any case" {
  local n
  for n in $TEMPLATE_NAMES .ENV.EXAMPLE .Env.Sample; do
    run bash "$SCRIPT" is-secret "$n"
    [ "$status" -eq 1 ] || { echo "expected NOT secret: $n"; return 1; }
  done
}

@test "a template-like name that is not an exact template is still secret" {
  run bash "$SCRIPT" is-secret ".env.example.local"
  [ "$status" -eq 0 ]
}

@test "ordinary files do not match, and neither do public keys and signatures" {
  local n
  for n in $PLAIN_NAMES; do
    run bash "$SCRIPT" is-secret "$n"
    [ "$status" -eq 1 ] || { echo "expected NOT secret: $n"; return 1; }
  done
}

@test "an empty name and a bare directory path are not secret" {
  run bash "$SCRIPT" is-secret ""
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" is-secret "src/"
  [ "$status" -eq 1 ]
}

# --- the CLI ---------------------------------------------------------------------------------------------------

@test "is-secret exits 2 on a usage error and the CLI rejects unknown commands" {
  run bash "$SCRIPT" is-secret
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" is-secret a b
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "--help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "is-secret <path>"
  assert_output_contains "patterns"
}

@test "patterns prints exactly the in-file array, one glob per line" {
  run bash "$SCRIPT" patterns
  [ "$status" -eq 0 ]
  [ "$output" = "$(in_file_patterns)" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -gt 25 ]
}

@test "templates prints exactly the in-file template array" {
  run bash "$SCRIPT" templates
  [ "$status" -eq 0 ]
  [ "$output" = "$(in_file_templates)" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 4 ]
}

@test "patterns holds only positive globs: no template name appears in it" {
  local t
  run bash "$SCRIPT" patterns
  for t in $TEMPLATE_NAMES; do
    case "
$output
" in
      *"
$t
"*) echo "template in patterns: $t"; return 1 ;;
    esac
  done
}

@test "a consumer that re-implements the rule from patterns plus templates gets identical results" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  local pats tpls n expect got
  pats="$(bash "$SCRIPT" patterns)"
  tpls="$(bash "$SCRIPT" templates)"
  for n in $ENV_NAMES $AUTH_NAMES $KEY_NAMES $TEMPLATE_NAMES $PLAIN_NAMES .ENV ID_RSA .ENV.EXAMPLE .env.example.local; do
    if bash "$SCRIPT" is-secret "$n"; then expect=1; else expect=0; fi
    got="$(PATTERNS="$pats" TEMPLATES="$tpls" NAME="$n" python3 -c '
import os, fnmatch
name = os.path.basename(os.environ["NAME"]).lower()
pats = [p for p in os.environ["PATTERNS"].split("\n") if p]
tpls = [t for t in os.environ["TEMPLATES"].split("\n") if t]
secret = name not in [t.lower() for t in tpls] and any(fnmatch.fnmatchcase(name, p.lower()) for p in pats)
print(1 if secret else 0)
')"
    [ "$got" = "$expect" ] || { echo "python and is-secret disagree on: $n (is-secret=$expect python=$got)"; return 1; }
  done
}

# --- sourcing --------------------------------------------------------------------------------------------------

@test "sourcing prints nothing, exits nothing, and works under set -eu" {
  run bash -c 'set -eu; . "$1"; echo still-here' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "still-here" ]
}

@test "sourcing does not run the CLI and leaves the caller's variables and options alone" {
  run bash -c '
    SECRET_FILES_CALLER_MARK=keep; name=caller-name; count=caller-count; pat=caller-pat
    trap_before="$(trap -p)"; opts_before="$(set +o)"
    . "$1" notice 5 a b
    [ "$name" = caller-name ] && [ "$count" = caller-count ] && [ "$pat" = caller-pat ] || { echo "variables clobbered"; exit 1; }
    [ "$SECRET_FILES_CALLER_MARK" = keep ] || { echo "marker clobbered"; exit 1; }
    [ "$trap_before" = "$(trap -p)" ] || { echo "trap changed"; exit 1; }
    [ "$opts_before" = "$(set +o)" ] || { echo "options changed"; exit 1; }
    echo clean
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

@test "secret_files_is_secret works from a sourcing script and restores nocasematch" {
  run bash -c '
    . "$1"
    secret_files_is_secret ".ENV" || { echo "missed .ENV"; exit 1; }
    secret_files_is_secret "README.md" && { echo "false positive"; exit 1; }
    shopt -q nocasematch && { echo "nocasematch leaked on"; exit 1; }
    shopt -s nocasematch
    secret_files_is_secret "README.md" || true
    shopt -q nocasematch || { echo "nocasematch lost"; exit 1; }
    echo ok
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# --- the notice ------------------------------------------------------------------------------------------------

@test "the notice prints nothing when nothing was skipped" {
  run bash "$SCRIPT" notice 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$SCRIPT" notice 0 stray-name
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$SCRIPT" notice-text 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the notice states the count and lists the names with the phrase contents never read" {
  run bash "$SCRIPT" notice-text 3 conf/.env id_rsa tls.key
  [ "$status" -eq 0 ]
  [ "$output" = "3 secret-looking file(s) skipped (names listed, contents never read): conf/.env, id_rsa, tls.key" ]
}

@test "the notice de-duplicates, sorts, and drops a leading ./" {
  run bash "$SCRIPT" notice-text 5 ./c.key b.pem c.key a.env b.pem
  [ "$status" -eq 0 ]
  [ "$output" = "5 secret-looking file(s) skipped (names listed, contents never read): a.env, b.pem, c.key" ]
}

@test "the notice lists 20 names without a more line" {
  local names=() i
  for i in $(seq -f 'k%02g.key' 1 20); do names+=("$i"); done
  run bash "$SCRIPT" notice-text 20 "${names[@]}"
  [ "$status" -eq 0 ]
  assert_output_contains "k20.key"
  assert_output_not_contains "more"
}

@test "the notice caps at 20 names and says how many more" {
  local names=() i
  for i in $(seq -f 'k%02g.key' 1 25); do names+=("$i"); done
  run bash "$SCRIPT" notice-text 25 "${names[@]}"
  [ "$status" -eq 0 ]
  assert_starts_with "$output" "25 secret-looking file(s) skipped"
  assert_output_contains "k20.key"
  assert_output_not_contains "k21.key"
  assert_output_contains ", ... and 5 more"
  assert_output_contains "contents never read"
}

@test "the notice caps on distinct names, not on arguments" {
  local names=() i
  for i in $(seq -f 'k%02g.key' 1 21); do names+=("$i" "$i"); done
  run bash "$SCRIPT" notice-text 42 "${names[@]}"
  [ "$status" -eq 0 ]
  assert_output_contains "and 1 more"
}

@test "with a count but no names the notice still says contents never read" {
  run bash "$SCRIPT" notice-text 2
  [ "$status" -eq 0 ]
  [ "$output" = "2 secret-looking file(s) skipped (names not available, contents never read)" ]
}

@test "a non-numeric count prints nothing and exits 2" {
  run bash "$SCRIPT" notice-text many a
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "notice writes to stderr and nothing to stdout; notice-text writes to stdout only" {
  run --separate-stderr bash "$SCRIPT" notice 1 id_rsa
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "1 secret-looking file(s) skipped"
  run --separate-stderr bash "$SCRIPT" notice-text 1 id_rsa
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_contains "$output" "1 secret-looking file(s) skipped"
}

@test "control characters in a name are neutralised" {
  run bash "$SCRIPT" notice-text 1 "$(printf 'bad\033[31mname.key')"
  [ "$status" -eq 0 ]
  assert_output_not_contains "$(printf '\033')"
  assert_output_contains "bad?[31mname.key"
}

# --- names only: a file is never opened ------------------------------------------------------------------------

@test "the notice never prints a file's content" {
  local root="$BATS_TEST_TMPDIR/tree" skipped=() n
  make_tree "$root"
  cd "$root"
  while IFS= read -r n; do
    if bash "$SCRIPT" is-secret "$n"; then skipped+=("${n#./}"); fi
  done < <(find . -type f | LC_ALL=C sort)
  [ "${#skipped[@]}" -gt 25 ]
  run bash "$SCRIPT" notice-text "${#skipped[@]}" "${skipped[@]}"
  [ "$status" -eq 0 ]
  assert_output_not_contains "$CONTENT"
  assert_output_contains "contents never read"
}

@test "the fixture walk skips exactly the secret-looking names and keeps templates and plain files" {
  local root="$BATS_TEST_TMPDIR/tree" kept="" skipped="" n
  make_tree "$root"
  cd "$root"
  while IFS= read -r n; do
    n="${n#./}"
    if bash "$SCRIPT" is-secret "$n"; then skipped="$skipped $n"; else kept="$kept $n"; fi
  done < <(find . -type f | LC_ALL=C sort)
  for n in $ENV_NAMES $AUTH_NAMES $KEY_NAMES; do
    case " $skipped " in *" $n "*) ;; *) echo "not skipped: $n"; return 1 ;; esac
  done
  for n in $TEMPLATE_NAMES $PLAIN_NAMES; do
    case " $kept " in *" $n "*) ;; *) echo "not kept: $n"; return 1 ;; esac
  done
}

@test "is-secret and the notice work on unreadable files and on paths that do not exist (names only)" {
  local root="$BATS_TEST_TMPDIR/locked"
  mkdir -p "$root"
  printf '%s\n' "$CONTENT" >"$root/id_rsa"
  chmod 000 "$root/id_rsa"
  run bash "$SCRIPT" is-secret "$root/id_rsa"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" is-secret "$root/does-not-exist.pem"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" notice-text 1 "id_rsa"
  [ "$status" -eq 0 ]
  chmod 600 "$root/id_rsa"
}
