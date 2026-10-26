#!/usr/bin/env bats
#
# Coverage for the secret-looking-file skip in skills/j-uncharted/scripts/detect-dependencies.sh,
# detect-tests.sh and inspect-provenance.sh (E85_S04_T07). The shared name list lives in secret-files.sh
# (E85_S04_T05); this suite proves the three detectors apply it: a secret-looking file is never opened, counted
# or listed, the skip is reported (optional JSON key + one stderr notice), a chmod 000 secret file does not make
# a run fail, and the output for a tree WITHOUT such files is byte-identical to what the scripts printed before.
#
# SAFETY / NO CREDENTIAL MATERIAL: nothing secret-looking is committed. Every fixture file is created at run
# time under $BATS_TEST_TMPDIR and holds only the literal string FIXTURE_NOT_A_SECRET (or SENTINEL_VALUE_XYZ in
# the one test that proves content never reaches the output); the secret-looking part is the file NAME. The
# byte-identical baselines under tests/fixtures/uncharted-detectors-secret-skip/ were generated from the three
# scripts as they were BEFORE this task (`git show HEAD~:<path>` equivalents), on the tree built by make_plain_tree,
# with the tree's own absolute path replaced by @TARGET@.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS="$REPO_ROOT/skills/j-uncharted/scripts"
DEPS="$SCRIPTS/detect-dependencies.sh"
TESTS="$SCRIPTS/detect-tests.sh"
PROV="$SCRIPTS/inspect-provenance.sh"
BASELINES="$REPO_ROOT/tests/fixtures/uncharted-detectors-secret-skip"
CONTENT="FIXTURE_NOT_A_SECRET"
SECRET_NAMES=".env .npmrc credentials.json id_rsa server.pem"
NOTICE_PHRASE="secret-looking file(s) skipped (names listed, contents never read)"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  ROOT="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$ROOT"
  # Resolved like the scripts resolve it, so expected "target" strings match on macOS (/var -> /private/var).
  ROOT="$(cd "$ROOT" && pwd -P)"
  # The fixture tree is never a git work tree; keep git from finding an enclosing repository above it.
  export GIT_CEILING_DIRECTORIES="$(dirname "$ROOT")"
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

# make_plain_tree <root>: the secret-free tree the byte-identical baselines were generated from. Ordinary
# manifests (package.json, requirements.txt), a LICENSE, sources, a test file and the .env.example template.
make_plain_tree() {
  local root="$1"
  mkdir -p "$root/src/lib" "$root/tests" "$root/docs"
  printf '%s\n' '{"name":"fixture","version":"1.0.0","scripts":{"test":"node tests/app.test.js"},"dependencies":{"left-pad":"^1.0.0"},"devDependencies":{"jest":"^29.0.0"}}' >"$root/package.json"
  printf 'MIT License\n\nCopyright (c) 2026 Fixture Authors\n\nPermission is hereby granted, free of charge, to any person obtaining a copy\nof this software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY.\n' >"$root/LICENSE"
  printf '# SPDX-License-Identifier: MIT\n# Copyright (c) 2026 Fixture Authors\nimport os\nimport json\nfrom lib import util\n# %s\n' "$CONTENT" >"$root/src/main.py"
  printf '// %s\nconst pad = require("left-pad");\nconst u = require("./lib/util");\nmodule.exports = { pad, u };\n' "$CONTENT" >"$root/src/app.js"
  printf 'module.exports = { n: 1 };\n// %s\n' "$CONTENT" >"$root/src/lib/util.js"
  printf 'const app = require("../src/app");\n// exercises src/app.js\n// %s\n' "$CONTENT" >"$root/tests/app.test.js"
  printf '#!/usr/bin/env bash\n# %s\n. ./src/helper.sh\ngit status\n' "$CONTENT" >"$root/run.sh"
  printf '# helper %s\n' "$CONTENT" >"$root/src/helper.sh"
  printf 'requests>=2\n' >"$root/requirements.txt"
  printf '%s\n' "$CONTENT" >"$root/.env.example"
  printf '# Fixture\n%s\n' "$CONTENT" >"$root/docs/README.md"
}

# add_secrets <root>: the five secret-looking names, in the root and (one of them) nested.
add_secrets() {
  local root="$1" n
  for n in $SECRET_NAMES; do put "$root" "$n"; done
}

# jget <python-expression over d>: evaluate against the JSON in $output and print the result.
jget() {
  printf '%s' "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# normalised <file>: the baseline with its @TARGET@ placeholder replaced by this run's resolved root.
normalised() {
  sed "s#@TARGET@#$ROOT#g" "$1"
}

# without_key <json> <key>: the JSON with one top-level key removed (compact, sorted keys), for equality checks.
without_key() {
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
d.pop(sys.argv[2], None)
print(json.dumps(d, sort_keys=True))
PY
}

# lock_secrets <root>: make every secret-looking fixture unreadable. A script that opened one would fail or
# report it as unreadable; a script that only compares names does neither.
lock_secrets() {
  [ "$(id -u)" -ne 0 ] || skip "running as root: chmod 000 does not make a file unreadable"
  local n
  for n in $SECRET_NAMES; do chmod 000 "$ROOT/$n"; done
}

# --- one list, no copies -----------------------------------------------------------------------------------------

@test "none of the three scripts embeds a copy of the pattern list" {
  for f in "$DEPS" "$TESTS" "$PROV"; do
    run grep -n -E "id_ed25519|id_ecdsa|\\.netrc|\\.pypirc|\\.htpasswd|service-account|\\*\\.pem|\\*\\.key" "$f"
    [ "$status" -eq 1 ]
    grep -q "secret-files.sh" "$f"
  done
}

@test "the scripts read the list from the helper, so a helper-side change is followed (fails closed without it)" {
  # Run a copy of the script in a scratch directory with NO secret-files.sh next to it: it must refuse, not guess.
  for s in detect-dependencies detect-tests inspect-provenance; do
    mkdir -p "$BATS_TEST_TMPDIR/nohelper-$s"
    cp "$SCRIPTS/$s.sh" "$BATS_TEST_TMPDIR/nohelper-$s/$s.sh"
  done
  make_plain_tree "$ROOT"
  run --separate-stderr bash "$BATS_TEST_TMPDIR/nohelper-detect-dependencies/detect-dependencies.sh" "$ROOT"
  [ "$status" -eq 3 ]
  run --separate-stderr bash "$BATS_TEST_TMPDIR/nohelper-detect-tests/detect-tests.sh" "$ROOT"
  [ "$status" -eq 3 ]
  run --separate-stderr bash "$BATS_TEST_TMPDIR/nohelper-inspect-provenance/inspect-provenance.sh" "$ROOT"
  [ "$status" -ne 0 ]
}

# --- trees without secret-looking files: byte-identical to the pre-change output, no notice ----------------------

@test "detect-dependencies: no secret-looking files, directory target: byte-identical to the baseline, no notice" {
  make_plain_tree "$ROOT"
  run --separate-stderr bash "$DEPS" "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(normalised "$BASELINES/expected-dependencies-dir.json")" ]
}

@test "detect-dependencies: no secret-looking files, file target: byte-identical to the baseline, no notice" {
  make_plain_tree "$ROOT"
  run --separate-stderr bash "$DEPS" "$ROOT/src/app.js"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(normalised "$BASELINES/expected-dependencies-file.json")" ]
}

@test "detect-tests: no secret-looking files, directory target: byte-identical to the baseline, no notice" {
  make_plain_tree "$ROOT"
  run --separate-stderr bash "$TESTS" "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(normalised "$BASELINES/expected-tests-dir.json")" ]
}

@test "detect-tests: no secret-looking files, file target: byte-identical to the baseline, no notice" {
  make_plain_tree "$ROOT"
  run --separate-stderr bash "$TESTS" "$ROOT/src/app.js"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$(normalised "$BASELINES/expected-tests-file.json")" ]
}

@test "inspect-provenance: no secret-looking files: byte-identical to the baseline, no secret notice" {
  make_plain_tree "$ROOT"
  run --separate-stderr bash "$PROV" "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"secret-looking"* ]]
  [ "$output" = "$(normalised "$BASELINES/expected-provenance-dir.json")" ]
}

# --- detect-dependencies -------------------------------------------------------------------------------------------

@test "detect-dependencies: secret-looking files yield the normal findings only, reported by count and name" {
  make_plain_tree "$ROOT"
  add_secrets "$ROOT"
  run --separate-stderr bash "$DEPS" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "5" ]
  [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = ".env .npmrc credentials.json id_rsa server.pem" ]
  # Everything but the additive key equals the baseline: nothing from a secret-looking file was scanned.
  [ "$(without_key "$output" secret_files_skipped)" = "$(without_key "$(normalised "$BASELINES/expected-dependencies-dir.json")" secret_files_skipped)" ]
  [[ "$stderr" == *"5 $NOTICE_PHRASE: "* ]]
  for n in $SECRET_NAMES; do [[ "$stderr" == *"$n"* ]]; done
  # stdout stays pure JSON: the notice is not mixed into it.
  [[ "$output" != *"contents never read"* ]]
}

@test "detect-dependencies: unreadable (chmod 000) secret-looking files do not make the run fail" {
  make_plain_tree "$ROOT"
  add_secrets "$ROOT"
  lock_secrets
  run --separate-stderr bash "$DEPS" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "5" ]
  [ "$(jget "d['files_scanned']")" = "6" ]
}

@test "detect-dependencies: a script that sources a secret-looking file does not resolve (stat) or list the file" {
  make_plain_tree "$ROOT"
  put "$ROOT" .env
  printf '#!/usr/bin/env bash\n. ./.env\n' >"$ROOT/src/loadenv.sh"
  run --separate-stderr bash "$DEPS" "$ROOT"
  [ "$status" -eq 0 ]
  # The specifier is what the script text says; it is not resolved to the (skipped) file.
  [ "$(jget "[e['resolved'] for e in d['internal'] if e['raw'] == './.env'][0]")" = "None" ]
  [ "$(jget "d['secret_files_skipped']['paths']")" = "['.env']" ]
}

@test "detect-dependencies: .env.example and the other templates are still processed" {
  make_plain_tree "$ROOT"
  put "$ROOT" .env.sample .env.template .env.dist
  run --separate-stderr bash "$DEPS" "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jget "'secret_files_skipped' in d")" = "False" ]
  # All four templates are scanned (counted as files with an unrecognised extension); none is secret-looking.
  [ "$(jget "{'.dist', '.example', '.sample', '.template'} <= set(e['extension'] for e in d['unrecognised_extensions'])")" = "True" ]
}

@test "detect-dependencies: manifests are never treated as secret by name" {
  make_plain_tree "$ROOT"
  run --separate-stderr bash "$DEPS" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "sorted(m['name'] for m in d['manifests'])")" = "['package.json', 'requirements.txt']" ]
  [ "$(jget "[m['declared_dependencies'] for m in d['manifests'] if m['name'] == 'package.json'][0]")" = "['jest', 'left-pad']" ]
}

@test "detect-dependencies: a single-file target that is itself secret-looking is skipped and reported, not read (even unreadable)" {
  put "$ROOT" .env
  chmod 000 "$ROOT/.env" 2>/dev/null || true
  run --separate-stderr bash "$DEPS" "$ROOT/.env"
  [ "$status" -eq 0 ]
  [ "$(jget "d['target_type']")" = "file" ]
  [ "$(jget "d['files_scanned']")" = "0" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "1" ]
  [ "$(jget "d['secret_files_skipped']['paths'][0]")" = ".env" ]
  [[ "$stderr" == *"1 $NOTICE_PHRASE: .env"* ]]
}

# --- detect-tests ------------------------------------------------------------------------------------------------

@test "detect-tests: secret-looking files yield the normal findings only, reported by count and name" {
  make_plain_tree "$ROOT"
  add_secrets "$ROOT"
  run --separate-stderr bash "$TESTS" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "5" ]
  [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = ".env .npmrc credentials.json id_rsa server.pem" ]
  [ "$(without_key "$output" secret_files_skipped)" = "$(without_key "$(normalised "$BASELINES/expected-tests-dir.json")" secret_files_skipped)" ]
  [[ "$stderr" == *"5 $NOTICE_PHRASE: "* ]]
  for n in $SECRET_NAMES; do [[ "$stderr" == *"$n"* ]]; done
  [[ "$output" != *"contents never read"* ]]
}

@test "detect-tests: unreadable (chmod 000) secret-looking files do not make the run fail" {
  make_plain_tree "$ROOT"
  add_secrets "$ROOT"
  lock_secrets
  run --separate-stderr bash "$TESTS" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "5" ]
  [ "$(jget "d['coverage_status']")" = "covered" ]
}

@test "detect-tests: a secret-looking file inside a tests directory is not a test file and is not listed" {
  make_plain_tree "$ROOT"
  put "$ROOT" tests/.env tests/fixtures/id_rsa
  run --separate-stderr bash "$TESTS" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = "tests/.env tests/fixtures/id_rsa" ]
  [ "$(jget "d['target_test_files']")" = "['tests/app.test.js']" ]
  [ "$(jget "'tests/.env' in d['reference_names'] or 'tests/fixtures/id_rsa' in d['reference_names']")" = "False" ]
}

@test "detect-tests: .env.example and the other templates are still processed" {
  make_plain_tree "$ROOT"
  put "$ROOT" .env.sample .env.template .env.dist
  run --separate-stderr bash "$TESTS" "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jget "'secret_files_skipped' in d")" = "False" ]
  [ "$(jget "'.env.example' in d['reference_names'] and '.env.dist' in d['reference_names']")" = "True" ]
}

@test "detect-tests: manifests and test-runner configs are never treated as secret by name" {
  make_plain_tree "$ROOT"
  run --separate-stderr bash "$TESTS" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "[c['runner'] for c in d['test_runner_configs']]")" = "['npm test']" ]
}

@test "detect-tests: a single-file target that is itself secret-looking is skipped and reported, not read (even unreadable)" {
  put "$ROOT" .env
  chmod 000 "$ROOT/.env" 2>/dev/null || true
  run --separate-stderr bash "$TESTS" "$ROOT/.env"
  [ "$status" -eq 0 ]
  [ "$(jget "d['target_type']")" = "file" ]
  [ "$(jget "d['target_files_considered']")" = "0" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "1" ]
  [ "$(jget "d['secret_files_skipped']['paths'][0]")" = ".env" ]
  [ "$(jget "d['reference_names']")" = "[]" ]
  [[ "$stderr" == *"1 $NOTICE_PHRASE: .env"* ]]
}

# --- inspect-provenance --------------------------------------------------------------------------------------------

@test "inspect-provenance: secret-looking files yield the normal findings only, reported by count and name" {
  make_plain_tree "$ROOT"
  add_secrets "$ROOT"
  run --separate-stderr bash "$PROV" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "5" ]
  [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = ".env .npmrc credentials.json id_rsa server.pem" ]
  [ "$(without_key "$output" secret_files_skipped)" = "$(without_key "$(normalised "$BASELINES/expected-provenance-dir.json")" secret_files_skipped)" ]
  [[ "$stderr" == *"5 $NOTICE_PHRASE: "* ]]
  for n in $SECRET_NAMES; do [[ "$stderr" == *"$n"* ]]; done
  [[ "$output" != *"contents never read"* ]]
}

@test "inspect-provenance: unreadable (chmod 000) secret-looking files do not make the run fail" {
  make_plain_tree "$ROOT"
  add_secrets "$ROOT"
  lock_secrets
  run --separate-stderr bash "$PROV" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "5" ]
  [ "$(jget "d['files_scanned']")" = "11" ]
}

@test "inspect-provenance: .env.example is still scanned; the secret-looking .env next to it is not" {
  put "$ROOT" .env.example LICENSE
  run --separate-stderr bash "$PROV" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['files_scanned']")" = "2" ]
  put "$ROOT" .env
  run --separate-stderr bash "$PROV" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['files_scanned']")" = "2" ]
  [ "$(jget "d['secret_files_skipped']['paths']")" = "['.env']" ]
}

@test "inspect-provenance: a LICENSE is never treated as secret by name" {
  put "$ROOT" LICENSE LICENSE.md NOTICE COPYING
  run --separate-stderr bash "$PROV" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "len(d['license']['files'])")" = "4" ]
  [ "$(jget "'secret_files_skipped' in d")" = "False" ]
}

@test "inspect-provenance: --json-out carries the same additive key" {
  make_plain_tree "$ROOT"
  put "$ROOT" .npmrc
  run --separate-stderr bash "$PROV" --json-out "$BATS_TEST_TMPDIR/report.json" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/report.json")" = "$output" ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "1" ]
}

@test "inspect-provenance: a single secret-looking file as the target is not read; it is reported and the exit code is unchanged (2)" {
  put "$ROOT" .env
  printf 'SENTINEL_VALUE_XYZ\n' >"$ROOT/.env"
  chmod 000 "$ROOT/.env" 2>/dev/null || true
  run --separate-stderr bash "$PROV" "$ROOT/.env"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"1 $NOTICE_PHRASE: .env"* ]]
  [[ "$stderr" == *"not a directory"* ]]
  [[ "$output" != *SENTINEL_VALUE_XYZ* ]]
  [[ "$stderr" != *SENTINEL_VALUE_XYZ* ]]
  # A normal single file keeps failing exactly as before, with no secret notice.
  put "$ROOT" notes.txt
  run --separate-stderr bash "$PROV" "$ROOT/notes.txt"
  [ "$status" -eq 2 ]
  [[ "$stderr" != *"secret-looking"* ]]
}

# --- all three: content never leaks, names are matched case-insensitively -----------------------------------------

@test "the content of a skipped file never reaches stdout or stderr of any detector" {
  make_plain_tree "$ROOT"
  add_secrets "$ROOT"
  printf 'SENTINEL_VALUE_XYZ\n' >"$ROOT/.env"
  printf 'SENTINEL_VALUE_XYZ\n' >"$ROOT/server.pem"
  for s in "$DEPS" "$TESTS" "$PROV"; do
    run --separate-stderr bash "$s" "$ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" != *SENTINEL_VALUE_XYZ* ]]
    [[ "$stderr" != *SENTINEL_VALUE_XYZ* ]]
  done
}

@test "upper-case variants and nested secret-looking files are skipped and reported by relative path" {
  make_plain_tree "$ROOT"
  put "$ROOT" "deploy/.ENV" "deploy/keys/SERVER.PEM"
  for s in "$DEPS" "$TESTS" "$PROV"; do
    run --separate-stderr bash "$s" "$ROOT"
    [ "$status" -eq 0 ]
    [ "$(jget "' '.join(d['secret_files_skipped']['paths'])")" = "deploy/.ENV deploy/keys/SERVER.PEM" ]
    [[ "$stderr" == *"2 $NOTICE_PHRASE: "* ]]
    # exactly one notice per run
    [ "$(printf '%s\n' "$stderr" | grep -c 'secret-looking file(s) skipped')" = "1" ]
  done
}

@test "the notice caps long name lists the way the helper does (count stays exact)" {
  make_plain_tree "$ROOT"
  local i
  for i in $(seq 1 25); do put "$ROOT" "keys/k$i.pem"; done
  run --separate-stderr bash "$DEPS" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jget "d['secret_files_skipped']['count']")" = "25" ]
  [[ "$stderr" == *"25 $NOTICE_PHRASE: "*"... and 5 more"* ]]
}
