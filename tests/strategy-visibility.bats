#!/usr/bin/env bats
#
# E34_S07_T06: the strategy brief lives at project/documentation/STRATEGY.md, so it is covered by the
# single `project/` entry that `project_files_visibility: ignored` adds to .gitignore, and it is a
# normal trackable file under `visible`. Both outcomes are asserted against the REAL
# skills/j-init/scripts/apply-project-visibility.sh (not a copy, not a mock) in a throwaway git repo
# under $BATS_TEST_TMPDIR; this repo's .gitignore and working tree are never touched.
#
# The accepted cost of E34_S07 (a consumer who ignores Jenga files has the brief ignored with them)
# is documented in docs/README.md, "STRATEGY.md placement". The last test records the contrast: a
# brief left at the legacy docs/STRATEGY.md is NOT ignored, because only `project/` is a working path.
#
# Only public-mirror files are referenced (skills/j-init/scripts/ is not blocklisted by
# .publicignore), so no skip guard for private paths is needed
# (project/documentation/public-mirror-content-parity.md).

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
APPLY="$REPO_ROOT/skills/j-init/scripts/apply-project-visibility.sh"

setup() {
  if ! command -v jq >/dev/null 2>&1; then
    skip "SKIPPED (no coverage): jq is required by apply-project-visibility.sh and is not installed"
  fi
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/documentation" "$PROJ/docs"
  git -C "$PROJ" init -q
  echo "# Strategy" > "$PROJ/project/documentation/STRATEGY.md"
  echo "# Legacy strategy" > "$PROJ/docs/STRATEGY.md"
}

@test "ignored: project/documentation/STRATEGY.md is gitignored by the existing project/ entry" {
  run bash "$APPLY" ignored "$PROJ"
  [ "$status" -eq 0 ]
  run git -C "$PROJ" check-ignore -q project/documentation/STRATEGY.md
  [ "$status" -eq 0 ]
  # Covered by the one `project/` entry: nothing names the brief in .gitignore.
  run grep -c 'STRATEGY' "$PROJ/.gitignore"
  [ "$output" = "0" ]
  run grep -cx 'project/' "$PROJ/.gitignore"
  [ "$output" = "1" ]
}

@test "visible: project/documentation/STRATEGY.md is not ignored and shows in git status" {
  run bash "$APPLY" visible "$PROJ"
  [ "$status" -eq 0 ]
  run git -C "$PROJ" check-ignore -q project/documentation/STRATEGY.md
  [ "$status" -eq 1 ]
  run git -C "$PROJ" status --porcelain --untracked-files=all
  [ "$status" -eq 0 ]
  assert_output_contains "?? project/documentation/STRATEGY.md"
}

@test "visible: the brief can be staged and shows as added" {
  run bash "$APPLY" visible "$PROJ"
  [ "$status" -eq 0 ]
  git -C "$PROJ" add project/documentation/STRATEGY.md
  run git -C "$PROJ" status --porcelain --untracked-files=all
  assert_output_contains "A  project/documentation/STRATEGY.md"
}

@test "ignored: a brief left at the legacy docs/STRATEGY.md is not ignored (the accepted cost, in contrast)" {
  run bash "$APPLY" ignored "$PROJ"
  [ "$status" -eq 0 ]
  run git -C "$PROJ" check-ignore -q docs/STRATEGY.md
  [ "$status" -eq 1 ]
}
