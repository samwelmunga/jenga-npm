#!/usr/bin/env bats
#
# Absent-safety of the board consumers outside validate-board.sh and the dashboard for the optional
# `external_refs`, `external_refs_declined` and `external_refs_declined_note` frontmatter fields
# (E71_S03_T04). The field contract lives in templates/SCRUM_BOARD_SCHEMA.md ("External Refs Fields").
#
# Consumers covered, by group (the actual code paths found by reading skills/, scripts/, hooks/):
#
#   j.status      skills/j-status/SKILL.md is prose (the agent reads board files itself, nothing to
#                 execute). The scripts it drives or shares are: scripts/mark-deployed.sh (its step 6.5,
#                 reads AND writes board frontmatter), skills/jenga/scripts/board-scan.sh (the shared
#                 inventory behind /jenga, /reconcile) and scripts/render-ranked-list.sh (/dooo, /todo).
#   rollup        Story/epic rollup itself is agent prose (scrum-master, tester); no script computes it.
#                 The scripted halves are skills/j-close-story/scripts/check-story-closeable.sh (the
#                 "every child terminal" guard) and update-task-frontmatter.sh (the writer every status /
#                 date_completed write goes through).
#   mirror        scripts/check-publicignore-match.sh and skills/j-close-story/scripts/check-privatized.sh
#                 (the .publicignore consumers). skills/j-mirror-public/scripts/mirror.sh reads no board
#                 frontmatter at all (it only reads .publicignore and the git tree), so it has no
#                 absent-safety surface to test.
#
# Method: two scratch git repos with an identical board, one plain ("plain") and one whose epic, story
# and tasks carry the fields ("carry"), in the on-disk shape the schema documents. For each consumer the
# carry result must equal the plain result once the three field keys are stripped, i.e. nothing is
# dropped, reordered or mangled, and the field lines themselves must survive the run byte for byte.

load helpers/assertions

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# --- fixture field blocks (schema shape) -------------------------------------------------------

emit_refs() {
  cat <<'EOF'
external_refs:
  - system: jira
    kind: issue
    key: PROJ-123
    linked_on: 2026-10-06
  - system: confluence
    kind: page
    url: https://example.atlassian.net/wiki/spaces/PROJ/pages/123456
    linked_on: 2026-10-06
EOF
}

emit_declined() {
  cat <<'EOF'
external_refs_declined: true
external_refs_declined_note: "2026-10-06: user skipped the link prompt"
EOF
}

# emit_fields <refs|declined|none>
emit_fields() {
  case "$1" in
    refs) emit_refs ;;
    declined) emit_declined ;;
    *) : ;;
  esac
}

# --- fixture board -----------------------------------------------------------------------------

# write_board <repo> <carry: 0|1> <task status>
#
# Items: epic E99, story E99_S01 (tasks T01..T03). With carry=1: T01 holds a two-entry external_refs
# list directly after an EMPTY `depends_on:` (the adversarial position for block-list readers), T02 holds
# the skip-marker pair mid-frontmatter, T03 never carries anything (control), the story holds
# external_refs immediately before `tasks:`, the epic holds external_refs before `stories:`.
write_board() {
  local repo="$1" carry="$2" tstatus="$3"
  local t1=none t2=none sref=none eref=none
  if [ "$carry" = "1" ]; then t1=refs; t2=declined; sref=refs; eref=refs; fi
  mkdir -p "$repo/project/board/epics" "$repo/project/board/stories" "$repo/project/board/tasks"

  {
    cat <<'EOF'
---
id: E99
title: Fixture epic
status: In Progress
date_created: 2026-10-01
date_started: 2026-10-02
date_completed:
EOF
    emit_fields "$eref"
    cat <<'EOF'
stories:
  - E99_S01
---

# Epic: Fixture epic

## Purpose
Fixture epic purpose line.
EOF
  } > "$repo/project/board/epics/E99_fixture-epic.md"

  {
    cat <<'EOF'
---
id: E99_S01
epic_id: E99
title: Fixture story
status: In Progress
date_created: 2026-10-01
date_started: 2026-10-02
date_completed:
docs: []
priority: P1
depends_on:
EOF
    emit_fields "$sref"
    cat <<'EOF'
tasks:
  - E99_S01_T01
  - E99_S01_T02
  - E99_S01_T03
---

# Story: Fixture story

As a maintainer I want the fixture so that the consumers have something to read.

## Acceptance Criteria
- [ ] Fixture criterion
EOF
  } > "$repo/project/board/stories/E99_S01_fixture-story.md"

  write_task "$repo" 1 "$tstatus" "$t1" first
  write_task "$repo" 2 "$tstatus" "$t2" middle
  write_task "$repo" 3 "$tstatus" none last
}

# write_task <repo> <n> <status> <refs|declined|none> <first|middle|last>
# `first` puts the fields right after `depends_on:`, `middle` before `epic_scope_approval`, `last` at the end.
write_task() {
  local repo="$1" n="$2" tstatus="$3" kind="$4" pos="$5"
  {
    cat <<EOF
---
id: E99_S01_T0$n
story_id: E99_S01
epic_id: E99
title: Fixture task $n
status: $tstatus
date_created: 2026-10-01
date_started: 2026-10-02
date_completed:
assigned_to: developer
depends_on:
EOF
    [ "$pos" = first ] && emit_fields "$kind"
    cat <<'EOF'
execution_scope: task
needs_docs: false
jenga_assigned: true
EOF
    [ "$pos" = middle ] && emit_fields "$kind"
    cat <<'EOF'
epic_scope_approval: false
EOF
    [ "$pos" = last ] && emit_fields "$kind"
    cat <<EOF
---

# Task: Fixture task $n

## Description
Fixture description $n.

## Acceptance Criteria
- [ ] Fixture criterion
EOF
  } > "$repo/project/board/tasks/E99_S01_T0${n}_fixture-task.md"
}

# make_repo <repo> <carry: 0|1> <task status>
# A scratch git repo holding copies of the scripts under test at their real repo-relative paths (several
# resolve the repo root from their own location), plus the board. Commit 1 is the scaffold, commit 2 is
# tagged with the task ids so the EST-commit matching in mark-deployed.sh / check-privatized.sh sees them.
make_repo() {
  local repo="$1" carry="$2" tstatus="$3" s
  mkdir -p "$repo/scripts" "$repo/skills/j-close-story/scripts"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.com
  git -C "$repo" config user.name fixture
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config core.hooksPath /dev/null
  for s in mark-deployed.sh with-lock.sh check-publicignore-match.sh; do
    cp "$REPO_ROOT/scripts/$s" "$repo/scripts/$s"
  done
  for s in check-story-closeable.sh update-task-frontmatter.sh check-privatized.sh; do
    cp "$REPO_ROOT/skills/j-close-story/scripts/$s" "$repo/skills/j-close-story/scripts/$s"
  done
  printf 'project/board/\nproject/queue/\n' > "$repo/.publicignore"
  mkdir -p "$repo/docs"
  printf 'public page\n' > "$repo/docs/guide.md"
  git -C "$repo" add scripts skills .publicignore docs
  git -C "$repo" commit -q -m "scaffold"

  write_board "$repo" "$carry" "$tstatus"
  git -C "$repo" add project/board/epics project/board/stories
  git -C "$repo" commit -q -m "story(E99_S01): fixture story"
  git -C "$repo" add project/board/tasks/E99_S01_T01_fixture-task.md
  git -C "$repo" commit -q -m "task(E99_S01_T01): fixture"
  git -C "$repo" add project/board/tasks/E99_S01_T02_fixture-task.md
  git -C "$repo" commit -q -m "task(E99_S01_T02): fixture"
  git -C "$repo" add project/board/tasks/E99_S01_T03_fixture-task.md
  git -C "$repo" commit -q -m "task(E99_S01_T03): fixture"
}

# --- comparison helpers ------------------------------------------------------------------------

# strip_fields <file>: the file with the three field keys (and their indented continuation lines)
# removed from the frontmatter. Everything else is untouched, in order.
strip_fields() {
  awk '
    BEGIN { fm = 0; skip = 0 }
    {
      if ($0 == "---") {
        if (fm == 0) { fm = 1 } else if (fm == 1) { fm = 2 }
        skip = 0
        print; next
      }
      if (fm == 1) {
        if ($0 ~ /^external_refs(_declined(_note)?)?:/) { skip = 1; next }
        if (skip == 1 && $0 ~ /^[[:space:]]/) { next }
        skip = 0
      }
      print
    }
  ' "$1"
}

# field_lines <file>: only the field lines (the inverse of strip_fields), for the "not mangled" check.
field_lines() {
  awk '
    BEGIN { fm = 0; keep = 0 }
    {
      if ($0 == "---") { if (fm == 0) fm = 1; else if (fm == 1) fm = 2; keep = 0; next }
      if (fm == 1) {
        if ($0 ~ /^external_refs(_declined(_note)?)?:/) { keep = 1; print; next }
        if (keep == 1 && $0 ~ /^[[:space:]]/) { print; next }
        keep = 0
      }
    }
  ' "$1"
}

# board_files <repo>: every board file, sorted, as repo-relative paths.
board_files() {
  (cd "$1" && find project/board -name '*.md' | sort)
}

# assert_boards_equivalent <plain repo> <carry repo>: every board file in carry, with the field keys
# stripped, equals the same file in plain. Fails with the diff on stderr otherwise.
assert_boards_equivalent() {
  local plain="$1" carry="$2" rel
  while IFS= read -r rel; do
    [ -f "$plain/$rel" ] || { echo "missing in plain: $rel" >&2; return 1; }
    if ! diff <(strip_fields "$carry/$rel") "$plain/$rel" >&2; then
      echo "board file differs once fields are stripped: $rel" >&2
      return 1
    fi
  done < <(board_files "$carry")
}

# snapshot_fields <repo>: all field lines of every board file, keyed by file, for before/after equality.
snapshot_fields() {
  local rel
  while IFS= read -r rel; do
    printf '== %s\n' "$rel"
    field_lines "$1/$rel"
  done < <(board_files "$1")
}

setup() {
  PLAIN="$BATS_TEST_TMPDIR/plain"
  CARRY="$BATS_TEST_TMPDIR/carry"
  unset JENGA_PROJECT_DIR
}

# --- sanity: the fixture really carries the fields, and only the carry board does ----------------

@test "fixture: carry board carries the fields, plain board carries none, and they are otherwise identical" {
  make_repo "$PLAIN" 0 Passed
  make_repo "$CARRY" 1 Passed
  [ -z "$(snapshot_fields "$PLAIN" | grep -v '^==')" ]
  grep -q '^external_refs:' "$CARRY/project/board/tasks/E99_S01_T01_fixture-task.md"
  grep -q '^external_refs_declined_note:' "$CARRY/project/board/tasks/E99_S01_T02_fixture-task.md"
  grep -q '^external_refs:' "$CARRY/project/board/stories/E99_S01_fixture-story.md"
  grep -q '^external_refs:' "$CARRY/project/board/epics/E99_fixture-epic.md"
  [ "$(grep -c 'external_refs' "$CARRY/project/board/tasks/E99_S01_T03_fixture-task.md" || true)" -eq 0 ]
  assert_boards_equivalent "$PLAIN" "$CARRY"
}

# --- group: j.status ---------------------------------------------------------------------------

@test "j.status: board-scan.sh emits an identical inventory for the carry and plain boards" {
  make_repo "$PLAIN" 0 Pending
  make_repo "$CARRY" 1 Pending
  run --separate-stderr env CLAUDE_PROJECT_DIR="$PLAIN" bash "$REPO_ROOT/skills/jenga/scripts/board-scan.sh"
  [ "$status" -eq 0 ]
  plain_out="$output"
  [ -z "$stderr" ]
  run --separate-stderr env CLAUDE_PROJECT_DIR="$CARRY" bash "$REPO_ROOT/skills/jenga/scripts/board-scan.sh"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$plain_out" ]
  # Nothing skipped: epic + story + 3 tasks, with siblings of the carried fields intact.
  [ "$(printf '%s' "$output" | jq 'length')" -eq 5 ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id=="E99_S01_T01") | .title')" = "Fixture task 1" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id=="E99_S01_T01") | .summary')" = "Fixture description 1." ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id=="E99_S01") | .summary')" = "As a maintainer I want the fixture so that the consumers have something to read." ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.id=="E99") | .status')" = "In Progress" ]
}

@test "j.status: render-ranked-list.sh lists the same eligible items with and without the fields, including after an empty depends_on" {
  make_repo "$PLAIN" 0 Pending
  make_repo "$CARRY" 1 Pending
  local repo
  for repo in "$PLAIN" "$CARRY"; do
    printf 'E99_S01_T01 - first\nE99_S01_T02 - second\nE99_S01_T03 - third\n' > "$repo/project/todo.md"
  done
  run --separate-stderr bash -c 'cd "$1" && bash "$2"' _ "$PLAIN" "$REPO_ROOT/scripts/render-ranked-list.sh"
  [ "$status" -eq 0 ]
  plain_out="$output"
  [ -n "$plain_out" ]
  run --separate-stderr bash -c 'cd "$1" && bash "$2"' _ "$CARRY" "$REPO_ROOT/scripts/render-ranked-list.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$plain_out" ]
  # T01 carries external_refs directly under an empty depends_on: it must still count as having no deps.
  printf '%s' "$output" | grep -q 'E99_S01_T01 — Fixture task 1'
  printf '%s' "$output" | grep -q 'E99_S01_T02 — Fixture task 2'
}

@test "j.status: mark-deployed.sh (step 6.5) promotes carry tickets exactly as plain ones and leaves the fields intact" {
  make_repo "$PLAIN" 0 Publicized
  make_repo "$CARRY" 1 Publicized
  local repo before_fields tsv
  before_fields="$(snapshot_fields "$CARRY")"
  for repo in "$PLAIN" "$CARRY"; do
    tsv="$repo/tags.tsv"
    printf 'prod\t1.0.0\tv1.0.0\t%s\n' "$(git -C "$repo" rev-parse HEAD)" > "$tsv"
    run bash "$repo/scripts/mark-deployed.sh" --diff-file "$tsv"
    [ "$status" -eq 0 ]
    # Every Publicized task was promoted and stamped.
    local n
    for n in 1 2 3; do
      grep -q '^status: Deployed to Prod$' "$repo/project/board/tasks/E99_S01_T0${n}_fixture-task.md"
      grep -q '^date_deployed_prod: ' "$repo/project/board/tasks/E99_S01_T0${n}_fixture-task.md"
    done
  done
  [ "$(snapshot_fields "$CARRY")" = "$before_fields" ]
  # The only difference from the plain run is the fields themselves.
  assert_boards_equivalent "$PLAIN" "$CARRY"
}

# --- group: rollup -----------------------------------------------------------------------------

@test "rollup: check-story-closeable.sh reports CLOSEABLE for a story whose children carry the fields, same as without" {
  make_repo "$PLAIN" 0 Passed
  make_repo "$CARRY" 1 Passed
  run bash "$PLAIN/skills/j-close-story/scripts/check-story-closeable.sh" E99_S01
  [ "$status" -eq 0 ]
  plain_out="$output"
  run bash "$CARRY/skills/j-close-story/scripts/check-story-closeable.sh" E99_S01
  [ "$status" -eq 0 ]
  [ "$output" = "$plain_out" ]
  printf '%s' "$output" | grep -q 'CLOSEABLE'
}

@test "rollup: check-story-closeable.sh still reads tasks: after an external_refs block, and still sees an open carrying child" {
  make_repo "$CARRY" 1 Passed
  # Re-open the task that carries external_refs: the story must no longer be closeable, i.e. the status
  # of a field-carrying child is read (not skipped) and the field block did not hide the tasks: list.
  update="$CARRY/skills/j-close-story/scripts/update-task-frontmatter.sh"
  bash "$update" "$CARRY/project/board/tasks/E99_S01_T01_fixture-task.md" status "In Progress"
  run bash "$CARRY/skills/j-close-story/scripts/check-story-closeable.sh" E99_S01
  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^CLOSEABLE' || true)" -eq 0 ]
}

@test "rollup: update-task-frontmatter.sh writes status and date_completed on carry items without touching the fields or sibling order" {
  make_repo "$PLAIN" 0 Passed
  make_repo "$CARRY" 1 Passed
  local repo f before_fields
  before_fields="$(snapshot_fields "$CARRY")"
  for repo in "$PLAIN" "$CARRY"; do
    for f in project/board/epics/E99_fixture-epic.md project/board/stories/E99_S01_fixture-story.md project/board/tasks/E99_S01_T01_fixture-task.md project/board/tasks/E99_S01_T02_fixture-task.md; do
      run bash "$repo/skills/j-close-story/scripts/update-task-frontmatter.sh" "$repo/$f" status "Passed"
      [ "$status" -eq 0 ]
      run bash "$repo/skills/j-close-story/scripts/update-task-frontmatter.sh" "$repo/$f" date_completed "2026-10-06"
      [ "$status" -eq 0 ]
    done
  done
  grep -q '^status: Passed$' "$CARRY/project/board/epics/E99_fixture-epic.md"
  grep -q '^date_completed: 2026-10-06$' "$CARRY/project/board/stories/E99_S01_fixture-story.md"
  [ "$(snapshot_fields "$CARRY")" = "$before_fields" ]
  assert_boards_equivalent "$PLAIN" "$CARRY"
}

@test "rollup: update-task-frontmatter.sh appends a new key after a trailing external_refs block inside the frontmatter" {
  # The refs block is the LAST thing in the frontmatter here, so the appended key lands directly after a list.
  f="$BATS_TEST_TMPDIR/trailing.md"
  { printf '%s\n' '---' 'id: E99_S01_T09' 'status: Passed'; emit_refs; printf '%s\n' '---' '' '# Body'; } > "$f"
  run bash "$REPO_ROOT/skills/j-close-story/scripts/update-task-frontmatter.sh" "$f" scope_divergence_flag true
  [ "$status" -eq 0 ]
  # The new key is inside the frontmatter (before the closing ---), the list above it is whole, the body is untouched.
  awk 'NR>1 && $0=="---" {exit} {print}' "$f" | grep -q '^scope_divergence_flag: true$'
  [ "$(field_lines "$f" | grep -c 'linked_on: 2026-10-06')" -eq 2 ]
  [ "$(tail -n 1 "$f")" = "# Body" ]
}

# --- group: mirror / .publicignore -------------------------------------------------------------

@test "mirror: check-publicignore-match.sh classifies carry and plain board files identically (blocked by .publicignore)" {
  make_repo "$PLAIN" 0 Passed
  make_repo "$CARRY" 1 Passed
  run bash "$PLAIN/scripts/check-publicignore-match.sh" project/board/tasks/E99_S01_T01_fixture-task.md project/board/stories/E99_S01_fixture-story.md project/board/epics/E99_fixture-epic.md docs/guide.md
  [ "$status" -eq 0 ]
  plain_out="$output"
  run bash "$CARRY/scripts/check-publicignore-match.sh" project/board/tasks/E99_S01_T01_fixture-task.md project/board/stories/E99_S01_fixture-story.md project/board/epics/E99_fixture-epic.md docs/guide.md
  [ "$status" -eq 0 ]
  [ "$output" = "$plain_out" ]
  printf '%s\n' "$output" | grep -q "^BLOCKED.project/board/tasks/E99_S01_T01_fixture-task.md$"
  printf '%s\n' "$output" | grep -q "^PUBLIC.docs/guide.md$"
}

@test "mirror: check-publicignore-match.sh classifies carry and plain board files identically when the board is not blocked" {
  make_repo "$PLAIN" 0 Passed
  make_repo "$CARRY" 1 Passed
  local repo
  for repo in "$PLAIN" "$CARRY"; do
    printf 'project/queue/\n' > "$repo/.publicignore"
  done
  run bash "$PLAIN/scripts/check-publicignore-match.sh" project/board/tasks/E99_S01_T01_fixture-task.md project/board/epics/E99_fixture-epic.md
  [ "$status" -eq 0 ]
  plain_out="$output"
  run bash "$CARRY/scripts/check-publicignore-match.sh" project/board/tasks/E99_S01_T01_fixture-task.md project/board/epics/E99_fixture-epic.md
  [ "$status" -eq 0 ]
  [ "$output" = "$plain_out" ]
  printf '%s\n' "$output" | grep -q "^PUBLIC.project/board/tasks/E99_S01_T01_fixture-task.md$"
}

@test "mirror: check-privatized.sh reads and writes carry tickets exactly as plain ones" {
  make_repo "$PLAIN" 0 Passed
  make_repo "$CARRY" 1 Passed
  local repo before_fields n
  before_fields="$(snapshot_fields "$CARRY")"
  for repo in "$PLAIN" "$CARRY"; do
    for n in 1 2 3; do
      run bash "$repo/skills/j-close-story/scripts/check-privatized.sh" "E99_S01_T0$n" "$repo/project/board/tasks/E99_S01_T0${n}_fixture-task.md"
      [ "$status" -eq 0 ]
      printf '%s' "$output" | grep -q 'PRIVATIZED'
      grep -q '^status: Privatized$' "$repo/project/board/tasks/E99_S01_T0${n}_fixture-task.md"
    done
  done
  [ "$(snapshot_fields "$CARRY")" = "$before_fields" ]
  assert_boards_equivalent "$PLAIN" "$CARRY"
}
