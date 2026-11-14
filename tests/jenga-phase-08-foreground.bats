#!/usr/bin/env bats
#
# Coverage for E67_S11_T03: /jenga Phase 0.8 (foreground check-in and cost/cadence prompt), the shared prompt
# asset, and the threading of the run id as the sender object's checklist_run_id.
#
# What is under test.
#   - skills/jenga/SKILL.md                    Phase 0.8, Phase 0.75/0.9 ordering, Phase 3.5 step 7b, Phase 4
#                                              steps 3 and 5c, the Edge Cases list (text assertions)
#   - skills/j-do/assets/foreground-prompt.md  the one place the prompt wording lives (text assertions)
#   - scripts/foreground-preflight.sh          the scripts Phase 0.8 calls, executed for real against a fixture:
#                                              the `*` path (verify with no run id), the Cancel path (gate without
#                                              --user-yes) and the Proceed path (gate with --user-yes)
#
# Honest limit. Phase 0.8's decision path is prose an agent follows. These tests assert what that prose says and
# execute the scripts it names; they cannot prove that an agent follows the prose. The Cancel and `*` paths are
# therefore pinned twice: by the text, and by showing that the only way to a satisfied state needs --user-yes on
# a named run id.
#
# Isolation. A temp project root ($PROJ) reached through JENGA_PROJECT_ROOT, with its own workflow.json,
# events.json, registry and tick-state directory (same pattern as tests/foreground-preflight.bats and
# tests/do-supplied-checklist-run-id.bats). The real project/logs/events.json and the real
# project/queue/checklist-ticks/ are never read or written. Every script call has an explicit stdin from /dev/null.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FG="$REPO_ROOT/scripts/foreground-preflight.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
GATE="$REPO_ROOT/skills/j-check-in/scripts/checkin-gate.sh"
SKILL="$REPO_ROOT/skills/jenga/SKILL.md"
ASSET="$REPO_ROOT/skills/j-do/assets/foreground-prompt.md"

CHECKIN_ID="checkin-run-before-dispatch"
COST_ID="dispatch-cost-and-cadence"

setup() {
  T="$BATS_TEST_TMPDIR"
  PROJ="$T/proj"
  F="$T/checklists.json"
  STATE="$T/state"
  EVENTS="$PROJ/project/logs/events.json"

  mkdir -p "$PROJ/project/configs" "$PROJ/project/logs" "$PROJ/project/queue"
  cat > "$PROJ/project/configs/workflow.json" <<'JSON'
{
  "paths": {
    "queue": "project/queue",
    "configs": "project/configs",
    "logs": "project/logs"
  }
}
JSON
  cat > "$PROJ/project/configs/scope-thresholds.json" <<'JSON'
{
  "marker_ttl_minutes": 60
}
JSON
  : > "$EVENTS"

  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_FILE="$F"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$T/no-default-checklists.json"
  export JENGA_CHECKLIST_STATE_DIR="$STATE"
  export CLAUDE_CODE_SESSION_ID="sess-main"
  unset JENGA_CHECKLIST_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_MARKER_DIR
  unset JENGA_CHECKLIST_MARKER_TTL_MINUTES JENGA_SCOPE_THRESHOLDS_FILE JENGA_CHECKLIST_NOW
  unset JENGA_PREFLIGHT_HOOK_SCRIPT_DIR JENGA_PREFLIGHT_HOOK_DEBUG JENGA_CHECKLIST_RUN_ID
  unset JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES JENGA_CHECKLIST_VERIFY_TIMEOUT

  write_registry
}

# -----------------------------------------------------------------------------
# Fixtures and helpers
# -----------------------------------------------------------------------------

# The two items under test, shaped like the real ones: the machine item is verified by the REAL check-in gate,
# the judgment item cannot be confirmed by the checker. Both are run-scoped confirm items.
write_registry() {
  jq -n --arg gate "$GATE" '{
    checklist_version: 1,
    situations: [],
    items: [
      {
        id: "checkin-run-before-dispatch",
        text: "A pre-dispatch check-in has been run in this session.",
        situations: ["pre-task"],
        kind: "machine",
        verify: ("bash " + $gate),
        enforcement: "confirm",
        tick_scope: "run"
      },
      {
        id: "dispatch-cost-and-cadence",
        text: "The expected cost and cadence were stated to the user and they agreed.",
        situations: ["pre-task"],
        kind: "judgment",
        enforcement: "confirm",
        tick_scope: "run"
      }
    ]
  }' > "$F"
}

# A check-in has run in the host session (the key the fixture session id resolves to).
add_checkin_event() {
  printf '{"event": "checkin", "agent": "orchestrator", "session_key": "sess-main", "date": "2026-10-12T12:00:00Z"}\n' >> "$EVENTS"
}

# tick_state <item> <run>: the last column of `checklist.sh list pre-task --run <run>` for that item.
tick_state() {
  bash "$CHECKLIST" list pre-task --run "$2" < /dev/null | awk -F'\t' -v id="$1" '$1 == id { print $NF }'
}

# section <start-regex> <stop-regex>: SKILL.md lines from the first line matching start up to (not including)
# the next line matching stop.
section() {
  awk -v s="$1" -v e="$2" '$0 ~ s { f = 1; print; next } f && $0 ~ e { exit } f { print }' "$SKILL"
}

edge_cases() { awk '/^## Edge Cases/{f=1} f' "$SKILL"; }
phase08() { section '^### Phase 0\.8 ' '^### Phase 0\.9 '; }

# bullet <marker>: the single Phase 0.8 answer bullet starting with "   - **<marker>".
bullet() { phase08 | grep -F -- "   - **$1" ; }

# =============================================================================
# Group 1 - Phase 0.8 placement and scope
# =============================================================================

@test "Phase 0.8 is a heading placed after Phase 0.75 and before Phase 0.9" {
  l075="$(grep -n '^### Phase 0\.75 ' "$SKILL" | cut -d: -f1)"
  l08="$(grep -n '^### Phase 0\.8 ' "$SKILL" | cut -d: -f1)"
  l09="$(grep -n '^### Phase 0\.9 ' "$SKILL" | cut -d: -f1)"
  [ -n "$l075" ] && [ -n "$l08" ] && [ -n "$l09" ]
  [ "$l075" -lt "$l08" ]
  [ "$l08" -lt "$l09" ]
  [ "$(grep -c '^### Phase 0\.8 ' "$SKILL")" -eq 1 ]
}

@test "Phase 0.8 runs on the bare and scoped branches only and says the wildcard skips it" {
  s="$(phase08)"
  [[ "$s" == *'bare and scoped branches only'* ]]
  [[ "$s" == *'**Wildcard (`/jenga *`) — this phase does not run.**'* ]]
  # Phase 0.75 hands the bare and scoped branches to Phase 0.8 and the wildcard past it.
  t="$(section '^### Phase 0\.75 ' '^### Phase 0\.8 ')"
  [[ "$t" == *'proceed to Phase 0.8, and the wildcard branch proceeds straight to Phase 0.9'* ]]
  [[ "$t" == *'Phase 0.8 (the foreground check-in and cost/cadence prompt) does not run here either'* ]]
}

@test "Phase 0.8 mints the run id with foreground-preflight.sh mint, runs j.check-in in the host, and is the only minting site" {
  s="$(phase08)"
  [[ "$s" == *'scripts/foreground-preflight.sh || echo node_modules/@jenga-ai/agent/scripts/foreground-preflight.sh)" mint`'* ]]
  [[ "$s" == *'Run `j.check-in` yourself, in this session. Never delegate it'* ]]
  [[ "$s" == *'the **only** place the id is minted'* ]]
  # No other part of the file calls mint.
  [ "$(grep -c 'foreground-preflight.sh)" mint' "$SKILL")" -eq 1 ]
}

# =============================================================================
# Group 2 - the prompt: wording in one asset, referenced and not duplicated
# =============================================================================

@test "Phase 0.8 references the asset by path, in both the repo and the installed location" {
  s="$(phase08)"
  [[ "$s" == *'`skills/j-do/assets/foreground-prompt.md`'* ]]
  [[ "$s" == *'`node_modules/@jenga-ai/agent/skills/j-do/assets/foreground-prompt.md`'* ]]
  [ -f "$ASSET" ]
}

@test "the prompt wording is not duplicated into SKILL.md" {
  run grep -nF -e 'The dispatch will run' -e 'each capped at about 30 minutes' -e 'no rework round without asking again.' "$SKILL"
  # The skill may mention the asset's rules in prose, but not carry the asset's sentence.
  [[ "$output" != *'The dispatch will run <N> units in the background'* ]]
  [[ "$output" != *'each capped at about 30 minutes, with a mid-run report'* ]]
  # The asset itself carries it exactly once.
  [ "$(grep -c '^The dispatch will run <N> units in the background (<scope mix>), up to <cap> at a time' "$ASSET")" -eq 1 ]
}

@test "the asset's prompt names unit count, scope mix, background, the 30 minute cap, mid-run report, the cap and no rework" {
  p="$(awk '/^## Prompt/{f=1;next} /^## /{f=0} f' "$ASSET")"
  [[ "$p" == *'<N> units'* ]]
  [[ "$p" == *'<scope mix>'* ]]
  [[ "$p" == *'in the background'* ]]
  [[ "$p" == *'<cap> at a time'* ]]
  [[ "$p" == *'each capped at about 30 minutes'* ]]
  [[ "$p" == *'mid-run report'* ]]
  [[ "$p" == *'no rework round without asking again'* ]]
}

@test "Phase 0.8 fills the placeholders from execution_scope and max_concurrent_developers in scope-thresholds.json" {
  s="$(phase08)"
  [[ "$s" == *'`execution_scope` distribution'* ]]
  [[ "$s" == *'`max_concurrent_developers` from `project/configs/scope-thresholds.json`'* ]]
  # The real config carries the key the prompt reads.
  run jq -e '.max_concurrent_developers | numbers' "$REPO_ROOT/project/configs/scope-thresholds.json"
  [ "$status" -eq 0 ]
}

@test "the prompt carries no token, time or dollar forecast and points at task-usage.sh for after-the-fact numbers" {
  p="$(awk '/^## Prompt/{f=1;next} /^## /{f=0} f' "$ASSET")"
  # No currency amount, no "<number> tokens/USD/minutes of usage" forecast. (The 30 minute cap is a cap, not a forecast.)
  run grep -E -e '[$€£][0-9]' -e '[0-9][0-9,.]*[kKmM]? *(tokens|USD|dollars)' <<< "$p"
  [ "$status" -ne 0 ]
  [[ "$p" == *'scripts/task-usage.sh'* ]]
  [ -x "$REPO_ROOT/scripts/task-usage.sh" ] || [ -f "$REPO_ROOT/scripts/task-usage.sh" ]
  [[ "$(phase08)" == *'do not add a token, time or dollar forecast'* ]]
}

@test "the options are a numbered Proceed, Cancel, Other list with free text last" {
  grep -q '^1\. Proceed$' "$ASSET"
  grep -q '^2\. Cancel$' "$ASSET"
  grep -q '^3\. Other (describe below)$' "$ASSET"
  a="$(grep -n '^1\. Proceed$' "$ASSET" | cut -d: -f1)"
  b="$(grep -n '^2\. Cancel$' "$ASSET" | cut -d: -f1)"
  c="$(grep -n '^3\. Other' "$ASSET" | cut -d: -f1)"
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]
  # Nothing numbered after the free-text option.
  run awk -v c="$c" 'NR > c && /^[0-9]+\. /' "$ASSET"
  [ -z "$output" ]
}

@test "the plug-in point for measured numbers is marked, one sentence, and names E90 and E76" {
  grep -q '^<!-- PLUG-IN POINT: measured-per-task-numbers (E90, E76)' "$ASSET"
  grep -q '^<!-- PLUG-IN START -->$' "$ASSET"
  grep -q '^<!-- PLUG-IN END -->$' "$ASSET"
  s="$(awk '/^<!-- PLUG-IN START -->$/{f=1;next} /^<!-- PLUG-IN END -->$/{f=0} f' "$ASSET")"
  [ "$(printf '%s\n' "$s" | grep -c .)" -eq 1 ]
  [[ "$s" == *'scripts/task-usage.sh'* ]]
  pi="$(awk '/PLUG-IN POINT/{f=1} f{print} /PLUG-IN START/{exit}' "$ASSET")"
  [[ "$pi" == *'E90'* ]]
  [[ "$pi" == *'E76'* ]]
  [[ "$pi" == *'Replace ONLY the single sentence'* ]]
  # Phase 0.8 names the same slot instead of restating the sentence.
  [[ "$(phase08)" == *'plug-in sentence'* ]]
  [[ "$(phase08)" == *'`E90`'* ]] && [[ "$(phase08)" == *'`E76`'* ]]
}

# =============================================================================
# Group 3 - the three answers, text
# =============================================================================

@test "Proceed is the only place gate is called with --user-yes, via jenga" {
  s="$(phase08)"
  [ "$(printf '%s\n' "$s" | grep -c -e '--user-yes')" -ge 1 ]
  p="$(bullet '1. Proceed')"
  [[ "$p" == *'gate --run "<checklist_run_id>" --via jenga --user-yes'* ]]
  [[ "$p" == *'only call that passes `--user-yes`'* ]]
  # Every line of Phase 0.8 that invokes `gate` with --user-yes is that one bullet.
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'gate --run .* --user-yes'" _ "$s"
  [ "$output" = "1" ]
  # A non-zero gate exit is reported and nothing is dispatched.
  [[ "$p" == *'Any non-zero exit'* ]]
  [[ "$p" == *'nothing is dispatched'* ]]
}

@test "Cancel halts like the picker and confirmation cancellations and never calls gate with --user-yes" {
  c="$(bullet '2. Cancel')"
  [[ "$c" == *'halt the entire `/jenga` run, exactly as the picker and confirmation cancellations do'* ]]
  [[ "$c" == *'Nothing is dispatched'* ]]
  [[ "$c" == *'`dispatch-cost-and-cadence` is left unticked'* ]]
  [[ "$c" == *'`gate` is **never** called with `--user-yes` on this path'* ]]
  # The Cancel bullet itself contains no gate invocation.
  [[ "$c" != *'gate --run'* ]]
}

@test "Other and free text are unresolved: re-ask, never tick" {
  o="$(bullet '3. Other')"
  [[ "$o" == *'unresolved'* ]]
  [[ "$o" == *'show the prompt again'* ]]
  [[ "$o" == *'Never tick on free text'* ]]
  [[ "$o" != *'gate --run'* ]]
  # The asset says the same, so every caller of the asset inherits it.
  grep -q 'is unresolved: answer it, then ask this prompt again. It never counts as a yes.' "$ASSET"
}

# =============================================================================
# Group 4 - threading the run id
# =============================================================================

@test "Phase 3.5 step 7b passes the Phase 0.8 run id as checklist_run_id" {
  s="$(section '^### Phase 3\.5 ' '^### Phase 4 ')"
  b="$(printf '%s\n' "$s" | grep -F '   b. Call `/do <E##_S##>` once')"
  [[ "$b" == *'checklist_run_id'* ]]
  [[ "$b" == *'minted in Phase 0.8'* ]]
  [[ "$b" == *'verbatim'* ]]
  [[ "$b" == *'`/jenga *` no such id exists'* ]]
}

@test "Phase 4 step 3 passes the run id on every wave and step 5c's loop-back reuses it unchanged" {
  s="$(section '^### Phase 4 ' '^### Exit condition')"
  three="$(printf '%s\n' "$s" | grep -F '3. **Invoke `/do` in parallel**')"
  [[ "$three" == *'checklist_run_id'* ]]
  [[ "$three" == *'minted in Phase 0.8'* ]]
  [[ "$three" == *'on every wave'* ]]
  [[ "$three" == *'Under `/jenga *` there is no such id and the field stays empty'* ]]
  five_c="$(printf '%s\n' "$s" | grep -F '   c. **Return to step 1**')"
  [[ "$five_c" == *'the SAME Phase 0.8 `checklist_run_id`, unchanged'* ]]
  [[ "$five_c" == *'never mints a new one and never re-runs Phase 0.8'* ]]
}

@test "the run id is only ever threaded, never regenerated, after Phase 0.8" {
  # Everything from Phase 0.9 onward: no mint call and no other source of a run id.
  rest="$(awk '/^### Phase 0\.9 /{f=1} f' "$SKILL")"
  [[ "$rest" != *'foreground-preflight.sh)" mint'* ]]
  [[ "$rest" != *'foreground-preflight.sh)" gate'* ]]
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'checklist_run_id'" _ "$rest"
  [ "$output" -ge 3 ]
  # The sender template field exists for the threading to land in.
  run jq -e '.sender | has("checklist_run_id")' "$REPO_ROOT/skills/j-do/assets/sender_template.json"
  [ "$status" -eq 0 ]
}

# =============================================================================
# Group 5 - /jenga * : documented, and units would still defer
# =============================================================================

@test "/jenga * is documented in Phase 0.8: no prompt, no tick, no checklist_run_id, exactly one hint line" {
  w="$(phase08 | awk '/^\*\*Wildcard/{f=1} /^\*\*Steps/{f=0} f')"
  [[ "$w" == *'prompts for nothing, ticks nothing, mints no run id and passes **no** `checklist_run_id`'* ]]
  [[ "$w" == *'defer at the pre-flight gate exactly as they did before this phase existed'* ]]
  [[ "$w" == *'exactly one line'* ]]
  # One hint line, in the whole file, naming the alternatives.
  [ "$(grep -c '^Note: /jenga \* skips the foreground check-in' "$SKILL")" -eq 1 ]
  hint="$(grep '^Note: /jenga \* skips the foreground check-in' "$SKILL")"
  [[ "$hint" == *'bare or scoped /jenga'* ]]
  [[ "$hint" == *'j.check-in'* ]]
  [[ "$hint" == *'foreground /do'* ]]
  # The hint is a single line: no embedded newline survives the grep above, and it is inside a code fence.
  [ "$(printf '%s\n' "$hint" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "/jenga * is documented in the Edge Cases list: no prompt, no tick, no checklist_run_id, one hint line, units still defer" {
  e="$(edge_cases | grep -F '**`/jenga *` (wildcard branch)**')"
  [[ "$e" == *'Phase 0.8 does not run'* ]]
  [[ "$e" == *'no prompt, no tick, no `checklist_run_id` is passed'* ]]
  [[ "$e" == *'exactly one hint line'* ]]
  [[ "$e" == *'Its units still defer at the pre-flight gate'* ]]
}

@test "the Cancel case has its own Edge Cases entry" {
  e="$(edge_cases | grep -F '**Cost/cadence prompt cancelled or unresolved (Phase 0.8')"
  [[ "$e" == *'Cancel halts the entire `/jenga` run'* ]]
  [[ "$e" == *'never called with `--user-yes`'* ]]
  [[ "$e" == *'unresolved'* ]]
}

@test "executed: under /jenga * (no run id) verify fails with empty stdout, so a unit would defer" {
  add_checkin_event
  # Even with a user having ticked both items for SOME run, a * run passes no id and has nothing to verify.
  bash "$CHECKLIST" tick "$CHECKIN_ID" --run fg-20261111T120000Z-aaaa1111 --by user:jenga < /dev/null > /dev/null
  bash "$CHECKLIST" tick "$COST_ID" --run fg-20261111T120000Z-aaaa1111 --by user:jenga < /dev/null > /dev/null
  run --separate-stderr bash "$FG" verify < /dev/null
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run --separate-stderr bash "$FG" verify --run "" < /dev/null
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # What a unit then does: mint its own do-... id and check. Both items need a decision (exit 11).
  RUN_ID="do-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  run --separate-stderr bash "$CHECKLIST" check pre-task --run "$RUN_ID" < /dev/null
  [ "$status" -eq 11 ]
  [ "$(tick_state "$COST_ID" "$RUN_ID")" != "" ]
  [[ "$(tick_state "$COST_ID" "$RUN_ID")" != ticked* ]]
}

# =============================================================================
# Group 6 - the Cancel and Proceed paths, executed
# =============================================================================

@test "executed: mint returns a fresh id that the scripts Phase 0.8 calls accept" {
  run --separate-stderr bash "$FG" mint < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^fg-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
  id="$output"
  run --separate-stderr bash "$FG" gate --run "$id" --via jenga < /dev/null
  [ "$status" -eq 10 ]
}

@test "executed: the Cancel path never reaches a gate call with --user-yes; a gate without it leaves the cost item unticked" {
  add_checkin_event
  id="fg-20261111T130000Z-bbbb2222"
  # Without --user-yes (what a Cancel, or any unresolved answer, must leave): the check-in item is ticked, the
  # judgment item is not, and the run id does not verify.
  run --separate-stderr bash "$FG" gate --run "$id" --via jenga < /dev/null
  [ "$status" -eq 11 ]
  [[ "$(tick_state "$CHECKIN_ID" "$id")" == ticked* ]]
  [[ "$(tick_state "$COST_ID" "$id")" != ticked* ]]
  run --separate-stderr bash "$FG" verify --run "$id" < /dev/null
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # Text side: the only SKILL.md line that invokes gate with --user-yes is the Proceed bullet (Group 3), and Phase
  # 0.8's Cancel and Other bullets contain no gate call at all.
  [ -z "$(bullet '2. Cancel' | grep -F 'gate --run')" ]
  [ -z "$(bullet '3. Other' | grep -F 'gate --run')" ]
}

@test "executed: the Proceed path (gate with --user-yes) makes the run id verify, so a unit adopts it and does not defer" {
  add_checkin_event
  id="fg-20261111T130000Z-cccc3333"
  run --separate-stderr bash "$FG" gate --run "$id" --via jenga --user-yes < /dev/null
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$FG" verify --run "$id" < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run --separate-stderr bash "$CHECKLIST" check pre-task --run "$id" < /dev/null
  [ "$status" -eq 0 ]
  # Same id, a different run: nothing carries over.
  run --separate-stderr bash "$FG" verify --run "fg-20261111T130000Z-dddd4444" < /dev/null
  [ "$status" -ne 0 ]
}

@test "executed: a check-in that did not register stops Proceed with a non-zero gate exit and ticks nothing" {
  # No checkin event in the fixture events.json.
  id="fg-20261111T130000Z-eeee5555"
  run --separate-stderr bash "$FG" gate --run "$id" --via jenga --user-yes < /dev/null
  [ "$status" -eq 10 ]
  [[ "$(tick_state "$CHECKIN_ID" "$id")" != ticked* ]]
  [[ "$(tick_state "$COST_ID" "$id")" != ticked* ]]
}

# =============================================================================
# Group 7 - unchanged files and isolation
# =============================================================================

@test "scripts/checklist.sh (and the other scripts this task builds on) are not modified by this task" {
  git -C "$REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1 || skip "not a git checkout"
  base="$(git -C "$REPO_ROOT" log --format=%H --grep='^story(E67_S11): merge T02' -1 2>/dev/null || true)"
  [ -n "$base" ] || skip "T02 merge commit not in history"
  run git -C "$REPO_ROOT" diff --quiet "$base" -- scripts/checklist.sh scripts/checklist-marker.sh scripts/foreground-preflight.sh skills/j-check-in/scripts/checkin-gate.sh
  [ "$status" -eq 0 ]
}

@test "isolation: these tests wrote nothing under the repository's real tick directory" {
  real="$REPO_ROOT/project/queue/checklist-ticks"
  before="$( [ -d "$real" ] && ls -A "$real" | sort | tr '\n' ' ' || echo none )"
  add_checkin_event
  bash "$FG" gate --run "fg-20261111T130000Z-ffff6666" --via jenga --user-yes < /dev/null > /dev/null
  after="$( [ -d "$real" ] && ls -A "$real" | sort | tr '\n' ' ' || echo none )"
  [ "$before" = "$after" ]
  [ -d "$STATE" ]
}
