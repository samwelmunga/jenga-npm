#!/usr/bin/env bats
#
# Regression coverage for lib/generate-skill-allow-list.js's three-way mapping (E50_S12_T01).
#
# Why this file exists
# --------------------
# lib/generate-skill-allow-list.js's header now states the three-way mapping explicitly:
#
#   skills/j-<name>/ (directory) <-> name: j.<name> (frontmatter) <-> <name> (allow-listed
#   identifier)
#
# for every skill except the three permanent exceptions (jenga, jenga-permission-level, index),
# which skip the j- prefix on all three legs. No prior test asserted this as a genuine bijection —
# tests/generate-j-alias.bats only covers extractName's prefix-stripping in isolation. This file
# closes that gap.
#
# Why a synthetic tree, not this repo's own skills/
# --------------------------------------------------
# This repo's own skills/ is mid-cutover: E50_S15 (frontmatter rewrite name: j.j-<name> ->
# j.<name>, landed together with the bare-directory deletion) has not run yet. Most
# skills/j-<name>/SKILL.md twins today still carry the doubled "j.j-<name>" form, which
# extractName correctly strips ONE prefix off, yielding the identifier "j-<name>" rather than
# "<name>" -- a real, but separately-owned and out-of-sequence, gap belonging to E50_S15, not a
# defect in this generator's own logic. Asserting a hard bijection against the live tree would
# make this suite red for a reason entirely outside this task's declared scope (2 files:
# lib/generate-skill-allow-list.js and this test), and would encourage exactly the kind of
# out-of-sequence "fix" E50_S15's story explicitly warns against (the frontmatter rewrite and the
# bare-directory deletion must land together, after E50_S11-S14 and E50_S19).
#
# So the bijection invariant itself is proven against a synthetic tree already in the settled
# post-E50_S15 shape -- matching the same pattern tests/router-prefix-guard.bats,
# load-nl-catalog's new regression test (E50_S12_T03), and the router guard's new regression test
# (E50_S12_T04) all use for the identical reason. See project/documentation/plans/E50_S12-plan.md.
#
# What IS asserted against the real repo (see the last two tests below) is something that holds
# true today regardless of the transitional frontmatter state: the two independent regeneration
# call sites (scripts/postinstall.js and skills/j-self-sync/scripts/run.js) must never drift from
# each other. Proving generateSkillAllowList() against skills/ and against .agents/skills/
# (the mirrored copy /self-sync produces) yields identical `skills` arrays covers both call sites
# without invoking either script's full flow, and holds regardless of whether E50_S15 has landed,
# because .agents/skills/ is a raw, content-identical mirror of skills/ either way.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$REPO_ROOT/tests/helpers/allow-list-scan.mjs"

# Builds a synthetic tree already in the settled post-E50_S15 shape:
#   j-alpha/    name: j.alpha       -- normal skill, twin directory, single-prefixed frontmatter
#   j-beta/     name: j.beta        -- normal skill, twin directory, single-prefixed frontmatter
#   jenga/      name: jenga         -- permanent exception, bare directory, bare frontmatter
#   jenga-permission-level/  name: jenga-permission-level  -- permanent exception
#   index/      (no SKILL.md)       -- permanent exception, not a skill, must be skipped silently
setup() {
  SKILLS_DIR="$BATS_TEST_TMPDIR/skills"
  mkdir -p "$SKILLS_DIR/j-alpha" "$SKILLS_DIR/j-beta" \
    "$SKILLS_DIR/jenga" "$SKILLS_DIR/jenga-permission-level" "$SKILLS_DIR/index"

  cat > "$SKILLS_DIR/j-alpha/SKILL.md" <<'SKILL'
---
name: j.alpha
description: Synthetic fixture skill alpha.
---

# alpha
SKILL

  cat > "$SKILLS_DIR/j-beta/SKILL.md" <<'SKILL'
---
name: j.beta
description: Synthetic fixture skill beta.
---

# beta
SKILL

  cat > "$SKILLS_DIR/jenga/SKILL.md" <<'SKILL'
---
name: jenga
description: Synthetic fixture for the jenga permanent exception.
---

# jenga
SKILL

  cat > "$SKILLS_DIR/jenga-permission-level/SKILL.md" <<'SKILL'
---
name: jenga-permission-level
description: Synthetic fixture for the jenga-permission-level permanent exception.
---

# jenga-permission-level
SKILL

  # index/ deliberately has NO SKILL.md -- it is not a skill (docs/skill-authoring.md, "not a
  # skill, no SKILL.md, not part of routing"). getSkillAllowListIdentifiers must skip it silently
  # rather than error, matching its documented "missing SKILL.md is skipped" behavior.
}

ids() {
  node "$HELPER" ids "$SKILLS_DIR" 2>/dev/null
}

# Resolves an identifier to the directory it is expected to live in under the three-way mapping:
# the three permanent exceptions keep their bare directory; every other identifier resolves via
# its j-<name> twin.
resolve_dir() {
  local id="$1"
  case "$id" in
    jenga|jenga-permission-level|index) echo "$SKILLS_DIR/$id" ;;
    *) echo "$SKILLS_DIR/j-$id" ;;
  esac
}

# --------------------------------------------------------------
# Forward direction: every identifier resolves to a real directory.
# --------------------------------------------------------------

@test "every identifier in the allow-list resolves to a directory on disk" {
  run ids
  [ "$status" -eq 0 ]
  local list="$output"
  local count
  count=$(node -e 'console.log(JSON.parse(process.argv[1]).length)' "$list")
  [ "$count" -gt 0 ]

  local id dir
  for id in $(node -e 'JSON.parse(process.argv[1]).forEach(x=>console.log(x))' "$list"); do
    dir=$(resolve_dir "$id")
    [ -f "$dir/SKILL.md" ]
  done
}

@test "the three permanent exceptions resolve via their bare directory, not a twin" {
  run ids
  [ "$status" -eq 0 ]
  assert_output_contains '"jenga"'
  assert_output_contains '"jenga-permission-level"'
  # index/ has no SKILL.md, so it must NOT appear as an identifier at all.
  assert_output_not_contains '"index"'
}

@test "a normal skill resolves via its j-<name> twin, not a bare directory that doesn't exist" {
  run ids
  [ "$status" -eq 0 ]
  assert_output_contains '"alpha"'
  assert_output_contains '"beta"'
  # No bare skills/alpha/ or skills/beta/ directory exists in this fixture -- only the twin.
  [ ! -d "$SKILLS_DIR/alpha" ]
  [ ! -d "$SKILLS_DIR/beta" ]
  [ -f "$SKILLS_DIR/j-alpha/SKILL.md" ]
  [ -f "$SKILLS_DIR/j-beta/SKILL.md" ]
}

# --------------------------------------------------------------
# Converse direction: every SKILL.md-bearing directory produces an entry. A true bijection,
# not a one-directional spot check.
# --------------------------------------------------------------

@test "every SKILL.md-bearing directory is represented in the identifier list (no silent drop)" {
  run ids
  [ "$status" -eq 0 ]
  local list="$output"

  for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
    local dirname
    dirname=$(basename "$(dirname "$skill_md")")
    local expected_id="${dirname#j-}"
    local found
    found=$(node -e '
      const list = JSON.parse(process.argv[1]);
      console.log(list.includes(process.argv[2]) ? "yes" : "no");
    ' "$list" "$expected_id")
    [ "$found" = "yes" ]
  done
}

@test "identifier count matches the number of SKILL.md-bearing directories exactly" {
  run ids
  [ "$status" -eq 0 ]
  local count
  count=$(node -e 'console.log(JSON.parse(process.argv[1]).length)' "$output")
  # 4 SKILL.md-bearing directories in the fixture: j-alpha, j-beta, jenga, jenga-permission-level.
  # index/ has no SKILL.md and contributes nothing.
  [ "$count" -eq 4 ]
}

# --------------------------------------------------------------
# Cross-mirror consistency: the two independent regeneration call sites
# (scripts/postinstall.js L362, skills/j-self-sync/scripts/run.js L221) must never drift.
# Run against THIS repo's real skills/ and .agents/skills/ -- holds regardless of the
# pre-E50_S15 transitional frontmatter state, because .agents/skills/ is a raw content mirror.
# --------------------------------------------------------------

@test "generateSkillAllowList() against skills/ and .agents/skills/ produce identical skills arrays" {
  skip_if_no_agents_mirror

  local out_a="$BATS_TEST_TMPDIR/from-skills.json"
  local out_b="$BATS_TEST_TMPDIR/from-agents-skills.json"

  run node "$HELPER" skills-only "$REPO_ROOT/skills" "$out_a"
  [ "$status" -eq 0 ]
  local skills_a="$output"

  run node "$HELPER" skills-only "$REPO_ROOT/.agents/skills" "$out_b"
  [ "$status" -eq 0 ]
  local skills_b="$output"

  [ "$skills_a" = "$skills_b" ]
}

skip_if_no_agents_mirror() {
  if [ ! -d "$REPO_ROOT/.agents/skills" ]; then
    skip "no .agents/skills/ mirror present in this checkout"
  fi
}
