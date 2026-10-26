#!/usr/bin/env bats
#
# Coverage for E79_S02_T04: the two j-close-story diff-stat scripts now resolve their commits through
# scripts/commits-for-item.sh instead of their own `git log --grep`.
#
#   skills/j-close-story/scripts/extract-task-diff-stats.sh   (audit row M1, per-task stats)
#   skills/j-close-story/scripts/extract-diff-stats.sh        (audit row M2, story-level stats)
#
# No bats suite covered either script before this task (project/documentation/commit-consumer-audit.md, test
# coverage section), so this file is both the regression gate for EST-only history and the proof of the three
# deliberate differences from the old unanchored substring match:
#
#   1. The id is anchored: an id followed by a digit or an underscore is another id. Task E10_S01_T01 no longer
#      picks up the commit for E10_S01_T010, nor a message that only mentions `E10_S01_T01_slug`.
#   2. extract-diff-stats.sh still means "the story's work": it resolves the story id plus each child task id
#      (story `tasks:` list and project/board/tasks/ files, superseded included) and unions them. A commit that
#      names a task with no board file, and a commit that names a different story whose id merely starts with this
#      one (E10_S010 for E10_S01), are not counted.
#   3. A malformed story id is a usage error (exit 1) instead of an all-zero success.
#
# Everything is built in throwaway fixture repositories under $BATS_TEST_TMPDIR; the working repository is never
# read for history. The scripts under test are run from their real location, so the resolver they find is the real
# scripts/commits-for-item.sh through the script-relative lookup.
#
# Fixture history (each commit adds one new file of N lines, so a commit is 1 file and N insertions):
#
#    1  task(E10_S01_T05): scaffold             ROOT commit        1 line   (T05)
#    2  story(E10_S01): outline                                    2 lines  (story)
#    3  task(E10_S01_T01): add retry                               3 lines  (T01)
#    4  ASD-001 add retry + Jenga-Task: E10_S01_T01 trailer        4 lines  (T01, by trailer only)
#    5  task(E10_S01_T010): add backoff                            5 lines  (another task: T01 is its prefix)
#    6  story(E10_S010): another story                             7 lines  (another story: E10_S01 is its prefix)
#    7  chore: notes for E10_S01_T01_slug                          11 lines (names T01 only as a prefix)
#    8  task(E10_S01_T01, E10_S01_T02): shared                     13 lines (bundle: T01 and T02)
#    9  task(E10_S01_T03): add logging                             17 lines (T03)
#   10  task(E10_S01_T09): orphan                                  19 lines (T09: no board file)
#   11  wip: unrelated                                             23 lines (names nothing)
#   12  task(E10_S01_T04): old approach                            29 lines (T04: board file is in tasks/_superseded)
#
# Board: story E10_S01 lists T01, T02, T03, T05 in `tasks:`; tasks/ holds T01, T02, T03, T05 and
# tasks/_superseded/ holds T04. T09 and T010 have no board file.
#
# Hand-computed expectations:
#   task T01    commits {3,4,8}   files 3  lines 3+4+13 = 20     (legacy substring match: adds 5 and 7 -> 5 / 36)
#   task T02    commits {8}       files 1  lines 13
#   task T03    commits {9}       files 1  lines 17
#   task T05    root commit       0 / 0   (a root commit has no parent: skipped, as before; the story script
#               does count it, because `git log --stat` shows a root commit's files)
#   task T99    nothing           0 / 0
#   story S01   commits {1,2,3,4,8,9,12}  diff_added 1+2+3+4+13+17+29 = 69, removed 0, 7 commits
#               printed as commits_matched 6: the legacy `wc -l` over newline-less `--pretty=format:%H` output
#               reports one fewer than the commit count and that quirk is kept on purpose (byte-identical output).
#               (legacy unanchored match would add 5, 6, 7 and 10 -> 69+5+7+11+19 = 111)

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TASK_SCRIPT="$REPO_ROOT/skills/j-close-story/scripts/extract-task-diff-stats.sh"
STORY_SCRIPT="$REPO_ROOT/skills/j-close-story/scripts/extract-diff-stats.sh"
SKILL_MD="$REPO_ROOT/skills/j-close-story/SKILL.md"
RESOLVER="$REPO_ROOT/scripts/commits-for-item.sh"

setup() {
  # No global identity, no signing, no hooks: the fixture alone decides how git behaves.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  FIX="$BATS_TEST_TMPDIR/fixture"
}

# add_file <name> <lines> <subject> [<body>] : commit a new file of <lines> lines.
add_file() {
  local name="$1" lines="$2"
  seq 1 "$lines" >"$FIX/$name"
  git -C "$FIX" add "$name"
  if [ $# -ge 4 ]; then
    git -C "$FIX" commit -q -m "$3" -m "$4"
  else
    git -C "$FIX" commit -q -m "$3"
  fi
}

build_fixture() {
  git init -q -b main "$FIX"
  git -C "$FIX" config user.email test@example.com
  git -C "$FIX" config user.name "Test"
  git -C "$FIX" config commit.gpgsign false
  git -C "$FIX" config core.hooksPath /dev/null

  add_file base.txt 1 "task(E10_S01_T05): scaffold"
  add_file a.txt 2 "story(E10_S01): outline"
  add_file b.txt 3 "task(E10_S01_T01): add retry"
  add_file c.txt 4 "ASD-001 add retry" "Jenga-Task: E10_S01_T01"
  add_file d.txt 5 "task(E10_S01_T010): add backoff"
  add_file e.txt 7 "story(E10_S010): another story"
  add_file f.txt 11 "chore: notes for E10_S01_T01_slug"
  add_file g.txt 13 "task(E10_S01_T01, E10_S01_T02): shared"
  add_file h.txt 17 "task(E10_S01_T03): add logging"
  add_file i.txt 19 "task(E10_S01_T09): orphan"
  add_file j.txt 23 "wip: unrelated"
  add_file k.txt 29 "task(E10_S01_T04): old approach"

  mkdir -p "$FIX/project/board/stories" "$FIX/project/board/tasks/_superseded"
  cat >"$FIX/project/board/stories/E10_S01_sample-story.md" <<'EOF'
---
id: E10_S01
status: In Progress
tasks:
  - E10_S01_T01
  - E10_S01_T02
  - E10_S01_T03
  - E10_S01_T05
---

# Story
EOF
  : >"$FIX/project/board/tasks/E10_S01_T01_add-retry.md"
  : >"$FIX/project/board/tasks/E10_S01_T02_second.md"
  : >"$FIX/project/board/tasks/E10_S01_T03_logging.md"
  : >"$FIX/project/board/tasks/E10_S01_T05_scaffold.md"
  : >"$FIX/project/board/tasks/_superseded/E10_S01_T04_old-approach.md"
}

# in_fixture <command...> : run a command with the fixture as the working directory.
in_fixture() {
  (cd "$FIX" && "$@")
}

# --------------------------------------------------------------------------------------------------------------
# extract-task-diff-stats.sh (M1)
# --------------------------------------------------------------------------------------------------------------

@test "task stats: EST subject, trailer-only and bundle commits are summed; prefix ids are not" {
  build_fixture
  run in_fixture bash "$TASK_SCRIPT" E10_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "actual_files_changed: 3
actual_lines_delta: 20" ]
}

@test "task stats: a bundle commit gives each of its tasks the full bundle stats" {
  build_fixture
  run in_fixture bash "$TASK_SCRIPT" E10_S01_T02
  [ "$status" -eq 0 ]
  [ "$output" = "actual_files_changed: 1
actual_lines_delta: 13" ]
}

@test "task stats: a task with one plain commit" {
  build_fixture
  run in_fixture bash "$TASK_SCRIPT" E10_S01_T03
  [ "$status" -eq 0 ]
  [ "$output" = "actual_files_changed: 1
actual_lines_delta: 17" ]
}

@test "task stats: a task that only has a root commit reports 0 and 0 (root commit skipped, as before)" {
  build_fixture
  run in_fixture bash "$TASK_SCRIPT" E10_S01_T05
  [ "$status" -eq 0 ]
  [ "$output" = "actual_files_changed: 0
actual_lines_delta: 0" ]
}

@test "task stats: no commit names the task -> 0 and 0, exit 0 (no --require-nonempty here)" {
  build_fixture
  run in_fixture bash "$TASK_SCRIPT" E10_S01_T99
  [ "$status" -eq 0 ]
  [ "$output" = "actual_files_changed: 0
actual_lines_delta: 0" ]
}

@test "task stats: intended difference from the legacy substring match is exactly the prefix over-match" {
  build_fixture
  # The legacy call, reproduced inline for the comparison only: it sees commits 5 and 7 as well.
  legacy="$(git -C "$FIX" log --all --no-merges --grep="E10_S01_T01" --pretty=format:%s)"
  new="$(bash "$RESOLVER" E10_S01_T01 --repo "$FIX" | while read -r sha; do git -C "$FIX" log -1 --pretty=format:%s "$sha"; echo; done)"
  extra="$(printf '%s\n' "$legacy" | grep -vxF -f <(printf '%s\n' "$new") || true)"
  [ "$extra" = "chore: notes for E10_S01_T01_slug
task(E10_S01_T010): add backoff" ]
}

@test "task stats: missing and malformed ids are still rejected with exit 1" {
  build_fixture
  run in_fixture bash "$TASK_SCRIPT"
  [ "$status" -eq 1 ]
  run in_fixture bash "$TASK_SCRIPT" not-an-id
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid task ID format"* ]]
}

# --------------------------------------------------------------------------------------------------------------
# extract-diff-stats.sh (M2)
# --------------------------------------------------------------------------------------------------------------

@test "story stats: the story's own commits plus its tasks' commits (tasks: list, tasks/, tasks/_superseded/)" {
  build_fixture
  run in_fixture bash "$STORY_SCRIPT" E10_S01
  [ "$status" -eq 0 ]
  [ "$output" = "diff_added: 69
diff_removed: 0
commits_matched: 6
commits_unmatched_in_window: unknown" ]
}

@test "story stats: a different story whose id starts with this one, and a task with no board file, are not counted" {
  build_fixture
  # Legacy substring match would have added commits 5, 6, 7 and 10 (5+7+11+19 = 42 more lines): 111.
  run in_fixture bash "$STORY_SCRIPT" E10_S01
  [ "$status" -eq 0 ]
  [[ "$output" != *"diff_added: 111"* ]]
  run in_fixture bash "$STORY_SCRIPT" E10_S010
  [ "$status" -eq 0 ]
  [ "$output" = "diff_added: 7
diff_removed: 0
commits_matched: 0
commits_unmatched_in_window: unknown" ]
}

@test "story stats: the date window counts commits in the window that are not part of the story" {
  build_fixture
  # A window wide enough to hold every fixture commit whatever the time zone or clock.
  run in_fixture bash "$STORY_SCRIPT" E10_S01 2000-01-01 2099-12-31
  [ "$status" -eq 0 ]
  # 12 commits in the fixture, 7 resolved to the story -> 5 unmatched (5, 6, 7, 10, 11).
  [[ "$output" == *"commits_unmatched_in_window: 5"* ]]
}

@test "story stats: no commit for the story -> zeros and exit 0" {
  build_fixture
  run in_fixture bash "$STORY_SCRIPT" E10_S77
  [ "$status" -eq 0 ]
  [ "$output" = "diff_added: 0
diff_removed: 0
commits_matched: 0
commits_unmatched_in_window: unknown" ]
}

@test "story stats: no story argument, or a malformed story id, is a usage error (exit 1)" {
  build_fixture
  run in_fixture bash "$STORY_SCRIPT"
  [ "$status" -eq 1 ]
  run in_fixture bash "$STORY_SCRIPT" E10_S01_T01
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid story ID format"* ]]
}

# --------------------------------------------------------------------------------------------------------------
# Resolver lookup: monorepo layout, node_modules layout, cwd fallbacks, missing resolver
# --------------------------------------------------------------------------------------------------------------

# install_layout <root> : copy the skill scripts and the resolver into <root> keeping the real relative layout.
install_layout() {
  mkdir -p "$1/skills/j-close-story/scripts" "$1/scripts"
  cp "$TASK_SCRIPT" "$STORY_SCRIPT" "$1/skills/j-close-story/scripts/"
  cp "$RESOLVER" "$1/scripts/"
}

@test "lookup: monorepo layout (resolver at <root>/scripts, found script-relative, not through the cwd)" {
  build_fixture
  install_layout "$BATS_TEST_TMPDIR/mono"
  run in_fixture bash "$BATS_TEST_TMPDIR/mono/skills/j-close-story/scripts/extract-task-diff-stats.sh" E10_S01_T01
  [ "$status" -eq 0 ]
  [[ "$output" == *"actual_files_changed: 3"* ]]
  run in_fixture bash "$BATS_TEST_TMPDIR/mono/skills/j-close-story/scripts/extract-diff-stats.sh" E10_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff_added: 69"* ]]
}

@test "lookup: node_modules/@jenga-ai/agent layout" {
  build_fixture
  install_layout "$BATS_TEST_TMPDIR/consumer/node_modules/@jenga-ai/agent"
  base="$BATS_TEST_TMPDIR/consumer/node_modules/@jenga-ai/agent/skills/j-close-story/scripts"
  run in_fixture bash "$base/extract-task-diff-stats.sh" E10_S01_T01
  [ "$status" -eq 0 ]
  [[ "$output" == *"actual_lines_delta: 20"* ]]
  run in_fixture bash "$base/extract-diff-stats.sh" E10_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff_added: 69"* ]]
}

@test "lookup: the .claude mirror layout" {
  build_fixture
  install_layout "$BATS_TEST_TMPDIR/mirror/.claude"
  run in_fixture bash "$BATS_TEST_TMPDIR/mirror/.claude/skills/j-close-story/scripts/extract-task-diff-stats.sh" E10_S01_T03
  [ "$status" -eq 0 ]
  [[ "$output" == *"actual_lines_delta: 17"* ]]
}

@test "lookup: scripts copied somewhere with no resolver beside them fall back to ./scripts in the working directory" {
  build_fixture
  mkdir -p "$BATS_TEST_TMPDIR/lonely/skills/j-close-story/scripts" "$FIX/scripts"
  cp "$TASK_SCRIPT" "$STORY_SCRIPT" "$BATS_TEST_TMPDIR/lonely/skills/j-close-story/scripts/"
  cp "$RESOLVER" "$FIX/scripts/"
  run in_fixture bash "$BATS_TEST_TMPDIR/lonely/skills/j-close-story/scripts/extract-task-diff-stats.sh" E10_S01_T01
  [ "$status" -eq 0 ]
  [[ "$output" == *"actual_files_changed: 3"* ]]
}

@test "lookup: ... and to node_modules/@jenga-ai/agent/scripts in the working directory" {
  build_fixture
  mkdir -p "$BATS_TEST_TMPDIR/lonely/skills/j-close-story/scripts" "$FIX/node_modules/@jenga-ai/agent/scripts"
  cp "$TASK_SCRIPT" "$STORY_SCRIPT" "$BATS_TEST_TMPDIR/lonely/skills/j-close-story/scripts/"
  cp "$RESOLVER" "$FIX/node_modules/@jenga-ai/agent/scripts/"
  run in_fixture bash "$BATS_TEST_TMPDIR/lonely/skills/j-close-story/scripts/extract-diff-stats.sh" E10_S01
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff_added: 69"* ]]
}

@test "lookup: no resolver anywhere is a loud error (exit 1) naming the resolver, never a silent 0 and 0" {
  build_fixture
  mkdir -p "$BATS_TEST_TMPDIR/lonely/skills/j-close-story/scripts"
  cp "$TASK_SCRIPT" "$STORY_SCRIPT" "$BATS_TEST_TMPDIR/lonely/skills/j-close-story/scripts/"
  run in_fixture bash "$BATS_TEST_TMPDIR/lonely/skills/j-close-story/scripts/extract-task-diff-stats.sh" E10_S01_T01
  [ "$status" -eq 1 ]
  [[ "$output" == *"commits-for-item.sh"* ]]
  [[ "$output" != *"actual_files_changed"* ]]
  run in_fixture bash "$BATS_TEST_TMPDIR/lonely/skills/j-close-story/scripts/extract-diff-stats.sh" E10_S01
  [ "$status" -eq 1 ]
  [[ "$output" == *"commits-for-item.sh"* ]]
}

# --------------------------------------------------------------------------------------------------------------
# Static: no inline message search is left
# --------------------------------------------------------------------------------------------------------------

@test "static: neither script nor SKILL.md contains a git log ... --grep command" {
  run grep -nE 'git +log[^#]*--grep' "$TASK_SCRIPT" "$STORY_SCRIPT" "$SKILL_MD"
  [ "$status" -eq 1 ]
}

@test "static: both scripts call commits-for-item.sh and SKILL.md points at it" {
  grep -q 'commits-for-item.sh' "$TASK_SCRIPT"
  grep -q 'commits-for-item.sh' "$STORY_SCRIPT"
  grep -q 'scripts/commits-for-item.sh' "$SKILL_MD"
}

@test "static: neither script passes --require-nonempty in code (that is E79_S06)" {
  # Comments may mention the flag; only non-comment lines count.
  run bash -c 'grep -hv "^[[:space:]]*#" "$@" | grep -e "--require-nonempty"' _ "$TASK_SCRIPT" "$STORY_SCRIPT"
  [ "$status" -eq 1 ]
}
