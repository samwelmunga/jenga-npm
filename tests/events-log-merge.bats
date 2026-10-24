#!/usr/bin/env bats
#
# Proves the merge strategy for project/logs/events.json (E75_S01_T02): two branches that each
# append one event to the shared JSONL log merge cleanly under the `merge=union` rule declared in
# .gitattributes, and the same two appends conflict when that rule is absent (negative control).
# Decision record: project/documentation/event-log-merge-strategy.md.
#
# Each test builds a throwaway git repository under $BATS_TEST_TMPDIR. Nothing here touches this
# repository's own project/logs/events.json, its index or its branches; the only read of the real
# checkout is `git check-attr` against its .gitattributes.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
  cd "$REPO" || return 1
  git config user.email test@example.com
  git config user.name "Test"
  git config commit.gpgsign false
  mkdir -p project/logs
  printf '%s\n' '{"event":"session_start","agent":"developer","session_id":"base","date":"2026-10-19T00:00:00Z"}' \
    > project/logs/events.json
}

# fork_two <yes|no>: commit the base (with the real .gitattributes when "yes"), then create branch-a and
# branch-b from it. Each branch appends exactly one new event line, the way two concurrent writers would.
fork_two() {
  if [ "$1" = yes ]; then
    cp "$REPO_ROOT/.gitattributes" .gitattributes
  fi
  git add -A
  git commit -q -m "base"

  git checkout -q -b branch-a
  printf '%s\n' '{"event":"task_completed","agent":"developer","session_id":"A","date":"2026-10-19T10:00:00Z"}' \
    >> project/logs/events.json
  git commit -q -am "a: append event"

  git checkout -q "$(git rev-list --max-parents=0 HEAD)"
  git checkout -q -b branch-b
  printf '%s\n' '{"event":"task_completed","agent":"tester","session_id":"B","date":"2026-10-19T10:01:00Z"}' \
    >> project/logs/events.json
  git commit -q -am "b: append event"
}

@test "two branches each appending one event merge cleanly under merge=union" {
  fork_two yes
  git checkout -q branch-a
  run git merge -q --no-edit branch-b
  [ "$status" -eq 0 ]

  # No conflict left in the index and no markers in the file.
  [ -z "$(git ls-files -u project/logs/events.json)" ]
  [ "$(grep -c '^<<<<<<<' project/logs/events.json || true)" -eq 0 ]

  # Both appended events survive, alongside the base event, and every line is a record.
  [ "$(wc -l < project/logs/events.json | tr -d ' ')" -eq 3 ]
  jq -s -e 'length == 3 and ([.[].session_id] | sort == ["A","B","base"])' project/logs/events.json > /dev/null
}

@test "negative control: without the merge=union attribute the same two appends conflict" {
  fork_two no
  git checkout -q branch-a
  run git merge -q --no-edit branch-b
  [ "$status" -ne 0 ]
  [ -n "$(git ls-files -u project/logs/events.json)" ]
  [ "$(grep -c '^<<<<<<<' project/logs/events.json || true)" -ge 1 ]
  git merge --abort
}

@test "the real repository declares merge=union for the event log" {
  run git -C "$REPO_ROOT" check-attr merge -- project/logs/events.json
  [ "$status" -eq 0 ]
  [ "$output" = "project/logs/events.json: merge: union" ]
}
