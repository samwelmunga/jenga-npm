#!/usr/bin/env bats
#
# Mirror parity for the commit test gate (E72_S04_T07).
#
# skills/, agents/ and scripts/ at the repo root are canonical; .claude/ and .agents/ are generated mirrors that this
# repo's own session reads. The commit test gate (E72_S04_T01-T05) spans skills/j-commit/, skills/j-lgtm/,
# skills/j-dev-done/ and agents/developer.md. Each case below walks the ACTUAL file list under one of those source
# trees (not a hard-coded list), so a file added or edited at the root and not copied into both mirrors goes red.
# Same design as the byte-identity case in tests/j-test-skill.bats.
#
# Content only: files are compared with cmp, never by mode. Executable bits are set by the orchestrator, not tested here.
# Read-only: nothing is written anywhere. A checkout without the generated mirrors (a packed or installed copy) skips
# the mirror comparison, since it does not ship them.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIRRORS=".claude .agents"

# Assert every file under skills/<skill>/ exists byte-identically under <mirror>/skills/<skill>/, for both mirrors.
assert_skill_mirrored() {
  local skill="$1" src mirror file count=0
  src="$REPO_ROOT/skills/$skill"
  [ -d "$src" ]
  for mirror in $MIRRORS; do
    if [ ! -d "$REPO_ROOT/$mirror/skills" ]; then
      continue
    fi
    count=0
    for file in $(cd "$src" && find . -type f | sed 's|^\./||' | sort); do
      count=$((count + 1))
      if [ ! -f "$REPO_ROOT/$mirror/skills/$skill/$file" ]; then
        echo "missing from mirror: $mirror/skills/$skill/$file" >&2
        return 1
      fi
      if ! cmp -s "$src/$file" "$REPO_ROOT/$mirror/skills/$skill/$file"; then
        echo "differs from root: $mirror/skills/$skill/$file" >&2
        return 1
      fi
    done
    # An empty walk would pass vacuously; the source tree must have yielded files.
    [ "$count" -gt 0 ]
  done
}

@test "every file under skills/j-commit/ is byte-identical in the .claude/ and .agents/ mirrors" {
  assert_skill_mirrored j-commit
}

@test "every file under skills/j-lgtm/ is byte-identical in the .claude/ and .agents/ mirrors" {
  assert_skill_mirrored j-lgtm
}

@test "every file under skills/j-dev-done/ is byte-identical in the .claude/ and .agents/ mirrors" {
  [ -d "$REPO_ROOT/skills/j-dev-done" ] || skip "skills/j-dev-done is private and not shipped in the public mirror"
  assert_skill_mirrored j-dev-done
}

@test "agents/developer.md is byte-identical in the .claude/ and .agents/ mirrors" {
  local mirror
  [ -f "$REPO_ROOT/agents/developer.md" ]
  for mirror in $MIRRORS; do
    if [ ! -d "$REPO_ROOT/$mirror/agents" ]; then
      continue
    fi
    [ -f "$REPO_ROOT/$mirror/agents/developer.md" ]
    cmp "$REPO_ROOT/agents/developer.md" "$REPO_ROOT/$mirror/agents/developer.md"
  done
}

@test "the three commit test gate scripts exist at the root and in both mirror trees" {
  local mirror script
  for script in test-gate-decide.sh test-gate-scoped.sh test-gate-run.sh; do
    [ -f "$REPO_ROOT/skills/j-commit/scripts/$script" ]
    for mirror in $MIRRORS; do
      if [ ! -d "$REPO_ROOT/$mirror/skills" ]; then
        continue
      fi
      if [ ! -f "$REPO_ROOT/$mirror/skills/j-commit/scripts/$script" ]; then
        echo "missing from mirror: $mirror/skills/j-commit/scripts/$script" >&2
        return 1
      fi
    done
  done
}
