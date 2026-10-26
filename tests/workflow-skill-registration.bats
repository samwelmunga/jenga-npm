#!/usr/bin/env bats
#
# Registration coverage for the j.workflow skill (E80_S05_T05).
#
# Adding skills/j-workflow/ changes the catalog, which carries two E50 obligations: the committed
# skill allow-list must be regenerated (never hand-edited), and the generated .claude/ and .agents/
# mirrors must be refreshed by j.self-sync. This file proves both landed, and that the Jenga Router
# picks the skill up -- against this repository's real skills/ tree, not a synthetic one.
#
# Shape follows tests/router-prefix-guard.bats (router) and tests/skill-allow-list-bijection.bats
# (allow-list), reusing their shims: tests/helpers/router-route.mjs and tests/helpers/allow-list-scan.mjs.
# No npm install, no network, no embedding model.
#
# The router does not claim the directory-resolved "/j-<name>" slash form at Stage 1 (E50_S12_T04: no
# leading-slash special case; Claude Code resolves that form by literal directory name). So for that form
# this file asserts the two halves the resolution actually rests on: the directory name skills/j-workflow/
# and the frontmatter identifier j.workflow, plus the router's own "/j-workflow" non-claim.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ROUTE="$REPO_ROOT/tests/helpers/router-route.mjs"
SCAN="$REPO_ROOT/tests/helpers/allow-list-scan.mjs"
SKILLS="$REPO_ROOT/skills"
SKILL_MD="$SKILLS/j-workflow/SKILL.md"

json_field() {
  node -e 'const o=JSON.parse(process.argv[1]);const v=o===null?null:o[process.argv[2]];process.stdout.write(String(v))' "$1" "$2"
}

# The index builder logs "[jenga-router] Indexed N skills" on stderr, and bats' `run` folds stderr into
# $output; this wrapper drops it so $output is only the shim's JSON line.
quiet_route() {
  node "$ROUTE" "$@" 2>/dev/null
}

# Succeeds when the JSON array in $1 contains the exact string $2.
json_array_has() {
  node -e 'const a=JSON.parse(process.argv[1]);process.exit(a.some(x=>(typeof x==="string"?x:x&&x.name)===process.argv[2])?0:1)' "$1" "$2"
}

@test "the skill directory and frontmatter follow the canonical j-<name> / j.<name> pairing" {
  [ -f "$SKILL_MD" ]
  run sed -n '2p' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "name: j.workflow" ]
}

@test "the generator, run against the real skills/ tree, yields the workflow identifier" {
  run node "$SCAN" ids "$SKILLS"
  [ "$status" -eq 0 ]
  json_array_has "$output" workflow
}

@test "the committed lib/skill-allow-list.json contains workflow and its skill_count matches" {
  run node -e '
    const l = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (!l.skills.includes("workflow")) process.exit(1);
    if (l.skill_count !== l.skills.length) process.exit(2);
  ' "$REPO_ROOT/lib/skill-allow-list.json"
  [ "$status" -eq 0 ]
}

@test "the committed allow-list and the generator agree on the skills array" {
  run node "$SCAN" ids "$SKILLS"
  [ "$status" -eq 0 ]
  expected="$output"
  run node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).skills))' "$REPO_ROOT/lib/skill-allow-list.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "the router's allow-list for the real skills/ tree contains workflow" {
  run node "$ROUTE" allow-list "$SKILLS"
  [ "$status" -eq 0 ]
  json_array_has "$output" workflow
}

@test "j.workflow is trusted as passthrough" {
  run node "$ROUTE" route "$SKILLS" "j.workflow run x"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" action)" = "passthrough" ]
  [ "$(json_field "$output" transformed)" = "j.workflow run x" ]
}

@test "the legacy j: separator for workflow is also trusted as passthrough" {
  run node "$ROUTE" route "$SKILLS" "j:workflow run x"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" action)" = "passthrough" ]
}

@test "the /j-workflow directory form is not claimed by the router (resolved natively by directory name)" {
  run node "$ROUTE" route "$SKILLS" "/j-workflow run x"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
  [ -d "$SKILLS/j-workflow" ]
}

@test "the router skill index lists workflow" {
  run quiet_route index "$SKILLS"
  [ "$status" -eq 0 ]
  json_array_has "$output" workflow
}

@test "Stage 2 emits the canonical j.workflow invocation for the indexed skill" {
  run quiet_route emit "$SKILLS" workflow "run x"
  [ "$status" -eq 0 ]
  [ "$output" = '"j.workflow run x"' ]
}

@test "j.workflownope stays guarded (no masquerading)" {
  run node "$ROUTE" route "$SKILLS" "j.workflownope run x"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" action)" = "unrecognized" ]
}

@test "the .claude/ and .agents/ SKILL.md copies are byte-identical to the source" {
  [ -f "$REPO_ROOT/.claude/skills/j-workflow/SKILL.md" ]
  [ -f "$REPO_ROOT/.agents/skills/j-workflow/SKILL.md" ]
  cmp "$SKILL_MD" "$REPO_ROOT/.claude/skills/j-workflow/SKILL.md"
  cmp "$SKILL_MD" "$REPO_ROOT/.agents/skills/j-workflow/SKILL.md"
}

@test "the .claude/ and .agents/ skill scripts are byte-identical to the source" {
  cmp "$SKILLS/j-workflow/scripts/workflow-cli.sh" "$REPO_ROOT/.claude/skills/j-workflow/scripts/workflow-cli.sh"
  cmp "$SKILLS/j-workflow/scripts/workflow-cli.sh" "$REPO_ROOT/.agents/skills/j-workflow/scripts/workflow-cli.sh"
}

@test "the mirrored skill allow-lists match the root allow-list" {
  cmp "$REPO_ROOT/lib/skill-allow-list.json" "$REPO_ROOT/.claude/lib/skill-allow-list.json"
  cmp "$REPO_ROOT/lib/skill-allow-list.json" "$REPO_ROOT/.agents/lib/skill-allow-list.json"
}

# ---------------------------------------------------------------------------
# Public-distribution decision (E80_S05_T07): j.workflow ships; project/.workflows/ is private.
# Asserted against the REAL .publicignore through scripts/check-publicignore-match.sh, which reuses
# /j-mirror-public's own rsync --exclude-from matching (no hand-rolled glob logic).
# ---------------------------------------------------------------------------

PUBLICIGNORE="$REPO_ROOT/.publicignore"
MATCH="$REPO_ROOT/scripts/check-publicignore-match.sh"

@test "skills/j-workflow and scripts/workflow are not matched by any .publicignore pattern" {
  run bash "$MATCH" \
    skills/j-workflow/SKILL.md \
    skills/j-workflow/scripts/workflow-cli.sh \
    scripts/workflow/lib.sh \
    scripts/workflow/load-workflows.sh \
    scripts/workflow/examples/example-report-select.sh \
    templates/workflows/example-report.json \
    templates/workflows/example-report.md
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^PUBLIC')" -eq 7 ]
  [[ "$output" != *BLOCKED* ]]
}

@test "no .publicignore pattern line names skills/j-workflow or scripts/workflow" {
  run bash -c 'grep -vE "^[[:space:]]*(#|$)" "$1" | grep -E "j-workflow|scripts/workflow|templates/workflows"' _ "$PUBLICIGNORE"
  [ "$status" -ne 0 ]
}

@test "the skills j.workflow's own text names are public too (no stranded step target)" {
  run bash "$MATCH" skills/j-playbook/SKILL.md skills/jenga/SKILL.md
  [ "$status" -eq 0 ]
  [[ "$output" != *BLOCKED* ]]
}

@test "project/.workflows/ is matched by .publicignore and appears exactly once as a pattern line" {
  run grep -Fxc 'project/.workflows/' "$PUBLICIGNORE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
  # Behavioural check with the same rsync semantics the mirror uses, on a throwaway tree: the
  # project-local directory is excluded, a sibling project file is not.
  scratch="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$scratch/project/.workflows" "$scratch/project/other" "$BATS_TEST_TMPDIR/dest"
  : > "$scratch/project/.workflows/mine.json"
  : > "$scratch/project/other/keep.json"
  run rsync -a --dry-run --exclude-from="$PUBLICIGNORE" --out-format='%n' "$scratch/" "$BATS_TEST_TMPDIR/dest/"
  [ "$status" -eq 0 ]
  [[ "$output" != *"project/.workflows/mine.json"* ]]
  [[ "$output" == *"project/other/keep.json"* ]]
}

@test "the ship decision is recorded in .publicignore with a stable marker, next to project/.workflows/" {
  run grep -Fc '# --- Decision (E80_S05_T07, 2026-10-25): j.workflow SHIPS to the public mirror ---' "$PUBLICIGNORE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
  marker="$(grep -Fn 'Decision (E80_S05_T07, 2026-10-25)' "$PUBLICIGNORE" | cut -d: -f1)"
  entry="$(grep -Fxn 'project/.workflows/' "$PUBLICIGNORE" | cut -d: -f1)"
  [ "$((marker - entry))" -le 3 ]
  run grep -F 'Stranded-check outcome' "$PUBLICIGNORE"
  [ "$status" -eq 0 ]
}

@test "distribution.md records the packaging decision" {
  run grep -F '### Workflow skill packaging decision (`j.workflow`)' "$REPO_ROOT/project/documentation/distribution.md"
  [ "$status" -eq 0 ]
}
