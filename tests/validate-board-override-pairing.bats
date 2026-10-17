#!/usr/bin/env bats
#
# Regression coverage for validate-board.sh's jenga_assigned / override_justification
# pairing rule.
#
# Why this file exists
# ---------------------
# templates/SCRUM_BOARD_SCHEMA.md has always said override_justification is
# REQUIRED when jenga_assigned is false, but validate-board.sh only ever
# allow-listed the key -- it never checked the pairing. Nothing else did either,
# so the invalid combination accumulated silently across 35 task files.
#
# That is not a cosmetic drift. skills/j-do/SKILL.md's step 4.1 HALTS the
# dispatch on exactly this combination:
#
#   OVERRIDE VALIDATION ERROR [<task_id>]: jenga_assigned is false but
#   override_justification is missing or empty.
#
# So every one of those files was undispatchable -- /do refused to start work on
# it -- and the validator that exists to catch board defects reported it clean.
# Found on 2026-10-04 when /do E28_S18_T01 halted; 16 of the 35 were still
# Pending and therefore still unworkable at that point.
#
# The point of this suite is narrow: prove the validator now rejects the halting
# combination, and still accepts the three shapes that are genuinely valid. The
# pairing rule is the ONE such rule validate-board.sh enforces (crucial_level's
# and scope_rationale's equivalents are deliberately left to authoring
# discipline) precisely because this one blocks dispatch rather than just
# looking untidy.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-board.sh"

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/board"
  mkdir -p "$FIXTURE_DIR"
}

# Writes a task fixture carrying the supplied jenga_assigned /
# override_justification lines verbatim, so each test states exactly the pairing
# it is pinning. Everything else is a minimal valid task.
write_task() {
  local name="$1" pairing="$2"
  cat > "$FIXTURE_DIR/$name" <<EOF
---
id: E99_S01_T01
story_id: E99_S01
epic_id: E99
title: Pairing fixture
status: Pending
date_created: 2026-10-04
assigned_to: developer
execution_scope: task
scope_rationale: "touches 1 file"
$pairing
---

# Task: Pairing fixture

## Description

Fixture.
EOF
}

@test "rejects jenga_assigned: false with an empty override_justification" {
  write_task "bad.md" 'jenga_assigned: false
override_justification: ""'

  run bash "$VALIDATE" "$FIXTURE_DIR/bad.md"
  [ "$status" -ne 0 ]
  assert_output_contains "jenga_assigned: false requires a non-empty override_justification"
}

@test "rejects jenga_assigned: false with an absent override_justification" {
  write_task "missing.md" 'jenga_assigned: false'

  run bash "$VALIDATE" "$FIXTURE_DIR/missing.md"
  [ "$status" -ne 0 ]
  assert_output_contains "jenga_assigned: false requires a non-empty override_justification"
}

# A justification of only spaces satisfies "present and non-empty" to a naive
# check but carries no information, and /do's own guard would not be fooled by
# it either -- so neither is this one.
@test "rejects a whitespace-only override_justification" {
  write_task "blank.md" 'jenga_assigned: false
override_justification: "   "'

  run bash "$VALIDATE" "$FIXTURE_DIR/blank.md"
  [ "$status" -ne 0 ]
  assert_output_contains "jenga_assigned: false requires a non-empty override_justification"
}

# The actionable half of the message: a human reading the failure needs to know
# both why it blocks and what the usual correct fix is, because in practice the
# field is far more often wrong than the justification is missing.
@test "the refusal names the /do halt and the jenga_assigned: true fix" {
  write_task "bad2.md" 'jenga_assigned: false
override_justification: ""'

  run bash "$VALIDATE" "$FIXTURE_DIR/bad2.md"
  [ "$status" -ne 0 ]
  assert_output_contains "/do step 4.1 halts dispatch on this pairing"
  assert_output_contains "set jenga_assigned: true instead"
}

@test "accepts jenga_assigned: true with an empty override_justification" {
  write_task "machine.md" 'jenga_assigned: true
override_justification: ""'

  run bash "$VALIDATE" "$FIXTURE_DIR/machine.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (task)"
}

@test "accepts a genuine human override carrying a justification" {
  write_task "override.md" 'jenga_assigned: false
override_justification: "human narrowed scope on 2026-10-04: docs-only change"'

  run bash "$VALIDATE" "$FIXTURE_DIR/override.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (task)"
}

# Backward compatibility: templates/SCRUM_BOARD_SCHEMA.md's rule is that a task
# omitting all six execution-scope fields is valid and defaults to
# jenga_assigned: true, so the new check must not fire on legacy files.
@test "accepts a legacy task that omits the execution-scope fields entirely" {
  cat > "$FIXTURE_DIR/legacy.md" <<'EOF'
---
id: E99_S02_T01
story_id: E99_S02
epic_id: E99
title: Legacy task
status: Done
date_created: 2026-01-01
assigned_to: developer
---

# Task: Legacy task

## Description

Fixture.
EOF

  run bash "$VALIDATE" "$FIXTURE_DIR/legacy.md"
  [ "$status" -eq 0 ]
  assert_output_contains "board frontmatter valid (task)"
}
