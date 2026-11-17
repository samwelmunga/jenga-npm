#!/usr/bin/env bats
#
# Coverage for E92_S02_T05: /j-do shows the progress bar after finished tasks and honours the caller-supplied
# `progress_owner` sender field.
#
# What is under test (text assertions over two files, no scripts run):
#   - skills/j-do/assets/sender_template.json  the optional progress_owner field, empty by default
#   - skills/j-do/SKILL.md                     ### 4.1.3 (new), the ### 4.4 progress_owner paragraph and the ### 7 pointer
#
# What this suite guards. SKILL.md says WHEN to call run-progress.sh and nothing about counting or drawing; the
# E67_S11 foreground hooks are neither moved, edited nor duplicated.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL="$REPO_ROOT/skills/j-do/SKILL.md"
TEMPLATE="$REPO_ROOT/skills/j-do/assets/sender_template.json"

# The ### headings of skills/j-do/SKILL.md as they were before E92_S02_T05, in order. Recorded at the start of the task.
ORIGINAL_HEADINGS='### 0. Load threshold config
### 1. Check for `project/todo.md`
### 1.4. Front-loaded foreground ask (once per invocation)
### 1.5. Story-Bundle Execution Mode
### Bundle Manifest and Rollback Anchor
### 2. List tasks and let the user choose
### 3. Detect and break down Epics or Stories (scrum-master phase)
### 4. Resolve the task to full scrum board context
### 4.1. Override validation
### 4.1.2. Pre-task gate
### 4.1.5. `--trivial` Dispatch-Time Override
### 4.2. Inline Execution Path (execution_scope: inline)
### 4.3. Light Execution Path (execution_scope: light)
### 4.4. Developer Concurrency Slot Enforcement (Shared Procedure)
### 5. Invoke the developer agent
### 5.1. Intent-vs-Diff Check (needs_docs: false only)
### 6. Verify documentation
### 7. After successful completion
### 7.1. Task-Completion Cleanup Procedure (Shared Procedure)
### 8. Break checkpoint, then loop
### 8.1. Persist usage at the end of the run (`E76_S02_T05`)'
FG_COUNT_BEFORE=4

# The new section's body: from its heading up to the next ### heading.
new_section() {
  awk '/^### 4\.1\.3\. Progress bar/{f=1; print; next} f && /^### /{exit} f{print}' "$SKILL"
}

@test "sender_template.json parses with jq" {
  run jq . "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "progress_owner is a string defaulting to empty" {
  run jq -r '.sender | has("progress_owner")' "$TEMPLATE"
  [ "$output" = "true" ]
  run jq -r '.sender.progress_owner | type' "$TEMPLATE"
  [ "$output" = "string" ]
  run jq -r '.sender.progress_owner' "$TEMPLATE"
  [ "$output" = "" ]
}

@test "the template's other fields are unchanged" {
  run jq -c '.sender | del(.progress_owner) | keys_unsorted' "$TEMPLATE"
  [ "$output" = '["agent","session_id","task_id","story_id","epic_id","date","paths","worktree","checklist_run_id"]' ]
  run jq -c '.sender | del(.progress_owner)' "$TEMPLATE"
  [ "$output" = '{"agent":"orchestrator","session_id":"","task_id":"","story_id":"","epic_id":"","date":"","paths":[],"worktree":"","checklist_run_id":""}' ]
}

@test "SKILL.md documents progress_owner: empty prints, caller owns the print" {
  grep -q '`progress_owner` (optional, caller-supplied)' "$SKILL"
  run grep -F 'Empty means this `/do` prints it. `caller` means `/jenga` or `/dooo` owns the print' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "the progress_owner paragraph sits next to the checklist_run_id paragraph in ### 4.4" {
  a="$(grep -n '^\*\*`checklist_run_id` (optional, caller-supplied)' "$SKILL" | cut -d: -f1)"
  b="$(grep -n '^\*\*`progress_owner` (optional, caller-supplied)' "$SKILL" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ]
  [ "$b" -gt "$a" ]
  [ $((b - a)) -le 4 ]
}

@test "the new step names run-progress.sh and calls only that for the bar" {
  new_section | grep -q 'skills/j-break/scripts/run-progress.sh'
  run bash -c "$(declare -f new_section); SKILL='$SKILL'; new_section | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u"
  [ "$output" = "run-progress.sh" ]
}

@test "the new step contains no counting and no bar drawing" {
  sec="$(new_section)"
  [ -n "$sec" ]
  # no status names, no bar glyphs (line cells, goal flag, star), no arithmetic over counts
  run grep -E 'Passed|Failed|Pending|In Progress|Merged|Rejected|Blocked|━|╌|⚑|★|⊘|\[#|\[=|%' <<<"$sec"
  [ "$status" -ne 0 ]
  run grep -E 'board-progress\.sh|render-progress-bar\.sh' <<<"$sec"
  [ "$status" -ne 0 ]
}

@test "heading order of the existing ### sections is preserved (new step is the only addition)" {
  actual="$(grep -n '^### ' "$SKILL" | cut -d: -f2- | grep -v '^### 4\.1\.3\. Progress bar')"
  [ "$actual" = "$ORIGINAL_HEADINGS" ]
}

@test "the new step comes after the E67_S11 hooks" {
  h14="$(grep -n '^### 1\.4\. ' "$SKILL" | cut -d: -f1)"
  h15="$(grep -n '^### 1\.5\. ' "$SKILL" | cut -d: -f1)"
  h412="$(grep -n '^### 4\.1\.2\. ' "$SKILL" | cut -d: -f1)"
  hnew="$(grep -n '^### 4\.1\.3\. Progress bar' "$SKILL" | cut -d: -f1)"
  h415="$(grep -n '^### 4\.1\.5\. ' "$SKILL" | cut -d: -f1)"
  [ "$hnew" -gt "$h14" ] && [ "$hnew" -gt "$h15" ] && [ "$hnew" -gt "$h412" ]
  [ "$hnew" -lt "$h415" ]
}

@test "foreground-preflight.sh occurrence count is unchanged" {
  n="$(grep -c 'foreground-preflight\.sh' "$SKILL")"
  [ "$n" -eq "$FG_COUNT_BEFORE" ]
  run bash -c "$(declare -f new_section); SKILL='$SKILL'; new_section | grep -c 'foreground-preflight'"
  [ "$output" = "0" ]
}

@test "the print is always the story-scope call with the finished task id (E92_S06_T22): no scope is resolved, no run-wide bar" {
  sec="$(new_section)"
  grep -qF 'RP --scope story --task <the finished task id>' <<<"$sec"
  [ "$(grep -c 'RP --scope' <<<"$sec")" -eq 2 ]
  run grep -E -- '--resolve-scope|--scope run|--ids|run-wide|kept answer|Resolve the scope|resolved once' <<<"$sec"
  [ "$status" -ne 0 ]
  # nowhere in the file either
  run grep -E -- '--resolve-scope|RP --scope <kept|resolve the scope' "$SKILL"
  [ "$status" -ne 0 ]
}

@test "bundle mode prints once when the bundle finishes, not per task, with the bundle's finished task ids" {
  sec="$(new_section)"
  grep -qF 'does not print per task' <<<"$sec"
  grep -qF 'prints once, when the bundle finishes' <<<"$sec"
  grep -qF "RP --scope story --task <the ids of the bundle's finished tasks> --after-story" <<<"$sec"
}

@test "E92_S06_T23: both calls pass --after-story, and the section names no script beyond run-progress.sh and holds no story-finished logic" {
  sec="$(new_section)"
  [ "$(grep -c -- '--after-story' <<<"$sec")" -eq 2 ]
  grep -qF 'RP --scope story --task <the finished task id> --after-story' <<<"$sec"
  grep -qF 'only when that task just finished its story' <<<"$sec"
  run grep -E 'story-finished|render-story-bar|ledger signature|story-finished-ledger' <<<"$sec"
  [ "$status" -ne 0 ]
}

@test "progress_owner: caller suppresses the print" {
  sec="$(new_section)"
  grep -qF '`caller`' <<<"$sec"
  grep -qF 'prints nothing and skips the print in step 2' <<<"$sec"
}

@test "the print is best-effort like the ledger call and sits right after it in ### 7" {
  sec="$(new_section)"
  grep -qF 'best-effort exactly like the ledger call' <<<"$sec"
  grep -qF 'never blocks, fails or re-statuses a task' <<<"$sec"
  l="$(grep -n 'Record the terminal status in the execution ledger' "$SKILL" | cut -d: -f1)"
  p="$(grep -n 'Show the progress line' "$SKILL" | cut -d: -f1)"
  [ "$p" -gt "$l" ]
  [ $((p - l)) -le 8 ]
}

# --- E92_S08_T07: the lines are copied into the reply; the colour rule lives once, in skills/j-break/SKILL.md ----------

@test "E92_S08_T07: both calls run with --charset utf8 --color never and the lines are copied into the reply as a fenced code block" {
  sec="$(new_section)"
  grep -qF 'RP --scope story --task <the finished task id> --after-story --charset utf8 --color never' <<<"$sec"
  grep -qF "RP --scope story --task <the ids of the bundle's finished tasks> --after-story --charset utf8 --color never" <<<"$sec"
  [ "$(grep -c -- 'RP --scope story [^`]*--after-story --charset utf8 --color never' <<<"$sec")" -eq 2 ]
  grep -qF 'copy the lines it prints into your reply as a fenced code block' <<<"$sec"
  run grep -F 'show the lines it prints' "$SKILL"
  [ "$status" -ne 0 ]
  # the rest of the rule is one pointer to j.break, not repeated here
  grep -qF '`skills/j-break/SKILL.md` ("Progress lines")' <<<"$sec"
}

@test "E92_S08_T07: the colour sentence is not in this section; it appears once, in skills/j-break/SKILL.md" {
  run grep -F -- '--color always' <<<"$(new_section)"
  [ "$status" -ne 0 ]
  [ "$(grep -c -- 'Colour needs `--color always` in a real terminal' "$REPO_ROOT/skills/j-break/SKILL.md")" -eq 1 ]
  for f in "$REPO_ROOT/skills/j-do/SKILL.md" "$REPO_ROOT/skills/j-dooo/SKILL.md" "$REPO_ROOT/skills/jenga/SKILL.md"; do
    run grep -iF 'needs `--color always`' "$f"
    [ "$status" -ne 0 ] || { echo "colour sentence repeated in $f" >&2; return 1; }
  done
}

@test "E92_S08_T07: skills/j-break/SKILL.md documents the copy rule, the Node default and --legacy" {
  B="$REPO_ROOT/skills/j-break/SKILL.md"
  sec="$(awk '/^## Progress lines/{f=1; print; next} f && /^## /{exit} f{print}' "$B")"
  [ -n "$sec" ]
  grep -qF -- '--charset utf8 --color never' <<<"$sec"
  grep -qF 'fenced code block' <<<"$sec"
  grep -qF -- '`--legacy`' <<<"$sec"
  grep -qF 'JENGA_PROGRESS_RENDERER=legacy' <<<"$sec"
  grep -qF 'lib/progress/cli.js' <<<"$sec"
}
