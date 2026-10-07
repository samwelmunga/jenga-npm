#!/usr/bin/env bats
#
# The no-op guarantee and the wiring of the pre-flight checklist gates (E67_S03_T05).
#
# Story E67_S03's acceptance criterion: an empty or absent registry is a silent no-op in every wired skill, and a
# skill's behaviour is otherwise unchanged. Five skills carry that guarantee as prose (`/j-commit`, `/j-reconcile`,
# `/j-do`, `/j-publish`, `/j-mirror-public`); the decision itself lives in scripts/checklist.sh, so the guarantee
# is made mechanical in two halves:
#
#   1. The checker half (behavioural). For every phase the skills fire -- the four base phases and the two release
#      extension phases -- `checklist.sh check <phase> --run <id>` exits 0, prints exactly `[]`, prints NOTHING on
#      stderr and creates nothing under the tick-state directory, when there is (a) no registry file at all, (b) a
#      registry with an empty items array, or (c) only the shipped default (for the phases it has no items for).
#   2. The wiring half (static). Each gated SKILL.md names the checker call for exactly the phase(s) the
#      "Phase-to-skill mapping" table of project/documentation/preflight-checklists.md assigns it, every phase used
#      is a real one, every exit code the gate prose branches on is documented in the checker's header, and no gate
#      hardcodes a project/ path for the checker. This catches a skill being renamed, a phase being retyped, or the
#      table and the skills drifting apart.
#
# Expectations are DERIVED from the files (the doc's tables, the skill files, the checker's header) rather than
# pinned to line numbers, and the checks match the checker call and phase tokens, never whole sentences, so a prose
# rewording does not break them. Only the mapping itself is pinned (one test), because it is the contract.
#
# One documented exception to "every phase is a no-op", asserted deliberately: a registry file that does not
# declare `pre-publish` / `pre-mirror` answers exit 3 for them (section 9, "Extension phases must be declared").
# The release skills treat exit 3 from their second, skill-specific phase as "no items" and continue silently, so
# the skill-level behaviour is still a no-op; exit 3 NEVER occurs for a base phase.
#
# Why "shipped default only" is not asserted as `[]` for every phase: templates/checklists.json is not empty (it
# ships pre-commit, pre-task and pre-release items). Its no-op phases are the ones it carries no item for
# (pre-reconcile, by design: see "Why a reconcile run by /j-commit does not fire pre-reconcile"), and the two
# extension phases it does not declare.
#
# Isolation. Every seam of the checker is pointed into $BATS_TEST_TMPDIR, so no real registry is read by the
# behavioural tests (except the shipped default, by path, in the two tests that name it) and the real tick-state
# directory is never touched. Fixture registries are generated at test time.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
DOC="$REPO_ROOT/project/documentation/preflight-checklists.md"
PROJECT_REGISTRY="$REPO_ROOT/project/configs/checklists.json"
SHIPPED_DEFAULT="$REPO_ROOT/templates/checklists.json"

# The five gated skills, as skill directory names.
GATED_SKILLS="j-commit j-reconcile j-do j-publish j-mirror-public"
# Every phase the skills fire: the four base phases, then the two release extension phases.
BASE_PHASES="pre-commit pre-task pre-release pre-reconcile"
EXTENSION_PHASES="pre-publish pre-mirror"
ALL_PHASES="$BASE_PHASES $EXTENSION_PHASES"
# The repository's dual-path idiom for locating the checker, as the schema document writes it (literal text).
DUAL_PATH_IDIOM='$([ -f scripts/checklist.sh ] && echo scripts/checklist.sh || echo node_modules/@jenga-ai/agent/scripts/checklist.sh'

setup() {
  T="$BATS_TEST_TMPDIR"
  F="$T/checklists.json"
  DEFAULT="$T/default-checklists.json"
  STATE="$T/state"
  PROJ="$T/proj"
  RUN="gating-test-run"
  mkdir -p "$PROJ/project/configs"
  echo '{}' > "$PROJ/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_FILE="$F"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$DEFAULT"
  export JENGA_CHECKLIST_STATE_DIR="$STATE"
  unset JENGA_CHECKLIST_RUN_ID JENGA_CHECKLIST_ACTOR JENGA_CHECKLIST_RUN_TTL_MINUTES JENGA_CHECKLIST_VERIFY_TIMEOUT
}

# -----------------------------------------------------------------------------
# Runners and fixtures
# -----------------------------------------------------------------------------

# ck <args...>: run the checker; $output is stdout, $stderr is stderr, $status the exit code.
ck() { run --separate-stderr bash "$CHECKLIST" "$@"; }

# empty_registry <file> <situations-json>: a valid registry with no items that declares the given extra situations.
empty_registry() {
  jq -n --argjson sit "$2" '{checklist_version: 1, situations: $sit, items: []}' > "$1"
}

# assert_noop <phase> [extra check args...]: the whole no-op contract for one phase, check and list alike.
assert_noop() {
  local phase="$1"
  shift
  ck check "$phase" "$@"
  [ "$status" -eq 0 ] || { echo "check $phase exited $status, expected 0 (stderr: $stderr)" >&2; return 1; }
  [ "$(printf '%s' "$output" | jq -c . 2>/dev/null)" = "[]" ] || {
    echo "check $phase did not print exactly []: $output" >&2
    return 1
  }
  [ -z "$stderr" ] || { echo "check $phase wrote to stderr (a no-op must be silent): $stderr" >&2; return 1; }
  [ ! -e "$STATE" ] || { echo "check $phase created the tick-state dir: $(ls -A "$STATE")" >&2; return 1; }
  ck list "$phase" "$@"
  [ "$status" -eq 0 ] || { echo "list $phase exited $status, expected 0 (stderr: $stderr)" >&2; return 1; }
  [ -z "$output" ] || { echo "list $phase printed something on a no-op: $output" >&2; return 1; }
  [ -z "$stderr" ] || { echo "list $phase wrote to stderr: $stderr" >&2; return 1; }
  [ ! -e "$STATE" ] || { echo "list $phase created the tick-state dir" >&2; return 1; }
}

# assert_undeclared <phase>: the documented exception, exit 3 with empty stdout and a diagnostic naming the phase.
assert_undeclared() {
  ck check "$1" --run "$RUN"
  [ "$status" -eq 3 ] || { echo "check $1 exited $status, expected 3 (undeclared extension phase)" >&2; return 1; }
  [ -z "$output" ] || { echo "check $1 printed stdout on exit 3: $output" >&2; return 1; }
  assert_contains "$stderr" "$1"
  [ ! -e "$STATE" ] || { echo "check $1 created the tick-state dir" >&2; return 1; }
}

# assert_valid_report: $output is one JSON array whose elements carry the documented keys with in-domain values.
assert_valid_report() {
  if ! jq -e 'type == "array" and all(.[];
        ((keys | sort) == ["action", "cause", "enforcement", "exit_status", "id", "kind", "reason", "result",
                           "text", "tick_scope", "tick_state"])
        and (.result | IN("passed", "failed", "requires_confirmation", "already_ticked"))
        and (.action | IN("proceed", "halt", "prompt", "remind")))' <<<"$output" >/dev/null; then
    echo "not a valid check report: $output" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Readers for the static half. Everything is derived from the files on disk.
# -----------------------------------------------------------------------------

skill_file() { printf '%s/skills/%s/SKILL.md' "$REPO_ROOT" "$1"; }

# doc_mapping_rows: the data rows of the doc's "Phase-to-skill mapping" table.
doc_mapping_rows() {
  awk '/^### Phase-to-skill mapping/ {f = 1; next} /^##/ {f = 0} f && /^\| `\/j-/' "$DOC"
}

# doc_phases <skill-dir>: the phases the doc's mapping table assigns the skill, in firing order, space-separated.
doc_phases() {
  doc_mapping_rows | awk -F'|' -v s="\`/$1\`" 'index($2, s) { print $3 }' \
    | grep -o 'pre-[a-z]*' | tr '\n' ' ' | sed 's/ $//'
}

# skill_phases <skill-dir>: the distinct phases the SKILL.md names in a `checklist.sh check <phase>` call, in order of
# first appearance. Newlines are flattened first so a call wrapped across two lines is still seen.
skill_phases() {
  tr '\n' ' ' < "$(skill_file "$1")" | grep -oE 'checklist\.sh check +pre-[a-z]+' \
    | awk '{ print $3 }' | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//'
}

# doc_base_vocabulary: the base situations, from the first column of the doc's section 4 table.
doc_base_vocabulary() {
  awk '/^## 4\. Situation vocabulary/ {f = 1; next} /^## / {f = 0} /^### / {f = 0} f && /^\| `pre-/' "$DOC" \
    | awk -F'|' '{ print $2 }' | grep -o 'pre-[a-z]*' | tr '\n' ' ' | sed 's/ $//'
}

# =============================================================================
# 1. The no-op guarantee: behavioural
# =============================================================================

@test "no registry file at all: every wired phase is a silent no-op, with and without a run id" {
  # Neither the instance ($F) nor the shipped default ($DEFAULT) exists.
  [ ! -e "$F" ]
  [ ! -e "$DEFAULT" ]
  local phase
  for phase in $ALL_PHASES; do
    assert_noop "$phase" --run "$RUN"
    assert_noop "$phase"
  done
}

@test "an empty-items registry that declares the extension phases: every wired phase is a silent no-op" {
  empty_registry "$F" '["pre-publish","pre-mirror"]'
  # A project instance with empty items is a deliberate "nothing applies": it must not fall back to the default.
  cp "$SHIPPED_DEFAULT" "$DEFAULT"
  local phase
  for phase in $ALL_PHASES; do
    assert_noop "$phase" --run "$RUN"
  done
}

@test "an empty-items registry that declares nothing: base phases are no-ops and exit 3 never occurs for them" {
  empty_registry "$F" '[]'
  local phase
  for phase in $BASE_PHASES; do
    assert_noop "$phase" --run "$RUN"
  done
}

@test "documented exception: a registry that does not declare the extension phases answers exit 3 for them" {
  # An empty registry, and a registry that has an item for another phase, behave the same way.
  empty_registry "$F" '[]'
  local phase
  for phase in $EXTENSION_PHASES; do
    assert_undeclared "$phase"
  done
  jq -n '{checklist_version: 1, items: [
        {id: "only-commit", text: "A commit item.", situations: ["pre-commit"], kind: "judgment",
         enforcement: "confirm", tick_scope: "run"}]}' > "$F"
  for phase in $EXTENSION_PHASES; do
    assert_undeclared "$phase"
  done
}

@test "a registry with items, none of which name the phase, is a silent no-op for that phase" {
  jq -n '{checklist_version: 1, situations: ["pre-publish", "pre-mirror"], items: [
        {id: "only-commit", text: "A commit item.", situations: ["pre-commit"], kind: "judgment",
         enforcement: "block", tick_scope: "run"}]}' > "$F"
  local phase
  for phase in pre-task pre-release pre-reconcile $EXTENSION_PHASES; do
    assert_noop "$phase" --run "$RUN"
  done
}

@test "the shipped default alone: the phases it carries no item for are silent no-ops" {
  # No project instance; the shipped default is the registry (whole-file selection, no merging).
  [ ! -e "$F" ]
  export JENGA_CHECKLISTS_DEFAULT_FILE="$SHIPPED_DEFAULT"
  # pre-reconcile: the default carries none, by design (section 9, "Why a reconcile run by /j-commit does not fire
  # pre-reconcile").
  assert_noop pre-reconcile --run "$RUN"
  # The default declares no extension phases, so the documented exit 3 applies, and it is exit 3 for those two only.
  local phase
  for phase in $EXTENSION_PHASES; do
    assert_undeclared "$phase"
  done
  # The other base phases are valid for it (never exit 3, never a diagnostic). Read-only list is used because check
  # would run the default's machine verify commands, which is not what this test is about.
  for phase in pre-commit pre-task pre-release; do
    ck list "$phase"
    [ "$status" -eq 0 ] || { echo "list $phase on the shipped default exited $status: $stderr" >&2; return 1; }
    [ -z "$stderr" ] || { echo "list $phase on the shipped default wrote to stderr: $stderr" >&2; return 1; }
  done
  [ ! -e "$STATE" ]
}

# =============================================================================
# 2. Wiring consistency: static
# =============================================================================

@test "the doc's mapping table assigns exactly the documented phases to exactly the five gated skills" {
  # The pin: this table is the contract the skills are checked against below.
  local rows listed
  rows="$(doc_mapping_rows | wc -l | tr -d ' ')"
  [ "$rows" -eq 5 ] || { echo "expected 5 rows in the phase-to-skill mapping table, found $rows" >&2; return 1; }
  [ "$(doc_phases j-commit)" = "pre-commit" ]
  [ "$(doc_phases j-reconcile)" = "pre-reconcile" ]
  [ "$(doc_phases j-do)" = "pre-task" ]
  [ "$(doc_phases j-publish)" = "pre-release pre-publish" ]
  [ "$(doc_phases j-mirror-public)" = "pre-release pre-mirror" ]
  listed="$(doc_mapping_rows | awk -F'|' '{ print $2 }' | grep -o 'j-[a-z-]*' | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$listed" = "$(printf '%s\n' $GATED_SKILLS | sort | tr '\n' ' ' | sed 's/ $//')" ]
}

# A gated skill may be absent only where .publicignore keeps it private (the public mirror); it is
# still required, and fully checked, everywhere else.
skill_absent_by_design() {
  [ ! -f "$(skill_file "$1")" ] && grep -qxF "skills/$1/" "$REPO_ROOT/.publicignore"
}

@test "every gated skill exists and names the checker call for exactly the phases the mapping table assigns it" {
  local skill expected actual fails=""
  for skill in $GATED_SKILLS; do
    if skill_absent_by_design "$skill"; then continue; fi
    if [ ! -f "$(skill_file "$skill")" ]; then
      fails="$fails\n$skill: skills/$skill/SKILL.md does not exist"
      continue
    fi
    expected="$(doc_phases "$skill")"
    actual="$(skill_phases "$skill")"
    if [ "$expected" != "$actual" ]; then
      fails="$fails\n$skill: the doc table says [$expected] but SKILL.md calls the checker for [$actual]"
    fi
  done
  [ -z "$fails" ] || { printf '%b\n' "$fails" >&2; return 1; }
}

@test "the release skills fire pre-release first and their extension phase second" {
  local skill ext content rel_pos ext_pos
  for skill in j-publish j-mirror-public; do
    if skill_absent_by_design "$skill"; then continue; fi
    ext="$(doc_phases "$skill" | awk '{ print $2 }')"
    content="$(tr '\n' ' ' < "$(skill_file "$skill")")"
    # Byte offset of the first checker call for each phase.
    rel_pos="$(printf '%s' "$content" | grep -ob 'checklist\.sh check  *pre-release' | head -n 1 | cut -d: -f1)"
    ext_pos="$(printf '%s' "$content" | grep -ob "checklist\\.sh check  *$ext" | head -n 1 | cut -d: -f1)"
    [ -n "$rel_pos" ] && [ -n "$ext_pos" ] || { echo "$skill: missing pre-release or $ext call" >&2; return 1; }
    [ "$rel_pos" -lt "$ext_pos" ] || { echo "$skill: $ext is called before pre-release" >&2; return 1; }
  done
}

@test "each gated skill points at the schema document that owns the calling protocol" {
  local skill fails=""
  for skill in $GATED_SKILLS; do
    if skill_absent_by_design "$skill"; then continue; fi
    grep -q 'preflight-checklists\.md' "$(skill_file "$skill")" \
      || fails="$fails $skill"
  done
  [ -z "$fails" ] || { echo "no reference to preflight-checklists.md in:$fails" >&2; return 1; }
  [ -f "$DOC" ]
}

@test "/j-commit and /j-reconcile agree on --from-commit, the flag that keeps pre-reconcile out of a commit flow" {
  grep -q -- '--from-commit' "$(skill_file j-commit)"
  grep -q -- '--from-commit' "$(skill_file j-reconcile)"
  # The mapping table documents the same carve-out from the reconcile side.
  doc_mapping_rows | awk -F'|' 'index($2, "/j-reconcile")' | grep -q 'j-commit'
}

@test "every phase the skills use is in the base vocabulary or declared in the project registry's situations" {
  local base declared phase skill fails=""
  base="$(doc_base_vocabulary)"
  [ "$base" = "$BASE_PHASES" ] || { echo "doc section 4 base vocabulary is [$base], test expects [$BASE_PHASES]" >&2; return 1; }
  declared="$(jq -r '(.situations // []) | .[]' "$PROJECT_REGISTRY" | tr '\n' ' ')"
  for skill in $GATED_SKILLS; do
    if skill_absent_by_design "$skill"; then continue; fi
    for phase in $(skill_phases "$skill"); do
      case " $base $declared " in
        *" $phase "*) ;;
        *) fails="$fails\n$skill uses phase $phase, which is neither a base phase nor declared in project/configs/checklists.json" ;;
      esac
    done
  done
  [ -z "$fails" ] || { printf '%b\n' "$fails" >&2; return 1; }
  # And the extension phases the doc tables name are the ones the project registry declares.
  for phase in $EXTENSION_PHASES; do
    case " $declared " in *" $phase "*) ;; *) echo "project registry does not declare $phase" >&2; return 1 ;; esac
  done
}

@test "every exit code the gate prose branches on is documented in the checker's EXIT CODES header" {
  local header codes code skill fails=""
  header="$(sed -n '/^# EXIT CODES/,/^# (pending and rejected/p' "$CHECKLIST")"
  [ -n "$header" ] || { echo "no EXIT CODES block found in checklist.sh" >&2; return 1; }
  # Codes the skills' gate prose names ("Exit `3` ...") plus codes in the doc's branching table (rules 3 and 6).
  codes="$(
    for skill in $GATED_SKILLS; do
      if skill_absent_by_design "$skill"; then continue; fi
      tr '\n' ' ' < "$(skill_file "$skill")" | grep -oiE 'exit +`[0-9]+`' | grep -o '[0-9][0-9]*'
    done
    sed -n '/^\*\*3\. Branch on the exit code/,/^\*\*4\./p' "$DOC" | grep -oE '^\| `[0-9]+`' | grep -o '[0-9][0-9]*'
    sed -n '/^\*\*6\. Exit `3` depends/,/^###/p' "$DOC" | grep -oiE 'exit `[0-9]+`' | grep -o '[0-9][0-9]*'
  )"
  codes="$(printf '%s\n' "$codes" | sort -un)"
  # The four the gates are known to branch on must all be present, so an empty extraction cannot pass vacuously.
  for code in 0 3 10 11; do
    case " $(printf '%s' "$codes" | tr '\n' ' ') " in
      *" $code "*) ;;
      *) fails="$fails\nexit code $code was not found in the gate prose" ;;
    esac
  done
  for code in $codes; do
    if ! printf '%s\n' "$header" | grep -qE "^#   $code  "; then
      fails="$fails\nexit code $code is named by the gate prose but not documented in checklist.sh's EXIT CODES block"
    fi
  done
  [ -z "$fails" ] || { printf '%b\n' "$fails" >&2; return 1; }
}

# =============================================================================
# 3. No hardcoded-path regressions
# =============================================================================

@test "no gated skill hardcodes a project/ path for the checker, or invokes scripts/checklist.sh outside the dual-path idiom" {
  local skill fails="" stripped
  for skill in $GATED_SKILLS; do
    if skill_absent_by_design "$skill"; then continue; fi
    if grep -qE 'project/[A-Za-z0-9_./-]*checklist\.sh' "$(skill_file "$skill")"; then
      fails="$fails\n$skill: a project/... path to checklist.sh"
    fi
    # Remove every complete dual-path idiom; any scripts/checklist.sh left over is a bare, single-path invocation.
    stripped="$(tr '\n' ' ' < "$(skill_file "$skill")")"
    stripped="${stripped//"$DUAL_PATH_IDIOM"/}"
    if printf '%s' "$stripped" | grep -qE '(^|[^A-Za-z0-9_/-])(\./)?scripts/checklist\.sh'; then
      fails="$fails\n$skill: scripts/checklist.sh outside the dual-path idiom"
    fi
  done
  [ -z "$fails" ] || { printf '%b\n' "$fails" >&2; return 1; }
}

@test "the schema document carries the dual-path idiom for the check and tick calls the skills defer to" {
  # Fixed-string matching (grep -F): the idiom contains `||`, `[` and `.`, all special in a regex, and an unescaped
  # `||` is an empty alternation that BSD grep rejects (exit 2) and other greps match against everything.
  grep -qF "$DUAL_PATH_IDIOM)\" check <phase> --run" "$DOC"
  grep -qF "$DUAL_PATH_IDIOM)\" tick <id> --run" "$DOC"
  # And the doc itself never points a skill at a project/... checker path. (A bare `! grep` would be inert: errexit
  # ignores negated commands, so the branch is explicit.)
  if grep -qE 'project/[A-Za-z0-9_./-]*checklist\.sh' "$DOC"; then
    echo "the schema document names a project/... path to checklist.sh" >&2
    return 1
  fi
}

# =============================================================================
# 4. Smoke against the real registries
# =============================================================================

@test "check against this project's registry returns a valid report for every phase" {
  # Shape only; the content of the registry may change. Verify commands run from the temp root (a non-git tree), so
  # machine items may fail, and any of exit 0, 10 and 11 is a legitimate answer. Nothing real is read or written.
  export JENGA_CHECKLISTS_FILE="$PROJECT_REGISTRY"
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=30
  local phase
  for phase in $ALL_PHASES; do
    ck check "$phase" --run "$RUN"
    case "$status" in 0|10|11) ;; *) echo "check $phase exited $status: $stderr" >&2; return 1 ;; esac
    assert_valid_report
    assert_not_contains "$stderr" "Traceback"
  done
  [ ! -e "$STATE" ]
}

@test "check against the shipped default returns a valid report for every base phase" {
  export JENGA_CHECKLISTS_FILE="$T/no-such-instance.json"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$SHIPPED_DEFAULT"
  export JENGA_CHECKLIST_VERIFY_TIMEOUT=30
  local phase
  for phase in $BASE_PHASES; do
    ck check "$phase" --run "$RUN"
    case "$status" in 0|10|11) ;; *) echo "check $phase exited $status: $stderr" >&2; return 1 ;; esac
    assert_valid_report
    assert_not_contains "$stderr" "Traceback"
  done
  [ ! -e "$STATE" ]
}
