#!/usr/bin/env bats
#
# Regression coverage for E46_S02_T02: board_index.py's ROOT_DIR used to be
# a fixed-depth climb (Path(__file__).resolve().parents[3]), computed
# unconditionally at module scope and used throughout the file (board
# scanning, project/todo.md, skills/agents directory walks). That only
# lands on the real repo root when the script runs from its monorepo source
# location (skills/index/scripts/). Once mirrored to
# .claude/skills/index/scripts/ (self-sync mirror target) or
# .agents/skills/index/scripts/ (npm postinstall mirror target), the same
# climb lands on .claude/ (or .agents/) instead of the real repo root.
#
# Fixed by resolving ROOT_DIR via `git rev-parse --show-toplevel` from a
# subprocess call, falling back to Path.cwd() on failure -- the Python
# equivalent of the same pattern this story's sibling task E46_S02_T01
# established for the bash cases (check-story-closeable.sh,
# check-privatized.sh:138, compute-scope-divergence.sh:54).
#
# This repo has no pytest/unittest scaffold anywhere -- the established
# convention for testing a Python helper is a bats file that shells out to
# python3 (see tests/board-hygiene-playbook.bats,
# tests/populate-knowledge-graph.bats). Followed here. Every test runs
# against a throwaway $BATS_TEST_TMPDIR fixture git repo, never against this
# repository's own board contents (E43/init.bats fixture-tree convention).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT_REL="skills/index/scripts/board_index.py"

setup() {
  FIXTURE_REPO="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email "test@example.com"
  git -C "$FIXTURE_REPO" config user.name "Test"
  git -C "$FIXTURE_REPO" commit -q --allow-empty -m "fixture: empty init"
}

# Copies the real, current (already-fixed) script under test to a given
# location inside the fixture repo -- so the test exercises the actual fix,
# not a reimplementation of it.
install_script_at() {
  local dest_dir="$1"
  mkdir -p "$dest_dir"
  cp "$REPO_ROOT/$SCRIPT_REL" "$dest_dir/board_index.py"
}

# Imports the installed copy as a module and prints ROOT_DIR.
resolved_root() {
  local script_dir="$1"
  python3 - "$script_dir" <<'PY'
import importlib.util
import sys

script_dir = sys.argv[1]
spec = importlib.util.spec_from_file_location("board_index", f"{script_dir}/board_index.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.ROOT_DIR)
PY
}

@test "ROOT_DIR resolves correctly from the script's real source location (skills/index/scripts/)" {
  install_script_at "$FIXTURE_REPO/skills/index/scripts"

  run resolved_root "$FIXTURE_REPO/skills/index/scripts"
  [ "$status" -eq 0 ]
  expected="$(cd "$FIXTURE_REPO" && pwd -P)"
  [ "$output" = "$expected" ]
}

@test "ROOT_DIR resolves correctly from a simulated .claude/ mirror location, where the old fixed climb landed one level too shallow" {
  install_script_at "$FIXTURE_REPO/.claude/skills/index/scripts"

  # Sanity check on the bug this guards against: the OLD fixed
  # parents[3] climb from this mirror location resolves to
  # $FIXTURE_REPO/.claude, not $FIXTURE_REPO.
  old_style_root="$(cd "$FIXTURE_REPO/.claude/skills/index/scripts/../../.." && pwd)"
  [ "$old_style_root" = "$FIXTURE_REPO/.claude" ]

  run resolved_root "$FIXTURE_REPO/.claude/skills/index/scripts"
  [ "$status" -eq 0 ]
  expected="$(cd "$FIXTURE_REPO" && pwd -P)"
  [ "$output" = "$expected" ]
}

@test "ROOT_DIR resolves correctly from a simulated .agents/ mirror location (npm postinstall mirror target)" {
  install_script_at "$FIXTURE_REPO/.agents/skills/index/scripts"

  run resolved_root "$FIXTURE_REPO/.agents/skills/index/scripts"
  [ "$status" -eq 0 ]
  expected="$(cd "$FIXTURE_REPO" && pwd -P)"
  [ "$output" = "$expected" ]
}

@test "falls back to Path.cwd() when not inside a git repository" {
  NONGIT_DIR="$BATS_TEST_TMPDIR/nongit/skills/index/scripts"
  install_script_at "$NONGIT_DIR"

  run resolved_root "$NONGIT_DIR"
  [ "$status" -eq 0 ]
  expected="$(pwd -P)"
  [ "$output" = "$expected" ]
}
