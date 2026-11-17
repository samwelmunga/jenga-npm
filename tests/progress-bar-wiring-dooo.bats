#!/usr/bin/env bats
#
# Coverage for E92_S02_T07: /j-dooo shows the progress bar once per wave and keeps its inner /do calls silent.
#
# What is under test (text assertions over one file, no scripts run):
#   - skills/j-dooo/SKILL.md   the "Progress ownership" paragraph in ### 1 and the new ### 1.1 (once-per-wave print)
#
# What this suite guards. SKILL.md says WHEN to call run-progress.sh and nothing about counting or drawing; ### 0 (the
# E67_S11 front-loaded ask), the break check and the persist-usage text are neither moved, edited nor duplicated.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL="$REPO_ROOT/skills/j-dooo/SKILL.md"

# The ### headings of skills/j-dooo/SKILL.md as they were before E92_S02_T07, in order. Recorded at the start of the task.
ORIGINAL_HEADINGS='### 0. Front-loaded foreground ask (once per `/dooo` invocation)
### 1. Invoke `/do`
### 2. Return to the board — identify parallelisable tasks
### 3. Present choices to the user
### 4. Branch on user selection
### 5. Loop termination'
# Occurrences of foreground-preflight.sh, and the sha256 of the ### 0 body (heading through the line before ### 1),
# both measured at the start of the task.
FG_COUNT_BEFORE=1
SECTION0_SHA256=f11695643e05f5da52ab4720332c6f43c6763c43c0333bf20f613868e37078e9

# A ### section: from its heading up to the next ### heading.
section() { awk -v s="$1" '$0 ~ s {f=1; print; next} f && /^### /{exit} f{print}' "$SKILL"; }
new_section() { section '^### 1\.1\. Progress line'; }
step1() { section '^### 1\. '; }
step4() { section '^### 4\. '; }

@test "no scope is resolved and no run-wide bar is described anywhere in the file (E92_S06_T22)" {
  run grep -E -- '--resolve-scope|--scope run|kept answer|run-wide|Resolve the scope|resolve the scope' "$SKILL"
  [ "$status" -ne 0 ]
  run grep -E -- 'RP --scope [^s]|RP --scope story --ids' "$SKILL"
  [ "$status" -ne 0 ]
}

@test "exactly one per-wave print step, and it is the new ### 1.1" {
  [ "$(grep -c '^### 1\.1\. ' "$SKILL")" -eq 1 ]
  # one print call site: the story-scope form with the wave's finished task ids
  [ "$(grep -c -- 'RP --scope' "$SKILL")" -eq 1 ]
  [ "$(new_section | grep -c '^1\. \*\*Print once per wave')" -eq 1 ]
  grep -- 'RP --scope' "$SKILL" | grep -qF -- 'RP --scope story --task <the ids of the tasks this wave finished'
  # E92_S06_T23: the after-story line is requested with one flag, and no story-finished logic lives in the skill
  grep -- 'RP --scope' "$SKILL" | grep -qF -- 'comma separated> --after-story'
  run grep -E 'story-finished|render-story-bar|story-finished-ledger' "$SKILL"
  [ "$status" -ne 0 ]
  run bash -c "grep -- 'RP --scope' '$SKILL' | grep -F -- '--ids'"
  [ "$status" -ne 0 ]
}

@test "the print is once per wave, never per task, and best-effort" {
  sec="$(new_section)"
  grep -qF 'What a wave is here' <<<"$sec"
  grep -qF 'One pass through step 1' <<<"$sec"
  grep -qF 'never once per task of the wave' <<<"$sec"
  grep -qF 'it never blocks, fails or re-statuses anything' <<<"$sec"
  grep -qF 'a warning on stderr is not an error' <<<"$sec"
}

@test "the print step sits after step 1 and before step 2's break check and step 3's offer" {
  h1="$(grep -n '^### 1\. ' "$SKILL" | cut -d: -f1)"
  h11="$(grep -n '^### 1\.1\. ' "$SKILL" | cut -d: -f1)"
  h2="$(grep -n '^### 2\. ' "$SKILL" | cut -d: -f1)"
  h3="$(grep -n '^### 3\. ' "$SKILL" | cut -d: -f1)"
  brk="$(grep -n 'Break check first' "$SKILL" | cut -d: -f1)"
  offer="$(grep -n 'Which task would you like to start next' "$SKILL" | cut -d: -f1)"
  [ "$h1" -lt "$h11" ] && [ "$h11" -lt "$h2" ] && [ "$h2" -lt "$h3" ]
  [ "$h11" -lt "$brk" ] && [ "$h11" -lt "$offer" ]
  grep -qF 'before the break check and before step 3 offers the next wave' <<<"$(new_section)"
}

@test "every /do call described in the file passes progress_owner: caller" {
  # step 1 is the only place /do is called; step 4 loops back to it
  s1="$(step1)"
  [ "$(grep -c 'Call the `/do` skill' "$SKILL")" -eq 1 ]
  grep -qF 'progress_owner: "caller"' <<<"$s1"
  grep -qF 'Every `/do` call this loop makes, on every iteration including each loop-back from step 4' <<<"$s1"
  grep -qF 'next to the `checklist_run_id`' <<<"$s1"
  grep -qF 'go back to step 1' <<<"$(step4)"
  # no other line in the file invokes /do directly
  n="$(grep -ciE '(invoke|call)( the)? `/do`' "$SKILL")"
  [ "$n" -le 3 ]
  [ "$(grep -cF 'progress_owner: "caller"' "$SKILL")" -eq 1 ]
}

@test "the checklist_run_id threading line of step 1 still stands" {
  l="$(step1 | grep -F 'Call the `/do` skill')"
  [[ "$l" == *'`checklist_run_id`'* ]]
  [[ "$l" == *'on every iteration of this loop'* ]]
  [[ "$l" == *'never re-minted'* ]]
}

@test "### 0 is unchanged: body hash, foreground-preflight.sh count and no foreground hook in the new text" {
  actual="$(awk '/^### 0\. /{f=1} /^### 1\. /{f=0} f' "$SKILL" | shasum -a 256 | cut -d' ' -f1)"
  [ "$actual" = "$SECTION0_SHA256" ]
  [ "$(grep -c 'foreground-preflight\.sh' "$SKILL")" -eq "$FG_COUNT_BEFORE" ]
  [ "$(new_section | grep -c 'foreground-preflight')" -eq 0 ]
  [ "$(grep -c 'FG mint' "$SKILL")" -eq 1 ]
}

@test "heading order of the existing ### sections is preserved (### 1.1 is the only addition)" {
  actual="$(grep '^### ' "$SKILL" | grep -v '^### 1\.1\. Progress line')"
  [ "$actual" = "$ORIGINAL_HEADINGS" ]
  [ "$(grep -c '^### ' "$SKILL")" -eq 7 ]
}

@test "the break check and the persist-usage text are untouched" {
  grep -qF '**Break check first** (`E44_S02`)' "$SKILL"
  [ "$(grep -c 'check-break.sh' "$SKILL")" -eq 1 ]
  grep -qF '**Persist usage (`E76_S02_T05`), on every termination above, the break path included.**' "$SKILL"
}

@test "the new text names run-progress.sh and calls only that for the bar" {
  new_section | grep -q 'skills/j-break/scripts/run-progress.sh'
  run bash -c "$(declare -f section new_section); SKILL='$SKILL'; new_section | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u"
  [ "$output" = "run-progress.sh" ]
  # the whole file calls neither the counter nor the renderer
  run grep -E 'board-progress\.sh|render-progress-bar\.sh' "$SKILL"
  [ "$status" -ne 0 ]
}

@test "the new text contains no counting and no bar drawing" {
  added="$(new_section; step1 | grep -F 'Progress ownership')"
  [ -n "$added" ]
  run grep -E 'Passed|Failed|Pending|In Progress|Merged|Rejected|Blocked|Done|━|╌|⚑|★|⊘|\[#|\[=|%' <<<"$added"
  [ "$status" -ne 0 ]
  run grep -E 'total|percent|divid|\+\+|\$\(\('  <<<"$added"
  [ "$status" -ne 0 ]
}

@test "/dooo prints only the one-line form per wave: no rich multi-line block in the step" {
  sec="$(new_section)"
  grep -qF 'one bar per distinct story' <<<"$sec"
  grep -qF 'Print once per wave' <<<"$sec"
  # no request for the rich block, the card or the dependency tree in the /dooo step
  run grep -iE -- '--rich|--card|--tree|--graph|multi-line|dependency tree' <<<"$sec"
  [ "$status" -ne 0 ]
  # exactly one run-progress.sh print form, and it is never given a rich-block flag
  [ "$(grep -c -- 'RP --scope' "$SKILL")" -eq 1 ]
  run bash -c "grep -- 'RP --scope' '$SKILL' | grep -E -- '--rich|--card|--tree|--graph'"
  [ "$status" -ne 0 ]
}

@test "the SKILL.md edit is limited to the root skill file: nothing under .claude/ or .agents/ is changed" {
  [ -f "$SKILL" ]
  [[ "$SKILL" == */skills/j-dooo/SKILL.md ]]
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    run git -C "$REPO_ROOT" status --porcelain -- .claude .agents
    # worktree directories live under .claude/worktrees and are not tracked content
    run bash -c "git -C '$REPO_ROOT' diff --name-only HEAD -- .claude .agents"
    [ -z "$output" ]
  fi
}

# --- E92_S08_T07: the lines are copied into the reply; the colour rule lives once, in skills/j-break/SKILL.md ----------

@test "E92_S08_T07: the wave call runs with --charset utf8 --color never and the lines are copied into the reply as a fenced code block" {
  sec="$(new_section)"
  grep -- 'RP --scope' "$SKILL" | grep -qF -- 'comma separated> --after-story --charset utf8 --color never'
  grep -qF 'copy the lines it prints into your reply as a fenced code block' <<<"$sec"
  run grep -F 'show the lines it prints' "$SKILL"
  [ "$status" -ne 0 ]
  grep -qF '`skills/j-break/SKILL.md` ("Progress lines")' <<<"$sec"
  run grep -F -- '--color always' <<<"$sec"
  [ "$status" -ne 0 ]
}
