#!/usr/bin/env bats
#
# Regression coverage for validate-board.sh's strict-YAML gate.
#
# Why this file exists
# ---------------------
# validate-board.sh parses frontmatter with a hand-rolled line splitter, which
# is considerably more lenient than YAML itself. That gap let 36 board files
# accumulate frontmatter the validator called valid but every real consumer --
# the dashboard's board parser among them -- silently skipped. The board
# under-reported itself and nothing anywhere surfaced an error; the breakage was
# only found by accident, while snapshotting a consumer project.
#
# So the point of this suite is narrow and specific: prove the validator now
# REJECTS each of the three shapes that actually got through, and still accepts
# a well-formed file. Each test is a real observed failure, not a hypothetical.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/board"
  mkdir -p "$FIXTURE_DIR"
}

# Writes a story fixture whose frontmatter body is supplied verbatim, so each
# test states exactly the shape it is pinning.
write_story() {
  cat > "$FIXTURE_DIR/$1" <<EOF
---
$2
---

## Description

Fixture.
EOF
}

@test "accepts well-formed frontmatter" {
  write_story "E99_S01_ok.md" "id: E99_S01
epic_id: E99
title: A perfectly ordinary title
status: Done
date_created: 2026-01-01
tasks:
  - E99_S01_T01"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S01_ok.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (story)"
}

# Observed in 22 files, e.g. `title: Adopt j: prefix for skill invocation`.
@test "rejects an unquoted colon in a scalar value" {
  write_story "E99_S02_colon.md" "id: E99_S02
epic_id: E99
title: Adopt j: prefix for skill invocation
status: Done
date_created: 2026-01-01
tasks:
  - E99_S02_T01"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S02_colon.md"
  [ "$status" -ne 0 ]
  assert_output_contains "not valid YAML"
}

# Observed in 4 files, e.g. `title: "Merged" Status via /self-sync` -- the value
# starts with a quote but is not a quoted scalar, which YAML rejects outright.
@test "rejects a value that merely starts with a double quote" {
  write_story "E99_S03_quote.md" 'id: E99_S03
epic_id: E99
title: "Merged" Status via /self-sync
status: Done
date_created: 2026-01-01
tasks:
  - E99_S03_T01'

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S03_quote.md"
  [ "$status" -ne 0 ]
  assert_output_contains "not valid YAML"
}

# Observed in 9 files. The schema itself used to document this invalid form as
# the way to record multiple reopen cycles, so every file that followed the
# schema became unparseable.
@test "rejects comma-separated quoted strings in reopened_reason" {
  write_story "E99_S04_reasons.md" 'id: E99_S04
epic_id: E99
title: Reopened twice
status: Done
date_created: 2026-01-01
reopened_reason: "Scope expanded", "Bug found post-release"
tasks:
  - E99_S04_T01'

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S04_reasons.md"
  [ "$status" -ne 0 ]
  assert_output_contains "not valid YAML"
}

@test "accepts reopened_reason written as a YAML list" {
  write_story "E99_S05_list.md" 'id: E99_S05
epic_id: E99
title: Reopened twice
status: Done
date_created: 2026-01-01
reopened_reason:
  - "Scope expanded"
  - "Bug found post-release"
tasks:
  - E99_S05_T01'

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S05_list.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (story)"
}

# Observed in 1 file. Some YAML loaders accept this as last-wins, which is worse
# than rejecting it: one of the two task lists disappears without a trace.
@test "rejects a duplicated frontmatter key" {
  write_story "E99_S06_dup.md" "id: E99_S06
epic_id: E99
title: Duplicated key
status: Done
date_created: 2026-01-01
tasks: [E99_S06_T01, E99_S06_T02]
tasks:
  - E99_S06_T03"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S06_dup.md"
  [ "$status" -ne 0 ]
  assert_output_contains "duplicated frontmatter key 'tasks'"
}

@test "the error message points at the schema section that explains the fix" {
  write_story "E99_S07_msg.md" "id: E99_S07
epic_id: E99
title: Broken: here
status: Done
date_created: 2026-01-01
tasks:
  - E99_S07_T01"

  run bash "$VALIDATE" "$FIXTURE_DIR/E99_S07_msg.md"
  [ "$status" -ne 0 ]
  assert_output_contains "SCRUM_BOARD_SCHEMA.md"
}

# The whole reason this class went unnoticed for 36 files is that nothing ran
# the validator across the board. This test does, so a regression fails here.
@test "every board file in this repo passes validation" {
  run bash -c "bash '$VALIDATE' '$REPO_ROOT'/project/board/epics/*.md '$REPO_ROOT'/project/board/stories/*.md '$REPO_ROOT'/project/board/tasks/*.md 2>&1 | grep '❌' | grep -v 'unknown frontmatter field' | grep -v 'docs must be a YAML list'"
  # grep exits 1 when it finds nothing -- which is the passing condition here.
  # The two exclusions above are pre-existing, non-YAML schema violations
  # (E19/E57's supersedes pair, and three E41 tasks with an empty docs:) that
  # are tracked separately; this test guards the YAML class specifically.
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
