#!/usr/bin/env bats
#
# Coverage for the /break signal and its orchestrator checkpoints (E44_S01, E44_S02).
#
# Two halves, kept honest about what each can prove:
#
#   1. The SCRIPT contract (set-break.sh, clear-break.sh, check-break.sh), exercised for real against a temp
#      project root. The story's Definition of Done lives here: soft is consumed once, hard persists, escalation
#      is one-way, a corrupt flag never wedges a loop.
#
#   2. The WIRING in skills/j-do, skills/j-dooo and skills/jenga. Those are instructions for an agent, so what is
#      pinned is what can be pinned mechanically: that each site calls check-break.sh, branches on the exit code,
#      never parses the flag itself, and keeps the ordering the story requires. `simulate_run` then models the loop
#      those instructions describe, driven by the real check-break.sh, to show that the documented placement
#      produces the documented behaviour. It does NOT prove an agent follows the prose.
#
# Isolation: every test runs in its own temp project root via JENGA_PROJECT_ROOT. The real project/queue is never
# touched.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SET="$REPO_ROOT/skills/j-break/scripts/set-break.sh"
CLEAR="$REPO_ROOT/skills/j-break/scripts/clear-break.sh"
CHECK="$REPO_ROOT/skills/j-break/scripts/check-break.sh"
DO_SKILL="$REPO_ROOT/skills/j-do/SKILL.md"
DOOO_SKILL="$REPO_ROOT/skills/j-dooo/SKILL.md"
JENGA_SKILL="$REPO_ROOT/skills/jenga/SKILL.md"
BREAK_SKILL="$REPO_ROOT/skills/j-break/SKILL.md"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs"
  # Deliberately NO project/queue: the scripts must cope with it being absent.
  printf '{"paths": {"queue": "project/queue", "configs": "project/configs"}}\n' > "$PROJ/project/configs/workflow.json"
  FLAG="$PROJ/project/queue/.break_request.json"
  export JENGA_PROJECT_ROOT="$PROJ"
}

# simulate_run <n-tasks> [set-at-boundary-after-task-N <cmd...>]
# Models the documented loop: do a task, then hit the boundary and call the real checker. Prints one line per
# completed task and returns the number completed on $status via the output's last line "completed=<n>".
simulate_run() {
  local total="$1" completed=0 i
  for ((i = 1; i <= total; i++)); do
    completed=$((completed + 1))
    if [ -n "${SET_AFTER:-}" ] && [ "$i" -eq "$SET_AFTER" ]; then
      bash "$SET" ${SET_ARGS:-} >/dev/null
    fi
    if bash "$CHECK" >/dev/null 2>&1; then :; else
      [ "$?" -eq 10 ] && break
    fi
  done
  echo "completed=$completed"
}

# ============================================================================
# Script contract — E44_S01
# ============================================================================

@test "all three scripts are executable and pass bash -n" {
  for s in "$SET" "$CLEAR" "$CHECK"; do
    [ -x "$s" ]
    bash -n "$s"
  done
}

@test "check-break.sh exits 0 silently when nothing exists, even with no queue directory" {
  [ ! -d "$PROJ/project/queue" ]
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "set-break.sh creates the queue directory and writes all four contracted fields" {
  run bash "$SET" --status
  [ "$status" -eq 0 ]
  [ -f "$FLAG" ]
  for k in mode with_status requested_at requested_by; do
    jq -e "has(\"$k\")" "$FLAG" >/dev/null
  done
  [ "$(jq -r .mode "$FLAG")" = "soft" ]
  [ "$(jq -r .with_status "$FLAG")" = "true" ]
  [[ "$(jq -r .requested_at "$FLAG")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$ ]]
}

@test "set-break.sh leaves no temp file behind (atomic write)" {
  bash "$SET" >/dev/null
  run bash -c "ls -A '$PROJ/project/queue' | grep -v '^\.break_request\.json$' || true"
  [ -z "$output" ]
}

@test "DoD: a soft break is reported once and then consumed" {
  bash "$SET" >/dev/null
  run bash "$CHECK"
  [ "$status" -eq 10 ]
  [[ "$output" == mode=soft* ]]
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "DoD: a hard break is reported every time and never consumed" {
  bash "$SET" --hard >/dev/null
  run bash "$CHECK"; [ "$status" -eq 10 ]; [[ "$output" == mode=hard* ]]
  run bash "$CHECK"; [ "$status" -eq 10 ]; [[ "$output" == mode=hard* ]]
  [ -f "$FLAG" ]
}

@test "DoD: set then clear leaves no flag, and clearing again is still a success" {
  bash "$SET" >/dev/null
  run bash "$CLEAR"; [ "$status" -eq 0 ]
  [ ! -e "$FLAG" ]
  run bash "$CLEAR"; [ "$status" -eq 0 ]
}

@test "escalation is one-way: a bare set never downgrades a standing hard break" {
  bash "$SET" --hard >/dev/null
  bash "$SET" >/dev/null
  [ "$(jq -r .mode "$FLAG")" = "hard" ]
}

@test "escalation: --hard upgrades a standing soft break" {
  bash "$SET" >/dev/null
  bash "$SET" --hard >/dev/null
  [ "$(jq -r .mode "$FLAG")" = "hard" ]
}

@test "--peek reports a soft break without consuming it" {
  bash "$SET" >/dev/null
  run bash "$CHECK" --peek; [ "$status" -eq 10 ]
  run bash "$CHECK" --peek; [ "$status" -eq 10 ]
  [ -f "$FLAG" ]
  run bash "$CHECK"; [ "$status" -eq 10 ]
  [ ! -e "$FLAG" ]
}

@test "a corrupt flag is no break: exit 0, warns on stderr, and is NOT deleted" {
  mkdir -p "$PROJ/project/queue"
  printf 'not json at all\n' > "$FLAG"
  run --separate-stderr bash "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"malformed"* ]]
  [ -f "$FLAG" ]
}

@test "a well-formed flag with an invalid mode is treated as corrupt, not as a break" {
  mkdir -p "$PROJ/project/queue"
  printf '{"mode":"medium","with_status":false}\n' > "$FLAG"
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ -f "$FLAG" ]
}

@test "the no-flag fast path runs before any interpreter is started" {
  local fast py
  fast=$(grep -n '\[ -e "\$FLAG" \] || exit 0' "$CHECK" | head -1 | cut -d: -f1)
  py=$(grep -n 'python3' "$CHECK" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
  [ -n "$fast" ] && [ -n "$py" ]
  [ "$fast" -lt "$py" ]
}

# ============================================================================
# Wiring — E44_S02 (static: what can be pinned about instructions for an agent)
# ============================================================================

@test "wiring: every orchestrator calls check-break.sh and branches on its exit code" {
  for f in "$DO_SKILL" "$DOOO_SKILL" "$JENGA_SKILL"; do
    grep -q 'check-break.sh' "$f"
    grep -q 'Exit `10`' "$f"
    grep -q 'Exit `0`\|Exit `0`,' "$f"
  done
}

@test "wiring: no orchestrator reads, parses or deletes the flag file itself" {
  for f in "$DO_SKILL" "$DOOO_SKILL" "$JENGA_SKILL" "$BREAK_SKILL"; do
    run grep -nE 'break_request\.json' "$f"
    [ "$status" -ne 0 ] || { echo "$f names the flag file: $output" >&2; return 1; }
  done
}

@test "wiring: /do step 8 is after step 7 and before returning to step 1" {
  run bash -c "sed -n '/^### 8\./,\$p' '$DO_SKILL'"
  [[ "$output" == *"Runs only after step 7 has fully completed"* ]]
  [[ "$output" == *"Do not return to step 1"* ]]
}

@test "wiring: /do bundle checkpoint is after c.2 and explicitly never between c and c.1" {
  grep -q 'c\.3\. \*\*Break checkpoint\*\*' "$DO_SKILL"
  grep -q 'never between c and c.1' "$DO_SKILL"
  local c2 c3 d
  c2=$(grep -n '^   c\.2\. \*\*Conflict report' "$DO_SKILL" | cut -d: -f1)
  c3=$(grep -n '^   c\.3\. \*\*Break checkpoint' "$DO_SKILL" | cut -d: -f1)
  d=$(grep -n '^   d\. \*\*After task failure' "$DO_SKILL" | cut -d: -f1)
  [ "$c2" -lt "$c3" ] && [ "$c3" -lt "$d" ]
}

@test "wiring: a halted bundle keeps its manifest and releases the lock and slot" {
  run bash -c "sed -n '/c\.3\. \*\*Break checkpoint/,/d\. \*\*After task failure/p' '$DO_SKILL'"
  [[ "$output" == *"Keep the bundle manifest"* ]]
  [[ "$output" == *"Release the developer concurrency slot"* ]]
  [[ "$output" == *"release the epic lock"* ]]
  [[ "$output" == *"Do **not** run the failure path"* ]]
}

@test "wiring: a halted bundle describes the resume path and no longer claims none exists (E44_S08)" {
  run bash -c "sed -n '/c\.3\. \*\*Break checkpoint/,/d\. \*\*After task failure/p' '$DO_SKILL'"
  [[ "$output" == *"resumes the halted bundle"* ]]
  [[ "$output" != *"no bundle-resume path"* ]]
  [[ "$output" != *"it does not exist"* ]]
}

@test "wiring: /dooo checks at the top of step 2, skips the choice prompt, and registers a termination case" {
  run bash -c "sed -n '/^### 2\./,/^### 3\./p' '$DOOO_SKILL'"
  [[ "$output" == *"Break check first"* ]]
  [[ "$output" == *"skip step 3's choice prompt entirely"* ]]
  [[ "$output" == *"not cancelled"* ]]
  run bash -c "sed -n '/^### 5\./,\$p' '$DOOO_SKILL'"
  [[ "$output" == *"A break was requested"* ]]
}

@test "wiring: /jenga orders drain, deferrals, check, loop — and the break exit does not claim completion" {
  grep -q 'drain (a), then clean up `todo.md` (a.1), then record deferrals (b), then check (b.1), then loop (c)' "$JENGA_SKILL"
  local a a1 b b1 c
  a=$(grep -n '^   a\. \*\*Drain the scrum' "$JENGA_SKILL" | cut -d: -f1)
  a1=$(grep -n '^   a\.1\. \*\*Task-completion cleanup' "$JENGA_SKILL" | cut -d: -f1)
  b=$(grep -n '^   b\. \*\*Record pre-flight' "$JENGA_SKILL" | cut -d: -f1)
  b1=$(grep -n '^   b\.1\. \*\*Break check' "$JENGA_SKILL" | cut -d: -f1)
  c=$(grep -n '^   c\. \*\*Return to step 1' "$JENGA_SKILL" | cut -d: -f1)
  [ "$a" -lt "$a1" ] && [ "$a1" -lt "$b" ] && [ "$b" -lt "$b1" ] && [ "$b1" -lt "$c" ]
  grep -q 'Jenga stopped at a requested break' "$JENGA_SKILL"
  # The completion message must still exist exactly once, and the break message must not borrow it.
  [ "$(grep -c 'Jenga complete. All eligible' "$JENGA_SKILL")" -eq 1 ]
  run bash -c "grep 'Jenga stopped at a requested break' '$JENGA_SKILL'"
  [[ "$output" != *"complete"* ]]
}

@test "wiring: /jenga's hands-free contract is preserved at the break site" {
  run bash -c "sed -n '/^   b\.1\. \*\*Break check/,/^   c\. \*\*Return/p' '$JENGA_SKILL'"
  [[ "$output" == *"does not prompt, offer options or wait for a decision"* ]]
}

@test "wiring: the previous loop-back reference to step 5c is still valid" {
  # Other sections cite 'Phase 4 step 5c' as the loop-back; inserting b.1 must not have renumbered it.
  grep -q 'across every loop-back at Phase 4 step 5c' "$JENGA_SKILL"
  grep -q '^   c\. \*\*Return to step 1' "$JENGA_SKILL"
}

@test "wiring: every site handles with_status and refuses to improvise a rapport" {
  for f in "$DO_SKILL" "$DOOO_SKILL" "$JENGA_SKILL"; do
    grep -q 'with_status=true' "$f"
    grep -q 'render-execution-status.sh' "$f"
  done
  grep -q 'Never improvise' "$DO_SKILL"
}

@test "wiring: a hard break must also stop a run that STARTS after it was set" {
  # The task ACs only place checks at loop boundaries, which a freshly started run would not reach before
  # doing a task. The story DoD requires the stronger guarantee, so /do and /jenga check at entry too.
  run bash -c "sed -n '/^#### Break entry check/,/^### 1\./p' '$DO_SKILL'"
  [[ "$output" == *"--peek"* ]]
  [[ "$output" == *"mode=hard"* ]]
  grep -q 'Break entry check' "$JENGA_SKILL"
  run bash -c "grep -A8 'Break entry check' '$JENGA_SKILL' | head -12"
  [[ "$output" == *"--peek"* ]]
}

# ============================================================================
# Behaviour — the documented loop placement, driven by the real checker
# ============================================================================

@test "DoD: with no flag, a run completes every task (no-op fast path)" {
  run simulate_run 5
  [[ "$output" == *"completed=5" ]]
}

@test "DoD: a soft break set during a run halts after exactly one more task" {
  SET_AFTER=2 SET_ARGS="" run simulate_run 5
  [[ "$output" == *"completed=2" ]]
  # The soft break was consumed, so the very next run proceeds normally with no action.
  run simulate_run 5
  [[ "$output" == *"completed=5" ]]
}

@test "DoD: a hard break blocks every following run until it is cleared" {
  SET_AFTER=1 SET_ARGS="--hard" run simulate_run 5
  [[ "$output" == *"completed=1" ]]
  run simulate_run 5; [[ "$output" == *"completed=1" ]]
  run simulate_run 5; [[ "$output" == *"completed=1" ]]
  bash "$CLEAR" >/dev/null
  run simulate_run 5; [[ "$output" == *"completed=5" ]]
}

@test "entry check semantics: --peek halts a run on hard and leaves a soft break for the first boundary" {
  bash "$SET" --hard >/dev/null
  run bash "$CHECK" --peek
  [ "$status" -eq 10 ]; [[ "$output" == mode=hard* ]]

  bash "$CLEAR" >/dev/null
  bash "$SET" >/dev/null
  run bash "$CHECK" --peek
  [ "$status" -eq 10 ]; [[ "$output" == mode=soft* ]]
  [ -f "$FLAG" ]   # not consumed, so the first task boundary still honours it
}

# ============================================================================
# `status` modifier and registration — E44_S03_T02, T03
# ============================================================================

@test "status: --status sets with_status and a soft break, and never clears anything" {
  bash "$SET" --status >/dev/null
  [ "$(jq -r .mode "$FLAG")" = "soft" ]
  [ "$(jq -r .with_status "$FLAG")" = "true" ]
  [ -f "$FLAG" ]
}

@test "status: against a standing hard break it does NOT downgrade, and says the break remains hard" {
  bash "$SET" --hard >/dev/null
  run bash "$SET" --status
  [ "$status" -eq 0 ]
  [ "$(jq -r .mode "$FLAG")" = "hard" ]
  [ "$(jq -r .with_status "$FLAG")" = "true" ]
  [[ "$output" == *"hard"* ]]
  [[ "$output" == *"does not downgrade"* ]]
}

@test "status: hard status sets a hard break carrying with_status" {
  bash "$SET" --hard --status >/dev/null
  [ "$(jq -r .mode "$FLAG")" = "hard" ]
  [ "$(jq -r .with_status "$FLAG")" = "true" ]
}

@test "status: the with_status request survives to the loop that consumes the flag" {
  bash "$SET" --status >/dev/null
  run bash "$CHECK"
  [ "$status" -eq 10 ]
  [[ "$output" == *"with_status=true"* ]]
}

@test "status wiring: /break status and /break hard status set the break first, then render the rapport" {
  grep -q 'set-break.sh" --status`, \*\*then\*\* `bash "$BREAK_DIR/render-execution-status.sh"`' "$BREAK_SKILL"
  grep -q 'set-break.sh" --hard --status`, \*\*then\*\* `bash "$BREAK_DIR/render-execution-status.sh"`' "$BREAK_SKILL"
}

@test "status wiring: both render moments are documented and state reads must use --peek" {
  run bash -c "sed -n '/^### 1\.1\./,/^### 2\./p' '$BREAK_SKILL'"
  [[ "$output" == *"**Immediately**"* ]]
  [[ "$output" == *"**At the halt**"* ]]
  [[ "$output" == *"with_status"* ]]
  [[ "$output" == *'check-break.sh" --peek'* ]]
  [[ "$output" == *"never a plain call"* ]]
  [[ "$output" == *"never clears anything"* ]]
  [[ "$output" == *"remains hard"* ]]
}

@test "status wiring: the skill adds no formatting or scope resolution of its own" {
  run grep -nE 'jq |python3|find |glob|todo\.md|project/board' "$BREAK_SKILL"
  [ "$status" -ne 0 ] || { echo "found: $output" >&2; return 1; }
}

@test "status wiring: the halt sites now run the real renderer rather than hedging on whether it exists" {
  for f in "$DO_SKILL" "$DOOO_SKILL" "$JENGA_SKILL"; do
    grep -q 'render-execution-status.sh' "$f"
    run grep -c 'has not landed' "$f"
    [ "$output" = "0" ]
  done
}

@test "registration: j.break is in the CLAUDE.md, README.md and AGENTS.md skills tables" {
  grep -q '^| `j\.break` |' "$REPO_ROOT/CLAUDE.md"
  grep -q '^| `j\.break` |' "$REPO_ROOT/README.md"
  grep -q '^| `/j-break` |' "$REPO_ROOT/AGENTS.md"
}

@test "registration: rows state the boundary semantics and mention the status and hard modifiers" {
  local f row
  for f in CLAUDE.md README.md AGENTS.md; do
    row="$(grep -E '^\| `(j\.break|/j-break)` \|' "$REPO_ROOT/$f")"
    [[ "$row" == *"after the current task"* || "$row" == *"current task finishes"* ]]
    [[ "$row" == *"next one starts"* ]]
    [[ "$row" == *"hard"* ]]
    [[ "$row" == *"status"* ]]
  done
}

@test "registration: the row sits among the execution commands, not at the end of the table" {
  # CLAUDE.md: between j.proceed and j.error. README.md: right after j.do.
  local before after
  before="$(grep -B1 '^| `j\.break` |' "$REPO_ROOT/CLAUDE.md" | head -1)"
  after="$(grep -A1 '^| `j\.break` |' "$REPO_ROOT/CLAUDE.md" | tail -1)"
  [[ "$before" == '| `j.proceed` |'* ]]
  [[ "$after" == '| `j.error` |'* ]]
  before="$(grep -B1 '^| `j\.break` |' "$REPO_ROOT/README.md" | head -1)"
  [[ "$before" == '| `j.do` |'* ]]
}

@test "registration: j-break's frontmatter description mentions the same modifiers the rows do" {
  local fm
  fm="$(sed -n '3p' "$BREAK_SKILL")"
  [[ "$fm" == *"next safe task boundary"* ]]
  [[ "$fm" == *"hard"* ]]
  [[ "$fm" == *"status"* ]]
}
