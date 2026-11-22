#!/usr/bin/env bats
# bats file_tags=tier:unit
#
# Coverage for the publicized_privatized_mismatch event that
# skills/j-close-story/scripts/check-privatized.sh appends through the shared
# scripts/events-append.sh helper (E75_S01_T01). Every case runs in a throwaway
# git repo under $BATS_TEST_TMPDIR; the live events.json is never touched.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  PROJ="$BATS_TEST_TMPDIR/repo"
  git init -q "$PROJ"
  cd "$PROJ" || return 1
  git config user.email test@example.com
  git config user.name Test
  mkdir -p scripts skills/j-close-story/scripts project/board/tasks project/logs secret
  cp "$REPO_ROOT/scripts/with-lock.sh" "$REPO_ROOT/scripts/events-append.sh" "$REPO_ROOT/scripts/commits-for-item.sh" scripts/
  cp "$REPO_ROOT/skills/j-close-story/scripts/check-privatized.sh" \
     "$REPO_ROOT/skills/j-close-story/scripts/update-task-frontmatter.sh" skills/j-close-story/scripts/
  printf 'secret/\n' > .publicignore
  printf '{"event":"earlier"}\n' > project/logs/events.json
  printf -- '---\nid: E01_S01_T01\nstatus: Publicized\n---\n\n# body\n' > project/board/tasks/E01_S01_T01_x.md
  git add -A && git commit -q -m "base"
  echo hi > secret/a.txt && git add -A && git commit -q -m "task(E01_S01_T01): impl"
}

@test "a Publicized ticket whose files are all blocklisted logs one JSONL mismatch event and becomes Privatized" {
  run bash skills/j-close-story/scripts/check-privatized.sh E01_S01_T01 project/board/tasks/E01_S01_T01_x.md
  [ "$status" -eq 0 ]
  [ "$(wc -l < project/logs/events.json | tr -d ' ')" = "2" ]
  [ "$(head -1 project/logs/events.json)" = '{"event":"earlier"}' ]
  [ "$(tail -1 project/logs/events.json | jq -r .event)" = "publicized_privatized_mismatch" ]
  [ "$(tail -1 project/logs/events.json | jq -r '.touched_files[0]')" = "secret/a.txt" ]
  grep -q '^status: Privatized' project/board/tasks/E01_S01_T01_x.md
}

@test "an array-shaped events.json is left untouched and the status write still proceeds" {
  printf '[{"event":"earlier"}]\n' > project/logs/events.json
  before="$(cksum < project/logs/events.json)"
  run bash skills/j-close-story/scripts/check-privatized.sh E01_S01_T01 project/board/tasks/E01_S01_T01_x.md
  [ "$status" -eq 0 ]
  [ "$(cksum < project/logs/events.json)" = "$before" ]
  grep -q '^status: Privatized' project/board/tasks/E01_S01_T01_x.md
}

# E99_S01_T04: an explicit --help / -h is a success (usage on stdout, exit 0); a missing or wrong
# argument count keeps exiting non-zero with the usage on stderr.
@test "--help and -h print usage on stdout and exit 0; wrong argument count exits 1 with usage on stderr" {
  local flag
  for flag in --help -h; do
    run --separate-stderr bash skills/j-close-story/scripts/check-privatized.sh "$flag"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: check-privatized.sh"* ]]
    [ -z "$stderr" ]
  done
  run --separate-stderr bash skills/j-close-story/scripts/check-privatized.sh
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Usage: check-privatized.sh"* ]]
}
