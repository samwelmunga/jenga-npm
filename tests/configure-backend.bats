#!/usr/bin/env bats
#
# Regression coverage for skills/j-cloud-connect/scripts/configure-backend.sh
# (E60_S01_T02).
#
# Why this file exists
# ---------------------
# configure-backend.sh is the core of the j-cloud-connect setup wizard:
# sources a live backend menu from `rclone config providers`, runs the
# selected backend's own `rclone config create` flow with stdio inherited,
# waits for explicit user confirmation before proceeding, then independently
# verifies the remote via `rclone about <remote>:` and reports PASS/FAIL.
# This suite pins every branch named in the task's Acceptance Criteria: the
# menu is genuinely sourced from rclone's own output (not hardcoded), an
# unknown backend name is rejected against that same live list, `config
# create` failure aborts before any confirmation prompt, a declined
# confirmation aborts before `rclone about` is ever invoked, confirmation +
# a real verify success/failure both produce the correct PASS/FAIL exit
# code (proving confirmation alone is never treated as success), and the
# exact same code path is exercised for two unrelated backend names (no
# per-backend branch).
#
# Every test runs against a throwaway PATH under $BATS_TEST_TMPDIR with a
# fake `rclone` binary placed ahead of the real one -- this never touches a
# real rclone remote, network, or OAuth flow. The real system `jq` is used
# directly (a read-only, deterministic parser with no side effects), the
# same way the existing suite lets real coreutils through and only fakes
# binaries that would otherwise have real side effects.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CONFIGURE_SRC="$REPO_ROOT/skills/j-cloud-connect/scripts/configure-backend.sh"

# A small, realistic-shaped fixture of rclone's own `config providers` JSON
# output -- just the fields this script actually reads (Name, Description).
FAKE_PROVIDERS_JSON='[
  {"Name": "drive", "Description": "Google Drive"},
  {"Name": "s3", "Description": "Amazon S3 Compliant Storage Providers"},
  {"Name": "dropbox", "Description": "Dropbox"}
]'

setup() {
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export PATH="$FAKE_BIN:$PATH"

  cp "$CONFIGURE_SRC" "$BATS_TEST_TMPDIR/configure-backend.sh"
  chmod +x "$BATS_TEST_TMPDIR/configure-backend.sh"
  CONFIGURE="$BATS_TEST_TMPDIR/configure-backend.sh"

  PROVIDERS_FILE="$BATS_TEST_TMPDIR/providers.json"
  printf '%s' "$FAKE_PROVIDERS_JSON" > "$PROVIDERS_FILE"
}

fake_bin() {
  # fake_bin <name> <script-body>
  local name="$1"
  local body="$2"
  cat > "$FAKE_BIN/$name" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$FAKE_BIN/$name"
}

# fake_rclone_base installs a fake `rclone` whose `config providers`
# subcommand returns the fixture JSON, and whose `config create`/`about`
# subcommands are driven by the CONFIG_CREATE_EXIT / ABOUT_EXIT env vars a
# test sets before calling `run`.
fake_rclone_base() {
  fake_bin rclone "
providers_file='$PROVIDERS_FILE'
case \"\$1 \$2\" in
  'config providers')
    cat \"\$providers_file\"
    exit 0
    ;;
esac
case \"\$1 \$2\" in
  'config create')
    echo \"[fake rclone] config create \$3 \$4 running...\"
    exit \"\${CONFIG_CREATE_EXIT:-0}\"
    ;;
esac
if [ \"\$1\" = 'about' ]; then
  if [ \"\${ABOUT_EXIT:-0}\" -eq 0 ]; then
    echo 'Total: 100 GiB'
  else
    echo 'about: remote not found' >&2
  fi
  exit \"\${ABOUT_EXIT:-0}\"
fi
echo \"[fake rclone] unhandled invocation: \$*\" >&2
exit 1
"
}

# ---------------------------------------------------------------------------
# AC: "Backend menu is generated from rclone's own provider list at run
# time, not a hardcoded list"
# ---------------------------------------------------------------------------

@test "--list prints the menu sourced from rclone config providers, not a hardcoded list" {
  fake_rclone_base
  run "$CONFIGURE" --list
  [ "$status" -eq 0 ]
  assert_output_contains "drive"
  assert_output_contains "Google Drive"
  assert_output_contains "s3"
  assert_output_contains "Amazon S3"
  assert_output_contains "dropbox"
}

@test "--list reflects whatever rclone's provider list actually returns (proves it's live, not hardcoded)" {
  fake_bin rclone '
if [ "$1 $2" = "config providers" ]; then
  echo "[{\"Name\": \"totally-fictional-backend\", \"Description\": \"Made up for this test\"}]"
  exit 0
fi
exit 1
'
  run "$CONFIGURE" --list
  [ "$status" -eq 0 ]
  assert_output_contains "totally-fictional-backend"
  assert_output_contains "Made up for this test"
  assert_output_not_contains "drive"
}

@test "rclone config providers failure is reported and exits non-zero" {
  fake_bin rclone '
if [ "$1 $2" = "config providers" ]; then
  echo "rclone: network unreachable" >&2
  exit 1
fi
exit 1
'
  run "$CONFIGURE" --list
  [ "$status" -eq 1 ]
  assert_output_contains "rclone config providers"
  assert_output_contains "failed"
}

@test "rclone not on PATH exits non-zero pointing at install-rclone.sh" {
  # No fake rclone placed; use a PATH with no rclone binary reachable at all.
  export PATH="$FAKE_BIN:/usr/bin:/bin"
  run "$CONFIGURE" --list
  [ "$status" -eq 1 ]
  assert_output_contains "rclone"
  assert_output_contains "install-rclone.sh"
}

# ---------------------------------------------------------------------------
# Argument-form backend validation against the live list
# ---------------------------------------------------------------------------

@test "a backend-type not in the live provider list is rejected" {
  fake_rclone_base
  run "$CONFIGURE" totally-not-a-real-backend some-remote
  [ "$status" -eq 1 ]
  assert_output_contains "totally-not-a-real-backend"
  assert_output_contains "not a backend"
}

@test "backend-type given without a remote-name is rejected with a usage message" {
  fake_rclone_base
  run "$CONFIGURE" drive
  [ "$status" -eq 1 ]
  assert_output_contains "expected exactly two arguments"
}

# ---------------------------------------------------------------------------
# AC: "For any selected backend, the script invokes that backend's own
# rclone config create flow" + failure aborts before confirmation.
# ---------------------------------------------------------------------------

@test "rclone config create failure aborts before any confirmation prompt is ever reached" {
  fake_rclone_base
  export CONFIG_CREATE_EXIT=1
  # No stdin provided at all -- if the script incorrectly reached a `read`
  # for confirmation, it would fail on end-of-input with a DIFFERENT error
  # message than the one asserted below, so this also proves ordering.
  run bash -c "$CONFIGURE drive myremote </dev/null"
  [ "$status" -eq 1 ]
  assert_output_contains "config create myremote drive"
  assert_output_contains "exited with status 1"
  assert_output_not_contains "Have you finished"
}

# ---------------------------------------------------------------------------
# AC: "Any auth URL produced by that flow is surfaced directly to the user"
# ---------------------------------------------------------------------------

@test "output from rclone config create (including any auth URL) is surfaced verbatim, not suppressed" {
  fake_bin rclone "
providers_file='$PROVIDERS_FILE'
case \"\$1 \$2\" in
  'config providers') cat \"\$providers_file\"; exit 0 ;;
  'config create')
    echo 'Please visit this link to authorize: https://example.com/oauth/authorize?token=abc123'
    exit 0
    ;;
esac
if [ \"\$1\" = 'about' ]; then echo 'Total: 1 GiB'; exit 0; fi
exit 1
"
  run bash -c "printf 'y\n' | $CONFIGURE drive myremote"
  [ "$status" -eq 0 ]
  assert_output_contains "https://example.com/oauth/authorize?token=abc123"
}

# ---------------------------------------------------------------------------
# AC: "the script waits for explicit user confirmation of completion before
# proceeding (never silently detects absence and stops)"
# ---------------------------------------------------------------------------

@test "declining confirmation aborts before rclone about is ever invoked" {
  fake_bin rclone "
providers_file='$PROVIDERS_FILE'
case \"\$1 \$2\" in
  'config providers') cat \"\$providers_file\"; exit 0 ;;
  'config create') echo 'configuring...'; exit 0 ;;
esac
if [ \"\$1\" = 'about' ]; then
  echo 'ERROR: about should never have been called' >&2
  exit 1
fi
exit 1
"
  run bash -c "printf 'n\n' | $CONFIGURE drive myremote"
  [ "$status" -eq 1 ]
  assert_output_contains "not confirmed complete"
  assert_output_not_contains "should never have been called"
}

@test "empty (default) answer to the confirmation prompt is treated as a decline, not a silent skip" {
  fake_rclone_base
  run bash -c "printf '\n' | $CONFIGURE drive myremote"
  [ "$status" -eq 1 ]
  assert_output_contains "not confirmed complete"
}

# ---------------------------------------------------------------------------
# AC: "After confirmation, the script verifies the remote works... and
# reports a clear pass/fail -- a user confirming 'done' alone never counts
# as verification"
# ---------------------------------------------------------------------------

@test "confirmed setup + rclone about success -> PASS, exit 0" {
  fake_rclone_base
  export ABOUT_EXIT=0
  run bash -c "printf 'y\n' | ABOUT_EXIT=0 $CONFIGURE drive myremote"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS"
  assert_output_contains "myremote"
}

@test "confirmed setup but rclone about FAILS -> FAIL, exit 1 (confirmation alone is not success)" {
  fake_rclone_base
  run bash -c "printf 'y\n' | ABOUT_EXIT=1 $CONFIGURE drive myremote"
  [ "$status" -eq 1 ]
  assert_output_contains "FAIL"
  assert_output_contains "did not verify"
}

@test "'yes' (not just 'y') is also accepted as confirmation" {
  fake_rclone_base
  run bash -c "printf 'yes\n' | ABOUT_EXIT=0 $CONFIGURE drive myremote"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS"
}

# ---------------------------------------------------------------------------
# AC: "The same code path runs identically regardless of backend selected"
# ---------------------------------------------------------------------------

@test "the identical flow (config create -> confirm -> verify) runs for a completely different backend, unmodified" {
  fake_rclone_base
  run bash -c "printf 'y\n' | ABOUT_EXIT=0 $CONFIGURE dropbox otherremote"
  [ "$status" -eq 0 ]
  assert_output_contains "config create otherremote dropbox"
  assert_output_contains "PASS"
  assert_output_contains "otherremote"
}

# ---------------------------------------------------------------------------
# Interactive (no-argument) selection path, driven from the same live menu.
# ---------------------------------------------------------------------------

@test "no-argument interactive mode: valid numeric selection resolves to the correct backend from the live list" {
  fake_rclone_base
  # Menu order from the fixture: 1) drive 2) s3 3) dropbox
  run bash -c "printf '2\nmys3remote\ny\n' | ABOUT_EXIT=0 $CONFIGURE"
  [ "$status" -eq 0 ]
  assert_output_contains "config create mys3remote s3"
  assert_output_contains "PASS"
}

@test "no-argument interactive mode: out-of-range numeric selection is rejected" {
  fake_rclone_base
  run bash -c "printf '99\n' | $CONFIGURE"
  [ "$status" -eq 1 ]
  assert_output_contains "invalid selection"
}

@test "no-argument interactive mode: non-numeric selection is rejected" {
  fake_rclone_base
  run bash -c "printf 'not-a-number\n' | $CONFIGURE"
  [ "$status" -eq 1 ]
  assert_output_contains "invalid selection"
}

# ---------------------------------------------------------------------------
# Usage / argument handling
# ---------------------------------------------------------------------------

@test "-h/--help prints usage and exits 0 without contacting rclone" {
  fake_bin rclone 'echo "rclone should never be called" >&2; exit 1'
  run "$CONFIGURE" --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage:"
  assert_output_not_contains "should never be called"
}

@test "too many positional arguments is rejected with a usage message" {
  fake_rclone_base
  run "$CONFIGURE" drive myremote extra-arg
  [ "$status" -eq 1 ]
  assert_output_contains "expected exactly two arguments"
}
