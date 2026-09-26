#!/usr/bin/env bats
#
# Regression coverage for E46_S02_T01: check-story-closeable.sh's PROJECT_ROOT
# used to be a fixed "three levels up" climb from the script's own directory
# (skills/j-close-story/scripts/../../..). That only lands on the real repo
# root when the script runs from its monorepo source location. Once mirrored
# to .claude/skills/j-close-story/scripts/ (the self-sync mirror target), the
# same climb lands on .claude/ instead, and the script then looks for
# project/board/stories at .claude/project/board/stories -- which never
# exists -- instead of the real project/board/stories.
#
# Fixed by resolving PROJECT_ROOT via `git rev-parse --show-toplevel`, the
# same approach already used by this script's siblings in the same directory:
#   - check-privatized.sh:138
#   - compute-scope-divergence.sh:54
#
# Every test below runs against a throwaway $BATS_TEST_TMPDIR fixture git
# repo, never against this repository's own board contents (E43/init.bats
# fixture-tree convention).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT_REL="skills/j-close-story/scripts/check-story-closeable.sh"

setup() {
  FIXTURE_REPO="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -q
  # A commit isn't required for `git rev-parse --show-toplevel` to work, but
  # keep the fixture a normal, non-degenerate repo.
  git -C "$FIXTURE_REPO" config user.email "test@example.com"
  git -C "$FIXTURE_REPO" config user.name "Test"

  mkdir -p "$FIXTURE_REPO/project/board/stories" "$FIXTURE_REPO/project/board/tasks"

  cat > "$FIXTURE_REPO/project/board/stories/E99_S01_sample-story.md" <<'EOF'
---
id: E99_S01
status: In Progress
tasks:
  - E99_S01_T01
---

# Sample story
EOF

  cat > "$FIXTURE_REPO/project/board/tasks/E99_S01_T01_sample-task.md" <<'EOF'
---
id: E99_S01_T01
status: Passed
---

# Sample task
EOF

  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -q -m "fixture: sample story + task"
}

# Copies the real, current (already-fixed) script under test to a given
# location inside the fixture repo -- so the test exercises the actual fix,
# not a reimplementation of it.
install_script_at() {
  local dest_dir="$1"
  mkdir -p "$dest_dir"
  cp "$REPO_ROOT/$SCRIPT_REL" "$dest_dir/check-story-closeable.sh"
  chmod +x "$dest_dir/check-story-closeable.sh"
}

@test "PROJECT_ROOT resolves correctly from the script's real source location (skills/j-close-story/scripts/)" {
  install_script_at "$FIXTURE_REPO/skills/j-close-story/scripts"

  run bash "$FIXTURE_REPO/skills/j-close-story/scripts/check-story-closeable.sh" E99_S01
  [ "$status" -eq 0 ]
  assert_output_contains "CLOSEABLE"
}

@test "PROJECT_ROOT resolves correctly from a simulated .claude/ mirror location, where the old fixed climb landed on .claude/ instead of the repo root" {
  install_script_at "$FIXTURE_REPO/.claude/skills/j-close-story/scripts"

  # Sanity check on the bug this guards against: the OLD fixed "../../.."
  # climb from this mirror location resolves to $FIXTURE_REPO/.claude, not
  # $FIXTURE_REPO -- and project/board/stories does not exist under .claude/.
  old_style_root="$(cd "$FIXTURE_REPO/.claude/skills/j-close-story/scripts/../../.." && pwd)"
  [ "$old_style_root" = "$FIXTURE_REPO/.claude" ]
  [ ! -d "$old_style_root/project/board/stories" ]

  run bash "$FIXTURE_REPO/.claude/skills/j-close-story/scripts/check-story-closeable.sh" E99_S01
  [ "$status" -eq 0 ]
  assert_output_contains "CLOSEABLE"
}

@test "reports OPEN (not a false CLOSEABLE) when a task is still in progress, from the .claude/ mirror location" {
  install_script_at "$FIXTURE_REPO/.claude/skills/j-close-story/scripts"

  cat > "$FIXTURE_REPO/project/board/tasks/E99_S01_T01_sample-task.md" <<'EOF'
---
id: E99_S01_T01
status: In Progress
---

# Sample task
EOF

  run bash "$FIXTURE_REPO/.claude/skills/j-close-story/scripts/check-story-closeable.sh" E99_S01
  [ "$status" -eq 1 ]
  assert_output_contains "OPEN"
}
