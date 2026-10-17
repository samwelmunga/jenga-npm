#!/usr/bin/env bats
#
# Regression coverage for E46_S02_T03: commit-version-bump.sh's MONOREPO_ROOT
# used to be a fixed "two levels up" climb from the script's own directory
# (skills/j-distribute/scripts/../../..). That only lands on the real
# monorepo root when the script runs from its monorepo source location. Once
# mirrored to .claude/skills/j-distribute/scripts/ (self-sync mirror
# target), the same climb lands on .claude/ instead, and the script then
# looks for package.json at .claude/package.json -- which never exists --
# instead of the real package.json at the monorepo root.
#
# Fixed by resolving MONOREPO_ROOT via `git rev-parse --show-toplevel`,
# falling back to the existing ../../.. climb only on git failure -- the
# same approach already used by this story's sibling tasks E46_S02_T01/T02
# and by skills/j-publish/scripts/run_gates.sh:26-29.
#
# Every test below runs the real, current (already-fixed) script end-to-end
# against a throwaway $BATS_TEST_TMPDIR fixture git repo, never against this
# repository's own package.json or git history (E43/init.bats fixture-tree
# convention).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT_REL="skills/j-distribute/scripts/commit-version-bump.sh"

setup() {
  FIXTURE_REPO="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email "test@example.com"
  git -C "$FIXTURE_REPO" config user.name "Test"

  cat > "$FIXTURE_REPO/package.json" <<'EOF'
{
  "name": "fixture-package",
  "version": "1.0.0"
}
EOF
  git -C "$FIXTURE_REPO" add package.json
  git -C "$FIXTURE_REPO" commit -q -m "fixture: initial package.json at 1.0.0"

  # Simulate a version bump that hasn't been committed yet -- the exact
  # scenario commit-version-bump.sh is called to handle after /distribute.
  cat > "$FIXTURE_REPO/package.json" <<'EOF'
{
  "name": "fixture-package",
  "version": "1.0.1"
}
EOF
}

# Copies the real, current (already-fixed) script under test to a given
# location inside the fixture repo -- so the test exercises the actual fix,
# not a reimplementation of it.
install_script_at() {
  local dest_dir="$1"
  mkdir -p "$dest_dir"
  cp "$REPO_ROOT/$SCRIPT_REL" "$dest_dir/commit-version-bump.sh"
  chmod +x "$dest_dir/commit-version-bump.sh"
}

@test "MONOREPO_ROOT resolves correctly from the script's real source location (skills/j-distribute/scripts/)" {
  install_script_at "$FIXTURE_REPO/skills/j-distribute/scripts"

  run bash "$FIXTURE_REPO/skills/j-distribute/scripts/commit-version-bump.sh"
  [ "$status" -eq 0 ]
  assert_output_contains "Committed successfully: chore: bump version to 1.0.1"

  run git -C "$FIXTURE_REPO" log -1 --pretty=%s
  [ "$status" -eq 0 ]
  [ "$output" = "chore: bump version to 1.0.1" ]
}

@test "MONOREPO_ROOT resolves correctly from a simulated .claude/ mirror location, where the old fixed climb landed on .claude/ instead of the repo root" {
  install_script_at "$FIXTURE_REPO/.claude/skills/j-distribute/scripts"

  # Sanity check on the bug this guards against: the OLD fixed "../../.."
  # climb from this mirror location resolves to $FIXTURE_REPO/.claude, not
  # $FIXTURE_REPO -- and package.json does not exist under .claude/.
  old_style_root="$(cd "$FIXTURE_REPO/.claude/skills/j-distribute/scripts/../../.." && pwd)"
  [ "$old_style_root" = "$FIXTURE_REPO/.claude" ]
  [ ! -f "$old_style_root/package.json" ]

  run bash "$FIXTURE_REPO/.claude/skills/j-distribute/scripts/commit-version-bump.sh"
  [ "$status" -eq 0 ]
  assert_output_contains "Committed successfully: chore: bump version to 1.0.1"

  run git -C "$FIXTURE_REPO" log -1 --pretty=%s
  [ "$status" -eq 0 ]
  [ "$output" = "chore: bump version to 1.0.1" ]
}

@test "falls back to the ../../.. climb and still resolves correctly when not inside a git repository at the script's own real-depth location" {
  # A plain directory tree at the same real depth (scripts/ -> j-distribute/
  # -> skills/ -> root) but with no .git anywhere above it -- the documented
  # fallback case. The script's own git operations will still fail (there is
  # no repo to commit into), but the fallback climb itself must resolve to
  # the tree's own root, not error out or resolve somewhere else, and the
  # script's own error message must name the expected (correct) path.
  NONGIT_DIR="$BATS_TEST_TMPDIR/nongit"
  mkdir -p "$NONGIT_DIR/skills/j-distribute/scripts"
  cp "$REPO_ROOT/$SCRIPT_REL" "$NONGIT_DIR/skills/j-distribute/scripts/commit-version-bump.sh"
  chmod +x "$NONGIT_DIR/skills/j-distribute/scripts/commit-version-bump.sh"
  # No package.json at all -- this proves the fallback climb landed on
  # $NONGIT_DIR (not some other directory), since the script's very first
  # failure names exactly that resolved path.

  run bash "$NONGIT_DIR/skills/j-distribute/scripts/commit-version-bump.sh"
  [ "$status" -eq 1 ]
  assert_output_contains "package.json not found at $NONGIT_DIR/package.json"
}
