#!/usr/bin/env bats
#
# skills/j-close-task/scripts/close-task-context.sh: context and report modes against a throwaway project.
# Everything happens in $BATS_TEST_TMPDIR; the real repository is only read through symlinks.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  FIX="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$FIX/skills/j-close-task" "$FIX/skills/j-reconcile" \
    "$FIX/project/board/tasks" "$FIX/project/board/stories" "$FIX/project/board/epics" "$FIX/project/queue"
  cp -R "$REPO_ROOT/skills/j-close-task/scripts" "$FIX/skills/j-close-task/scripts"
  ln -s "$REPO_ROOT/scripts" "$FIX/scripts"
  ln -s "$REPO_ROOT/templates" "$FIX/templates"
  ln -s "$REPO_ROOT/skills/j-reconcile/scripts" "$FIX/skills/j-reconcile/scripts"
  SCRIPT="$FIX/skills/j-close-task/scripts/close-task-context.sh"

  board_file() { # <dir> <id> <status> [extra frontmatter]
    printf -- '---\nid: %s\nstatus: %s\n%s---\n\n# %s\n' "$2" "$3" "${4:-}" "$2" > "$1/$2_x.md"
  }
  board_file "$FIX/project/board/epics" E99 "In Progress"
  board_file "$FIX/project/board/stories" E99_S01 "In Progress"
  board_file "$FIX/project/board/tasks" E99_S01_T01 "Pending"
  board_file "$FIX/project/board/tasks" E99_S01_T02 "Merged"

  git -C "$FIX" init -q -b main
  git -C "$FIX" config user.email t@example.com
  git -C "$FIX" config user.name t
  git -C "$FIX" config commit.gpgsign false
  git -C "$FIX" add -A
  git -C "$FIX" commit -q -m "chore: fixture board"
  git -C "$FIX" commit -q --allow-empty -m "task(E99_S01_T01): implement the thing"
  git -C "$FIX" checkout -q -b elsewhere
  git -C "$FIX" commit -q --allow-empty -m "task(E99_S01_T02): only on another branch"
  git -C "$FIX" checkout -q main
}

@test "context resolves ids, files, status class and the merged commit" {
  run bash "$SCRIPT" context E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$(jq -r .story_id <<<"$output")" = "E99_S01" ]
  [ "$(jq -r .epic_id <<<"$output")" = "E99" ]
  [ "$(jq -r .task_status <<<"$output")" = "Pending" ]
  [ "$(jq -r .status_class <<<"$output")" = "incomplete" ]
  [ "$(jq -r '.commits | length' <<<"$output")" = "1" ]
  [ "$(jq -r .task_file <<<"$output")" = "project/board/tasks/E99_S01_T01_x.md" ]
}

@test "the sender object carries the commits as paths and the main checkout as worktree" {
  run bash "$SCRIPT" context E99_S01_T01 --session sess-42
  [ "$status" -eq 0 ]
  [ "$(jq -r .sender.session_id <<<"$output")" = "sess-42" ]
  [ "$(jq -c .sender.paths <<<"$output")" = "$(jq -c .commits <<<"$output")" ]
  [ "$(jq -r .sender.worktree <<<"$output")" = "$(cd "$FIX" && pwd -P)" ] || [ "$(jq -r .sender.worktree <<<"$output")" = "$FIX" ]
  [ "$(jq -r .sender.task_id <<<"$output")" = "E99_S01_T01" ]
}

@test "a commit only on another branch lands in other_branch_commits, not commits" {
  run bash "$SCRIPT" context E99_S01_T02
  [ "$status" -eq 0 ]
  [ "$(jq -r '.commits | length' <<<"$output")" = "0" ]
  [ "$(jq -r '.other_branch_commits | length' <<<"$output")" = "1" ]
}

@test "a script-set status counts as the ladder class" {
  run bash "$SCRIPT" context E99_S01_T02
  [ "$(jq -r .status_class <<<"$output")" = "ladder" ]
}

@test "an unknown task exits 1 and a malformed id exits 2" {
  run bash "$SCRIPT" context E99_S01_T09
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" context nope
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" bogus E99_S01_T01
  [ "$status" -eq 2 ]
}

@test "report lists the open siblings and an empty queue" {
  run bash "$SCRIPT" report E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$(jq -r '.story.open_tasks | map(.id) | join(",")' <<<"$output")" = "E99_S01_T01" ]
  [ "$(jq -r '.epic.open_stories | map(.id) | join(",")' <<<"$output")" = "E99_S01" ]
  [ "$(jq -r .queue.total <<<"$output")" = "0" ]
}

@test "report counts queued triggers by type" {
  printf '%s\n%s\n' '{"type":"story_rollup","story_id":"E99_S01"}' '{"type":"rapport_review"}' \
    > "$FIX/project/queue/scrum_triggers.jsonl"
  run bash "$SCRIPT" report E99_S01_T01
  [ "$status" -eq 0 ]
  [ "$(jq -r .queue.total <<<"$output")" = "2" ]
  [ "$(jq -r '.queue.types | map(.type) | sort | join(",")' <<<"$output")" = "rapport_review,story_rollup" ]
}

@test "neither mode writes into the project" {
  before="$(cd "$FIX" && find . -path ./.git -prune -o -type f -newer "$SCRIPT" -print | sort)"
  bash "$SCRIPT" context E99_S01_T01 >/dev/null
  bash "$SCRIPT" report E99_S01_T01 >/dev/null
  after="$(cd "$FIX" && find . -path ./.git -prune -o -type f -newer "$SCRIPT" -print | sort)"
  [ "$before" = "$after" ]
  [ -z "$(git -C "$FIX" status --porcelain)" ]
}
