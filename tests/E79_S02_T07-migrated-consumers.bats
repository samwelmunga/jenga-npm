#!/usr/bin/env bats
#
# Focused coverage for the commit-discovery path of the consumers that E79_S02_T07 moved onto the shared resolver
# scripts/commits-for-item.sh:
#
#   skills/j-close-story/scripts/check-privatized.sh   (audit row M4)
#   scripts/mark-deployed.sh                           (audit row M7)
#
# The audit (project/documentation/commit-consumer-audit.md, section 7) records that neither script had a test of its
# commit discovery: tests/external-refs-absent-safe.bats exercises their external_refs handling only, and
# tests/check-privatized-event.bats pins the mismatch event. The cases here pin what a migration must not change for
# EST-only history, and were written to hold for the old private `git log --all --no-merges --grep` copy and for the
# resolver alike:
#
#   - anchoring: a story id does not pick up its child tasks' commits, and E..._T01 does not pick up E..._T010;
#   - a ticket's files (or ancestry) are taken over ALL of its commits, not just the newest;
#   - zero matched commits leaves the ticket unchanged, exit 0 (no --require-nonempty: that is E79_S06);
#   - a merge commit is ignored, a commit on another branch is found (--all --no-merges);
#   - the resolver is looked up beside the script, and a missing resolver is a clear failure, not a silent "no commits".
#
# mark-publicized.sh (row M6) is covered by tests/mark-publicized.bats, which already pins zero-match, union and the
# anchored story id; it only needed the resolver copied into its fixture.
#
# Every case runs in a throwaway repository under $BATS_TEST_TMPDIR with the scripts copied to their repo-relative
# paths (they derive their repo root from their own location). Nothing touches the live board or events.json.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  PROJ="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$PROJ"
  cd "$PROJ" || return 1
  git config user.email test@example.com
  git config user.name Test
  git config commit.gpgsign false
  git config core.hooksPath /dev/null

  mkdir -p scripts skills/j-close-story/scripts project/board/tasks project/board/stories project/logs secret pub
  cp "$REPO_ROOT/scripts/with-lock.sh" "$REPO_ROOT/scripts/events-append.sh" \
     "$REPO_ROOT/scripts/commits-for-item.sh" "$REPO_ROOT/scripts/mark-deployed.sh" scripts/
  cp "$REPO_ROOT/skills/j-close-story/scripts/check-privatized.sh" \
     "$REPO_ROOT/skills/j-close-story/scripts/update-task-frontmatter.sh" skills/j-close-story/scripts/
  printf 'secret/\n' > .publicignore
  : > project/logs/events.json
  git add -A
  git commit -q -m "base"
  CK="$PROJ/skills/j-close-story/scripts/check-privatized.sh"
  MD="$PROJ/scripts/mark-deployed.sh"
}

# make_ticket <tasks|stories> <id> <status>   (committed with a message naming no ticket id)
make_ticket() {
  printf -- '---\nid: %s\nstatus: %s\n---\n\n# body\n' "$2" "$3" > "$PROJ/project/board/$1/$2_x.md"
  git -C "$PROJ" add "project/board/$1/$2_x.md"
  git -C "$PROJ" commit -q -m "fixture: ticket file"
}

# commit_file <subject> <path>   (a commit that adds <path>; prints nothing)
commit_file() {
  mkdir -p "$PROJ/$(dirname "$2")"
  printf '%s\n' "$1" > "$PROJ/$2"
  git -C "$PROJ" add "$2"
  git -C "$PROJ" commit -q -m "$1"
}

status_of() { awk '/^status:/ {sub(/^status:[ \t]*/, ""); print; exit}' "$PROJ/project/board/$1/$2_x.md"; }

# --- check-privatized.sh (M4) ------------------------------------------------------------------------------------

@test "check-privatized: every commit of the task is blocklisted -> Privatized" {
  make_ticket tasks E01_S01_T01 Passed
  commit_file "task(E01_S01_T01): first" secret/a.txt
  commit_file "task(E01_S01_T01): second" secret/b.txt
  run bash "$CK" E01_S01_T01 "$PROJ/project/board/tasks/E01_S01_T01_x.md"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "PRIVATIZED" ]
  [ "$(status_of tasks E01_S01_T01)" = "Privatized" ]
}

@test "check-privatized: the file union spans all commits, so one public commit keeps the task unchanged" {
  make_ticket tasks E01_S01_T01 Passed
  commit_file "task(E01_S01_T01): first" secret/a.txt
  commit_file "task(E01_S01_T01): second" pub/b.txt
  run bash "$CK" E01_S01_T01 "$PROJ/project/board/tasks/E01_S01_T01_x.md"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "UNCHANGED" ]
  [ "$(status_of tasks E01_S01_T01)" = "Passed" ]
}

@test "check-privatized: zero matched commits -> UNCHANGED, exit 0" {
  make_ticket tasks E01_S01_T09 Passed
  commit_file "unrelated work" secret/a.txt
  run bash "$CK" E01_S01_T09 "$PROJ/project/board/tasks/E01_S01_T09_x.md"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "UNCHANGED" ]
  [[ "$output" == *"zero matched"* ]]
  [ "$(status_of tasks E01_S01_T09)" = "Passed" ]
}

@test "check-privatized: a story id is anchored and does not collect its child tasks' commits" {
  make_ticket stories E01_S01 Passed
  commit_file "task(E01_S01_T01): child, blocklisted" secret/child.txt
  # Only a child task commit exists. If the story over-matched it, the story would be Privatized.
  run bash "$CK" E01_S01 "$PROJ/project/board/stories/E01_S01_x.md"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "UNCHANGED" ]
  [ "$(status_of stories E01_S01)" = "Passed" ]
  # Its own commit, blocklisted, is what makes it Privatized.
  commit_file "story(E01_S01): roll up" secret/story.txt
  run bash "$CK" E01_S01 "$PROJ/project/board/stories/E01_S01_x.md"
  [ "${lines[${#lines[@]}-1]}" = "PRIVATIZED" ]
}

@test "check-privatized: T01 does not collect T010's commits" {
  make_ticket tasks E01_S01_T01 Passed
  commit_file "task(E01_S01_T01): public work" pub/a.txt
  commit_file "task(E01_S01_T010): blocklisted" secret/ten.txt
  run bash "$CK" E01_S01_T01 "$PROJ/project/board/tasks/E01_S01_T01_x.md"
  [ "${lines[${#lines[@]}-1]}" = "UNCHANGED" ]
  [ "$(status_of tasks E01_S01_T01)" = "Passed" ]
}

@test "check-privatized: a commit that arrived through a merged side branch is found (--no-merges skips the merge itself)" {
  make_ticket tasks E01_S01_T01 Passed
  git checkout -q -b side
  commit_file "task(E01_S01_T01): on a side branch" secret/side.txt
  git checkout -q main
  git merge -q --no-ff side -m "merge: E01_S01_T01-side into main"
  git branch -q -D side
  run bash "$CK" E01_S01_T01 "$PROJ/project/board/tasks/E01_S01_T01_x.md"
  [ "${lines[${#lines[@]}-1]}" = "PRIVATIZED" ]
}

@test "check-privatized: a Jenga-Task trailer on an id-free subject is found" {
  make_ticket tasks E01_S01_T01 Passed
  mkdir -p secret && echo x > secret/t.txt && git add secret/t.txt
  git commit -q -m "ASD-001 add retry" -m "Jenga-Task: E01_S01_T01"
  run bash "$CK" E01_S01_T01 "$PROJ/project/board/tasks/E01_S01_T01_x.md"
  [ "${lines[${#lines[@]}-1]}" = "PRIVATIZED" ]
}

@test "check-privatized: a missing resolver fails loudly, not as 'zero matched commits'" {
  make_ticket tasks E01_S01_T01 Passed
  commit_file "task(E01_S01_T01): blocklisted" secret/a.txt
  rm scripts/commits-for-item.sh
  run bash "$CK" E01_S01_T01 "$PROJ/project/board/tasks/E01_S01_T01_x.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"commits-for-item.sh"* ]]
  [ "$(status_of tasks E01_S01_T01)" = "Passed" ]
}

# --- mark-deployed.sh (M7) ---------------------------------------------------------------------------------------

# tag_file <sha>   (a one-line prod tag diff file for --diff-file)
tag_file() {
  printf 'prod\t1.0.0\tv1.0.0\t%s\n' "$1" > "$BATS_TEST_TMPDIR/tags.tsv"
  printf '%s' "$BATS_TEST_TMPDIR/tags.tsv"
}

@test "mark-deployed: every commit of the task is an ancestor of the tag -> Deployed to Prod" {
  make_ticket tasks E01_S01_T01 Publicized
  commit_file "task(E01_S01_T01): first" pub/a.txt
  commit_file "task(E01_S01_T01): second" pub/b.txt
  run bash "$MD" --diff-file "$(tag_file "$(git rev-parse HEAD)")"
  [ "$status" -eq 0 ]
  [ "$(status_of tasks E01_S01_T01)" = "Deployed to Prod" ]
}

@test "mark-deployed: one commit of the task after the tag keeps it unchanged (ancestry is over all commits)" {
  make_ticket tasks E01_S01_T01 Publicized
  commit_file "task(E01_S01_T01): before the tag" pub/a.txt
  local tagsha
  tagsha="$(git rev-parse HEAD)"
  commit_file "task(E01_S01_T01): after the tag" pub/b.txt
  run bash "$MD" --diff-file "$(tag_file "$tagsha")"
  [ "$status" -eq 0 ]
  [ "$(status_of tasks E01_S01_T01)" = "Publicized" ]
}

@test "mark-deployed: zero matched commits -> unchanged, exit 0" {
  make_ticket tasks E01_S01_T09 Publicized
  commit_file "unrelated work" pub/a.txt
  run bash "$MD" --diff-file "$(tag_file "$(git rev-parse HEAD)")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zero matched"* ]]
  [ "$(status_of tasks E01_S01_T09)" = "Publicized" ]
}

@test "mark-deployed: a story id is anchored and does not collect its child tasks' commits" {
  make_ticket stories E01_S01 Publicized
  commit_file "task(E01_S01_T01): child only" pub/a.txt
  run bash "$MD" --diff-file "$(tag_file "$(git rev-parse HEAD)")"
  [ "$status" -eq 0 ]
  # No commit names the story itself, so it has zero matched commits and stays put.
  [[ "$output" == *"E01_S01: zero matched"* ]]
  [ "$(status_of stories E01_S01)" = "Publicized" ]
}

@test "mark-deployed: T01 does not collect T010's later commit" {
  make_ticket tasks E01_S01_T01 Publicized
  commit_file "task(E01_S01_T01): shipped" pub/a.txt
  local tagsha
  tagsha="$(git rev-parse HEAD)"
  commit_file "task(E01_S01_T010): not yet shipped" pub/b.txt
  run bash "$MD" --diff-file "$(tag_file "$tagsha")"
  [ "$(status_of tasks E01_S01_T01)" = "Deployed to Prod" ]
}

@test "mark-deployed: a missing resolver fails loudly before touching the board" {
  make_ticket tasks E01_S01_T01 Publicized
  commit_file "task(E01_S01_T01): shipped" pub/a.txt
  rm scripts/commits-for-item.sh
  run bash "$MD" --diff-file "$(tag_file "$(git rev-parse HEAD)")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"commits-for-item.sh"* ]]
  [ "$(status_of tasks E01_S01_T01)" = "Publicized" ]
}
