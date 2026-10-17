#!/usr/bin/env bats
# tests/pages-permalinks.bats  (E70_S03_T05)
#
# Covers scripts/verify-pages-permalinks.sh with a stub curl that returns 200 for
# every URL except one named by the test. No test touches the network or a live site.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/verify-pages-permalinks.sh"
BASE="https://example.test/jenga"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
}

# make_curl_stub <url-substring-that-returns-404-or-empty>
make_curl_stub() {
  cat > "$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
url="\${@: -1}"
if [ -n "$1" ] && [[ "\$url" == *"$1"* ]]; then
  printf '404'
else
  printf '200'
fi
STUB
  chmod +x "$STUB_DIR/curl"
}

@test "no base URL exits 2 with usage" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: verify-pages-permalinks.sh"* ]]
}

@test "every URL returning 200 exits 0 and checks the root plus each declared permalink" {
  make_curl_stub ""
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" "$BASE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"200 $BASE/"* ]]
  [[ "$output" == *"200 $BASE/skills.html"* ]]
  [[ "$output" == *"200 $BASE/jenga-config.html"* ]]
  expected_permalinks=$(grep -rh --include='*.md' '^permalink:' "$REPO_ROOT/site" | wc -l | tr -d ' ')
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq $((expected_permalinks + 1)) ]
}

@test "one non-200 URL exits 1 and names the failing URL" {
  make_curl_stub "skills.html"
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" "$BASE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"404 $BASE/skills.html"* ]]
  [[ "$output" == *"200 $BASE/"* ]]
  [[ "$output" == *"did not return 200"* ]]
}

@test "a trailing slash on the base URL does not produce a double slash" {
  make_curl_stub ""
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" "$BASE/"
  [ "$status" -eq 0 ]
  [[ "$output" == *"200 $BASE/skills.html"* ]]
  [[ "$output" != *"jenga//"* ]]
}
