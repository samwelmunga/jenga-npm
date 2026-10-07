#!/usr/bin/env bats
#
# Coverage for skills/j-connect/scripts/ensure-secret-safe.sh (E65_S01_T03).
#
# Each test builds a throwaway git repo under $BATS_TEST_TMPDIR; nothing here
# touches the real repository. A sentinel secret string is written into the
# target file in every scenario that has one, and asserted to never appear in
# stdout/stderr or in the .gitignore.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GUARD="$REPO_ROOT/skills/j-connect/scripts/ensure-secret-safe.sh"
SENTINEL="SENTINEL-SECRET-VALUE-9f3a1c77"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  git -C "$PROJ" init -q .
  git -C "$PROJ" config user.email t@example.invalid
  git -C "$PROJ" config user.name t
}

@test "already-ignored path: exit 0 and .gitignore is byte-identical" {
  printf 'node_modules/\n.env\n' > "$PROJ/.gitignore"
  cp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/before"
  run bash "$GUARD" .env "$PROJ"
  [ "$status" -eq 0 ]
  cmp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/before"
  [[ "$output" == *"already ignored"* ]] || false
}

@test "already-ignored via a pattern elsewhere is left alone" {
  printf '*.env\n' > "$PROJ/.gitignore"
  cp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/before"
  run bash "$GUARD" prod.env "$PROJ"
  [ "$status" -eq 0 ]
  cmp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/before"
}

@test "not-ignored path: added via managed block, preserved bytes outside it, exit 0" {
  printf '# my rules\nnode_modules/\ndist/\n' > "$PROJ/.gitignore"
  cp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/before"
  run bash "$GUARD" .env "$PROJ"
  [ "$status" -eq 0 ]
  git -C "$PROJ" check-ignore -q .env
  # Original content is an exact prefix of the new file.
  head -c "$(wc -c < "$BATS_TEST_TMPDIR/before")" "$PROJ/.gitignore" | cmp - "$BATS_TEST_TMPDIR/before"
  grep -qxF '# >>> jenga:connect-secrets >>>' "$PROJ/.gitignore"
  grep -qxF '/.env' "$PROJ/.gitignore"
  grep -qxF '# <<< jenga:connect-secrets <<<' "$PROJ/.gitignore"
}

@test "no .gitignore yet: one is created with the block" {
  run bash "$GUARD" .env "$PROJ"
  [ "$status" -eq 0 ]
  git -C "$PROJ" check-ignore -q .env
}

@test "file without a trailing newline: earlier bytes untouched" {
  printf 'dist/' > "$PROJ/.gitignore"
  run bash "$GUARD" .env "$PROJ"
  [ "$status" -eq 0 ]
  head -c 5 "$PROJ/.gitignore" | cmp - <(printf 'dist/')
  git -C "$PROJ" check-ignore -q .env
}

@test "idempotent re-run: second run changes nothing, one entry" {
  printf 'dist/\n' > "$PROJ/.gitignore"
  run bash "$GUARD" .env "$PROJ"
  [ "$status" -eq 0 ]
  cp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/after-first"
  run bash "$GUARD" .env "$PROJ"
  [ "$status" -eq 0 ]
  cmp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/after-first"
  [ "$(grep -cxF '/.env' "$PROJ/.gitignore")" -eq 1 ]
  [ "$(grep -cF '>>> jenga:connect-secrets >>>' "$PROJ/.gitignore")" -eq 1 ]
}

@test "second distinct path joins the existing block; other content preserved" {
  printf 'dist/\n' > "$PROJ/.gitignore"
  bash "$GUARD" .env "$PROJ"
  printf 'tail-rule\n' >> "$PROJ/.gitignore"
  run bash "$GUARD" config/.env.local "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(grep -cF '>>> jenga:connect-secrets >>>' "$PROJ/.gitignore")" -eq 1 ]
  grep -qxF '/.env' "$PROJ/.gitignore"
  grep -qxF '/config/.env.local' "$PROJ/.gitignore"
  grep -qxF 'tail-rule' "$PROJ/.gitignore"
  grep -qxF 'dist/' "$PROJ/.gitignore"
}

@test "tracked path: refused, non-zero, .gitignore not written" {
  printf '%s\n' "$SENTINEL" > "$PROJ/.env"
  git -C "$PROJ" add .env
  git -C "$PROJ" commit -q -m init
  [ ! -e "$PROJ/.gitignore" ]
  run bash "$GUARD" .env "$PROJ"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tracked"* ]] || false
  [ ! -e "$PROJ/.gitignore" ]
}

@test "sentinel secret never appears in stdout/stderr or .gitignore (all outcomes)" {
  printf '%s\n' "$SENTINEL" > "$PROJ/.env"
  printf '%s\n' "$SENTINEL" > "$PROJ/other.env"
  # not-ignored -> added
  run bash "$GUARD" .env "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$SENTINEL"* ]] || false
  # already-ignored
  run bash "$GUARD" .env "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$SENTINEL"* ]] || false
  # tracked -> refused
  git -C "$PROJ" add -f other.env
  git -C "$PROJ" commit -q -m tracked
  run bash "$GUARD" other.env "$PROJ"
  [ "$status" -eq 1 ]
  [[ "$output" != *"$SENTINEL"* ]] || false
  ! grep -qF "$SENTINEL" "$PROJ/.gitignore"
}

@test "absolute path inside the project root is accepted" {
  run bash "$GUARD" "$PROJ/.env" "$PROJ"
  [ "$status" -eq 0 ]
  git -C "$PROJ" check-ignore -q .env
}

@test "path outside the root or escaping with .. is a usage error" {
  run bash "$GUARD" /etc/passwd "$PROJ"
  [ "$status" -eq 2 ]
  run bash "$GUARD" ../escape.env "$PROJ"
  [ "$status" -eq 2 ]
  [ ! -e "$PROJ/.gitignore" ]
}

@test "glob/negation/comment characters in the path are refused" {
  run bash "$GUARD" '*.env' "$PROJ"
  [ "$status" -eq 2 ]
  run bash "$GUARD" '!keep.env' "$PROJ"
  [ "$status" -eq 2 ]
}

@test "later negation rule makes the path un-ignorable: refused and .gitignore restored" {
  # Put the managed block BEFORE the negation so the negation wins.
  printf '# >>> jenga:connect-secrets >>>\n# <<< jenga:connect-secrets <<<\n!.env\n' > "$PROJ/.gitignore"
  cp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/before"
  run bash "$GUARD" .env "$PROJ"
  [ "$status" -eq 1 ]
  cmp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/before"
}

@test "not a git repo: recorded in a writable .gitignore, exit 0" {
  PLAIN="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$PLAIN"
  run bash "$GUARD" .env "$PLAIN"
  [ "$status" -eq 0 ]
  grep -qxF '/.env' "$PLAIN/.gitignore"
  [[ "$output" == *"not a git repository"* ]] || false
}

@test "not a git repo and unwritable root: refused" {
  PLAIN="$BATS_TEST_TMPDIR/ro"
  mkdir -p "$PLAIN"
  chmod 555 "$PLAIN"
  run bash "$GUARD" .env "$PLAIN"
  chmod 755 "$PLAIN"
  if [ "$(id -u)" -eq 0 ]; then skip "running as root: directory permissions do not apply"; fi
  [ "$status" -eq 1 ]
  [ ! -e "$PLAIN/.gitignore" ]
}

@test "usage errors exit 2 and --help exits 0" {
  run bash "$GUARD"
  [ "$status" -eq 2 ]
  run bash "$GUARD" --help
  [ "$status" -eq 0 ]
  run bash "$GUARD" .env "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}
