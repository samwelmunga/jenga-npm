#!/usr/bin/env bats
#
# Coverage for the E50_S19_T04 parity gate: package.json's `gate:twin-parity`
# script, and proof (by fault injection) that it actually detects something.
#
# Why this is a separate file from tests/audit-twin-divergence.bats
# -------------------------------------------------------------------------
# tests/audit-twin-divergence.bats covers the underlying script's
# classification logic in isolation (E50_S19_T01). This file covers the GATE
# as a thing a developer or CI step would actually invoke: is it wired to a
# reachable entry point, and does it fail/pass on cue. `docs/
# public-mirror-content-parity.md` instructed "Always pass --min-pairs when
# using this script as a gate" with nothing actually invoking it — that gap is
# `project/rapports/problems/E50_S19-parity-gate-is-manual-only.md`, Finding 1.
# This file is the gate's own test coverage, not a duplicate of T01's.
#
# Deliberately does NOT assert `npm run gate:twin-parity` exits 0 against the
# REAL repo. As of E50_S19_T04, a real run of scripts/audit-twin-divergence.sh
# against this repo reports 61 pre-existing divergences that are unrelated to
# anything this task changes — see project/rapports/problems/
# E50_S19_T04-audit-classification-stale-post-contract-flip.md for the root
# cause (a contract-direction reversal landed by E50_S11/E50_S12/E50_S14,
# concurrently with this task, that the audit's classification engine does
# not yet know about). Asserting a clean real-repo exit code here would couple
# this suite's pass/fail to that separate, out-of-scope fix landing — exactly
# the kind of real-tree-state dependency the original rapport flagged as a
# design risk worth deciding deliberately rather than backing into. Every test
# below proves the GATE MECHANISM is correct using a synthetic sandbox
# instead, the same approach tests/audit-twin-divergence.bats already
# established for the underlying script.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# -----------------------------------------------------------------------------
# Wiring: the gate is a real, reachable entry point (AC: "reachable from the
# project's normal test entry point").
# -----------------------------------------------------------------------------

@test "package.json wires gate:twin-parity to the real audit script with --min-pairs against the real repo" {
  run node -e "const p = require('$REPO_ROOT/package.json'); process.stdout.write(p.scripts['gate:twin-parity'] || '')"
  [ "$status" -eq 0 ]
  assert_output_contains "scripts/audit-twin-divergence.sh"
  assert_output_contains "--min-pairs"
}

@test "the gate is deliberately NOT folded into the default npm test run (see this file's header)" {
  run node -e "const p = require('$REPO_ROOT/package.json'); process.stdout.write(p.scripts['test'] || '')"
  [ "$status" -eq 0 ]
  assert_output_not_contains "audit-twin-divergence"
}

@test "npm run gate:twin-parity is live and actually audits the real repo (not just present in package.json text)" {
  # Runs the real gate. Asserted on the identifying "audited N pair(s)" line,
  # never on the exit code or "no unexpected divergence" -- see this file's
  # header for why a clean real-repo run is out of scope for this suite.
  #
  # The count dropped from 40 to 0 permanently on E50_S15_T04: that task
  # deleted every bare skills/<name>/ source, so there is no longer a bare
  # source for any twin to diverge from anywhere in this repo, ever again.
  # 0 is therefore the correct, permanent real-repo value now -- not a stale
  # fixture -- and this assertion still proves the gate is live: it reads a
  # real, freshly-computed count off the real tree, it just happens to be
  # zero by design. package.json's own `--min-pairs 40` is now permanently
  # unsatisfiable for the same reason and was flagged for a scrum-master
  # decision on the gate's future (retire vs. repurpose) rather than changed
  # here -- see the E50_S15_T05 crucial_escalation rapport.
  cd "$REPO_ROOT"
  run npm run --silent gate:twin-parity
  assert_output_contains "audited 0 twinned pair(s) under"
}

# -----------------------------------------------------------------------------
# Fault injection (AC: "introduce a genuine divergence, show the gate fails;
# remove it, show the gate passes" AND "injecting a gitignored artifact does
# not trip the gate" -- both proven in one flow below so the two behaviors are
# shown to be distinguishable, not just individually true).
# -----------------------------------------------------------------------------

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  PROJECT_DIR="$SANDBOX/project"

  mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/lib" "$PROJECT_DIR/skills"
  cp "$REPO_ROOT/scripts/audit-twin-divergence.sh" "$PROJECT_DIR/scripts/"
  cp "$REPO_ROOT/lib/resolve-project-dir.sh" "$PROJECT_DIR/lib/"

  ( cd "$PROJECT_DIR" && git init -q && printf '**/__pycache__\n' > .gitignore )

  write_clean_pair
}

# A zero-divergence fixture that matches the audit's CURRENT classification
# engine exactly -- same shape as tests/audit-twin-divergence.bats's own
# write_demo_source()/make_demo_twin() (E50_S19_T01), renamed to "gatefix" to
# avoid any collision with that file's sandbox. This is deliberately NOT a
# byte-identical copy: the engine still reconstructs the twin's SKILL.md via
# the retired generator's transforms (path rewrite, frontmatter name:/
# description: rewrite, appended keywords/examples, injected alias note; see
# scripts/audit-twin-divergence.sh's own header), so a naively byte-identical
# pair trips SKILL_DRIFT on the description field alone -- confirmed while
# writing this file, and itself more evidence for the classification-staleness
# rapport this task files (project/rapports/problems/
# E50_S19_T04-audit-classification-stale-post-contract-flip.md). Fault
# injection below happens entirely in scripts/run.sh, which no transform other
# than the path rewrite touches, so it stays independent of that staleness.
write_clean_pair() {
  mkdir -p "$PROJECT_DIR/skills/gatefix/scripts" "$PROJECT_DIR/skills/j-gatefix/scripts"

  cat > "$PROJECT_DIR/skills/gatefix/SKILL.md" <<'EOF'
---
name: j.gatefix
description: Fixture skill for gate-twin-parity.bats coverage.
keywords:
  - gatefix
---

# Gatefix

Run `skills/gatefix/scripts/run.sh`.
EOF

  cat > "$PROJECT_DIR/skills/j-gatefix/SKILL.md" <<'EOF'
---
name: j.j-gatefix
description: Polyfill alias of the gatefix skill under a collision-safe directory name. Identical behavior to /gatefix — Fixture skill for gate-twin-parity.bats coverage. Use when the bare /gatefix form is shadowed by another tool's own built-in command of the same name.
keywords:
  - gatefix
  - j-gatefix
  - polyfill
---

# Gatefix

This skill is a literal-directory-name duplicate of `skills/gatefix/`. It exists so that `/j-gatefix` (and `j.j-gatefix`) give a guaranteed-unshadowed way to reach the same flow as `/gatefix`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/gatefix` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh gatefix` from `skills/gatefix/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

Run `skills/j-gatefix/scripts/run.sh`.
EOF

  echo "echo hello" > "$PROJECT_DIR/skills/gatefix/scripts/run.sh"
  cp "$PROJECT_DIR/skills/gatefix/scripts/run.sh" "$PROJECT_DIR/skills/j-gatefix/scripts/run.sh"
}

run_gate() {
  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$PROJECT_DIR" --min-pairs 1
}

@test "gate fault injection: clean pair passes, a genuine divergence trips it, removing the divergence clears it" {
  # 1. Clean baseline: the gate passes.
  run_gate
  [ "$status" -eq 0 ]
  assert_output_contains "no unexpected divergence"

  # 2. Inject a genuine divergence: a file present in the source, never
  #    reaching the twin -- the exact E22_S09_T07 shape this whole audit
  #    exists to catch.
  echo "genuinely missing from the twin" > "$PROJECT_DIR/skills/gatefix/scripts/new-helper.sh"
  run_gate
  [ "$status" -eq 1 ]
  assert_output_contains "MISSING_FILE"
  assert_output_contains "skills/j-gatefix/scripts/new-helper.sh"

  # 3. Remove it: the gate clears again -- proves the gate reacts to the
  #    divergence itself, not to some other side effect of step 2.
  rm "$PROJECT_DIR/skills/gatefix/scripts/new-helper.sh"
  run_gate
  [ "$status" -eq 0 ]
  assert_output_contains "no unexpected divergence"
}

@test "gate distinguishability: a gitignored artifact does not trip the gate, but a genuine divergence still does (E50_S19_T04, Defect 1 + Defect 2 together)" {
  # Baseline: clean.
  run_gate
  [ "$status" -eq 0 ]

  # Inject ONLY a gitignored build artifact under the source -- the
  # skills/train/__pycache__/*.pyc shape. The gate must stay clean.
  mkdir -p "$PROJECT_DIR/skills/gatefix/__pycache__"
  echo "compiled bytecode" > "$PROJECT_DIR/skills/gatefix/__pycache__/gatefix.cpython-312.pyc"
  run_gate
  [ "$status" -eq 0 ]
  assert_output_contains "no unexpected divergence"
  assert_output_not_contains "__pycache__"

  # With the gitignored artifact still present, ALSO inject a genuine
  # divergence. The gate must now fail, and must fail on the genuine
  # divergence specifically -- proving the gitignored artifact never
  # contributed to (or masked) the gate's verdict either way.
  echo "genuinely missing from the twin" > "$PROJECT_DIR/skills/gatefix/scripts/new-helper.sh"
  run_gate
  [ "$status" -eq 1 ]
  assert_output_contains "MISSING_FILE"
  assert_output_contains "skills/j-gatefix/scripts/new-helper.sh"
  assert_output_not_contains "__pycache__"
}
