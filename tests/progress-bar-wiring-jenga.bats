#!/usr/bin/env bats
#
# Coverage for E92_S02_T06 (revised by E92_S06_T22): /jenga passes progress_owner "caller" in every dispatched /do sender
# object and prints the story-scope progress line (`RP --scope story --task <finished task ids>`) per finished wave and per
# Phase 3.5 bundle. No scope is resolved and no run-wide bar exists.
#
# What is under test (text assertions over skills/jenga/SKILL.md only, no scripts run).
#
# What this suite guards. SKILL.md says WHEN to call run-progress.sh and nothing about counting or drawing; the
# E67_S11 foreground hooks (Phase 0.8 and Phase 0.9) are neither moved, edited nor duplicated.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL="$REPO_ROOT/skills/jenga/SKILL.md"

# The #/### headings of skills/jenga/SKILL.md as they were before E92_S02_T06, in order. Recorded at the start of the task.
ORIGINAL_HEADINGS='### Phase 0 — Load threshold config
### Phase 0.5 — Pre-flight Validation
#### Rule 1 — Valid execution_scope value
#### Rule 2 — scope_rationale must contain a measurable claim
#### Rule 3 — epic scope requires explicit human approval
#### Rule 4 — crucial_level: locked forces execution_scope: inline
#### Backward compatibility — legacy tasks
#### Validation success
### Phase 0.75 — Entry Mode Resolution
#### Wildcard branch (`/jenga *`)
#### Bare branch (`/jenga`)
#### Scoped branch (`/jenga <ids>`)
#### Natural-language branch (`/jenga <free-form text>`)
#### Shared confirmation step (bare and scoped branches only)
### Phase 0.8 — Foreground Check-in and Cost/Cadence Confirmation
### Phase 0.9 — Generate the Run'"'"'s Shared `orchestrator_session_id`
### Phase 1 — Decompose Epics into Stories
### Phase 2 — Decompose Stories into Tasks
### Phase 3 — Queue all Tasks into `todo.md`
### Phase 3.5 — Story-bundle detection
### Phase 4 — Execute
### Exit condition'
FG_COUNT_BEFORE=5
# sha256 of the Phase 0.8 and Phase 0.9 section bodies (heading up to the next ### heading) at task start.
PHASE_08_SHA=b4c0f85acc9cd480ec4ba854191d676c3105ac8e571204212bd354f7cf26c119
PHASE_09_SHA=5818b140f258782e877436287846fcf3be615b50fddf6311b19449a4b8eab2bf

# Body of the ### section whose heading starts with $1, up to the next ### heading.
section() {
  awk -v h="$1" 'index($0,h)==1{f=1; print; next} f && /^### /{exit} f{print}' "$SKILL"
}
sha() { shasum -a 256 | cut -d' ' -f1; }
line_of() { grep -n -- "$1" "$SKILL" | head -1 | cut -d: -f1; }

@test "no scope is resolved anywhere in the file and no run-wide bar is described (E92_S06_T22)" {
  run grep -E -- '--resolve-scope|--scope run|kept answer|run-wide|never re-made per print' "$SKILL"
  [ "$status" -ne 0 ]
  run grep -E -- 'RP --scope [^s]|RP --scope story --ids' "$SKILL"
  [ "$status" -ne 0 ]
}

@test "the new phase names run-progress.sh, says when to print and passes the finished task ids" {
  sec="$(section '### Phase 0.95')"
  [ -n "$sec" ]
  grep -q 'skills/j-break/scripts/run-progress.sh' <<<"$sec"
  grep -qF 'node_modules/@jenga-ai/agent/skills/j-break/scripts/run-progress.sh' <<<"$sec"
  grep -qF 'RP --scope story --task <the ids of the tasks the wave or bundle finished, comma separated>' <<<"$sec"
  grep -qF 'one bar per distinct story' <<<"$sec"
  grep -qF -- '--after-story' <<<"$sec"
  run grep -E 'story-finished|render-story-bar' <<<"$sec"
  [ "$status" -ne 0 ]
  grep -qF 'best-effort' <<<"$sec"
}

@test "the new phase sits after Phase 0.9 and before Phase 1" {
  a="$(line_of '^### Phase 0\.9 ')"
  b="$(line_of '^### Phase 0\.95 ')"
  c="$(line_of '^### Phase 1 ')"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ]
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]
}

@test "every sender-object description from Phase 3.5 on that passes a run id also states progress_owner caller" {
  start="$(line_of '^### Phase 3\.5 ')"
  count=0
  while IFS= read -r l; do
    count=$((count + 1))
    grep -qF 'progress_owner: "caller"' <<<"$l" || { echo "missing progress_owner: ${l:0:120}"; return 1; }
  done < <(tail -n +"$start" "$SKILL" | grep -i 'sender' | grep -E 'orchestrator_session_id|checklist_run_id|shared `orchestrator_session_id`')
  # Phase 3.5 step 7b, Phase 4 step 3 and the edge-case paragraph
  [ "$count" -ge 3 ]
}

@test "the Phase 3.5 bundle dispatch and the Phase 4 wave dispatch both state progress_owner caller" {
  section '### Phase 3.5' | grep -F 'Call `/do <E##_S##>` once' | grep -qF 'progress_owner: "caller"'
  section '### Phase 4' | grep -F 'Invoke `/do` in parallel' | grep -qF 'progress_owner: "caller"'
}

@test "the wave print sits between deferral recording (5b) and the loop-back (5c)" {
  b="$(line_of '^   b\. \*\*Record pre-flight deferrals\*\*')"
  p="$(line_of '^   b\.0\. \*\*Show the progress line\*\*')"
  c="$(line_of '^   c\. \*\*Return to step 1\*\*')"
  [ -n "$b" ] && [ -n "$p" ] && [ -n "$c" ]
  [ "$b" -lt "$p" ] && [ "$p" -lt "$c" ]
  # after the queue drain (5a)
  a="$(line_of '^   a\. \*\*Drain the scrum triggers queue\*\*')"
  [ "$a" -lt "$p" ]
}

@test "the wave print is best-effort, after every wave, and passes the wave's finished task ids" {
  l="$(grep -F 'b.0. **Show the progress line**' "$SKILL")"
  grep -qF "RP --scope story --task <the wave's finished task ids> --after-story" <<<"$l"
  grep -qF 'after every wave regardless of its outcome' <<<"$l"
  grep -qF 'never stops the run' <<<"$l"
}

@test "each Phase 3.5 bundle dispatch prints once, after the bundle returns" {
  l="$(section '### Phase 3.5' | grep -F 'Show the progress line')"
  [ -n "$l" ]
  grep -qF "RP --scope story --task <the bundle's finished task ids> --after-story" <<<"$l"
  grep -qF 'Once per bundle' <<<"$l"
  p="$(line_of 'd\. \*\*Show the progress line\*\* — when the bundle')"
  m="$(line_of 'c\. \*\*Mark these tasks as bundled\*\*')"
  [ "$p" -gt "$m" ]
}

@test "the added text contains no counting and no bar drawing" {
  added="$( { section '### Phase 0.95'; grep -F 'Show the progress line' "$SKILL"; } )"
  [ -n "$added" ]
  run grep -E 'Passed|Failed|Pending|In Progress|Merged|Rejected|Blocked|━|╌|⚑|★|⊘|\[#|\[=|%' <<<"$added"
  [ "$status" -ne 0 ]
  run grep -E 'board-progress\.sh|render-progress-bar\.sh' "$SKILL"
  [ "$status" -ne 0 ]
  run bash -c "SKILL='$SKILL'; $(declare -f section); section '### Phase 0.95' | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u"
  [ "$output" = "run-progress.sh" ]
}

@test "heading list is unchanged apart from the one new phase" {
  actual="$(grep -E '^#{3,4} ' "$SKILL" | grep -v '^### Phase 0\.95 ')"
  [ "$actual" = "$ORIGINAL_HEADINGS" ]
}

@test "Phase 0.8 and Phase 0.9 bodies are byte-for-byte unchanged" {
  [ "$(section '### Phase 0.8 ' | sha)" = "$PHASE_08_SHA" ]
  [ "$(section '### Phase 0.9 ' | sha)" = "$PHASE_09_SHA" ]
}

@test "foreground-preflight.sh occurrence count is unchanged and the new phase has none" {
  n="$(grep -c 'foreground-preflight\.sh' "$SKILL")"
  [ "$n" -eq "$FG_COUNT_BEFORE" ]
  [ "$(section '### Phase 0.95' | grep -c 'foreground-preflight')" -eq 0 ]
}

@test "this task changes nothing under .claude/ or .agents/" {
  # Mirrors are produced by j.self-sync. Inspect only the commits this task made.
  cd "$REPO_ROOT"
  git rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  shas="$(git log --format=%H --grep='^task(E92_S02_T06)')"
  [ -n "$shas" ] || skip "no task commits yet"
  for c in $shas; do
    run git show --name-only --format= "$c" -- .claude .agents
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

# --- E92_S08_T07: the lines are copied into the reply; the colour rule lives once, in skills/j-break/SKILL.md ----------

@test "E92_S08_T07: every print runs with --charset utf8 --color never and copies the lines into the reply as a fenced code block" {
  sec="$(section '### Phase 0.95')"
  grep -qF 'comma separated> --after-story --charset utf8 --color never' <<<"$sec"
  grep -qF 'Copy the lines it prints into your reply as a fenced code block' <<<"$sec"
  grep -qF '`skills/j-break/SKILL.md` ("Progress lines")' <<<"$sec"
  for l in "$(grep -F 'b.0. **Show the progress line**' "$SKILL")" "$(section '### Phase 3.5' | grep -F 'Show the progress line')"; do
    grep -qF -- '--after-story --charset utf8 --color never' <<<"$l"
    grep -qF 'copy the lines it prints into your reply as a fenced code block' <<<"$l"
  done
  run grep -F 'show the lines it prints' "$SKILL"
  [ "$status" -ne 0 ]
  run grep -F -- '--color always' <<<"$( { section '### Phase 0.95'; grep -F 'Show the progress line' "$SKILL"; } )"
  [ "$status" -ne 0 ]
}
