#!/usr/bin/env bats
# tests/pages-cutover.bats  (E70_S03_T03)
#
# Covers scripts/pages-cutover.sh with a stub gh on PATH. The stub logs every
# invocation, so each test can prove what was and was not called. No test
# reaches the real gh, the network, or samwelmunga/jenga-npm.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/pages-cutover.sh"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  EMPTY_DIR="$BATS_TEST_TMPDIR/empty"
  LOG="$BATS_TEST_TMPDIR/gh.log"
  mkdir -p "$STUB_DIR" "$EMPTY_DIR"
  : > "$LOG"
}

# make_stub <auth-exit-code> <api-exit-code>
make_stub() {
  cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LOG"
case "\$1" in
  auth) exit $1 ;;
  api) exit $2 ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/gh"
}

@test "--dry-run prints the exact PUT command one token per line and exits 0" {
  make_stub 0 0
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  expected=$'gh\napi\n-X\nPUT\nrepos/samwelmunga/jenga-npm/pages\n-f\nbuild_type=workflow'
  [ "$output" = "$expected" ]
}

@test "--dry-run calls only the gh auth preflight and never gh api" {
  make_stub 0 0
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  run cat "$LOG"
  [ "$output" = "auth status" ]
  ! grep -q '^api' "$LOG"
}

@test "no mode flag exits 2 with usage" {
  make_stub 0 0
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: pages-cutover.sh"* ]]
  [ ! -s "$LOG" ]
}

@test "an unknown flag exits 2 and never calls gh" {
  make_stub 0 0
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --repo other/repo
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
  [ ! -s "$LOG" ]
}

@test "passing two mode flags exits 2" {
  make_stub 0 0
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --dry-run --execute
  [ "$status" -eq 2 ]
  [ ! -s "$LOG" ]
}

@test "missing gh exits 3 with the install message, in dry-run mode too" {
  run env PATH="$EMPTY_DIR" /bin/bash "$SCRIPT" --dry-run
  [ "$status" -eq 3 ]
  [[ "$output" == *"cli.github.com"* ]]
}

@test "unauthenticated gh exits 4 telling the user to run gh auth login, with no api call" {
  make_stub 1 0
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --dry-run
  [ "$status" -eq 4 ]
  [[ "$output" == *"gh auth login"* ]]
  ! grep -q '^api' "$LOG"
}

@test "--execute runs the PUT with exactly the documented arguments and prints the next steps" {
  make_stub 0 0
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --execute
  [ "$status" -eq 0 ]
  next_steps="$output"
  run cat "$LOG"
  [ "$output" = "auth status
api -X PUT repos/samwelmunga/jenga-npm/pages -f build_type=workflow" ]
  [[ "$next_steps" == *"Run /j-mirror-public"* ]]
  [[ "$next_steps" == *"workflow run pages.yml"* ]]
}

@test "--execute exits 5 when the PUT fails" {
  make_stub 0 1
  run env PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --execute
  [ "$status" -eq 5 ]
  [[ "$output" == *"Pages PUT failed"* ]]
}
