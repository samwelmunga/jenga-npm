#!/usr/bin/env bats
#
# Regression coverage for skills/j-cloud-connect/scripts/install-rclone.sh
# (E60_S01_T01).
#
# Why this file exists
# ---------------------
# install-rclone.sh detects whether `rclone` is on PATH and, if not, installs
# it automatically (brew on macOS, the official curl|sudo install script on
# Linux), re-verifying afterward before ever reporting success. This suite
# pins every branch named in the task's Acceptance Criteria: already-present
# skip, macOS install (brew missing / brew install failure / brew "succeeds"
# but binary still absent), Linux install (curl missing / sudo missing /
# download failure / install-script failure with the REAL captured exit code
# / full success), unsupported OS, and the usage/argument paths.
#
# Every test runs against a throwaway PATH under $BATS_TEST_TMPDIR with fake
# `rclone`/`brew`/`curl`/`sudo`/`uname` binaries placed ahead of the real
# ones -- this never touches this machine's real package managers or network,
# and never installs or uninstalls anything for real.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALL_SRC="$REPO_ROOT/skills/j-cloud-connect/scripts/install-rclone.sh"

setup() {
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  # Fresh PATH with only the fake bin dir plus the bare minimum real system
  # binaries the script and bats itself need (bash, coreutils, mktemp, rm...).
  # We keep the real PATH appended AFTER our fake bin dir, so a fake binary
  # always shadows a real one, but anything we don't fake still resolves.
  export REAL_PATH="$PATH"
  export PATH="$FAKE_BIN:$REAL_PATH"

  cp "$INSTALL_SRC" "$BATS_TEST_TMPDIR/install-rclone.sh"
  chmod +x "$BATS_TEST_TMPDIR/install-rclone.sh"
  INSTALL="$BATS_TEST_TMPDIR/install-rclone.sh"

  # Curated PATHs used to make a real system tool genuinely absent (not just
  # shadowed) without also losing the coreutils (bash, cat, rm, mktemp,
  # head, dirname...) the script and bats itself need to even run. Computed
  # here (not at file top level) so they pick up THIS test's $FAKE_BIN --
  # top-level assignment would freeze on the empty value from file-parse
  # time, before setup() ever runs. On this host:
  #   - brew lives under /opt/homebrew/bin (or /usr/local/bin) -- NOT /bin
  #     or /usr/bin -- so restricting to /bin:/usr/bin hides it for real.
  #   - curl and sudo are core system utilities that live in /usr/bin
  #     alongside mktemp/head/dirname, so hiding them for real means
  #     dropping /usr/bin entirely and keeping only /bin (bash/cat/rm/
  #     chmod/mkdir/date live there); any command the test still needs from
  #     /usr/bin (curl or sudo) is then re-added as an explicit fake in
  #     FAKE_BIN.
  # PATH_FULL still includes /usr/bin (mktemp, head, dirname...) so the
  # script can run its full course; it omits /opt/homebrew/bin (and any
  # other Homebrew prefix) so a real `brew` is never found unless a fake is
  # placed in FAKE_BIN, which -- being first on PATH -- always wins anyway.
  PATH_FULL="$FAKE_BIN:/bin:/usr/bin"
  # PATH_MINIMAL additionally drops /usr/bin, so curl and sudo (both real
  # system utilities that live there on this host) are genuinely absent
  # unless a fake is placed in FAKE_BIN. Only safe for tests that never
  # reach the mktemp/head/dirname calls further down the Linux branch.
  PATH_MINIMAL="$FAKE_BIN:/bin"
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

# ---------------------------------------------------------------------------
# AC: "Detects an existing rclone on PATH and skips installation entirely
# when already present (reports this, does not reinstall)"
# ---------------------------------------------------------------------------

@test "already-installed rclone is detected, install is skipped, exits 0" {
  fake_bin rclone 'if [ "$1" = "version" ]; then echo "rclone v1.66.0"; exit 0; fi; exit 0'
  fake_bin brew 'echo "brew should never be called" >&2; exit 1'

  run "$INSTALL"
  [ "$status" -eq 0 ]
  assert_output_contains "already installed"
  assert_output_contains "skipping install"
}

# ---------------------------------------------------------------------------
# AC: "installs rclone automatically on macOS (via brew, if available)"
# ---------------------------------------------------------------------------

@test "macOS: brew missing exits non-zero with an actionable message naming Homebrew" {
  fake_bin uname 'echo Darwin'
  # No fake brew placed on PATH, and no real rclone/brew reachable either
  # (FAKE_BIN shadows nothing here, but the assertion is that install still
  # fails cleanly even if a real brew happens to exist on the CI host -- so
  # we also shadow brew with a "not found" stand-in by simply not defining
  # it and relying on `command -v brew` failing under a scrubbed PATH).
  export PATH="$PATH_FULL"

  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_contains "Homebrew"
  assert_output_contains "not available"
}

@test "macOS: brew install failure exits non-zero with an actionable message" {
  fake_bin uname 'echo Darwin'
  fake_bin brew 'echo "install" "$@"; exit 1'
  export PATH="$PATH_FULL"

  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_contains "brew install rclone"
  assert_output_contains "failed"
}

# ---------------------------------------------------------------------------
# AC: "After attempting install, re-verifies rclone is actually on PATH and
# runnable... before reporting success"
# ---------------------------------------------------------------------------

@test "macOS: brew reports success but rclone still absent from PATH -- re-verification catches it, exits non-zero" {
  fake_bin uname 'echo Darwin'
  # brew "succeeds" (exit 0) but never actually places an rclone binary --
  # this is exactly the case the post-install verify_install() step exists
  # to catch; a naive script would report success here.
  fake_bin brew 'echo "install" "$@"; exit 0'
  export PATH="$PATH_FULL"

  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_contains "still not on PATH"
}

@test "macOS: brew succeeds and rclone becomes runnable -- verified and reports success" {
  fake_bin uname 'echo Darwin'
  # The fake brew "installs" rclone by dropping a working fake rclone binary
  # into the same fake bin dir, simulating a real install landing on PATH.
  fake_bin brew "cat > \"$FAKE_BIN/rclone\" <<'RCLONE'
#!/usr/bin/env bash
if [ \"\$1\" = \"version\" ]; then echo \"rclone v1.66.0\"; exit 0; fi
exit 0
RCLONE
chmod +x \"$FAKE_BIN/rclone\"
exit 0"
  export PATH="$PATH_FULL"

  run "$INSTALL"
  [ "$status" -eq 0 ]
  assert_output_contains "installed and verified successfully"
}

# ---------------------------------------------------------------------------
# AC: "installs rclone automatically on... Linux (via the official install
# method)" + failure paths (no package manager / sudo unavailable / network)
# ---------------------------------------------------------------------------

@test "Linux: curl missing exits non-zero with an actionable message naming curl" {
  fake_bin uname 'echo Linux'
  fake_bin sudo 'exit 0'
  export PATH="$PATH_MINIMAL"

  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_contains "curl"
  assert_output_contains "not available"
}

@test "Linux: sudo missing exits non-zero with an actionable message naming sudo" {
  fake_bin uname 'echo Linux'
  fake_bin curl 'exit 0'
  export PATH="$PATH_MINIMAL"

  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_contains "sudo"
  assert_output_contains "not available"
}

@test "Linux: install-script download failure (network failure) exits non-zero with an actionable message" {
  fake_bin uname 'echo Linux'
  fake_bin sudo 'exit 0'
  fake_bin curl 'echo "curl: network failure" >&2; exit 7'
  export PATH="$PATH_FULL"

  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_contains "failed to download"
  assert_output_contains "network access"
}

# Pins the real bug the developer found and fixed during self-testing:
# capturing $? directly inside `if ! sudo bash ...; then` reads the negated
# test's own exit code (always 0), never the real one. The fix runs the
# command unnegated into a captured INSTALL_EXIT_CODE variable. This test
# would have reported "exit status 0" (or simply never fired the failure
# branch's exit-code message) under the old, buggy version.
@test "Linux: install script downloads but fails to run -- reports the REAL non-zero exit code, not 0" {
  fake_bin uname 'echo Linux'
  fake_bin curl 'shift $(($#-1)); out="$1"; echo "#!/usr/bin/env bash" > "$out"; echo "exit 1" >> "$out"; exit 0'
  fake_bin sudo 'shift; bash "$@"; exit $?'
  export PATH="$PATH_FULL"

  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_contains "failed to run"
  assert_output_contains "exit status 1"
  # explicitly rule out the pre-fix regression (always reporting status 0)
  assert_output_not_contains "exit status 0"
}

@test "Linux: full success path -- install script runs, rclone lands on PATH, re-verified" {
  fake_bin uname 'echo Linux'
  # curl "downloads" a tiny install script that, when sudo-run, drops a
  # working fake rclone binary into the fake bin dir -- simulating the real
  # rclone.org/install.sh placing the binary on PATH.
  fake_bin curl "shift \$((\$#-1)); out=\"\$1\"; cat > \"\$out\" <<'SCRIPT'
#!/usr/bin/env bash
cat > \"$FAKE_BIN/rclone\" <<'RCLONE'
#!/usr/bin/env bash
if [ \"\$1\" = \"version\" ]; then echo \"rclone v1.66.0\"; exit 0; fi
exit 0
RCLONE
chmod +x \"$FAKE_BIN/rclone\"
exit 0
SCRIPT
exit 0"
  fake_bin sudo 'shift; bash "$@"; exit $?'
  export PATH="$PATH_FULL"

  run "$INSTALL"
  [ "$status" -eq 0 ]
  assert_output_contains "installed and verified successfully"
}

# ---------------------------------------------------------------------------
# Unsupported OS
# ---------------------------------------------------------------------------

@test "unsupported OS exits non-zero naming the detected OS" {
  fake_bin uname 'echo SunOS'
  # Must exclude /opt/homebrew/bin (where a real rclone may already be
  # installed on the host running this suite) -- otherwise Step 1 detection
  # finds the real binary and exits 0 before the OS branch is ever reached.
  export PATH="$PATH_FULL"

  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_contains "unsupported OS"
  assert_output_contains "SunOS"
}

# ---------------------------------------------------------------------------
# Usage / argument handling
# ---------------------------------------------------------------------------

@test "-h/--help prints usage and exits 0 without attempting any install" {
  fake_bin uname 'echo Darwin'
  fake_bin brew 'echo "brew should never be called" >&2; exit 1'

  run "$INSTALL" --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: install-rclone.sh"
}

@test "unknown argument exits non-zero with a usage message" {
  run "$INSTALL" bogus
  [ "$status" -eq 1 ]
  assert_output_contains "unknown argument: bogus"
}
