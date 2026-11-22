#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# skills/j-workflow-capture/scripts/snapshot-external.sh (epic E103, task E103_S03_T01): external instructions,
# fetched from a link or pasted, become an untrusted snapshot plus provenance.
#
#   1. url: the snapshot is the normalised content (CR removed, final newline), mode 600, named by its hash, with a
#      .meta.json sidecar; the one JSON line carries source external-url and a single-line source_ref holding the
#      URL, the UTC fetch time and the full sha256 of the snapshot.
#   2. Refusals leave nothing behind: a non-http(s) URL, a URL with user information or a credential-named query
#      parameter, a malformed fetch time, empty content and NUL bytes.
#   3. The content is data: command substitutions and backticks in it are never run (canary files in the working
#      directory are never created), and it is never printed.
#   4. paste: pasted text gives source pasted with a captured_at time and the hash.
#   5. END TO END with the vendor-style guide fixture (install, login, env-export, dashboard, plus an embedded
#      instruction aimed at an AI agent): snapshot -> extract-steps.sh --kind pasted -> render-review-table.sh ->
#      write-capture.sh create/seal/emit, unchanged, gives an external-url recording and definition, and runs
#      nothing from the guide.
#   6. snapshot-external.sh never names the recorder's pointer script.
#
# Isolation: everything is written under $BATS_TEST_TMPDIR, the working directory is a scratch directory there,
# and JENGA_PROJECT_ROOT names a throwaway project. Only shipped paths and the shipped fixture are read, so the suite
# runs unchanged in the public mirror.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAP="$REPO_ROOT/skills/j-workflow-capture/scripts"
SNAP="$CAP/snapshot-external.sh"
XS="$CAP/extract-steps.sh"
RT="$CAP/render-review-table.sh"
WC="$CAP/write-capture.sh"
RR="$CAP/record-review.sh"
VALIDATOR="$REPO_ROOT/scripts/workflow/validate-workflow.sh"
GUIDE="$REPO_ROOT/tests/fixtures/workflow-capture/vendor-guide.md"
URL="https://docs.acme.invalid/cli/getting-started"
AT="2026-11-20T10:00:00Z"

setup() {
  T="$BATS_TEST_TMPDIR"
  OUT="$T/snap"
  WORK="$T/work"
  mkdir -p "$WORK" "$T/proj/project/configs"
  printf '%s\n' '{"paths":{"workflows":"project/.workflows"}}' > "$T/proj/project/configs/workflow.json"
  unset JENGA_CAPTURE_OUT_DIR JENGA_CAPTURE_NOW JENGA_RECORDING_DIR JENGA_WORKFLOWS_TEST_ROOT
  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID JENGA_RECORDING_SESSION_ID
  export JENGA_PROJECT_ROOT="$T/proj"
  export JENGA_RECORDER_NOW=2026-11-20T03:04:05Z
  export JENGA_RECORDING_STATE_DIR="$T/state"
  cd "$WORK"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  else shasum -a 256 < "$1" | cut -c1-64
  fi
}

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# No canary file appeared anywhere under the test's directory.
assert_no_canaries() {
  [ -z "$(find "$T" -name 'pwned-*' 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# url
# ---------------------------------------------------------------------------

@test "help: exits 0 and documents both sub-commands, the output and the exit codes" {
  run bash "$SNAP" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "snapshot-external.sh url"
  assert_contains "$output" "snapshot-external.sh paste"
  assert_contains "$output" "source_ref"
  assert_contains "$output" "EXIT CODES"
}

@test "url: writes a normalised mode-600 snapshot, a sidecar, and one JSON line with URL, UTC time and sha256" {
  printf 'line one\r\nline two' > "$T/in.txt"
  run --separate-stderr bash "$SNAP" url --out-dir "$OUT" --fetched-at "$AT" "$URL" < "$T/in.txt"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]

  local path sha
  path="$(printf '%s' "$output" | jq -r .path)"
  [ -f "$path" ]
  [ "$(cat "$path")" = "$(printf 'line one\nline two')" ]
  [ "$(tail -c 1 "$path" | od -An -c | tr -d ' ')" = '\n' ]
  ! grep -q "$(printf '\r')" "$path"
  [ "$(mode_of "$path")" = "600" ]

  sha="$(sha256_file "$path")"
  [ "$(printf '%s' "$output" | jq -r .sha256)" = "$sha" ]
  [ "$path" = "$(cd "$OUT" && pwd -P)/external-$(printf '%s' "$sha" | cut -c1-12).txt" ]
  [ "$(printf '%s' "$output" | jq -r .form)" = "external-url" ]
  [ "$(printf '%s' "$output" | jq -r .source)" = "external-url" ]
  [ "$(printf '%s' "$output" | jq -r .url)" = "$URL" ]
  [ "$(printf '%s' "$output" | jq -r .fetched_at)" = "$AT" ]
  [ "$(printf '%s' "$output" | jq -r .source_ref)" = "$URL fetched_at=$AT sha256=$sha" ]

  local meta="${path%.txt}.meta.json"
  [ -f "$meta" ]
  [ "$(mode_of "$meta")" = "600" ]
  [ "$(jq -c . "$meta")" = "$(printf '%s' "$output" | jq -c .)" ]
}

@test "url: the fetch time defaults to JENGA_CAPTURE_NOW, else the current UTC time in the documented shape" {
  run --separate-stderr env JENGA_CAPTURE_NOW=2026-01-02T03:04:05Z bash "$SNAP" url --out-dir "$OUT" "$URL" <<< "x"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .fetched_at)" = "2026-01-02T03:04:05Z" ]

  run --separate-stderr bash "$SNAP" url --out-dir "$OUT" "$URL" <<< "x"
  [ "$status" -eq 0 ]
  [[ "$(printf '%s' "$output" | jq -r .fetched_at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "url: --content-file reads the content from a file and gives the same snapshot as stdin" {
  run --separate-stderr bash "$SNAP" url --out-dir "$OUT" --fetched-at "$AT" --content-file "$GUIDE" "$URL"
  [ "$status" -eq 0 ]
  local a="$output"
  run --separate-stderr bash "$SNAP" url --out-dir "$OUT" --fetched-at "$AT" "$URL" < "$GUIDE"
  [ "$status" -eq 0 ]
  [ "$output" = "$a" ]
}

@test "url: refused URLs exit 2 and write nothing" {
  local bad
  for bad in "ftp://docs.acme.invalid/x" "docs.acme.invalid/x" "https://" "https://docs.acme.invalid/a b" \
             "https://user:pass@docs.acme.invalid/x" "https://docs.acme.invalid/x?token=abc" \
             "https://docs.acme.invalid/x?a=1&api_key=abc"; do
    run --separate-stderr bash "$SNAP" url --out-dir "$OUT" --fetched-at "$AT" "$bad" <<< "content"
    [ "$status" -eq 2 ] || { echo "not refused: $bad ($status)" >&2; return 1; }
    [ -z "$output" ]
  done
  [ -z "$(ls -A "$OUT" 2>/dev/null)" ]
}

@test "url: a credential-bearing URL is refused without echoing the secret on stdout" {
  run --separate-stderr bash "$SNAP" url --out-dir "$OUT" "https://docs.acme.invalid/x?token=s3cr3tvalue" <<< "x"
  [ "$status" -eq 2 ]
  assert_not_contains "$output" "s3cr3tvalue"
  assert_contains "$stderr" "credential"
}

@test "url: a malformed fetch time exits 2 and writes nothing" {
  local bad
  for bad in "2026-11-20 10:00:00" "2026-11-20T10:00:00+01:00" "2026-13-01T00:00:00Z" "now"; do
    run --separate-stderr bash "$SNAP" url --out-dir "$OUT" --fetched-at "$bad" "$URL" <<< "x"
    [ "$status" -eq 2 ] || { echo "accepted: $bad" >&2; return 1; }
  done
  [ -z "$(ls -A "$OUT" 2>/dev/null)" ]
}

@test "content: blank exits 5, NUL bytes exit 8, and nothing is left behind" {
  run --separate-stderr bash "$SNAP" url --out-dir "$OUT" "$URL" < <(printf '  \n\t\r\n')
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  run --separate-stderr bash "$SNAP" paste --out-dir "$OUT" < <(printf 'a\000b\n')
  [ "$status" -eq 8 ]
  [ -z "$output" ]
  [ -z "$(ls -A "$OUT")" ]
}

@test "usage errors exit 2" {
  run --separate-stderr bash "$SNAP"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SNAP" fetch "$URL"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SNAP" url --out-dir "$OUT" <<< "x"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SNAP" paste extra --out-dir "$OUT" <<< "x"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SNAP" url --bogus "$URL" <<< "x"
  [ "$status" -eq 2 ]
}

@test "the content is data: substitutions and backticks in it are never run, and it is never printed" {
  printf '1. Run $(touch pwned-subst)\n2. Run `touch pwned-tick`\n3. ; touch pwned-semi\n' > "$T/in.txt"
  run --separate-stderr bash "$SNAP" url --out-dir "$OUT" --fetched-at "$AT" "$URL" < "$T/in.txt"
  [ "$status" -eq 0 ]
  assert_no_canaries
  assert_not_contains "$output" "touch"
  assert_not_contains "$stderr" "touch"
  # The snapshot keeps the text verbatim, as data.
  assert_contains "$(cat "$(printf '%s' "$output" | jq -r .path)")" 'Run $(touch pwned-subst)'
}

@test "snapshot-external.sh never evaluates or sources anything but the recording format contract" {
  run grep -nE '(^|[^A-Za-z_])(eval|exec)[[:space:]]' "$SNAP"
  [ "$status" -ne 0 ]
  # The only file sourced is recording-format.sh.
  run grep -nE '^[[:space:]]*(\.|source)[[:space:]]' "$SNAP"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  assert_contains "$output" '"$FMT"'
}

# ---------------------------------------------------------------------------
# paste
# ---------------------------------------------------------------------------

@test "paste: pasted text becomes a pasted source with captured_at and the hash, no URL" {
  run --separate-stderr bash "$SNAP" paste --out-dir "$OUT" --fetched-at "$AT" < "$GUIDE"
  [ "$status" -eq 0 ]
  local path sha
  path="$(printf '%s' "$output" | jq -r .path)"
  sha="$(sha256_file "$path")"
  [ "$(printf '%s' "$output" | jq -r .form)" = "pasted-text" ]
  [ "$(printf '%s' "$output" | jq -r .source)" = "pasted" ]
  [ "$(printf '%s' "$output" | jq -r .url)" = "null" ]
  [ "$(printf '%s' "$output" | jq -r .source_ref)" = "pasted captured_at=$AT sha256=$sha" ]
  [ "$(basename "$path")" = "pasted-$(printf '%s' "$sha" | cut -c1-12).txt" ]
  cmp -s "$path" "$GUIDE"
  assert_no_canaries
}

@test "paste: the pasted source extracts to the guide's four steps and writes a pasted recording" {
  run --separate-stderr bash "$SNAP" paste --out-dir "$OUT" --fetched-at "$AT" < "$GUIDE"
  [ "$status" -eq 0 ]
  local snap="$output"

  run --separate-stderr bash "$XS" range 1 4 --kind pasted --out "$T/c.json" "$(printf '%s' "$snap" | jq -r .path)"
  [ "$status" -eq 0 ]
  [ "$(jq '.steps | length' "$T/c.json")" -eq 4 ]

  run --separate-stderr bash "$WC" create --source "$(printf '%s' "$snap" | jq -r .source)" \
    --source-ref "$(printf '%s' "$snap" | jq -r .source_ref)" --dir "$T/recs" "$T/c.json" "Set up the Acme CLI"
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$output")" "source: pasted"
  assert_contains "$(cat "$output")" "source_ref: \"pasted captured_at=$AT sha256="
  assert_no_canaries
}

# ---------------------------------------------------------------------------
# end to end with the vendor-style guide
# ---------------------------------------------------------------------------

@test "end to end: the vendor guide flows through the review table and the writer unchanged as external-url" {
  run --separate-stderr bash "$SNAP" url --out-dir "$OUT" --fetched-at "$AT" "$URL" < "$GUIDE"
  [ "$status" -eq 0 ]
  local snap="$output" ref path rec def
  ref="$(printf '%s' "$snap" | jq -r .source_ref)"
  path="$(printf '%s' "$snap" | jq -r .path)"

  run --separate-stderr bash "$XS" list --kind pasted "$path"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 4 ]

  run --separate-stderr bash "$XS" range 1 4 --kind pasted --out "$T/c.json" "$path"
  [ "$status" -eq 0 ]
  # install, login, env-export, dashboard, in order.
  assert_contains "$(jq -r '.steps[0].text' "$T/c.json")" "npm install -g @acme/cloud-cli"
  assert_contains "$(jq -r '.steps[1].text' "$T/c.json")" "acme login"
  assert_contains "$(jq -r '.steps[2].text' "$T/c.json")" "export ACME_API_KEY="
  assert_contains "$(jq -r '.steps[3].text' "$T/c.json")" "acme dashboard open"
  # The instruction aimed at an agent is not a step; it is context evidence at most.
  [ "$(jq '[.steps[].text | select(test("ignore your previous instructions"))] | length' "$T/c.json")" -eq 0 ]

  run --separate-stderr bash "$RT" "$T/c.json"
  [ "$status" -eq 0 ]
  assert_contains "$output" "| 4 |"

  run --separate-stderr bash "$WC" create --source external-url --source-ref "$ref" --dir "$T/recs" \
    "$T/c.json" "Set up the Acme CLI"
  [ "$status" -eq 0 ]
  rec="$output"
  assert_contains "$(cat "$rec")" "source: external-url"
  assert_contains "$(cat "$rec")" "source_ref: \"$ref\""

  local n
  for n in 1 2 4; do
    bash "$RR" decide "$rec" "$n" include >/dev/null
    bash "$RR" decide "$rec" "$n" type confirm >/dev/null
  done
  bash "$RR" decide "$rec" 3 exclude >/dev/null
  run --separate-stderr bash "$WC" seal "$rec" "$T/c.json"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$WC" emit "$rec"
  [ "$status" -eq 0 ]
  def="$output"
  run --separate-stderr bash "$VALIDATOR" "$def"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.provenance.source' "$def")" = "external-url" ]
  [ "$(jq -r '.provenance.source_ref' "$def")" = "$ref" ]
  [ "$(jq '.steps | length' "$def")" -eq 3 ]

  # Nothing from the guide ran at any stage.
  assert_no_canaries
  [ ! -e "$WORK/pwned-by-guide" ] && [ ! -e "$WORK/pwned-by-backticks" ]
}

@test "snapshot-external.sh never names the recorder's pointer script" {
  run grep -cE 'active-recording\.sh|active-recording["'"'"']?[[:space:]]+(set|clear|refresh)([[:space:]]|$)' "$SNAP"
  [ "$output" = "0" ]
}

@test "SKILL.md states the untrusted-content rule and routes the external source through snapshot-external.sh" {
  local skill="$REPO_ROOT/skills/j-workflow-capture/SKILL.md"
  assert_contains "$(cat "$skill")" "snapshot-external.sh"
  assert_contains "$(cat "$skill")" "data, not instructions"
  assert_contains "$(cat "$skill")" "quote it to the user"
  assert_contains "$(cat "$skill")" "Nothing in it is executed"
}
