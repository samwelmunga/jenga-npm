#!/usr/bin/env bats
#
# Coverage for the failure-cleanup guard in skills/j-uncharted/scripts/import-source.sh (E85_S02_T04).
#
# The guard is the `case "$STAGING_ROOT" in /|/tmp|/var|/usr|/etc|"$HOME") : ;;` arm of `cleanup_on_failure`, the
# EXIT trap that removes a half-written staging root. It must never delete `/`, a system root, or the home directory,
# and must do nothing for an empty path. E85_S02_T04 deliberately left that line byte-for-byte unchanged (the literal
# HOME token cannot be removed without changing behaviour; see project/documentation/credential-access-audit.md), so
# these tests pin the behaviour rather than the text.
#
# SAFETY: the unit tests extract the trap function (and the two helpers it calls) from the script and run it with a
# PATH-stubbed `rm` that only logs its arguments, so no real path is ever deleted, whatever the guard decides.
# The end-to-end tests only ever hand the script directories under $BATS_TEST_TMPDIR, with HOME pointed at one of them.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-uncharted/scripts/import-source.sh"

setup() {
  STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
  RM_LOG="$BATS_TEST_TMPDIR/rm.log"
  FNS="$BATS_TEST_TMPDIR/fns.sh"
  mkdir -p "$STUB_BIN" "$BATS_TEST_TMPDIR/home"
  : >"$RM_LOG"
  # Stand-in `rm`: records its arguments, deletes nothing.
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$RM_LOG"' >"$STUB_BIN/rm"
  chmod +x "$STUB_BIN/rm"
  # Canonical form: the script canonicalises STAGING_ROOT with `pwd -P`, so HOME must be canonical to be comparable.
  FAKE_HOME="$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)"

  # Pull cleanup_on_failure and the helpers it calls out of the script, unchanged, so the real guard text is tested.
  # (The script cannot be sourced: it parses arguments and runs the import at top level.)
  : >"$FNS"
  local fn
  for fn in path_repo_root is_inside_repo cleanup_on_failure; do
    awk -v name="$fn" '
      $0 ~ "^" name "\\(\\) \\{" { on = 1 }
      on { print }
      on && /^\}/ { on = 0 }
    ' "$SCRIPT" >>"$FNS"
  done
}

# run_guard <staging-root> [exit-code]: run the trap function as the script would, with the script's `set -u`.
run_guard() {
  RM_LOG="$RM_LOG" HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" \
    bash -c 'set -uo pipefail; source "$1"; STAGING_ROOT="$2"; (exit "${3:-3}"); cleanup_on_failure' \
    _ "$FNS" "$1" "${2:-3}"
}

@test "extraction found the guard (so the tests below exercise the real function)" {
  grep -q '^cleanup_on_failure() {' "$FNS"
  grep -q 'rm -rf "\$STAGING_ROOT"' "$FNS"
}

@test "positive control: an ordinary staging directory IS removed" {
  mkdir -p "$BATS_TEST_TMPDIR/ordinary"
  run run_guard "$BATS_TEST_TMPDIR/ordinary"
  [ "$status" -eq 0 ]
  [ "$(cat "$RM_LOG")" = "-rf $BATS_TEST_TMPDIR/ordinary" ]
}

@test "positive control: a subdirectory of HOME is removed (only HOME itself is protected)" {
  mkdir -p "$FAKE_HOME/stage"
  run run_guard "$FAKE_HOME/stage"
  [ "$status" -eq 0 ]
  [ "$(cat "$RM_LOG")" = "-rf $FAKE_HOME/stage" ]
}

@test "refuses to delete /" {
  run run_guard "/"
  [ "$status" -eq 0 ]
  [ ! -s "$RM_LOG" ]
}

@test "refuses to delete the home directory (HOME pointed at a temp directory)" {
  run run_guard "$FAKE_HOME"
  [ "$status" -eq 0 ]
  [ ! -s "$RM_LOG" ]
}

@test "refuses to delete /tmp, /var, /usr and /etc" {
  local p
  for p in /tmp /var /usr /etc; do
    [ -d "$p" ] || continue
    run run_guard "$p"
    [ "$status" -eq 0 ]
  done
  [ ! -s "$RM_LOG" ]
}

@test "an empty staging path deletes nothing" {
  run run_guard ""
  [ "$status" -eq 0 ]
  [ ! -s "$RM_LOG" ]
}

@test "a staging path that does not exist deletes nothing" {
  run run_guard "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 0 ]
  [ ! -s "$RM_LOG" ]
}

@test "a successful run (exit 0) deletes nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/ordinary"
  run run_guard "$BATS_TEST_TMPDIR/ordinary" 0
  [ "$status" -eq 0 ]
  [ ! -s "$RM_LOG" ]
}

# --- end to end: the real script, real rm, temp directories only --------------------------------------------------

e2e_skip_if_tmp_in_repo() {
  if git -C "$BATS_TEST_TMPDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "TMPDIR sits inside a git working tree; import-source.sh would refuse the staging dir"
  fi
}

@test "e2e: a failed import with --staging-dir at HOME leaves the home directory in place" {
  e2e_skip_if_tmp_in_repo
  # Empty stdin -> exit 5 after the staging root exists and the EXIT trap is installed.
  run env HOME="$FAKE_HOME" bash "$SCRIPT" --type snippet --staging-dir "$FAKE_HOME" - </dev/null
  [ "$status" -eq 5 ]
  [ -d "$FAKE_HOME" ]
}

@test "e2e: a failed import cleans up an ordinary staging directory" {
  e2e_skip_if_tmp_in_repo
  run env HOME="$FAKE_HOME" bash "$SCRIPT" --type snippet --staging-dir "$BATS_TEST_TMPDIR/stage" - </dev/null
  [ "$status" -eq 5 ]
  [ ! -e "$BATS_TEST_TMPDIR/stage" ]
}
