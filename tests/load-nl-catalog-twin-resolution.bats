#!/usr/bin/env bats
#
# Regression coverage for skills/jenga/scripts/load-nl-catalog.js's twin-directory
# resolution (E50_S12_T03).
#
# Why this file exists
# --------------------
# load-nl-catalog.js's canonicalSkillDir(name) (L75-77) maps an allow-listed bare
# identifier to its skills/j-<name>/ twin directory, except the three permanent
# exceptions (jenga, jenga-permission-level, index) which resolve via their bare
# directory instead. That logic was added by a prior fix (commit 0ed77648) but had no
# regression test of its own -- E50_S12's Context calls this out explicitly: "any
# allow-listed name without a directory is warned and skipped ... this is the join that
# must learn the twin directory, or every skill silently drops out of the NL catalog at
# cutover." This file closes that gap.
#
# Fixture, not the live repo
# ---------------------------
# Builds a synthetic pkgRoot with its own lib/skill-allow-list.json and a skills/ tree
# containing ONLY twin directories (skills/j-alpha/, skills/j-beta/) plus the three
# exceptions' bare directories -- no bare skills/alpha/ or skills/beta/ at all, so a pass
# here proves resolution works once E50_S15 deletes the corresponding bare directories in
# the real repo, not merely that today's repo happens to still have both.
#
# lib/generate-skill-allow-list.js itself is copied in verbatim (not re-implemented) so
# this fixture's readSkillAllowList() call exercises the real module, matching the
# pattern tests/router-prefix-guard.bats and tests/skill-allow-list-bijection.bats use.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LOADER="$REPO_ROOT/skills/jenga/scripts/load-nl-catalog.js"

setup() {
  PKG_ROOT="$BATS_TEST_TMPDIR/pkg"
  PROJECT_ROOT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PKG_ROOT/lib" "$PROJECT_ROOT"
  cp "$REPO_ROOT/lib/generate-skill-allow-list.js" "$PKG_ROOT/lib/"

  mkdir -p "$PKG_ROOT/skills/j-alpha" "$PKG_ROOT/skills/j-beta" \
    "$PKG_ROOT/skills/jenga" "$PKG_ROOT/skills/jenga-permission-level"

  cat > "$PKG_ROOT/skills/j-alpha/SKILL.md" <<'SKILL'
---
name: j.alpha
description: Fixture skill alpha (twin-only, settled post-cutover shape).
keywords:
  - alpha thing
examples:
  - "do the alpha thing"
---

# alpha
SKILL

  cat > "$PKG_ROOT/skills/j-beta/SKILL.md" <<'SKILL'
---
name: j.beta
description: Fixture skill beta (twin-only, settled post-cutover shape).
---

# beta
SKILL

  cat > "$PKG_ROOT/skills/jenga/SKILL.md" <<'SKILL'
---
name: jenga
description: Fixture for the jenga permanent exception -- keeps its bare directory.
---

# jenga
SKILL

  cat > "$PKG_ROOT/skills/jenga-permission-level/SKILL.md" <<'SKILL'
---
name: jenga-permission-level
description: Fixture for the jenga-permission-level permanent exception.
---

# jenga-permission-level
SKILL

  # "index" is deliberately NOT included in the allow-list fixture below: it has no
  # SKILL.md in the real repo (it is not a skill at all -- docs/skill-authoring.md), so
  # it never appears as a genuine allow-listed identifier. Only NEVER_TWINNED's set
  # membership is what this file's cross-check test cares about for "index".

  cat > "$PKG_ROOT/lib/skill-allow-list.json" <<'JSON'
{
  "generated_at": "2026-01-01T00:00:00.000Z",
  "skill_count": 4,
  "skills": ["alpha", "beta", "jenga", "jenga-permission-level"]
}
JSON
}

run_loader() {
  node "$LOADER" "$PROJECT_ROOT" "$PKG_ROOT" 2>"$BATS_TEST_TMPDIR/stderr.log"
}

@test "zero 'not found for allow-listed skill' warnings against a twin-only tree" {
  run run_loader
  [ "$status" -eq 0 ]
  local stderr_content
  stderr_content=$(cat "$BATS_TEST_TMPDIR/stderr.log")
  assert_not_contains "$stderr_content" "not found for allow-listed skill"
}

@test "catalog entry count matches the allow-list identifier count exactly (no silent drops)" {
  run run_loader
  [ "$status" -eq 0 ]
  local count
  count=$(node -e 'console.log(JSON.parse(process.argv[1]).length)' "$output")
  [ "$count" -eq 4 ]
}

@test "catalog entries resolve via the twin directory for normal skills, bare directory for exceptions" {
  run run_loader
  [ "$status" -eq 0 ]
  local names
  names=$(node -e '
    JSON.parse(process.argv[1]).forEach(e => console.log(e.name));
  ' "$output")
  # Normal skills resolve to their j-<name> twin directory name.
  case "$names" in *j-alpha*) : ;; *) return 1 ;; esac
  case "$names" in *j-beta*) : ;; *) return 1 ;; esac
  # The two exceptions present in this fixture resolve to their bare directory name,
  # NOT a j-jenga / j-jenga-permission-level twin (which does not exist).
  case "$names" in *j-jenga*) return 1 ;; esac
  case "$names" in *jenga*) : ;; *) return 1 ;; esac
  case "$names" in *jenga-permission-level*) : ;; *) return 1 ;; esac
}

@test "alpha's description, keywords, and examples are read from its twin SKILL.md" {
  run run_loader
  [ "$status" -eq 0 ]
  local alpha_entry
  alpha_entry=$(node -e '
    const e = JSON.parse(process.argv[1]).find(x => x.name === "j-alpha");
    console.log(JSON.stringify(e));
  ' "$output")
  assert_contains "$alpha_entry" "Fixture skill alpha"
  assert_contains "$alpha_entry" "alpha thing"
  assert_contains "$alpha_entry" "do the alpha thing"
}

# --------------------------------------------------------------
# NEVER_TWINNED cross-check against the repo's surviving permanent-exception list, per
# this task's second acceptance criterion. Extracted textually from both source files
# rather than hand-copied, so a future edit to either list makes this test fail instead
# of silently drifting.
#
# Cross-check partner, and why it changed (E42_S07_T01, 2026-09-20)
# -----------------------------------------------------------------
# This test originally compared the loader's set against the twin-divergence audit
# script's own NEVER_TWINNED tuple. That script was deleted when E42_S07 retired the
# twin-parity gate -- its entire bare/twin-pair input population went to zero
# permanently when E50_S15_T04 deleted the bare-name skill directories. The cross-check
# itself is still worth having (the loader's exception set must never drift unnoticed),
# so it is repointed rather than deleted, at scripts/repoint-skill-refs.sh's
# REPOINT_SKILL_REFS_EXCEPTIONS -- a surviving list that file labels its "Single named
# source", and that scripts/delete-bare-skill-dirs.sh already documents itself as
# mirroring. Same three names, same textual-extraction discipline, one fewer deleted
# dependency.
# --------------------------------------------------------------

@test "NEVER_TWINNED in load-nl-catalog.js matches repoint-skill-refs.sh's exception list" {
  local loader_set exceptions_set
  loader_set=$(grep -o 'NEVER_TWINNED = new Set(\[[^]]*\])' "$LOADER" \
    | node -e 'const m=require("fs").readFileSync(0,"utf8").match(/\[(.*)\]/)[1]; console.log(eval("["+m+"]").sort().join(","))')
  exceptions_set=$(grep -o 'REPOINT_SKILL_REFS_EXCEPTIONS=([^)]*)' "$REPO_ROOT/scripts/repoint-skill-refs.sh" \
    | node -e '
      const text = require("fs").readFileSync(0,"utf8");
      const m = text.match(/\(([^)]*)\)/s);
      const items = m[1].trim().split(/\s+/).filter(Boolean);
      console.log(items.sort().join(","));
    ')
  # Both extractions must actually find something. Without this, a rename on either
  # side would empty both captures and the equality below would pass vacuously --
  # exactly the silent drift this test exists to prevent.
  [ -n "$loader_set" ]
  [ -n "$exceptions_set" ]
  [ "$loader_set" = "$exceptions_set" ]
}
