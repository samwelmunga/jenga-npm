#!/usr/bin/env bats
#
# Regression coverage for E46_S02_T03: smoke_test.sh's REPO_ROOT used to be a
# fixed "three levels up" climb from the script's own directory
# (skills/index/scripts/../../..). That only lands on the real repo root when
# the script runs from its monorepo source location. Once mirrored to
# .claude/skills/index/scripts/ (self-sync mirror target), the same climb
# lands on .claude/ instead, and the embedded Python heredoc's leaked-reference
# check then looks for skills/index/scripts/board_index.py and board-index at
# .claude/skills/index/scripts/... -- which never exists -- instead of the
# real skills/index/scripts/.
#
# Fixed by resolving REPO_ROOT via `git rev-parse --show-toplevel`, falling
# back to the existing ../../.. climb only on git failure -- the same
# approach already used by this story's sibling tasks E46_S02_T01/T02 and by
# skills/j-publish/scripts/run_gates.sh:26-29.
#
# smoke_test.sh is maintainer-only, inherently unrunnable outside this
# monorepo's own checkout (it asserts hardcoded board-size thresholds and
# shells out to a sibling board-index CLI). To keep the fixture small, a fake
# board-index stub stands in for the real one, emitting just enough synthetic
# nodes/edges to satisfy those thresholds -- REPO_ROOT resolution is what's
# under test here, not board-index's own behavior. Every test below runs
# against a throwaway $BATS_TEST_TMPDIR fixture git repo, never against this
# repository's own board contents (E43/init.bats fixture-tree convention).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT_REL="skills/index/scripts/smoke_test.sh"

setup() {
  FIXTURE_REPO="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email "test@example.com"
  git -C "$FIXTURE_REPO" config user.name "Test"
  git -C "$FIXTURE_REPO" commit -q --allow-empty -m "fixture: empty init"

  # The script's leaked-reference check always looks at the CANONICAL
  # skills/index/scripts/ location relative to REPO_ROOT, regardless of where
  # smoke_test.sh itself is copied to -- so these two files must exist there
  # in every test, mirror-location or not.
  mkdir -p "$FIXTURE_REPO/skills/index/scripts"
  cat > "$FIXTURE_REPO/skills/index/scripts/board_index.py" <<'EOF'
# stub board_index.py for smoke_test.sh root-climb regression coverage
EOF
  install_fake_board_index "$FIXTURE_REPO/skills/index/scripts/board-index"
}

# A stand-in for the real board-index CLI, emitting the minimum synthetic
# nodes/edges smoke_test.sh's own thresholds require, so the script's
# unrelated business logic doesn't get in the way of testing REPO_ROOT
# resolution.
install_fake_board_index() {
  local dest="$1"
  cat > "$dest" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  graph::nodes)
    python3 - <<'PY'
import json

counts = {"Epic": 22, "Story": 90, "Task": 150, "TodoEntry": 10, "Skill": 5, "Agent": 2}
nodes = []
for node_type, count in counts.items():
    for i in range(count):
        nodes.append({"type": node_type, "id": f"{node_type}{i}"})
print(json.dumps(nodes))
PY
    ;;
  graph::edges)
    echo '[{"type": "contains"}, {"type": "queued_as"}]'
    ;;
  *)
    echo "fake board-index: unknown command: $1" >&2
    exit 1
    ;;
esac
FAKE
  chmod +x "$dest"
}

# Copies the real, current (already-fixed) script under test to a given
# location inside the fixture repo -- so the test exercises the actual fix,
# not a reimplementation of it. Also installs the fake board-index CLI
# alongside it, since smoke_test.sh invokes "$SCRIPT_DIR/board-index".
install_script_at() {
  local dest_dir="$1"
  mkdir -p "$dest_dir"
  cp "$REPO_ROOT/$SCRIPT_REL" "$dest_dir/smoke_test.sh"
  chmod +x "$dest_dir/smoke_test.sh"
  install_fake_board_index "$dest_dir/board-index"
}

@test "REPO_ROOT resolves correctly from the script's real source location (skills/index/scripts/)" {
  install_script_at "$FIXTURE_REPO/skills/index/scripts"

  run bash "$FIXTURE_REPO/skills/index/scripts/smoke_test.sh"
  [ "$status" -eq 0 ]
  assert_output_contains "SMOKE TEST PASSED"
}

@test "REPO_ROOT resolves correctly from a simulated .claude/ mirror location, where the old fixed climb landed on .claude/ instead of the repo root" {
  install_script_at "$FIXTURE_REPO/.claude/skills/index/scripts"

  # Sanity check on the bug this guards against: the OLD fixed "../../.."
  # climb from this mirror location resolves to $FIXTURE_REPO/.claude, not
  # $FIXTURE_REPO -- and the canonical skills/index/scripts/board_index.py
  # does not exist under .claude/.
  old_style_root="$(cd "$FIXTURE_REPO/.claude/skills/index/scripts/../../.." && pwd)"
  [ "$old_style_root" = "$FIXTURE_REPO/.claude" ]
  [ ! -f "$old_style_root/skills/index/scripts/board_index.py" ]

  run bash "$FIXTURE_REPO/.claude/skills/index/scripts/smoke_test.sh"
  [ "$status" -eq 0 ]
  assert_output_contains "SMOKE TEST PASSED"
}

@test "falls back to the ../../.. climb and still resolves correctly when not inside a git repository" {
  NONGIT_DIR="$BATS_TEST_TMPDIR/nongit"
  mkdir -p "$NONGIT_DIR/skills/index/scripts"
  cp "$REPO_ROOT/$SCRIPT_REL" "$NONGIT_DIR/skills/index/scripts/smoke_test.sh"
  chmod +x "$NONGIT_DIR/skills/index/scripts/smoke_test.sh"
  install_fake_board_index "$NONGIT_DIR/skills/index/scripts/board-index"
  cat > "$NONGIT_DIR/skills/index/scripts/board_index.py" <<'EOF'
# stub board_index.py for smoke_test.sh root-climb regression coverage
EOF

  run bash "$NONGIT_DIR/skills/index/scripts/smoke_test.sh"
  [ "$status" -eq 0 ]
  assert_output_contains "SMOKE TEST PASSED"
}
