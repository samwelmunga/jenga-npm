#!/usr/bin/env bats
#
# Regression coverage for mirror.sh's check_permission_level_invariant
# (E28_S15_T01).
#
# Why this file exists
# ---------------------
# /jenga-permission-level writes a loosened permissions.deny/autoMode.allow
# straight into .claude/settings.json and .agents/settings.json for a
# session-local, intentionally EPHEMERAL override (E33's deliberate design --
# it never touches root settings.json). mirror.sh ships whatever is currently
# sitting in the working tree via rsync, not `git HEAD`, so a real push while
# a session is still elevated -- before /self-sync restores the baseline --
# would ship that loosened deny list as the DEFAULT settings.json every
# consumer inherits on `npm install`. This happened live on 2026-09-22,
# caught only by a manual --dry-run inspection. Full writeup:
#   project/board/stories/E28_S15_permission-level-invariant-guard.md
#
# Design of this suite
# ---------------------
# Unlike tests/mirror-orphaned-twin-rewrite.bats (which extracts a single pure
# function into a sandbox tree), this check's entire job is "does a REAL push
# get refused" -- there is no meaningful way to test that without invoking the
# real mirror.sh end-to-end. Every test here runs the actual script against a
# freshly created LOCAL BARE git remote via MIRROR_PUBLIC_URL_OVERRIDE, exactly
# the pattern documented in skills/j-mirror-public/SKILL.md's own examples and
# this repo's CLAUDE.md hard safety constraint for this task: the real
# https://github.com/samwelmunga/jenga-npm URL is NEVER passed to mirror.sh
# here, directly or via config.json (config.json is never touched -- the
# override env var replaces its publicRepoUrl at runtime).
#
# Each test gets a brand-new bare remote AND a wiped scratch worktree
# (.mirror-worktrees/public, path from config.json's worktreePath) in setup(),
# so every run is an independent "genuine first-run bootstrap" case -- no
# cross-test marker-tag state to reason about.
#
# .jenga-permission-level.json, .claude/settings.json, and .agents/settings.json
# are the real files this repo ships (mirror.sh reads REPO_ROOT from its own
# on-disk location via `git rev-parse --show-toplevel`, which resolves to
# THIS worktree when bats runs from here). Tests that need an elevated fixture
# overwrite those three files and teardown() unconditionally restores the
# exact bytes captured in setup(), so no fixture mutation ever survives a test,
# pass or fail.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIRROR_SH="$REPO_ROOT/skills/j-mirror-public/scripts/mirror.sh"
SCRATCH_WORKTREE="$REPO_ROOT/.mirror-worktrees/public"

LEVEL_FILE="$REPO_ROOT/.jenga-permission-level.json"
CLAUDE_SETTINGS="$REPO_ROOT/.claude/settings.json"
AGENTS_SETTINGS="$REPO_ROOT/.agents/settings.json"
LEVEL5_TEMPLATE="$REPO_ROOT/templates/permission-levels/level-5-unrestricted.json"

setup() {
  # Snapshot the real files this test worktree ships, so any fixture mutation
  # below can be restored byte-for-byte in teardown() regardless of outcome.
  LEVEL_BACKUP="$BATS_TEST_TMPDIR/level.orig.json"
  CLAUDE_BACKUP="$BATS_TEST_TMPDIR/claude-settings.orig.json"
  AGENTS_BACKUP="$BATS_TEST_TMPDIR/agents-settings.orig.json"
  cp "$LEVEL_FILE" "$LEVEL_BACKUP"
  cp "$CLAUDE_SETTINGS" "$CLAUDE_BACKUP"
  cp "$AGENTS_SETTINGS" "$AGENTS_BACKUP"

  # Every test starts from a clean, unborn scratch worktree so the safety
  # check always takes the "genuine first-run bootstrap" branch, never a
  # stale marker left over from a previous test or a previous real run.
  rm -rf "$SCRATCH_WORKTREE"

  BARE_REMOTE="$BATS_TEST_TMPDIR/public.git"
  git init --bare -q -b main "$BARE_REMOTE"
}

teardown() {
  cp "$LEVEL_BACKUP" "$LEVEL_FILE"
  cp "$CLAUDE_BACKUP" "$CLAUDE_SETTINGS"
  cp "$AGENTS_BACKUP" "$AGENTS_SETTINGS"
  rm -rf "$SCRATCH_WORKTREE"
}

elevate_to_level_5() {
  printf '{\n  "session_level": 5\n}\n' > "$LEVEL_FILE"
  cp "$LEVEL5_TEMPLATE" "$CLAUDE_SETTINGS"
  cp "$LEVEL5_TEMPLATE" "$AGENTS_SETTINGS"
}

run_real_push() {
  run env MIRROR_PUBLIC_URL_OVERRIDE="$BARE_REMOTE" bash "$MIRROR_SH"
}

# refs_on_bare_remote: prints nothing (and exits non-zero from show-ref) if
# the bare remote has no refs at all -- the "zero push side effects" signal.
bare_remote_has_any_ref() {
  git --git-dir="$BARE_REMOTE" show-ref --quiet
}

# -----------------------------------------------------------------------------
# Fail case (task AC + DoD): session elevated, real push refused, zero
# rsync/commit/push side effects, verified against a local bare remote.
# -----------------------------------------------------------------------------

@test "real push is refused when the session is elevated to level 5" {
  elevate_to_level_5
  run_real_push
  [ "$status" -ne 0 ]
}

@test "refusal names both off-baseline files and points at /self-sync" {
  elevate_to_level_5
  run_real_push
  assert_output_contains "permission-level-invariant"
  assert_output_contains ".claude/settings.json"
  assert_output_contains ".agents/settings.json"
  assert_output_contains "/self-sync"
}

@test "refusal reports the session_level found, as a diagnostic" {
  elevate_to_level_5
  run_real_push
  assert_output_contains "session_level in .jenga-permission-level.json reads '5'"
}

@test "refusal leaves the bare remote with zero refs (no push occurred)" {
  elevate_to_level_5
  run_real_push
  [ "$status" -ne 0 ]
  run bare_remote_has_any_ref
  [ "$status" -ne 0 ]
}

@test "refusal leaves no committed marker in the scratch worktree (no commit occurred)" {
  elevate_to_level_5
  run_real_push
  [ "$status" -ne 0 ]
  # The scratch worktree is prepared (clone/init) before the invariant check
  # runs, but no commit should ever land in it -- HEAD stays unborn.
  run git -C "$SCRATCH_WORKTREE" rev-parse --verify HEAD
  [ "$status" -ne 0 ]
}

@test "only the actually-off-baseline file is named when just one diverges" {
  elevate_to_level_5
  # Restore .agents/settings.json back to the real (level-2) baseline --
  # only .claude/settings.json stays elevated.
  cp "$AGENTS_BACKUP" "$AGENTS_SETTINGS"
  run_real_push
  [ "$status" -ne 0 ]
  assert_output_contains ".claude/settings.json"
  assert_output_not_contains ".agents/settings.json"
}

# -----------------------------------------------------------------------------
# Pass case (task AC + DoD): level-2 baseline, real push proceeds normally --
# no behavior change for the already-safe case, verified against a local bare
# remote.
# -----------------------------------------------------------------------------

@test "real push proceeds normally at the level-2 baseline" {
  run_real_push
  [ "$status" -eq 0 ]
  assert_output_contains "permission-level-invariant"
  assert_output_contains "level-2 baseline"
  assert_output_contains "OK"
}

@test "a successful baseline push actually lands a commit on the bare remote" {
  run_real_push
  [ "$status" -eq 0 ]
  run bare_remote_has_any_ref
  [ "$status" -eq 0 ]
  run git --git-dir="$BARE_REMOTE" rev-parse refs/heads/main
  [ "$status" -eq 0 ]
}

@test "the passing-case log reports the actual session_level" {
  run_real_push
  [ "$status" -eq 0 ]
  assert_output_contains "session_level: 2"
}

# -----------------------------------------------------------------------------
# --dry-run and --inventory must never invoke this check at all.
# -----------------------------------------------------------------------------

# Note: the repo's own file tree (this test file's name, and this task's
# board files) contains the literal substring "permission-level-invariant" in
# several PATHS -- which --dry-run's/--inventory's ship/block file listings
# legitimately print regardless of this check. A bare
# `assert_output_not_contains "permission-level-invariant"` would false-fail
# on that noise, so these two assertions target the exact log-line PREFIX the
# check itself emits (`log`/`die` always print "mirror.sh: <msg>" or
# "mirror.sh: error: <msg>") rather than the bare substring.

@test "--dry-run never runs the permission-level invariant, even when elevated" {
  elevate_to_level_5
  run env MIRROR_PUBLIC_URL_OVERRIDE="$BARE_REMOTE" bash "$MIRROR_SH" --dry-run
  [ "$status" -eq 0 ]
  assert_output_not_contains "mirror.sh: permission-level-invariant"
  assert_output_not_contains "mirror.sh: error: permission-level-invariant"
}

@test "--inventory never runs the permission-level invariant, even when elevated" {
  elevate_to_level_5
  run env MIRROR_PUBLIC_URL_OVERRIDE="$BARE_REMOTE" bash "$MIRROR_SH" --inventory
  [ "$status" -eq 0 ]
  assert_output_not_contains "mirror.sh: permission-level-invariant"
  assert_output_not_contains "mirror.sh: error: permission-level-invariant"
}

# -----------------------------------------------------------------------------
# Missing-file branch: nothing to ship from a file that isn't there, so
# nothing it could leak -- a harmless, logged skip, not a failure.
# -----------------------------------------------------------------------------

@test "a missing settings file is a harmless skip, not a failure" {
  rm -f "$CLAUDE_SETTINGS" "$AGENTS_SETTINGS"
  run_real_push
  [ "$status" -eq 0 ]
  assert_output_contains ".claude/settings.json does not exist"
  assert_output_contains ".agents/settings.json does not exist"
  assert_output_contains "nothing to check"
}
