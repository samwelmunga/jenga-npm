#!/usr/bin/env bats
#
# E76_S02_T05: grep-level checks that the three task-looping skills call `task-usage.sh --persist`, that the call is
# guarded by an explicit existence test (public-mirror guard, E76 epic decision 6: the script is blocklisted from the
# public mirror, so an absent script must make every call site a silent no-op), and that the skills that do not loop
# over tasks stay unwired. Nothing here runs the script or touches the board.
#
# E76 ships publicly (decided 2026-11-07), so this file ships and must not depend on anything private.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

WIRED=(skills/j-do/SKILL.md skills/j-dooo/SKILL.md skills/jenga/SKILL.md)
NOT_WIRED=(skills/j-proceed/SKILL.md skills/j-continue/SKILL.md skills/j-redo/SKILL.md)

# The repo's script-location idiom, verbatim
IDIOM='[ -f scripts/task-usage.sh ] && echo scripts/task-usage.sh || echo node_modules/@jenga-ai/agent/scripts/task-usage.sh'

@test "each looping skill calls task-usage.sh --persist --task" {
  for f in "${WIRED[@]}"; do
    grep -Eq 'task-usage\.sh.*--persist --task <id>' "$REPO_ROOT/$f" || { echo "$f does not call task-usage.sh --persist --task <id>"; return 1; }
  done
}

@test "each call site uses the repo's script-location idiom" {
  for f in "${WIRED[@]}"; do
    grep -Fq "$IDIOM" "$REPO_ROOT/$f" || { echo "$f does not use the script-location idiom"; return 1; }
  done
}

@test "public-mirror guard: each call site states the existence test and a silent no-op" {
  for f in "${WIRED[@]}"; do
    grep -Fq 'Existence test' "$REPO_ROOT/$f" || { echo "$f states no existence test"; return 1; }
    grep -Fq 'neither' "$REPO_ROOT/$f" || { echo "$f does not name the both-locations-absent case"; return 1; }
    grep -Fq 'public mirror' "$REPO_ROOT/$f" || { echo "$f does not say why (public mirror)"; return 1; }
    grep -Eqi 'do nothing' "$REPO_ROOT/$f" || { echo "$f does not say the call is a no-op"; return 1; }
    grep -Eqi 'no output|print nothing' "$REPO_ROOT/$f" || { echo "$f does not say the no-op prints nothing"; return 1; }
  done
}

@test "public-mirror guard: the existence test is false in a tree that holds the script in neither location" {
  local d="$BATS_TEST_TMPDIR/mirror"
  mkdir -p "$d"
  cd "$d"
  run bash -c '[ -f scripts/task-usage.sh ] || [ -f node_modules/@jenga-ai/agent/scripts/task-usage.sh ]'
  [ "$status" -ne 0 ]
  # and true in this repository, where the script ships
  cd "$REPO_ROOT"
  run bash -c '[ -f scripts/task-usage.sh ] || [ -f node_modules/@jenga-ai/agent/scripts/task-usage.sh ]'
  [ "$status" -eq 0 ]
}

@test "the persist step is non-blocking: each call site says it never changes the outcome" {
  for f in "${WIRED[@]}"; do
    grep -Eq 'never (changes|alters)' "$REPO_ROOT/$f" || { echo "$f does not state the call is non-blocking"; return 1; }
    grep -Fq 'possibly incomplete' "$REPO_ROOT/$f" || { echo "$f does not report the possibly incomplete outcome"; return 1; }
    grep -Fq 'not measured' "$REPO_ROOT/$f" || { echo "$f does not report the not measured outcome"; return 1; }
  done
}

@test "skills that do not execute tasks in a loop are not wired" {
  for f in "${NOT_WIRED[@]}"; do
    [ -f "$REPO_ROOT/$f" ] || { echo "$f is missing"; return 1; }
    if grep -Fq 'task-usage.sh' "$REPO_ROOT/$f"; then echo "$f unexpectedly references task-usage.sh"; return 1; fi
  done
}

@test "E76 ships publicly: .publicignore no longer blocks the task-usage tests (reversed 2026-11-07)" {
  [ -f "$REPO_ROOT/.publicignore" ] || skip ".publicignore is not part of the public tree"
  run grep -Fx 'tests/task-usage*.bats' "$REPO_ROOT/.publicignore"
  [ "$status" -ne 0 ]
}

@test "task-usage.md lists the three call sites as persist trigger points" {
  local doc="$REPO_ROOT/project/documentation/task-usage.md"
  grep -Fq 'j.close-story' "$doc"
  grep -Fq 'j.do' "$doc"
  grep -Fq 'j.dooo' "$doc"
  grep -Fq '/jenga' "$doc"
}
