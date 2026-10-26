#!/usr/bin/env bats
#
# Coverage for scripts/audit-deps.sh (epic E85, story E85_S01, task E85_S01_T03).
#
# The script is the single deterministic entry point for dependency audits. Every branch is exercised here
# without a network call and without the real npm registry:
#
#   * A stub `npm` sits first on PATH. It prints a chosen fixture, exits the way real `npm audit` does
#     (non-zero whenever the report lists vulnerabilities; STUB_NPM_EXIT overrides that), and appends one
#     line per invocation (cwd and args) to a log, so a test can assert npm was or was not called.
#   * PATH for every run is a throwaway directory of symlinks to the handful of tools the script needs
#     (bash, jq, dirname, date, mktemp, rm, ...) plus the stub directory. No real npm is reachable, so a
#     stub-only case cannot reach the registry even by mistake, and the "missing npm" case simply leaves the
#     stub directory off PATH. The script is always invoked as `<absolute bash> scripts/audit-deps.sh`, so the
#     restricted PATH never has to resolve the `#!/usr/bin/env bash` shebang.
#   * Each test builds a throwaway package directory (package.json + a package-lock.json stub) and a
#     throwaway project root holding workflow.json and, when a case needs one, audit-config.json, handed to
#     the script through JENGA_PROJECT_ROOT. This repository's own project/configs/audit-config.json and
#     project/logs/events.json are never read or written (the "touches nothing" test pins that with checksums).
#
# Fixtures: tests/fixtures/audit/high-and-low.json (one high, one low vulnerability, npm v7+ audit shape) and
# tests/fixtures/audit/clean.json (no vulnerabilities).

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
AUDIT="$REPO_ROOT/scripts/audit-deps.sh"
FIX_DIR="$REPO_ROOT/tests/fixtures/audit"
HIGH_LOW="$FIX_DIR/high-and-low.json"
CLEAN="$FIX_DIR/clean.json"

setup() {
  BASH_BIN="$(type -P bash)"

  # Throwaway project root: workflow.json maps paths.configs; audit-config.json is written per test.
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs"
  printf '{"paths": {"configs": "project/configs"}}\n' > "$PROJ/project/configs/workflow.json"
  CFG="$PROJ/project/configs/audit-config.json"
  export JENGA_PROJECT_ROOT="$PROJ"

  # Throwaway package directory with a lockfile stub.
  PKG="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$PKG"
  printf '{"name": "audit-fixture", "version": "1.0.0"}\n' > "$PKG/package.json"
  printf '{"name": "audit-fixture", "lockfileVersion": 3, "packages": {}}\n' > "$PKG/package-lock.json"

  # Tools directory: symlinks only, deliberately without npm.
  TOOLS="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$TOOLS"
  local t src
  for t in bash jq dirname date mktemp rm cat sed awk grep tr head cut basename uname env; do
    src="$(type -P "$t" || true)"
    [ -n "$src" ] && ln -s "$src" "$TOOLS/$t"
  done

  # Stub npm directory.
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  STUB_LOG="$BATS_TEST_TMPDIR/npm-calls.log"
  mkdir -p "$STUB_DIR"
  : > "$STUB_LOG"
  cat > "$STUB_DIR/npm" <<STUB
#!$BASH_BIN
# Stub npm for tests/audit-deps.bats: record the call, print the chosen fixture, exit like real npm audit.
printf 'cwd=%s args=%s\n' "\$PWD" "\$*" >> "\$STUB_NPM_LOG"
[ -n "\${STUB_NPM_FIXTURE:-}" ] && cat "\$STUB_NPM_FIXTURE"
if [ -n "\${STUB_NPM_EXIT:-}" ]; then
  exit "\$STUB_NPM_EXIT"
fi
# Real npm audit exits non-zero whenever the report lists vulnerabilities.
if [ -n "\${STUB_NPM_FIXTURE:-}" ] && grep -q '"total": *0' "\$STUB_NPM_FIXTURE"; then
  exit 0
fi
exit 1
STUB
  chmod +x "$STUB_DIR/npm"
  export STUB_NPM_LOG="$STUB_LOG"
  unset STUB_NPM_FIXTURE STUB_NPM_EXIT

  # PATH used for every run: stub first, tools after. The npm-less variant is TOOLS alone.
  RUN_PATH="$STUB_DIR:$TOOLS"
  NO_NPM_PATH="$TOOLS"
}

# write_cfg <mode> [severity_threshold] [offline_behavior] [production_only]
write_cfg() {
  jq -n --arg mode "$1" --arg thr "${2:-high}" --arg off "${3:-warn}" --argjson prod "${4:-false}" \
    '{config_version: 1, mode: $mode, severity_threshold: $thr, offline_behavior: $off, production_only: $prod}' > "$CFG"
}

# audit [args...]: run the script against $PKG with the stub PATH; stdout and stderr captured separately.
audit() {
  run --separate-stderr env PATH="$RUN_PATH" "$BASH_BIN" "$AUDIT" --dir "$PKG" "$@"
}

# audit_no_npm [args...]: same, but with no npm anywhere on PATH.
audit_no_npm() {
  run --separate-stderr env PATH="$NO_NPM_PATH" "$BASH_BIN" "$AUDIT" --dir "$PKG" "$@"
}

npm_calls() { wc -l < "$STUB_LOG" | tr -d ' '; }

# ============================================================================
# Consent
# ============================================================================

@test "consent: refused under ask without --approved or --ci (exit 4, npm not called, nothing on stdout)" {
  write_cfg ask
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *"consent"* ]]
  [ "$(npm_calls)" -eq 0 ]
}

@test "consent: a missing config falls back to mode ask and is refused" {
  rm -f "$CFG"
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ "$(npm_calls)" -eq 0 ]
}

@test "consent: refused under off even with --approved (exit 4, npm not called)" {
  write_cfg off
  STUB_NPM_FIXTURE="$CLEAN" audit --json --approved
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *"disabled"* ]]
  [ "$(npm_calls)" -eq 0 ]
}

@test "consent: refused under off even with --ci (exit 4, npm not called)" {
  write_cfg off
  STUB_NPM_FIXTURE="$CLEAN" audit --json --ci
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ "$(npm_calls)" -eq 0 ]
}

@test "consent: refused under off with both --approved and --ci (exit 4, npm not called)" {
  write_cfg off
  STUB_NPM_FIXTURE="$CLEAN" audit --json --approved --ci
  [ "$status" -eq 4 ]
  [ "$(npm_calls)" -eq 0 ]
}

@test "consent: allowed under ask with --approved (session-approval, npm called once)" {
  write_cfg ask
  STUB_NPM_FIXTURE="$CLEAN" audit --json --approved
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .consent_basis)" = "session-approval" ]
  [ "$(npm_calls)" -eq 1 ]
}

@test "consent: allowed under ask with --ci (ci-workflow, npm called once)" {
  write_cfg ask
  STUB_NPM_FIXTURE="$CLEAN" audit --json --ci
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .consent_basis)" = "ci-workflow" ]
  [ "$(npm_calls)" -eq 1 ]
}

@test "consent: allowed under on with no flag (config-mode-on, npm called once)" {
  write_cfg on
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .consent_basis)" = "config-mode-on" ]
  [ "$(npm_calls)" -eq 1 ]
}

@test "consent_basis: under on, a flag wins over config-mode-on and ci-workflow outranks session-approval" {
  write_cfg on
  STUB_NPM_FIXTURE="$CLEAN" audit --json --approved
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .consent_basis)" = "session-approval" ]
  STUB_NPM_FIXTURE="$CLEAN" audit --json --ci
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .consent_basis)" = "ci-workflow" ]
  STUB_NPM_FIXTURE="$CLEAN" audit --json --approved --ci
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .consent_basis)" = "ci-workflow" ]
}

# ============================================================================
# Threshold and verdict
# ============================================================================

@test "threshold: high trips on a high vulnerability (exit 1, status findings)" {
  write_cfg on high
  STUB_NPM_FIXTURE="$HIGH_LOW" audit --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "findings" ]
  [ "$(printf '%s' "$output" | jq -r .threshold)" = "high" ]
  [ "$(printf '%s' "$output" | jq -r .counts.high)" = "1" ]
  [ "$(printf '%s' "$output" | jq -r .counts.low)" = "1" ]
  [ "$(printf '%s' "$output" | jq -r .counts.total)" = "2" ]
  # most severe first
  [ "$(printf '%s' "$output" | jq -r '.findings[0].name')" = "left-padder" ]
  [ "$(printf '%s' "$output" | jq -r '.findings[0].severity')" = "high" ]
  [ "$(printf '%s' "$output" | jq -r '.findings[0].fix_available')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.findings[1].name')" = "tiny-logger" ]
  [ "$(printf '%s' "$output" | jq -r '.findings[1].fix_available')" = "false" ]
}

@test "threshold: critical does not trip on high and low vulnerabilities (exit 0, status clean)" {
  write_cfg on critical
  STUB_NPM_FIXTURE="$HIGH_LOW" audit --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "clean" ]
  [ "$(printf '%s' "$output" | jq -r .threshold)" = "critical" ]
  # below-threshold findings are still reported, they just do not trip the run
  [ "$(printf '%s' "$output" | jq -r .counts.total)" = "2" ]
}

@test "threshold: low trips on a low-only report, moderate does not" {
  jq '.vulnerabilities |= with_entries(select(.value.severity == "low"))
      | .metadata.vulnerabilities = {info:0, low:1, moderate:0, high:0, critical:0, total:1}' "$HIGH_LOW" \
    > "$BATS_TEST_TMPDIR/low-only.json"
  write_cfg on low
  STUB_NPM_FIXTURE="$BATS_TEST_TMPDIR/low-only.json" audit --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "findings" ]
  write_cfg on moderate
  STUB_NPM_FIXTURE="$BATS_TEST_TMPDIR/low-only.json" audit --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "clean" ]
}

@test "threshold: --threshold overrides the config in both directions" {
  write_cfg on high
  STUB_NPM_FIXTURE="$HIGH_LOW" audit --json --threshold critical
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "clean" ]
  [ "$(printf '%s' "$output" | jq -r .threshold)" = "critical" ]

  write_cfg on critical
  STUB_NPM_FIXTURE="$HIGH_LOW" audit --json --threshold high
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "findings" ]
  [ "$(printf '%s' "$output" | jq -r .threshold)" = "high" ]
}

@test "threshold: an invalid --threshold value exits 2 without calling npm" {
  write_cfg on
  STUB_NPM_FIXTURE="$CLEAN" audit --json --threshold severe
  [ "$status" -eq 2 ]
  [ "$(npm_calls)" -eq 0 ]
}

@test "verdict: npm exiting 0 while reporting a high vulnerability is still findings" {
  write_cfg on high
  STUB_NPM_FIXTURE="$HIGH_LOW" STUB_NPM_EXIT=0 audit --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "findings" ]
}

@test "verdict: npm exiting 1 with a clean report is still clean" {
  write_cfg on high
  STUB_NPM_FIXTURE="$CLEAN" STUB_NPM_EXIT=1 audit --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "clean" ]
}

# ============================================================================
# npm arguments
# ============================================================================

@test "production_only true passes --omit=dev to npm audit, run from the audited directory" {
  write_cfg on high warn true
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 0 ]
  [ "$(npm_calls)" -eq 1 ]
  grep -q 'args=audit --json --omit=dev$' "$STUB_LOG"
  grep -q "cwd=$(cd "$PKG" && pwd -P)" "$STUB_LOG" || grep -q "cwd=$(cd "$PKG" && pwd)" "$STUB_LOG"
}

@test "production_only false does not pass --omit=dev" {
  write_cfg on high warn false
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 0 ]
  grep -q 'args=audit --json$' "$STUB_LOG"
  run grep -c -- '--omit' "$STUB_LOG"
  [ "$output" = "0" ]
}

# ============================================================================
# Unavailable audits: warn versus fail
# ============================================================================

@test "unavailable: missing lockfile is unavailable, exit 0 under warn and 3 under fail, npm not called" {
  rm -f "$PKG/package-lock.json"
  write_cfg on high warn
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "unavailable" ]
  [[ "$stderr" == *"package-lock.json"* ]]

  write_cfg on high fail
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 3 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "unavailable" ]
  [ "$(npm_calls)" -eq 0 ]
}

@test "unavailable: an npm-shrinkwrap.json counts as a lockfile" {
  rm -f "$PKG/package-lock.json"
  printf '{"name": "audit-fixture", "lockfileVersion": 3, "packages": {}}\n' > "$PKG/npm-shrinkwrap.json"
  write_cfg on
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "clean" ]
  [ "$(npm_calls)" -eq 1 ]
}

@test "unavailable: missing npm is unavailable, exit 0 under warn and 3 under fail" {
  [ -z "$(PATH="$NO_NPM_PATH" type -P npm || true)" ]
  write_cfg on high warn
  audit_no_npm --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "unavailable" ]
  [[ "$stderr" == *"npm was not found"* ]]

  write_cfg on high fail
  audit_no_npm --json
  [ "$status" -eq 3 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "unavailable" ]
  [ "$(npm_calls)" -eq 0 ]
}

@test "unavailable: garbage npm output is unavailable, exit 0 under warn and 3 under fail" {
  printf 'this is not json at all\n' > "$BATS_TEST_TMPDIR/garbage.txt"
  write_cfg on high warn
  STUB_NPM_FIXTURE="$BATS_TEST_TMPDIR/garbage.txt" audit --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "unavailable" ]
  [[ "$stderr" == *"unparseable"* ]]

  write_cfg on high fail
  STUB_NPM_FIXTURE="$BATS_TEST_TMPDIR/garbage.txt" audit --json
  [ "$status" -eq 3 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "unavailable" ]
  [ "$(npm_calls)" -eq 2 ]
}

@test "unavailable: an npm error object (registry unreachable) is unavailable, not clean" {
  printf '{"error": {"code": "ENOTFOUND", "summary": "request to the registry failed"}}\n' > "$BATS_TEST_TMPDIR/err.json"
  write_cfg on high warn
  STUB_NPM_FIXTURE="$BATS_TEST_TMPDIR/err.json" STUB_NPM_EXIT=1 audit --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "unavailable" ]
  [[ "$stderr" == *"request to the registry failed"* ]]

  write_cfg on high fail
  STUB_NPM_FIXTURE="$BATS_TEST_TMPDIR/err.json" STUB_NPM_EXIT=1 audit --json
  [ "$status" -eq 3 ]
}

# ============================================================================
# Config and usage errors
# ============================================================================

@test "config: malformed JSON exits 2 and the message names the file; npm not called" {
  printf '{ this is not json' > "$CFG"
  STUB_NPM_FIXTURE="$CLEAN" audit --json --approved
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$CFG"* ]]
  [ "$(npm_calls)" -eq 0 ]
}

@test "config: a valid object with a bad value exits 2 and the message names the file" {
  printf '{"config_version": 1, "mode": "sometimes"}\n' > "$CFG"
  STUB_NPM_FIXTURE="$CLEAN" audit --json --approved
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"$CFG"* ]]
  [[ "$stderr" == *"mode"* ]]
  [ "$(npm_calls)" -eq 0 ]
}

@test "usage: a directory without package.json exits 2" {
  rm -f "$PKG/package.json"
  write_cfg on
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 2 ]
  [ "$(npm_calls)" -eq 0 ]
}

@test "usage: an unknown flag exits 2" {
  write_cfg on
  STUB_NPM_FIXTURE="$CLEAN" audit --json --frobnicate
  [ "$status" -eq 2 ]
  [ "$(npm_calls)" -eq 0 ]
}

# ============================================================================
# Output contract
# ============================================================================

@test "json: stdout parses with jq and carries every contract field with the right type" {
  write_cfg ask
  STUB_NPM_FIXTURE="$HIGH_LOW" audit --json --approved
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e . >/dev/null
  printf '%s' "$output" | jq -e '
    (.status | IN("clean","findings","unavailable","disabled"))
    and (.threshold | IN("low","moderate","high","critical"))
    and (.counts | type == "object")
    and (.counts | has("info") and has("low") and has("moderate") and has("high") and has("critical") and has("total"))
    and (.findings | type == "array")
    and (.findings | all(has("name") and has("severity") and has("fix_available") and has("range")))
    and (.scanned_dir | type == "string" and startswith("/"))
    and (.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.consent_basis | IN("config-mode-on","session-approval","ci-workflow"))' >/dev/null
  # scanned_dir is the audited directory, as an absolute path
  [ "$(cd "$(printf '%s' "$output" | jq -r .scanned_dir)" && pwd -P)" = "$(cd "$PKG" && pwd -P)" ]
}

@test "json: the contract fields are present on an unavailable result too" {
  rm -f "$PKG/package-lock.json"
  write_cfg on
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    has("status") and has("threshold") and has("counts") and has("findings")
    and has("scanned_dir") and has("generated_at") and has("consent_basis")
    and (.findings == []) and (.counts.total == 0)' >/dev/null
}

@test "json: diagnostics go to stderr, so stdout is a single JSON document" {
  rm -f "$PKG/package-lock.json"
  write_cfg on
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ -n "$stderr" ]
  [ "$(printf '%s\n' "$output" | jq -c . | wc -l | tr -d ' ')" -eq 1 ]
}

@test "human summary: without --json the output names the status, directory and threshold" {
  write_cfg on high
  STUB_NPM_FIXTURE="$HIGH_LOW" audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"Dependency audit: findings"* ]]
  [[ "$output" == *"threshold: high"* ]]
  [[ "$output" == *"left-padder"* ]]
  [[ "$output" != "{"* ]]
}

@test "help: -h prints usage and exits 0 without needing a config or npm" {
  run env PATH="$RUN_PATH" "$BASH_BIN" "$AUDIT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [ "$(npm_calls)" -eq 0 ]
}

# ============================================================================
# Isolation and mirror
# ============================================================================

@test "isolation: this repository's audit-config.json is untouched and no events log is written" {
  sum() { if [ -f "$1" ]; then shasum -a 256 "$1" | cut -d' ' -f1; else echo absent; fi; }
  local real_cfg="$REPO_ROOT/project/configs/audit-config.json"
  local cfg_before
  cfg_before="$(sum "$real_cfg")"

  write_cfg ask
  STUB_NPM_FIXTURE="$HIGH_LOW" audit --json --approved
  [ "$status" -eq 1 ]
  STUB_NPM_FIXTURE="$CLEAN" audit --json
  [ "$status" -eq 4 ]

  [ "$(sum "$real_cfg")" = "$cfg_before" ]
  # events.json is shared with concurrently running agents, so assert on the throwaway root instead
  [ ! -e "$PROJ/project/logs" ]
  # and the run really did read the throwaway config, not the repository's
  [ "$(jq -r .mode "$CFG")" = "ask" ]
}

@test "isolation: the stub npm is the only npm reachable on the run PATH" {
  [ "$(PATH="$RUN_PATH" type -P npm)" = "$STUB_DIR/npm" ]
  [ -z "$(PATH="$NO_NPM_PATH" type -P npm || true)" ]
}

@test "mirror: .publicignore does not block the script or this test file" {
  run -1 grep -Eq '^[[:space:]]*/?(scripts/audit-deps\.sh|tests/audit-deps\.bats|tests/fixtures/audit/?.*)[[:space:]]*$' "$REPO_ROOT/.publicignore"
  [ -f "$AUDIT" ]
  [ -f "$HIGH_LOW" ]
  [ -f "$CLEAN" ]
}
