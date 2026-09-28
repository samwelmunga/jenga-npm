#!/usr/bin/env bats
#
# Regression coverage for E46_S02_T02: add_trivial_task.sh's REPO_ROOT used
# to be a fixed "three levels up" BASH_SOURCE climb
# (skills/j-todo/scripts/../../..). That only lands on the real repo root
# when the script runs from its monorepo source location. Once mirrored to
# .claude/skills/j-todo/scripts/ (the self-sync mirror target) or
# .agents/skills/j-todo/scripts/ (the npm postinstall mirror target), the
# same climb lands on .claude/ (or .agents/) instead, and the script then
# looks for project/board/tasks at .claude/project/board/tasks -- which
# never exists -- instead of the real project/board/tasks.
#
# Fixed by resolving REPO_ROOT via `git rev-parse --show-toplevel`, the same
# approach already used by this story's sibling task E46_S02_T01
# (skills/j-close-story/scripts/check-story-closeable.sh,
# check-privatized.sh:138, compute-scope-divergence.sh:54).
#
# Every test below runs the real, current (already-fixed) script end-to-end
# against a throwaway $BATS_TEST_TMPDIR fixture git repo, with all of its
# real runtime dependencies (scripts/with-lock.sh, scripts/todo_manager.sh,
# skills/j-todo/scripts/update_story_tasks.py,
# skills/j-todo/assets/todo_template.md) copied alongside it -- never against
# this repository's own board contents (E43/init.bats fixture-tree
# convention, same as tests/check-story-closeable-root-climb.bats).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT_REL="skills/j-todo/scripts/add_trivial_task.sh"

setup() {
  FIXTURE_REPO="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email "test@example.com"
  git -C "$FIXTURE_REPO" config user.name "Test"

  mkdir -p "$FIXTURE_REPO/project/board/stories" "$FIXTURE_REPO/project/board/tasks"
  mkdir -p "$FIXTURE_REPO/scripts"
  mkdir -p "$FIXTURE_REPO/skills/j-todo/scripts" "$FIXTURE_REPO/skills/j-todo/assets"

  # Real runtime dependencies the script under test shells out to, copied
  # verbatim so the test exercises the actual current implementations, not
  # reimplementations of them.
  cp "$REPO_ROOT/scripts/with-lock.sh" "$FIXTURE_REPO/scripts/with-lock.sh"
  cp "$REPO_ROOT/scripts/todo_manager.sh" "$FIXTURE_REPO/scripts/todo_manager.sh"
  cp "$REPO_ROOT/skills/j-todo/scripts/update_story_tasks.py" "$FIXTURE_REPO/skills/j-todo/scripts/update_story_tasks.py"
  cp "$REPO_ROOT/skills/j-todo/assets/todo_template.md" "$FIXTURE_REPO/skills/j-todo/assets/todo_template.md"
  chmod +x "$FIXTURE_REPO/scripts/with-lock.sh" "$FIXTURE_REPO/scripts/todo_manager.sh"

  cat > "$FIXTURE_REPO/project/board/stories/E99_S01_sample-story.md" <<'EOF'
---
id: E99_S01
epic_id: E99
status: In Progress
tasks: []
---

# Sample story
EOF

  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -q -m "fixture: sample story"
}

# Copies the real, current (already-fixed) script under test to a given
# location inside the fixture repo -- so the test exercises the actual fix,
# not a reimplementation of it.
install_script_at() {
  local dest_dir="$1"
  mkdir -p "$dest_dir"
  cp "$REPO_ROOT/$SCRIPT_REL" "$dest_dir/add_trivial_task.sh"
  chmod +x "$dest_dir/add_trivial_task.sh"
}

@test "REPO_ROOT resolves correctly from the script's real source location (skills/j-todo/scripts/)" {
  install_script_at "$FIXTURE_REPO/skills/j-todo/scripts"

  run bash "$FIXTURE_REPO/skills/j-todo/scripts/add_trivial_task.sh" \
    --story E99_S01 --title "Sample trivial task" \
    --description "A sample description." \
    --criteria "First criterion|Second criterion" \
    --computed-tier task --est-files 1 --est-lines 5

  [ "$status" -eq 0 ]
  assert_output_contains "E99_S01_T01"
  [ -f "$FIXTURE_REPO/project/board/tasks/E99_S01_T01_sample-trivial-task.md" ]
  grep -q "id: E99_S01_T01" "$FIXTURE_REPO/project/board/tasks/E99_S01_T01_sample-trivial-task.md"
}

@test "REPO_ROOT resolves correctly from a simulated .claude/ mirror location, where the old fixed climb landed one level too shallow" {
  install_script_at "$FIXTURE_REPO/.claude/skills/j-todo/scripts"

  # Sanity check on the bug this guards against: the OLD fixed
  # "../../.." BASH_SOURCE climb from this mirror location resolves to
  # $FIXTURE_REPO/.claude, not $FIXTURE_REPO -- and project/board/tasks does
  # not exist under .claude/.
  old_style_root="$(cd "$FIXTURE_REPO/.claude/skills/j-todo/scripts/../../.." && pwd)"
  [ "$old_style_root" = "$FIXTURE_REPO/.claude" ]
  [ ! -d "$old_style_root/project/board/tasks" ]

  run bash "$FIXTURE_REPO/.claude/skills/j-todo/scripts/add_trivial_task.sh" \
    --story E99_S01 --title "Mirror trivial task" \
    --description "A sample description from the mirror location." \
    --criteria "Only criterion" \
    --computed-tier inline --est-files 1 --est-lines 3

  [ "$status" -eq 0 ]
  assert_output_contains "E99_S01_T01"
  [ -f "$FIXTURE_REPO/project/board/tasks/E99_S01_T01_mirror-trivial-task.md" ]
  # Written to the REAL project/board/tasks at the repo root, not under
  # .claude/ -- this is what the fix guarantees.
  [ ! -d "$FIXTURE_REPO/.claude/project" ]
}

@test "REPO_ROOT resolves correctly from a simulated .agents/ mirror location (npm postinstall mirror target)" {
  install_script_at "$FIXTURE_REPO/.agents/skills/j-todo/scripts"

  run bash "$FIXTURE_REPO/.agents/skills/j-todo/scripts/add_trivial_task.sh" \
    --story E99_S01 --title "Agents mirror trivial task" \
    --description "A sample description from the .agents mirror location." \
    --criteria "Only criterion" \
    --computed-tier inline --est-files 1 --est-lines 3

  [ "$status" -eq 0 ]
  assert_output_contains "E99_S01_T01"
  [ -f "$FIXTURE_REPO/project/board/tasks/E99_S01_T01_agents-mirror-trivial-task.md" ]
  [ ! -d "$FIXTURE_REPO/.agents/project" ]
}
