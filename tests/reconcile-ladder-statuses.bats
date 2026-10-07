#!/usr/bin/env bats
#
# E17_S10 regression coverage: /j-reconcile must treat the script-set ladder statuses
# (Merged, Publicized, Privatized, Deployed to Stage, Deployed to Prod) as completed-and-beyond.
#
# Background: /j-reconcile's completed-status list was a hand-typed literal (Done, Passed,
# Passed with remarks) that omitted the ladder statuses, so Phase 3 "promoted" a Merged ticket
# back to Passed and overwrote its date_completed. The fix (E17_S10_T01) moves the vocabulary into
# skills/j-reconcile/scripts/completed-statuses.sh, which derives it from the Status Values table
# in templates/SCRUM_BOARD_SCHEMA.md, and rewords SKILL.md's Phases 2/3/4/6 around it.
#
# What can and cannot be tested: SKILL.md is prose executed by an agent. The deterministic seam is
# the classifier script, so these tests (1) exercise it against temp board fixtures through a small
# reference model of the Phase 2/3/4 decisions, and (2) pin the structural properties of the prose
# (no hand-typed list, vocabulary loaded before the --from-commit-skipped gate, each phase refers to
# the ladder). The reference model mirrors SKILL.md's wording; it is not the skill itself.
#
# Isolation: every fixture (board, schema copy, script copy) lives under $BATS_TEST_TMPDIR. The
# live project/board/ is never read or written. macOS bash 3.2 compatible; no `timeout` binary.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL="$REPO_ROOT/skills/j-reconcile/SKILL.md"
COMMIT_SKILL="$REPO_ROOT/skills/j-commit/SKILL.md"
REAL_SCHEMA="$REPO_ROOT/templates/SCRUM_BOARD_SCHEMA.md"

# A date no real ticket carries, so "overwritten with today" is unmistakable.
TODAY_STAMP="2099-01-01"
ORIGINAL_DATE="2026-09-01"

setup() {
  FIXTURE_REPO="$BATS_TEST_TMPDIR/fixture-repo"
  BOARD="$FIXTURE_REPO/project/board"
  mkdir -p "$BOARD/tasks" "$BOARD/stories" "$BOARD/epics" \
           "$FIXTURE_REPO/skills/j-reconcile/scripts" "$FIXTURE_REPO/templates"
  git -C "$FIXTURE_REPO" init -q

  # The script resolves the schema relative to itself, so copying both into the fixture means the
  # classifier reads the fixture schema, never anything under the live repo's board.
  cp "$REPO_ROOT/skills/j-reconcile/scripts/completed-statuses.sh" "$FIXTURE_REPO/skills/j-reconcile/scripts/"
  cp "$REAL_SCHEMA" "$FIXTURE_REPO/templates/SCRUM_BOARD_SCHEMA.md"
  CLASSIFY="$FIXTURE_REPO/skills/j-reconcile/scripts/completed-statuses.sh"
}

# --- fixture helpers ---------------------------------------------------------------------------

write_task() { # write_task <id> <status> [date_completed]
  local id="$1" status="$2" date="${3:-}"
  cat > "$BOARD/tasks/${id}_fixture.md" <<EOF
---
id: $id
story_id: ${id%_T*}
epic_id: ${id%%_*}
title: Fixture $id
status: $status
date_created: 2026-08-01
date_started: 2026-08-02
date_completed: $date
---

# Task: Fixture $id
EOF
}

write_story() { # write_story <id> <status>
  cat > "$BOARD/stories/${1}_fixture.md" <<EOF
---
id: $1
epic_id: ${1%%_*}
title: Fixture $1
status: $2
date_completed: $ORIGINAL_DATE
---

# Story: Fixture $1
EOF
}

field() { sed -n "s/^$2: *//p" "$1" | head -1; }
task_file() { echo "$BOARD/tasks/${1}_fixture.md"; }
story_file() { echo "$BOARD/stories/${1}_fixture.md"; }
checksum() { cksum < "$1"; }
set_field() { sed -i.bak "s/^$2:.*/$2: $3/" "$1"; rm -f "$1.bak"; }

# Reference model of /j-reconcile Phases 2, 3 and 4 for TASK files, driven by the real classifier.
#   CONFIRMED  space-separated task ids whose implementation is confirmed (Phases 2/3 evidence)
# completed  + unconfirmed (no branch)  -> Pending, dates cleared      (Phase 2)
# ladder     + unconfirmed (no branch)  -> untouched, reported         (Phase 2, report-only)
# incomplete + confirmed                -> Passed, date_completed=now  (Phase 3)
# ladder                                -> never a Phase 3 candidate
reconcile_tasks() {
  local f id st class
  for f in "$BOARD"/tasks/*.md; do
    id="$(field "$f" id)"; st="$(field "$f" status)"
    class="$("$CLASSIFY" --classify "$st")"
    case "$class" in
      ladder) : ;;
      completed)
        case " ${CONFIRMED:-} " in *" $id "*) : ;; *)
          set_field "$f" status Pending; set_field "$f" date_started ""; set_field "$f" date_completed "" ;;
        esac ;;
      incomplete|unknown)
        case " ${CONFIRMED:-} " in *" $id "*)
          set_field "$f" status Passed; set_field "$f" date_completed "$TODAY_STAMP" ;;
        esac ;;
    esac
  done
}

# Phase 4 rollup for one story: all tasks completed-or-beyond -> Done, unless the story is itself ladder.
rollup_story() { # rollup_story <story_id>
  local sid="$1" sf st t tst all=1
  sf="$(story_file "$sid")"; st="$(field "$sf" status)"
  [ "$("$CLASSIFY" --classify "$st")" = "ladder" ] && return 0
  for t in "$BOARD"/tasks/${sid}_T*_fixture.md; do
    tst="$(field "$t" status)"
    case "$("$CLASSIFY" --classify "$tst")" in completed|ladder) : ;; *) all=0 ;; esac
  done
  [ "$all" -eq 1 ] && set_field "$sf" status Done
  return 0
}

# Asserts a ticket in the given status survives a full reconcile pass byte-for-byte.
assert_ladder_ticket_survives() {
  local status="$1" before after
  write_task E98_S01_T01 "$status" "$ORIGINAL_DATE"
  # A Pending sibling that IS promotable, so a pass that does nothing at all cannot pass this test.
  write_task E98_S01_T02 "Pending" ""
  before="$(checksum "$(task_file E98_S01_T01)")"
  CONFIRMED="E98_S01_T01 E98_S01_T02" reconcile_tasks
  after="$(checksum "$(task_file E98_S01_T01)")"
  [ "$(field "$(task_file E98_S01_T01)" status)" = "$status" ]
  [ "$(field "$(task_file E98_S01_T01)" date_completed)" = "$ORIGINAL_DATE" ]
  [ "$before" = "$after" ]
  # ...and the pass really ran: the genuinely incomplete sibling was promoted.
  [ "$(field "$(task_file E98_S01_T02)" status)" = "Passed" ]
  [ "$(field "$(task_file E98_S01_T02)" date_completed)" = "$TODAY_STAMP" ]
}

# --- one surviving-ticket case per ladder status -----------------------------------------------

@test "Merged ticket survives a reconcile pass unchanged" {
  [ "$("$CLASSIFY" --classify "Merged")" = "ladder" ]
  assert_ladder_ticket_survives "Merged"
}

@test "Publicized ticket survives a reconcile pass unchanged" {
  [ "$("$CLASSIFY" --classify "Publicized")" = "ladder" ]
  assert_ladder_ticket_survives "Publicized"
}

@test "Privatized ticket survives a reconcile pass unchanged" {
  [ "$("$CLASSIFY" --classify "Privatized")" = "ladder" ]
  assert_ladder_ticket_survives "Privatized"
}

@test "Deployed to Stage ticket survives a reconcile pass unchanged" {
  [ "$("$CLASSIFY" --classify "Deployed to Stage")" = "ladder" ]
  assert_ladder_ticket_survives "Deployed to Stage"
}

@test "Deployed to Prod ticket survives a reconcile pass unchanged" {
  [ "$("$CLASSIFY" --classify "Deployed to Prod")" = "ladder" ]
  assert_ladder_ticket_survives "Deployed to Prod"
}

# --- date_completed preservation ---------------------------------------------------------------

@test "date_completed is preserved, not overwritten with today, for every ladder status" {
  local s i=0
  for s in "Merged" "Publicized" "Privatized" "Deployed to Stage" "Deployed to Prod"; do
    i=$((i + 1))
    write_task "E97_S01_T0$i" "$s" "$ORIGINAL_DATE"
  done
  CONFIRMED="E97_S01_T01 E97_S01_T02 E97_S01_T03 E97_S01_T04 E97_S01_T05" reconcile_tasks
  for i in 1 2 3 4 5; do
    [ "$(field "$(task_file "E97_S01_T0$i")" date_completed)" = "$ORIGINAL_DATE" ]
  done
}

@test "an unconfirmable ladder ticket is never demoted to Pending (report-only)" {
  write_task E96_S01_T01 "Merged" "$ORIGINAL_DATE"
  write_task E96_S01_T02 "Passed" "$ORIGINAL_DATE"
  CONFIRMED="" reconcile_tasks
  [ "$(field "$(task_file E96_S01_T01)" status)" = "Merged" ]
  [ "$(field "$(task_file E96_S01_T01)" date_completed)" = "$ORIGINAL_DATE" ]
  # Control: a plain completed status with no evidence still demotes, so the exemption is ladder-only.
  [ "$(field "$(task_file E96_S01_T02)" status)" = "Pending" ]
  [ "$(field "$(task_file E96_S01_T02)" date_completed)" = "" ]
}

@test "Phase 4: a ladder-status story is not rewritten to Done; a Passed story still rolls up" {
  write_story E95_S01 "Merged"
  write_task E95_S01_T01 "Merged" "$ORIGINAL_DATE"
  write_story E95_S02 "In Progress"
  write_task E95_S02_T01 "Merged" "$ORIGINAL_DATE"
  rollup_story E95_S01
  rollup_story E95_S02
  [ "$(field "$(story_file E95_S01)" status)" = "Merged" ]
  [ "$(field "$(story_file E95_S01)" date_completed)" = "$ORIGINAL_DATE" ]
  # All-ladder tasks count as completed for rollup, so an incomplete story over them does close out.
  [ "$(field "$(story_file E95_S02)" status)" = "Done" ]
}

# --- /j-commit --from-commit path --------------------------------------------------------------

@test "--from-commit: the vocabulary is loaded in Section 0, before the gate that the flag skips" {
  local load_line gate_line skip_line
  load_line="$(grep -n 'skills/j-reconcile/scripts/completed-statuses.sh' "$SKILL" | head -1 | cut -d: -f1)"
  gate_line="$(grep -n '^### Pre-reconcile gate' "$SKILL" | head -1 | cut -d: -f1)"
  skip_line="$(grep -n 'If `--from-commit` was passed' "$SKILL" | head -1 | cut -d: -f1)"
  [ -n "$load_line" ]
  [ -n "$gate_line" ]
  [ -n "$skip_line" ]
  [ "$load_line" -lt "$gate_line" ]
  [ "$gate_line" -lt "$skip_line" ]
}

@test "--from-commit: Section 0 states the vocabulary load applies to --from-commit runs too" {
  run sed -n '/^### 0\. Read configuration/,/^### Phase 0/p' "$SKILL"
  [ "$status" -eq 0 ]
  assert_output_contains "--from-commit"
  assert_output_contains "completed-statuses.sh"
}

@test "--from-commit: the skip clause removes only the gate, so it cannot skip the vocabulary" {
  run sed -n '/If `--from-commit` was passed/,/^- \*\*Otherwise\*\*/p' "$SKILL"
  [ "$status" -eq 0 ]
  assert_output_contains "do not fire the gate"
  assert_output_not_contains "completed-statuses"
}

@test "--from-commit: /j-commit invokes /reconcile with the flag and carries no status list of its own" {
  grep -q -- '--from-commit' "$COMMIT_SKILL"
  run grep -c -E 'Passed with remarks|Deployed to Prod|Merged' "$COMMIT_SKILL"
  [ "$output" = "0" ]
}

# --- structural: no hand-typed list, every completion-aware phase refers to the ladder ----------

@test "SKILL.md carries no hand-typed completed-status list" {
  run grep -c 'Passed with remarks' "$SKILL"
  [ "$output" = "0" ]
  run grep -c -E 'Publicized|Privatized|Deployed to' "$SKILL"
  [ "$output" = "0" ]
}

@test "SKILL.md Phases 2, 3, 4, DoD-gap and 6 each refer to the ladder / completed-or-beyond rule" {
  local sec
  for sec in '### 2\. Verify' '### 3\. Verify' '### 4\. Roll up' '#### DoD Gap Detection' '### 6\. Clean'; do
    run sed -n "/^${sec}/,/^###\{0,1\}#* [0-9A-Z]/p" "$SKILL"
    [ "$status" -eq 0 ]
    case "$output" in
      *ladder*|*completed-or-beyond*) : ;;
      *) echo "section '${sec}' mentions neither ladder nor completed-or-beyond" >&2; return 1 ;;
    esac
  done
}

@test "scripts under skills/j-reconcile/scripts carry no completed-status literal other than the classifier" {
  local f
  for f in "$REPO_ROOT"/skills/j-reconcile/scripts/*.sh; do
    case "$f" in */completed-statuses.sh) continue ;; esac
    run grep -c -E 'Passed with remarks|Deployed to (Stage|Prod)' "$f"
    [ "$output" = "0" ]
  done
}

# --- schema parity (story AC 6): the vocabulary tracks templates/SCRUM_BOARD_SCHEMA.md ----------

@test "parity: every status in the real schema table is classified, none unknown, none twice" {
  local table out s n
  table="$(awk '/^## Status Values/{f=1;next} f&&/^#/{exit} f&&/^\| *`/{s=$0; sub(/^\| *`/,"",s); sub(/`.*/,"",s); print s}' "$REAL_SCHEMA")"
  [ -n "$table" ]
  out="$("$CLASSIFY")"
  while IFS= read -r s; do
    [ "$("$CLASSIFY" --classify "$s")" != "unknown" ]
    n="$(printf '%s' "$out" | grep -o "\"$s\"" | wc -l | tr -d ' ')"
    [ "$n" = "1" ]
  done <<EOF
$table
EOF
}

@test "parity: the ladder class is exactly the five script-set statuses today" {
  run "$CLASSIFY"
  [ "$status" -eq 0 ]
  assert_output_contains '"ladder":["Merged","Publicized","Privatized","Deployed to Stage","Deployed to Prod"]'
  assert_output_contains '"completed":["Passed","Passed with remarks","Done"]'
}

@test "parity: a status added to the schema is picked up as ladder with no edit to reconcile" {
  # Append a new row to the fixture schema's Status Values table, directly after the last ladder row.
  awk '{print} /^\| `Deployed to Prod`/{print "| `Archived`           | Hypothetical future script-set status added only to this fixture schema |"}' \
    "$REAL_SCHEMA" > "$FIXTURE_REPO/templates/SCRUM_BOARD_SCHEMA.md"
  run "$CLASSIFY" --classify "Archived"
  [ "$status" -eq 0 ]
  [ "$output" = "ladder" ]
  run "$CLASSIFY"
  assert_output_contains '"Archived"'

  write_task E94_S01_T01 "Archived" "$ORIGINAL_DATE"
  CONFIRMED="E94_S01_T01" reconcile_tasks
  [ "$(field "$(task_file E94_S01_T01)" status)" = "Archived" ]
  [ "$(field "$(task_file E94_S01_T01)" date_completed)" = "$ORIGINAL_DATE" ]
}

@test "parity: the real script run against the real schema agrees with the fixture copy" {
  run "$REPO_ROOT/skills/j-reconcile/scripts/completed-statuses.sh" --schema "$REAL_SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "$("$CLASSIFY")" ]
}

@test "parity: renaming a pinned status in the schema fails loudly (exit 3), never a silent reclassification" {
  sed 's/^| `Backlog`/| `Backlogged`/' "$REAL_SCHEMA" > "$FIXTURE_REPO/templates/SCRUM_BOARD_SCHEMA.md"
  run "$CLASSIFY"
  [ "$status" -eq 3 ]
  assert_output_contains "vocabulary drift"
  assert_output_contains "Backlog"
}

@test "parity: a schema with no Status Values table fails (exit 4) instead of falling back to a hand list" {
  printf '# Schema\n\nno table here\n' > "$FIXTURE_REPO/templates/SCRUM_BOARD_SCHEMA.md"
  run "$CLASSIFY"
  [ "$status" -eq 4 ]
}

@test "parity: a missing schema fails (exit 2) instead of falling back to a hand list" {
  rm -f "$FIXTURE_REPO/templates/SCRUM_BOARD_SCHEMA.md"
  # The script also tries cwd-relative locations, so run from the schema-less fixture, not the repo.
  cd "$FIXTURE_REPO"
  run "$CLASSIFY"
  [ "$status" -eq 2 ]
  assert_output_contains "cannot find"
}

@test "unknown statuses (not in the schema) classify as unknown, which reconcile treats as incomplete" {
  [ "$("$CLASSIFY" --classify "Running")" = "unknown" ]
  write_task E93_S01_T01 "Running" ""
  CONFIRMED="E93_S01_T01" reconcile_tasks
  [ "$(field "$(task_file E93_S01_T01)" status)" = "Passed" ]
}
