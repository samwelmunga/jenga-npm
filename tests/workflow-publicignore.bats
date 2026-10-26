#!/usr/bin/env bats
#
# E80_S01_T08: `project/.workflows/` is blocklisted in .publicignore (project-local workflow
# definitions are per-project, never shipped) and documented in the public-mirror parity doc,
# mirroring the `project/.playbooks/` treatment (E28_S14_T01).
#
# Read-only: asserts against the repository's real .publicignore and parity doc; writes nothing.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PUBLICIGNORE="$REPO_ROOT/.publicignore"
PARITY_DOC="$REPO_ROOT/project/documentation/public-mirror-content-parity.md"

@test ".publicignore contains the exact line project/.workflows/" {
  run grep -Fxc 'project/.workflows/' "$PUBLICIGNORE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test ".publicignore entry is preceded by a comment block explaining it" {
  line="$(grep -Fxn 'project/.workflows/' "$PUBLICIGNORE" | cut -d: -f1)"
  [ -n "$line" ]
  # The line directly above the entry is a comment, and the block names the directory.
  prev="$(sed -n "$((line - 1))p" "$PUBLICIGNORE")"
  [[ "$prev" == '#'* ]]
  run grep -F '# `project/.workflows/` is per-project' "$PUBLICIGNORE"
  [ "$status" -eq 0 ]
}

@test ".publicignore does not blocklist the shipped templates/workflows/ builtins" {
  run grep -Ex '/?templates/workflows/?.*|/?templates/?' "$PUBLICIGNORE"
  [ "$status" -ne 0 ]
}

@test "parity doc mentions project/.workflows/ and that templates/workflows/ ships" {
  run grep -F 'project/.workflows/' "$PARITY_DOC"
  [ "$status" -eq 0 ]
  run grep -F 'templates/workflows/' "$PARITY_DOC"
  [ "$status" -eq 0 ]
  run grep -F '## Project-local workflows are private: `project/.workflows/`' "$PARITY_DOC"
  [ "$status" -eq 0 ]
}
