#!/usr/bin/env bats
#
# Coverage for skills/j-connect/scripts/validate-descriptor.sh (E65_S01_T02).
# One test per fixture under tests/fixtures/connect/descriptors/.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/skills/j-connect/scripts/validate-descriptor.sh"
FX="$REPO_ROOT/tests/fixtures/connect/descriptors"

@test "valid descriptor passes" {
  run bash "$VALIDATE" "$FX/valid.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "descriptor with register_mcp explicitly marked absent passes" {
  run bash "$VALIDATE" "$FX/valid-no-mcp.json"
  [ "$status" -eq 0 ]
}

@test "missing detect is rejected and named" {
  run bash "$VALIDATE" "$FX/invalid-missing-detect.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"detect: missing"* ]] || false
}

@test "missing install is rejected and named" {
  run bash "$VALIDATE" "$FX/invalid-missing-install.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"install: missing"* ]] || false
}

@test "missing auth is rejected and named" {
  run bash "$VALIDATE" "$FX/invalid-missing-auth.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"auth: missing"* ]] || false
}

@test "missing verify is rejected and named" {
  run bash "$VALIDATE" "$FX/invalid-missing-verify.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"verify: missing"* ]] || false
}

@test "missing docs is rejected and named" {
  run bash "$VALIDATE" "$FX/invalid-missing-docs.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs: missing"* ]] || false
}

@test "register_mcp neither present nor explicitly absent is rejected" {
  run bash "$VALIDATE" "$FX/invalid-missing-register-mcp.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"register_mcp: missing"* ]] || false
  [[ "$output" == *'"supported": false'* ]] || false
}

@test "secret-named key holding a value is rejected without echoing the value" {
  run bash "$VALIDATE" "$FX/invalid-secret-value-key.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"auth.token"* ]] || false
  [[ "$output" != *"not-an-env-var-name-just-a-literal-value"* ]] || false
}

@test "credential-shaped string value is rejected without echoing the value" {
  # Built at run time (prefix split) so no credential-shaped literal is committed
  # as a fixture file where a repo secret scanner could flag it.
  local fake="gh""p_0123456789abcdefghijklmnopqrstuvwxyz0123"
  jq --arg v "run it with key $fake" '.install.hint=$v' "$FX/valid.json" > "$BATS_TEST_TMPDIR/pattern.json"
  run bash "$VALIDATE" "$BATS_TEST_TMPDIR/pattern.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"install.hint"* ]] || false
  [[ "$output" == *"literal secret"* ]] || false
  [[ "$output" != *"ghp_0123456789"* ]] || false
}

@test "literal value in place of an env-var name is rejected" {
  run bash "$VALIDATE" "$FX/invalid-secret-env-name.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"env-var NAME"* ]] || false
  [[ "$output" != *"abc-literal-value-123"* ]] || false
}

@test "authoritative hardcoded install command with no docs URL is rejected" {
  run bash "$VALIDATE" "$FX/invalid-install-hardcoded-command.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"install.command"* ]] || false
  [[ "$output" == *"install.docs_url"* ]] || false
}

@test "version-pinned install package is rejected" {
  run bash "$VALIDATE" "$FX/invalid-install-pinned-package.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unpinned"* ]] || false
}

@test "stored-string verification is rejected" {
  run bash "$VALIDATE" "$FX/invalid-verify-stored-string.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"verify.expect_output"* ]] || false
}

@test "usage errors and non-JSON exit 2" {
  run bash "$VALIDATE"
  [ "$status" -eq 2 ]
  run bash "$VALIDATE" "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
  echo 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  run bash "$VALIDATE" "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
}
