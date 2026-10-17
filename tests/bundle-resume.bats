#!/usr/bin/env bats
#
# Coverage for skills/j-do/scripts/bundle-resume.sh (E44_S08).
#
# Every test builds a throwaway git repository with a synthetic story, tasks and bundle manifest under
# BATS_TEST_TMPDIR and points JENGA_PROJECT_ROOT at it. The real board, queue and git state are never touched.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RESUME="$REPO_ROOT/skills/j-do/scripts/bundle-resume.sh"
DO_SKILL="$REPO_ROOT/skills/j-do/SKILL.md"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs" "$PROJ/project/board/stories" "$PROJ/project/board/tasks" "$PROJ/project/queue"
  cat > "$PROJ/project/configs/workflow.json" <<'EOF2'
{
  "paths": {
    "board": "project/board",
    "epics": "project/board/epics",
    "stories": "project/board/stories",
    "tasks": "project/board/tasks",
    "queue": "project/queue",
    "configs": "project/configs"
  }
}
EOF2
  export JENGA_PROJECT_ROOT="$PROJ"
  git -C "$PROJ" init -q
  git -C "$PROJ" config user.email t@example.com
  git -C "$PROJ" config user.name t
  git -C "$PROJ" config commit.gpgsign false
  git -C "$PROJ" commit -q --allow-empty -m one
  ANCHOR="$(git -C "$PROJ" rev-parse HEAD)"
  git -C "$PROJ" commit -q --allow-empty -m two
}

story() {  # story <id> <task ids...>
  local id="$1"; shift
  { printf -- '---\nid: %s\nepic_id: E1\ntitle: s\nstatus: In Progress\ntasks:\n' "$id"; local t; for t in "$@"; do printf '  - %s\n' "$t"; done; printf -- '---\n'; } \
    > "$PROJ/project/board/stories/${id}_x.md"
}
task() {  # task <id> <status>
  printf -- '---\nid: %s\nstory_id: E1_S1\nepic_id: E1\ntitle: t\nstatus: %s\n---\n' "$1" "$2" > "$PROJ/project/board/tasks/$1_x.md"
}
manifest() {  # manifest <anchor> <changed-json> [story]
  printf '{"story_id":"%s","anchor_sha":"%s","started_at":"2026-10-13T00:00:00Z","tasks":["E1_S1_T1","E1_S1_T2","E1_S1_T3"],"task_changed_files":%s}\n' \
    "${3:-E1_S1}" "$1" "$2" > "$PROJ/project/queue/bundle-E1_S1.json"
}
tree_sum() { (cd "$PROJ" && find project -type f | sort | xargs cksum | cksum); }
resume() { run --separate-stderr bash "$RESUME" "${1:-E1_S1}"; }
jq_() { printf '%s' "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

@test "script is executable and passes bash -n" {
  [ -x "$RESUME" ]
  bash -n "$RESUME"
}

@test "usage error exits 2" {
  run bash "$RESUME"
  [ "$status" -eq 2 ]
  run bash "$RESUME" notastory
  [ "$status" -eq 2 ]
}

@test "no manifest: fresh, null anchor, whole task list in order, nothing skipped" {
  story E1_S1 E1_S1_T1 E1_S1_T2 E1_S1_T3
  task E1_S1_T1 Pending; task E1_S1_T2 Pending; task E1_S1_T3 Pending
  resume
  [ "$status" -eq 0 ]
  [ "$(jq_ 'd["mode"]')" = "fresh" ]
  [ "$(jq_ 'd["anchor_sha"]')" = "None" ]
  [ "$(jq_ '",".join(d["run"])')" = "E1_S1_T1,E1_S1_T2,E1_S1_T3" ]
  [ "$(jq_ 'len(d["skipped"])')" = "0" ]
}

@test "success prints exactly one JSON object and nothing on stderr" {
  story E1_S1 E1_S1_T1; task E1_S1_T1 Pending
  resume
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  [ -z "$stderr" ]
}

@test "valid manifest: resume, original anchor verbatim, only the pending task runs" {
  story E1_S1 E1_S1_T1 E1_S1_T2 E1_S1_T3
  task E1_S1_T1 Passed; task E1_S1_T2 Passed; task E1_S1_T3 Pending
  manifest "$ANCHOR" '{"E1_S1_T1":["a"],"E1_S1_T2":["b"]}'
  resume
  [ "$status" -eq 0 ]
  [ "$(jq_ 'd["mode"]')" = "resume" ]
  [ "$(jq_ 'd["anchor_sha"]')" = "$ANCHOR" ]
  [ "$(jq_ '",".join(d["run"])')" = "E1_S1_T3" ]
  [ "$(jq_ '",".join(d["skipped"])')" = "E1_S1_T1,E1_S1_T2" ]
}

@test "Merged and Passed with remarks count as skipped" {
  story E1_S1 E1_S1_T1 E1_S1_T2 E1_S1_T3
  task E1_S1_T1 Merged; task E1_S1_T2 "Passed with remarks"; task E1_S1_T3 Pending
  manifest "$ANCHOR" '{"E1_S1_T1":[],"E1_S1_T2":[]}'
  resume
  [ "$status" -eq 0 ]
  [ "$(jq_ '",".join(d["skipped"])')" = "E1_S1_T1,E1_S1_T2" ]
  [ "$(jq_ '",".join(d["run"])')" = "E1_S1_T3" ]
}

@test "board status wins: Passed task absent from task_changed_files is skipped" {
  story E1_S1 E1_S1_T1 E1_S1_T2
  task E1_S1_T1 Passed; task E1_S1_T2 Pending
  manifest "$ANCHOR" '{}'
  resume
  [ "$status" -eq 0 ]
  [ "$(jq_ '",".join(d["skipped"])')" = "E1_S1_T1" ]
  [ "$(jq_ '",".join(d["run"])')" = "E1_S1_T2" ]
}

@test "board status wins: task present in task_changed_files but not Passed is run again" {
  story E1_S1 E1_S1_T1 E1_S1_T2
  task E1_S1_T1 Pending; task E1_S1_T2 Pending
  manifest "$ANCHOR" '{"E1_S1_T1":["a"]}'
  resume
  [ "$status" -eq 0 ]
  [ "$(jq_ '",".join(d["run"])')" = "E1_S1_T1,E1_S1_T2" ]
}

@test "Failed, In Progress and Blocked tasks are run and noted" {
  story E1_S1 E1_S1_T1 E1_S1_T2 E1_S1_T3
  task E1_S1_T1 Failed; task E1_S1_T2 "In Progress"; task E1_S1_T3 Blocked
  manifest "$ANCHOR" '{}'
  resume
  [ "$status" -eq 0 ]
  [ "$(jq_ '",".join(d["run"])')" = "E1_S1_T1,E1_S1_T2,E1_S1_T3" ]
  [ "$(jq_ 'len([n for n in d["notes"] if "will be run again" in n])')" = "3" ]
}

@test "all tasks terminal-success: resume with an empty run list" {
  story E1_S1 E1_S1_T1 E1_S1_T2
  task E1_S1_T1 Passed; task E1_S1_T2 Passed
  manifest "$ANCHOR" '{"E1_S1_T1":[],"E1_S1_T2":[]}'
  resume
  [ "$status" -eq 0 ]
  [ "$(jq_ 'd["mode"]')" = "resume" ]
  [ "$(jq_ 'len(d["run"])')" = "0" ]
}

@test "story list wins over manifest task list and the drift is noted" {
  story E1_S1 E1_S1_T1 E1_S1_T4
  task E1_S1_T1 Passed; task E1_S1_T4 Pending
  manifest "$ANCHOR" '{"E1_S1_T1":[]}'
  resume
  [ "$status" -eq 0 ]
  [ "$(jq_ '",".join(d["run"])')" = "E1_S1_T4" ]
  [ "$(jq_ 'len([n for n in d["notes"] if "drift" in n])')" = "1" ]
}

@test "anchor not an ancestor of HEAD: exit 3, cause on stderr, disk unchanged" {
  story E1_S1 E1_S1_T1; task E1_S1_T1 Pending
  manifest "0123456789012345678901234567890123456789" '{}'
  local before; before="$(tree_sum)"
  resume
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not an ancestor"* ]]
  [ -z "$output" ]
  [ "$(tree_sum)" = "$before" ]
}

@test "unparseable manifest: exit 3, disk unchanged" {
  story E1_S1 E1_S1_T1; task E1_S1_T1 Pending
  printf '{not json' > "$PROJ/project/queue/bundle-E1_S1.json"
  local before; before="$(tree_sum)"
  resume
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"unparseable"* ]]
  [ "$(tree_sum)" = "$before" ]
}

@test "manifest missing anchor_sha: exit 3" {
  story E1_S1 E1_S1_T1; task E1_S1_T1 Pending
  printf '{"story_id":"E1_S1","tasks":[]}' > "$PROJ/project/queue/bundle-E1_S1.json"
  resume
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"anchor_sha"* ]]
}

@test "manifest naming another story: exit 3" {
  story E1_S1 E1_S1_T1; task E1_S1_T1 Pending
  manifest "$ANCHOR" '{}' E9_S9
  resume
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"E9_S9"* ]]
}

@test "story file missing: exit 4" {
  resume E1_S1
  [ "$status" -eq 4 ]
}

@test "task file missing: exit 4" {
  story E1_S1 E1_S1_T1 E1_S1_T2; task E1_S1_T1 Pending
  resume
  [ "$status" -eq 4 ]
}

@test "the script contains no write, move, delete or directory-creating construct" {
  local real
  real=$(grep -vE '^\s*#' "$RESUME" \
    | sed -e 's#[0-9]*>/dev/null##g' -e 's/[0-9]*>&[0-9]//g' \
    | grep -nE '>|open\([^)]*, *.(r\+|[wax])|mode *= *.(r\+|[wax])|os\.(remove|unlink|rename|replace|mkdir|makedirs|rmdir)|shutil\.|\brm\b|\bmv\b|\btee\b|\bmkdir\b|\btouch\b|&$' || true)
  [ -z "$real" ] || { echo "write construct found: $real" >&2; return 1; }
}

@test "the script hardcodes no project/ path" {
  run bash -c "grep -vE '^\s*#' '$RESUME' | grep -n 'project/'"
  [ "$status" -ne 0 ]
}

@test "SKILL.md wires the helper and no longer claims a resume path does not exist" {
  grep -q 'bundle-resume.sh' "$DO_SKILL"
  run grep -niE "no bundle-resume path|no bundle.resume|resume the bundle.*(does not|doesn.t) exist|bundle resume (path )?does not exist" "$DO_SKILL"
  [ "$status" -ne 0 ]
  grep -q 'resume the bundle' "$DO_SKILL"
}

@test "anti-vacuity: a helper stubbed to always print fresh fails the resume case" {
  local stub="$BATS_TEST_TMPDIR/stub.sh"
  printf '#!/usr/bin/env bash\necho "{\\"mode\\":\\"fresh\\"}"\n' > "$stub"
  story E1_S1 E1_S1_T1 E1_S1_T2
  task E1_S1_T1 Passed; task E1_S1_T2 Pending
  manifest "$ANCHOR" '{"E1_S1_T1":[]}'
  run bash "$stub" E1_S1
  [ "$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mode"])')" = "fresh" ]
  resume
  [ "$(jq_ 'd["mode"]')" = "resume" ]
}

@test "no manifest and every task terminal: fresh carries an all_terminal note; a Pending task suppresses it" {
  story E1_S1 E1_S1_T1 E1_S1_T2
  task E1_S1_T1 Passed; task E1_S1_T2 Merged
  resume
  [ "$status" -eq 0 ]
  [ "$(jq_ 'd["mode"]')" = "fresh" ]
  [[ "$output" == *all_terminal* ]]
  task E1_S1_T2 Pending
  resume
  [[ "$output" != *all_terminal* ]]
  grep -q 'all_terminal' "$DO_SKILL"
}

@test "c.1 diffs the commit, not the working tree" {
  run grep -c 'git diff --name-only HEAD~1 HEAD' "$REPO_ROOT/skills/j-do/SKILL.md"
  [ "$output" -ge 1 ]
  run grep -c 'git diff --name-only HEAD~1`' "$REPO_ROOT/skills/j-do/SKILL.md"
  [ "$output" -eq 0 ]
}
