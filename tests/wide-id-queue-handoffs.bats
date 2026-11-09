#!/usr/bin/env bats
#
# Group 3 of the E86_S05 audit (E86_S05_T04): queue triggers, handoffs, context digests and bundle manifests with
# three- and four-digit board IDs.
#
# Subject: a developer handoff for E1001_S100_T100 and a scrum-master batch handoff for E100_S100_T99/T100 are routed
# by hooks/on_session_end.sh to trigger lines that carry the exact IDs; the staleness guard (is_task_terminal) maps
# E10_S1_T1 and E10_S1_T10 to their own task files only; a context digest and a bundle manifest round-trip with the
# same IDs; and no reader recovers an ID from a file name by a fixed-width split.
#
#   - hooks/on_session_end.sh                 section 4 routing, is_task_terminal(), section 6 sweep
#   - scripts/write-context-digest.sh, consume-context-digest.sh, sweep-stale-context-digests.sh
#   - skills/j-do/scripts/bundle-resume.sh    bundle-<E##_S##>.json manifest (E1001_S100)
#
# Isolation. Every test builds its own throwaway repository ($PROJ) under $BATS_TEST_TMPDIR. The hook and the scripts
# it calls are COPIED into $PROJ and run there; bundle-resume.sh runs from this repository against JENGA_PROJECT_ROOT
# ($PROJ), is read-only, and so never touches the real board or queue. Nothing pushes or touches a real branch.
#
# The hook appends each trigger pretty-printed (jq without -c), so a record count is `jq -s length`, never `wc -l`.
# Fixed expectations: an ID is never cut or matched by prefix; E10_S1_T1 and E10_S1_T10 each match only themselves.
# Assertions use `[ ... ]` and tests/helpers/assertions.bash, never a bare `[[ ... ]]`.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RESUME="$REPO_ROOT/skills/j-do/scripts/bundle-resume.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed"
  command -v git >/dev/null 2>&1 || skip "git is not installed"

  unset CLAUDE_CODE_SESSION_ID JENGA_SESSION_ID CLAUDE_SESSION_ID JENGA_CHECKLIST_SESSION_ID
  unset CLAUDE_PROJECT_DIR COPILOT_WORKSPACE_FOLDER JENGA_PROJECT_DIR JENGA_AGENT_TYPE CLAUDE_AGENT_TYPE
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  : >"$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1

  PROJ="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/proj"
  mkdir -p "$PROJ/scripts" "$PROJ/lib" "$PROJ/hooks" "$PROJ/project/configs" \
    "$PROJ/project/board/tasks" "$PROJ/project/board/stories" "$PROJ/project/queue"
  local f
  for f in resolve-root with-lock events-append generate-rapport-manifest todo_cleanup \
    write-context-digest consume-context-digest sweep-stale-context-digests; do
    [ -f "$REPO_ROOT/scripts/$f.sh" ] || skip "scripts/$f.sh is not in this tree"
    cp "$REPO_ROOT/scripts/$f.sh" "$PROJ/scripts/$f.sh"
  done
  cp "$REPO_ROOT/lib/resolve-project-dir.sh" "$PROJ/lib/resolve-project-dir.sh"
  cp "$REPO_ROOT/hooks/on_session_end.sh" "$PROJ/hooks/on_session_end.sh"
  cat >"$PROJ/project/configs/workflow.json" <<'EOF'
{"paths":{"board":"project/board","epics":"project/board/epics","stories":"project/board/stories","tasks":"project/board/tasks","queue":"project/queue","configs":"project/configs","logs":"project/logs"}}
EOF
  git -C "$PROJ" init -q
  git -C "$PROJ" config user.name bats
  git -C "$PROJ" config user.email bats@example.invalid
  git -C "$PROJ" config commit.gpgsign false
  git -C "$PROJ" commit -q --allow-empty -m one
  ANCHOR="$(git -C "$PROJ" rev-parse HEAD)"
  git -C "$PROJ" commit -q --allow-empty -m two
  export JENGA_PROJECT_ROOT="$PROJ"
}

# --- helpers ------------------------------------------------------------------------------------------------------

Q() { printf '%s/project/queue/%s' "$PROJ" "$1"; }

# handoff <file-name> <json>: writes a handoff exactly where the agents write them.
handoff() { printf '%s\n' "$2" >"$PROJ/project/queue/handoffs/$1"; }

# task <id> <status>: a board task file named <id>_x.md, as the board names them.
task() { printf -- '---\nid: %s\nstatus: %s\n---\n' "$1" "$2" >"$PROJ/project/board/tasks/$1_x.md"; }

# run_hook [VAR=value ...]: hooks/on_session_end.sh the way the harness runs it, cwd in the fixture, stdin empty.
run_hook() {
  run env "$@" PROJ="$PROJ" bash -c 'cd "$PROJ" && bash hooks/on_session_end.sh </dev/null'
}

dev_handoff() { # dev_handoff <task_id> [<story_id> <epic_id>]
  handoff "developer-sess-$1.json" "$(jq -nc --arg t "$1" --arg s "${2:-}" --arg e "${3:-}" \
    '{agent:"developer",session_id:"sess",status:"implementation_complete",task_id:$t,story_id:$s,epic_id:$e,worktree:"/w",paths:["abc1234"]}')"
}

setup_handoffs_dir() { mkdir -p "$PROJ/project/queue/handoffs"; }

# --- hooks/on_session_end.sh: routing -----------------------------------------------------------------------------

@test "developer handoff for E1001_S100_T100 becomes a test_assignment carrying the exact ids" {
  setup_handoffs_dir
  dev_handoff E1001_S100_T100 E1001_S100 E1001
  run_hook JENGA_AGENT_TYPE=developer JENGA_SESSION_ID=sess
  [ "$status" -eq 0 ]
  [ "$(jq -s 'length' "$(Q tester_triggers.jsonl)")" = "1" ]
  [ "$(jq -r '.type' "$(Q tester_triggers.jsonl)")" = "test_assignment" ]
  [ "$(jq -r '.task_id' "$(Q tester_triggers.jsonl)")" = "E1001_S100_T100" ]
  [ "$(jq -r '.story_id' "$(Q tester_triggers.jsonl)")" = "E1001_S100" ]
  [ "$(jq -r '.epic_id' "$(Q tester_triggers.jsonl)")" = "E1001" ]
  [ ! -e "$PROJ/project/queue/handoffs/developer-sess-E1001_S100_T100.json" ]
}

@test "scrum-master batch handoff yields an implementation_assignment with E100_S100_T99 and E100_S100_T100" {
  setup_handoffs_dir
  handoff "scrum-master-sess-E100_S100_T99.json" \
    '{"agent":"scrum-master","session_id":"sess","status":"planning_complete","task_ids":["E100_S100_T99","E100_S100_T100"],"story_id":"E100_S100","epic_id":"E100"}'
  run_hook JENGA_AGENT_TYPE=scrum-master JENGA_SESSION_ID=sess
  [ "$status" -eq 0 ]
  [ "$(jq -r '.type' "$(Q developer_triggers.jsonl)")" = "implementation_assignment" ]
  [ "$(jq -c '.task_ids' "$(Q developer_triggers.jsonl)")" = '["E100_S100_T99","E100_S100_T100"]' ]
  [ "$(jq -r '.story_id' "$(Q developer_triggers.jsonl)")" = "E100_S100" ]
  [ "$(jq -r '.epic_id' "$(Q developer_triggers.jsonl)")" = "E100" ]
}

@test "failed tester handoff for E1001_S100_T100 routes the full id to both the rollup and the rework trigger" {
  setup_handoffs_dir
  handoff "tester-sess-E1001_S100_T100.json" \
    '{"agent":"tester","session_id":"sess","status":"failed","task_id":"E1001_S100_T100","story_id":"E1001_S100","epic_id":"E1001","worktree":"/w"}'
  run_hook JENGA_AGENT_TYPE=tester JENGA_SESSION_ID=sess
  [ "$status" -eq 0 ]
  [ "$(jq -rs '[.[] | select(.type=="story_rollup")][0].task_id' "$(Q scrum_triggers.jsonl)")" = "E1001_S100_T100" ]
  [ "$(jq -r '.task_id' "$(Q developer_triggers.jsonl)")" = "E1001_S100_T100" ]
  [ "$(jq -r '.type' "$(Q developer_triggers.jsonl)")" = "rework_assignment" ]
}

@test "routing reads the id from the handoff body, never from the file name" {
  setup_handoffs_dir
  # A name that parses (by any fixed-width or last-token rule) to a different task than the body names.
  handoff "developer-sess-E10_S1_T1.json" \
    '{"agent":"developer","session_id":"sess","status":"implementation_complete","task_id":"E1001_S100_T100","story_id":"E1001_S100","epic_id":"E1001","worktree":"/w","paths":[]}'
  run_hook JENGA_AGENT_TYPE=developer JENGA_SESSION_ID=sess
  [ "$(jq -r '.task_id' "$(Q tester_triggers.jsonl)")" = "E1001_S100_T100" ]
}

# --- hooks/on_session_end.sh: staleness guard ---------------------------------------------------------------------

@test "staleness guard: a Passed E10_S1_T10 does not make the live E10_S1_T1 handoff stale" {
  setup_handoffs_dir
  task E10_S1_T1 Pending
  task E10_S1_T10 Passed
  dev_handoff E10_S1_T1 E10_S1 E10
  run_hook JENGA_AGENT_TYPE=developer JENGA_SESSION_ID=sess
  [ "$(jq -r '.task_id' "$(Q tester_triggers.jsonl)")" = "E10_S1_T1" ]
  assert_output_not_contains "stale handoff"
}

@test "staleness guard: a Passed E10_S1_T1 does not make the live E10_S1_T10 handoff stale, and is itself dropped" {
  setup_handoffs_dir
  task E10_S1_T1 Passed
  task E10_S1_T10 Pending
  dev_handoff E10_S1_T1 E10_S1 E10
  dev_handoff E10_S1_T10 E10_S1 E10
  run_hook JENGA_AGENT_TYPE=developer JENGA_SESSION_ID=sess
  assert_output_contains "stale handoff for already-terminal task E10_S1_T1 "
  [ "$(jq -s 'length' "$(Q tester_triggers.jsonl)")" = "1" ]
  [ "$(jq -r '.task_id' "$(Q tester_triggers.jsonl)")" = "E10_S1_T10" ]
}

@test "staleness guard: a longer sibling alone never stands in for a task with no file (fails open)" {
  setup_handoffs_dir
  task E10_S1_T10 Passed
  dev_handoff E10_S1_T1 E10_S1 E10
  run_hook JENGA_AGENT_TYPE=developer JENGA_SESSION_ID=sess
  [ "$(jq -r '.task_id' "$(Q tester_triggers.jsonl)")" = "E10_S1_T1" ]
}

@test "staleness guard: a terminal E1001_S100_T100 is dropped and its shorter E1001_S100_T10 sibling is routed" {
  setup_handoffs_dir
  task E1001_S100_T100 Passed
  task E1001_S100_T10 "In Progress"
  dev_handoff E1001_S100_T100 E1001_S100 E1001
  dev_handoff E1001_S100_T10 E1001_S100 E1001
  run_hook JENGA_AGENT_TYPE=developer JENGA_SESSION_ID=sess
  assert_output_contains "stale handoff for already-terminal task E1001_S100_T100 "
  [ "$(jq -r '.task_id' "$(Q tester_triggers.jsonl)")" = "E1001_S100_T10" ]
}

# --- context digests ----------------------------------------------------------------------------------------------

@test "context digest for E1001_S100_T100 round-trips and its file name parses back to the same id" {
  local sid="1f2e3d4c-aaaa-bbbb-cccc-0123456789ab" path base tid
  path="$(cd "$PROJ" && bash scripts/write-context-digest.sh --agent developer --session-id "$sid" \
    --task-id E1001_S100_T100 --content "touched hooks/on_session_end.sh")"
  base="$(basename "$path")"
  [ "$base" = "developer-$sid-E1001_S100_T100.json" ]
  # the session id carries dashes; the task id is the last dash-separated token, never a fixed-width slice
  tid="${base%.json}"; tid="${tid##*-}"
  [ "$tid" = "E1001_S100_T100" ]
  [ "$(jq -r '.task_id' "$path")" = "E1001_S100_T100" ]
  run bash "$PROJ/scripts/consume-context-digest.sh" --raw "$path"
  [ "$status" -eq 0 ]
  [ "$output" = "touched hooks/on_session_end.sh" ]
  [ ! -e "$path" ]
}

@test "consuming the E10_S1_T1 digest leaves the E10_S1_T10 digest in place" {
  local a b
  a="$(cd "$PROJ" && bash scripts/write-context-digest.sh --agent tester --session-id s1 --task-id E10_S1_T1 --content one)"
  b="$(cd "$PROJ" && bash scripts/write-context-digest.sh --agent tester --session-id s1 --task-id E10_S1_T10 --content ten)"
  [ "$a" != "$b" ]
  run bash "$PROJ/scripts/consume-context-digest.sh" "$a"
  [ "$status" -eq 0 ]
  [ -f "$b" ]
  [ "$(jq -r '.task_id' "$b")" = "E10_S1_T10" ]
}

@test "stale-digest sweep is age-based: it removes only the old digest and names the full id" {
  local old new
  old="$(cd "$PROJ" && bash scripts/write-context-digest.sh --agent developer --session-id s1 --task-id E1001_S100_T100 --content x)"
  new="$(cd "$PROJ" && bash scripts/write-context-digest.sh --agent developer --session-id s1 --task-id E1001_S100_T10 --content y)"
  touch -t 202001010000 "$old"
  run bash "$PROJ/scripts/sweep-stale-context-digests.sh" --context-dir "$PROJ/project/queue/context"
  [ "$status" -eq 0 ]
  assert_output_contains "removed: $old "
  [ ! -e "$old" ]
  [ -f "$new" ]
}

@test "the session-end hook's own digest sweep keeps a fresh wide-id digest" {
  local d
  d="$(cd "$PROJ" && bash scripts/write-context-digest.sh --agent developer --session-id s1 --task-id E1001_S100_T100 --content x)"
  run_hook JENGA_AGENT_TYPE=developer JENGA_SESSION_ID=sess
  [ "$status" -eq 0 ]
  [ -f "$d" ]
}

# --- bundle manifests ---------------------------------------------------------------------------------------------

story() { # story <id> <task ids...>
  local id="$1" t; shift
  { printf -- '---\nid: %s\nepic_id: E1001\ntitle: s\nstatus: In Progress\ntasks:\n' "$id"; for t in "$@"; do printf '  - %s\n' "$t"; done; printf -- '---\n'; } \
    >"$PROJ/project/board/stories/${id}_x.md"
}

@test "bundle manifest for E1001_S100 is read back with the same story, task ids and anchor" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"
  story E1001_S100 E1001_S100_T9 E1001_S100_T10 E1001_S100_T100
  task E1001_S100_T9 Passed; task E1001_S100_T10 Passed; task E1001_S100_T100 Pending
  jq -n --arg a "$ANCHOR" '{story_id:"E1001_S100",anchor_sha:$a,started_at:"2026-11-06T00:00:00Z",
    tasks:["E1001_S100_T9","E1001_S100_T10","E1001_S100_T100"],
    task_changed_files:{"E1001_S100_T9":["a"],"E1001_S100_T10":["b"]}}' >"$(Q bundle-E1001_S100.json)"
  run --separate-stderr bash "$RESUME" E1001_S100
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "resume" ]
  [ "$(printf '%s' "$output" | jq -r '.story_id')" = "E1001_S100" ]
  [ "$(printf '%s' "$output" | jq -r '.anchor_sha')" = "$ANCHOR" ]
  [ "$(printf '%s' "$output" | jq -c '.skipped')" = '["E1001_S100_T9","E1001_S100_T10"]' ]
  [ "$(printf '%s' "$output" | jq -c '.run')" = '["E1001_S100_T100"]' ]
}

@test "bundle-E1001_S100.json is never taken for the manifest of the shorter story E1001_S10" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"
  story E1001_S100 E1001_S100_T1
  story E1001_S10 E1001_S10_T1
  task E1001_S100_T1 Passed; task E1001_S10_T1 Pending
  jq -n --arg a "$ANCHOR" '{story_id:"E1001_S100",anchor_sha:$a,tasks:["E1001_S100_T1"],task_changed_files:{"E1001_S100_T1":["a"]}}' \
    >"$(Q bundle-E1001_S100.json)"
  run --separate-stderr bash "$RESUME" E1001_S10
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "fresh" ]
  [ "$(printf '%s' "$output" | jq -c '.run')" = '["E1001_S10_T1"]' ]
}

@test "a manifest naming another story is refused rather than matched by prefix" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"
  story E1001_S10 E1001_S10_T1
  task E1001_S10_T1 Pending
  jq -n --arg a "$ANCHOR" '{story_id:"E1001_S100",anchor_sha:$a,tasks:[],task_changed_files:{}}' >"$(Q bundle-E1001_S10.json)"
  run --separate-stderr bash "$RESUME" E1001_S10
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "names story"
}
