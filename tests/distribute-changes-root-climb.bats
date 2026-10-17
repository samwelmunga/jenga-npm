#!/usr/bin/env bats
#
# Regression coverage for E46_S02_T03: distribute-changes.sh's REPO_ROOT used
# to be a fixed "three levels up" climb from the script's own directory
# (skills/j-distribute/scripts/../../..). That only lands on the real
# monorepo root when the script runs from its monorepo source location. Once
# mirrored to .claude/skills/j-distribute/scripts/ (self-sync mirror
# target), the same climb lands on .claude/ instead, and the script then
# looks for distribute.config.json (and package.json) under .claude/ --
# which never exists -- instead of the real monorepo root.
#
# Fixed by resolving REPO_ROOT via `git rev-parse --show-toplevel`, falling
# back to the existing ../../.. climb only on git failure -- the same
# approach already used by this story's sibling tasks E46_S02_T01/T02 and by
# skills/j-publish/scripts/run_gates.sh:26-29.
#
# Every test below runs the real, current (already-fixed) script end-to-end
# in --dry-run mode (so nothing is actually written to a target project)
# against a throwaway $BATS_TEST_TMPDIR fixture git repo playing the role of
# the monorepo, never against this repository's own distribute.config.json
# or package.json (E43/init.bats fixture-tree convention).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT_REL="skills/j-distribute/scripts/distribute-changes.sh"

setup() {
  FIXTURE_REPO="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FIXTURE_REPO"
  # Resolve to the physical path up front: on macOS $BATS_TEST_TMPDIR lives
  # under a /var symlink to /private/var, and `git rev-parse --show-toplevel`
  # (used by the fix under test) always returns the resolved physical path --
  # so comparisons below must use the same resolved form, not the raw
  # $BATS_TEST_TMPDIR-relative one.
  FIXTURE_REPO="$(cd "$FIXTURE_REPO" && pwd -P)"
  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email "test@example.com"
  git -C "$FIXTURE_REPO" config user.name "Test"

  cat > "$FIXTURE_REPO/package.json" <<'EOF'
{
  "name": "fixture-package",
  "version": "1.2.3"
}
EOF

  cat > "$FIXTURE_REPO/distribute.config.json" <<'EOF'
{
  "distribute": {
    "include": ["skills"]
  }
}
EOF

  mkdir -p "$FIXTURE_REPO/skills/some-skill"
  echo "placeholder" > "$FIXTURE_REPO/skills/some-skill/SKILL.md"

  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -q -m "fixture: minimal distributable monorepo"

  # The consuming project target. jenga.config.json is intentionally absent
  # (first-distribution path) -- irrelevant to REPO_ROOT resolution.
  TARGET_PROJECT="$BATS_TEST_TMPDIR/target-project"
  mkdir -p "$TARGET_PROJECT"
}

# Copies the real, current (already-fixed) script under test to a given
# location inside the fixture repo -- so the test exercises the actual fix,
# not a reimplementation of it.
install_script_at() {
  local dest_dir="$1"
  mkdir -p "$dest_dir"
  cp "$REPO_ROOT/$SCRIPT_REL" "$dest_dir/distribute-changes.sh"
  chmod +x "$dest_dir/distribute-changes.sh"
}

@test "REPO_ROOT resolves correctly from the script's real source location (skills/j-distribute/scripts/)" {
  install_script_at "$FIXTURE_REPO/skills/j-distribute/scripts"

  run bash "$FIXTURE_REPO/skills/j-distribute/scripts/distribute-changes.sh" "$TARGET_PROJECT" --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "Monorepo root : $FIXTURE_REPO"
  assert_output_contains "Dry run complete"
}

@test "REPO_ROOT resolves correctly from a simulated .claude/ mirror location, where the old fixed climb landed on .claude/ instead of the repo root" {
  install_script_at "$FIXTURE_REPO/.claude/skills/j-distribute/scripts"

  # Sanity check on the bug this guards against: the OLD fixed "../../.."
  # climb from this mirror location resolves to $FIXTURE_REPO/.claude, not
  # $FIXTURE_REPO -- and distribute.config.json does not exist under
  # .claude/.
  old_style_root="$(cd "$FIXTURE_REPO/.claude/skills/j-distribute/scripts/../../.." && pwd)"
  [ "$old_style_root" = "$FIXTURE_REPO/.claude" ]
  [ ! -f "$old_style_root/distribute.config.json" ]

  run bash "$FIXTURE_REPO/.claude/skills/j-distribute/scripts/distribute-changes.sh" "$TARGET_PROJECT" --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "Monorepo root : $FIXTURE_REPO"
  assert_output_contains "Dry run complete"
}

@test "falls back to the ../../.. climb and still resolves correctly when not inside a git repository at the script's own real-depth location" {
  # A plain directory tree at the same real depth (scripts/ -> j-distribute/
  # -> skills/ -> root) but with no .git anywhere above it -- the documented
  # fallback case. The fallback climb must land on the tree's own root, not
  # error out or resolve somewhere else -- proven here by the script's own
  # "Monorepo root :" info line naming the resolved path, and by it failing
  # for the RIGHT reason (missing distribute.config.json at that resolved
  # root) rather than some unrelated path.
  NONGIT_DIR="$BATS_TEST_TMPDIR/nongit"
  mkdir -p "$NONGIT_DIR/skills/j-distribute/scripts"
  cp "$REPO_ROOT/$SCRIPT_REL" "$NONGIT_DIR/skills/j-distribute/scripts/distribute-changes.sh"
  chmod +x "$NONGIT_DIR/skills/j-distribute/scripts/distribute-changes.sh"
  mkdir -p "$NONGIT_DIR/nongit-target"

  run bash "$NONGIT_DIR/skills/j-distribute/scripts/distribute-changes.sh" "$NONGIT_DIR/nongit-target" --dry-run
  [ "$status" -eq 2 ]
  assert_output_contains "Monorepo root : $NONGIT_DIR"
  assert_output_contains "distribute.config.json not found at $NONGIT_DIR/distribute.config.json"
}
