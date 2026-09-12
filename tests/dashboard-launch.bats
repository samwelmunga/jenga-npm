#!/usr/bin/env bats
#
# Regression coverage for skills/j-dashboard/scripts/launch.sh (E47_S04_T01).
#
# Why this file exists
# ---------------------
# launch.sh is a thin wrapper around project/app's existing `dashboard:start`
# / `dashboard:open` npm scripts (E47_S04_T01's scope: default, no-`--snapshot`
# launch mode). Its own logic -- mode parsing (start|open|both), --port /
# --serve-app pass-through, repo-root resolution via `git rev-parse
# --show-toplevel`, and the missing-package.json guard -- is what this task
# actually added, and is what this suite pins. It deliberately does NOT
# exercise the real dashboard-start.cjs/dashboard-open.cjs server behavior
# (that belongs to their own epics, E05-E09) -- a fake `npm` on PATH captures
# what launch.sh invokes and where, so these tests run fast and don't bind a
# real port.
#
# Every test runs against a throwaway git repo under $BATS_TEST_TMPDIR, never
# against this repository's own project/app.

# Shared assertion helpers -- see tests/helpers/assertions.bash header for why
# a bare `[[ ... ]]` must never be used under tests/ (bats' ERR trap does not
# fire for a failing `[[`, a shell keyword, so a false one can silently pass).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LAUNCH_SRC="$REPO_ROOT/skills/j-dashboard/scripts/launch.sh"

setup() {
  # Resolve via `pwd -P` (not just string-concatenated from
  # $BATS_TEST_TMPDIR) so this matches what the fake npm's own `pwd` reports
  # after `cd` -- macOS's /tmp -> /private/tmp symlink otherwise makes the two
  # forms disagree even though they name the same directory.
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  TMP_REPO="$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)"
  mkdir -p "$TMP_REPO/skills/j-dashboard/scripts"
  git -C "$TMP_REPO" init -q

  cp "$LAUNCH_SRC" "$TMP_REPO/skills/j-dashboard/scripts/launch.sh"
  chmod +x "$TMP_REPO/skills/j-dashboard/scripts/launch.sh"
  LAUNCH="$TMP_REPO/skills/j-dashboard/scripts/launch.sh"

  mkdir -p "$TMP_REPO/project/app"
  cat > "$TMP_REPO/project/app/package.json" <<'EOF'
{ "name": "fixture-app" }
EOF

  # Fake `npm` placed ahead of the real one on PATH -- logs its cwd and args
  # instead of actually running dashboard-start.cjs/dashboard-open.cjs, so
  # these tests assert what launch.sh forwards, not the real server's
  # behavior (out of this task's scope).
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
  : > "$NPM_LOG"
  cat > "$FAKE_BIN/npm" <<EOF
#!/usr/bin/env bash
echo "CWD:\$(pwd)" >> "$NPM_LOG"
echo "ARGS:\$*" >> "$NPM_LOG"
exit 0
EOF
  chmod +x "$FAKE_BIN/npm"
  export PATH="$FAKE_BIN:$PATH"
  export NPM_LOG
}

@test "start mode invokes npm run dashboard:start in project/app with --port and --serve-app forwarded unchanged" {
  run "$LAUNCH" start --port 4321 --serve-app
  [ "$status" -eq 0 ]

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  assert_output_contains "CWD:$TMP_REPO/project/app"
  assert_output_contains "ARGS:run dashboard:start -- --port 4321 --serve-app"
}

@test "open mode invokes npm run dashboard:open in project/app with --port forwarded unchanged" {
  run "$LAUNCH" open --port 4321
  [ "$status" -eq 0 ]

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  assert_output_contains "CWD:$TMP_REPO/project/app"
  assert_output_contains "ARGS:run dashboard:open -- --port 4321"
}

@test "both mode invokes dashboard:start then dashboard:open with the same forwarded flags" {
  run "$LAUNCH" both --port 4321
  [ "$status" -eq 0 ]

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  assert_output_contains "ARGS:run dashboard:start -- --port 4321"
  assert_output_contains "ARGS:run dashboard:open -- --port 4321"
}

@test "missing mode argument exits non-zero with a usage message" {
  run "$LAUNCH"
  [ "$status" -eq 1 ]
  assert_output_contains "Usage: launch.sh"
  assert_output_contains "missing mode argument"
}

@test "unknown mode exits non-zero with a clear error naming the bad value" {
  run "$LAUNCH" bogus
  [ "$status" -eq 1 ]
  assert_output_contains "unknown mode: bogus"
}

@test "-h/--help prints usage and exits 0 without invoking npm" {
  run "$LAUNCH" --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: launch.sh"

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing project/app/package.json exits non-zero with a clear message, no npm invocation" {
  rm "$TMP_REPO/project/app/package.json"

  run "$LAUNCH" start
  [ "$status" -ne 0 ]
  assert_output_contains "dashboard app not found"
  assert_output_contains "project/app/package.json"

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Currently RED -- pins a real regression found during E47_S04_T01 tester
# verification: `EXTRA_ARGS=()` plus `set -u` means `"${EXTRA_ARGS[@]}"`
# throws "unbound variable" under bash < 4.4 (e.g. macOS's stock /bin/bash
# 3.2) whenever launch.sh is invoked with neither --port nor --serve-app --
# the single most common invocation shape start/open/both all support. See
# project/rapports/problems/E47_S04_T01-launch-sh-empty-args-crash.md.
@test "no --port/--serve-app given forwards no extra args beyond the npm run script name" {
  run "$LAUNCH" open
  [ "$status" -eq 0 ]

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  assert_output_contains "ARGS:run dashboard:open --"
}
