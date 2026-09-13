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
RESOLVER_SRC="$REPO_ROOT/skills/j-dashboard/scripts/resolve-app-dir.sh"

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

  # launch.sh delegates project/app resolution to its sibling resolve-app-dir.sh,
  # so the fixture skill directory must carry it too -- exactly as the real
  # skills/j-dashboard/scripts/ directory ships both together.
  cp "$RESOLVER_SRC" "$TMP_REPO/skills/j-dashboard/scripts/resolve-app-dir.sh"

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

# The defect this pins: launch.sh used to compute APP_DIR as
# "$(git rev-parse --show-toplevel)/project/app", which is only ever correct
# inside this monorepo. A consumer installs the dashboard as a dependency, so
# it lives at <consumer>/node_modules/@jenga-ai/agent/project/app and the old
# resolution died with "dashboard app not found" on every consumer install.
@test "consumer install: resolves project/app from node_modules/@jenga-ai/agent" {
  # Shape the fixture like a real consumer: the skill was mirrored into
  # .claude/skills/ by postinstall, and the app only exists inside the package.
  rm -rf "$TMP_REPO/project"
  mkdir -p "$TMP_REPO/.claude/skills/j-dashboard/scripts"
  cp "$LAUNCH_SRC" "$TMP_REPO/.claude/skills/j-dashboard/scripts/launch.sh"
  cp "$RESOLVER_SRC" "$TMP_REPO/.claude/skills/j-dashboard/scripts/resolve-app-dir.sh"
  chmod +x "$TMP_REPO/.claude/skills/j-dashboard/scripts/launch.sh"

  PKG_APP="$TMP_REPO/node_modules/@jenga-ai/agent/project/app"
  mkdir -p "$PKG_APP"
  cat > "$PKG_APP/package.json" <<'EOF'
{ "name": "fixture-packaged-app" }
EOF

  run "$TMP_REPO/.claude/skills/j-dashboard/scripts/launch.sh" start
  [ "$status" -eq 0 ]

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  assert_output_contains "CWD:$PKG_APP"
  assert_output_contains "ARGS:run dashboard:start"
}

@test "missing project/app/package.json exits non-zero with a clear message, no npm invocation" {
  rm "$TMP_REPO/project/app/package.json"

  # Run from a directory with no jenga install anywhere above it. Without this
  # the resolver's walk-up could climb out of the fixture entirely and find an
  # unrelated checkout's project/app -- which is exactly why that walk-up only
  # ever accepts an installed node_modules/@jenga-ai/agent, never a bare
  # project/app. Asserting from a neutral cwd pins that narrowing.
  cd "$BATS_TEST_TMPDIR"

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
