#!/usr/bin/env bats
#
# Coverage for scripts/audit-twin-divergence.sh (E50_S19_T01).
#
# What this suite has to prove
# ----------------------------
# The audit's whole job is to tell two kinds of twin difference apart:
#
#   EXPECTED   — produced deliberately by scripts/generate-j-alias.sh (the
#                skills/<name>/ -> skills/j-<name>/ path rewrite, the frontmatter
#                name:/description: rewrite, the appended keywords/examples, the
#                injected alias note).
#   UNEXPECTED — anything else, i.e. a candidate content gap.
#
# Getting that wrong in the fail-open direction is the expensive failure: a genuine
# gap waved through as "probably just a path rewrite" is exactly how E22_S09_T07's
# stage-id fix sat unreachable in the public mirror while the board read Merged. So
# every test below pairs a positive with a negative — the audit must stay silent on a
# difference the generator explains AND must speak up on one it does not.
#
# Fixture strategy
# ----------------
# The "expected twin" fixtures are produced by running the REAL
# scripts/generate-j-alias.sh in a sandbox, rather than by hand-writing what its
# output is believed to be. That is deliberate: the audit is specified as a port of
# that generator, so agreement with the generator's actual output IS the contract, and
# a hand-written fixture would only ever pin one author's reading of it. To stop that
# becoming circular, the expected-difference tests additionally assert the concrete
# property that makes the fixture non-trivial — that the generated twin really does
# differ from its source, on the path rewrite specifically — so a generator that
# emitted a byte-identical copy could not make these tests pass vacuously.
#
# Every test runs against a throwaway sandbox under $BATS_TEST_TMPDIR, never against
# this repository's own skills/ contents.

# Shared assertion helpers. A bare `[[ ... ]]` does NOT fail a bats test unless it is
# the body's final statement -- `[[` is a shell keyword and never fires bats' ERR trap
# -- so every string assertion below goes through a helper function, which is an
# ordinary simple command and does abort on failure. See the header of
# tests/helpers/assertions.bash (E50_S07_T08).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  PROJECT_DIR="$SANDBOX/project"

  mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/lib" "$PROJECT_DIR/skills"
  cp "$REPO_ROOT/scripts/audit-twin-divergence.sh" "$PROJECT_DIR/scripts/"
  cp "$REPO_ROOT/scripts/generate-j-alias.sh" "$PROJECT_DIR/scripts/"
  cp "$REPO_ROOT/lib/resolve-project-dir.sh" "$PROJECT_DIR/lib/"

  write_demo_source
}

# A synthetic source skill carrying the two things that matter: a self-referential
# skills/demo/ path (so transform 2 has something to do) and a body function whose
# later removal stands in for a real content gap.
write_demo_source() {
  mkdir -p "$PROJECT_DIR/skills/demo/scripts"
  cat > "$PROJECT_DIR/skills/demo/SKILL.md" <<'SKILL_EOF'
---
name: j.demo
description: Fixture skill for audit-twin-divergence.sh coverage.
output_types: text
keywords:
  - demo
examples:
  - "run the demo"
---

# Demo

## Usage

Run the helper:

```bash
skills/demo/scripts/run.sh
```

Falls back to `.claude/skills/demo/scripts/run.sh` on a mirrored install.
SKILL_EOF

  cat > "$PROJECT_DIR/skills/demo/scripts/run.sh" <<'RUN_EOF'
#!/usr/bin/env bash
# skills/demo/scripts/run.sh — fixture helper.
set -euo pipefail

parse_stage_id_from_text() {
  printf 'stage-id: %s\n' "$1"
}

parse_stage_id_from_text "$@"
RUN_EOF
}

run_generator() {
  JENGA_PROJECT_DIR="$PROJECT_DIR" bash "$PROJECT_DIR/scripts/generate-j-alias.sh" "$1"
}

run_audit() {
  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$PROJECT_DIR"
}

# A stand-in for the real skills/init/ <-> skills/j-init/ pair: same shape (hand-written
# twin description and alias note, shared body below the first '## ' heading, a shared
# scripts/ tree), small enough to reason about.
make_init_pair() {
  mkdir -p "$PROJECT_DIR/skills/init/scripts" "$PROJECT_DIR/skills/j-init/scripts"

  cat > "$PROJECT_DIR/skills/init/SKILL.md" <<'SRC_EOF'
---
name: j.init
description: Initialize a new project.
output_types: text
keywords:
  - init
---

# Init — Project Setup

## Instructions

Run the detector:

```bash
skills/init/scripts/init.sh
```
SRC_EOF

  cat > "$PROJECT_DIR/skills/j-init/SKILL.md" <<'TWIN_EOF'
---
name: j.j-init
description: Polyfill alias of the init skill, hand-written rather than generated.
output_types: text
keywords:
  - init
  - j-init
  - polyfill
---

# J-Init — Project Setup (polyfill alias of Init)

A hand-written alias note that deliberately does not match the generator's own
wording, because the generator refuses this pair (L97-100).

## Instructions

Run the detector:

```bash
skills/j-init/scripts/init.sh
```
TWIN_EOF

  cat > "$PROJECT_DIR/skills/init/scripts/init.sh" <<'SRC_SH_EOF'
#!/usr/bin/env bash
# skills/init/scripts/init.sh — fixture helper.
detect_state() {
  echo "empty"
}
detect_state
SRC_SH_EOF

  sed 's|skills/init/|skills/j-init/|g' "$PROJECT_DIR/skills/init/scripts/init.sh" \
    > "$PROJECT_DIR/skills/j-init/scripts/init.sh"
}

# -----------------------------------------------------------------------------
# Expected difference: the generator's own transforms must NOT be reported.
# -----------------------------------------------------------------------------

@test "a difference that is only the skills/<name>/ -> skills/j-<name>/ path rewrite is classified as EXPECTED" {
  run_generator demo

  # Guard against a vacuous pass: the twin must genuinely differ from its source on
  # the path rewrite, otherwise "the audit reported nothing" would prove nothing.
  run cat "$PROJECT_DIR/skills/j-demo/scripts/run.sh"
  [ "$status" -eq 0 ]
  assert_output_contains "skills/j-demo/scripts/run.sh"
  assert_output_not_contains "skills/demo/scripts/run.sh"

  # The mirrored-install fallback path falls out of the same substring replace.
  run cat "$PROJECT_DIR/skills/j-demo/SKILL.md"
  [ "$status" -eq 0 ]
  assert_output_contains ".claude/skills/j-demo/scripts/run.sh"

  run_audit
  [ "$status" -eq 0 ]
  assert_output_contains "no unexpected divergence"
  assert_output_not_contains "CONTENT_DRIFT"
  assert_output_not_contains "SKILL_DRIFT"
}

@test "the transform-3 name: tolerance accepts both j.j-<name> and the canonical j.<name>" {
  run_generator demo

  # The generator emits j.j-demo (L262); E50_S10's settled contract keeps the
  # canonical twin at j.demo and E50_S15 lands that rewrite. The audit must not force
  # either value, so rewriting to the canonical form must stay silent.
  run grep -c '^name: j.j-demo$' "$PROJECT_DIR/skills/j-demo/SKILL.md"
  [ "$status" -eq 0 ]
  assert_output_contains "1"

  sed -i.bak 's/^name: j\.j-demo$/name: j.demo/' "$PROJECT_DIR/skills/j-demo/SKILL.md"
  rm -f "$PROJECT_DIR/skills/j-demo/SKILL.md.bak"

  run_audit
  [ "$status" -eq 0 ]
  assert_output_contains "no unexpected divergence"
}

@test "a name: value that is NEITHER accepted form is still reported (the tolerance is narrow)" {
  run_generator demo
  sed -i.bak 's/^name: j\.j-demo$/name: j.something-else/' "$PROJECT_DIR/skills/j-demo/SKILL.md"
  rm -f "$PROJECT_DIR/skills/j-demo/SKILL.md.bak"

  run_audit
  [ "$status" -eq 1 ]
  assert_output_contains "SKILL_DRIFT"
  assert_output_contains "skills/j-demo/SKILL.md"
}

# -----------------------------------------------------------------------------
# Unexpected difference: a genuine content gap must be reported.
# -----------------------------------------------------------------------------

@test "a genuine content gap in a twin script is classified as UNEXPECTED" {
  run_generator demo

  # Reproduces the E22_S09_T07 shape: a helper present in the source that never
  # reached the twin. Everything else about the twin stays correct, so the audit
  # cannot find this by any signal other than the content comparison itself.
  grep -v 'parse_stage_id_from_text() {' "$PROJECT_DIR/skills/j-demo/scripts/run.sh" \
    > "$PROJECT_DIR/skills/j-demo/scripts/run.sh.tmp"
  mv "$PROJECT_DIR/skills/j-demo/scripts/run.sh.tmp" "$PROJECT_DIR/skills/j-demo/scripts/run.sh"

  run_audit
  [ "$status" -eq 1 ]
  assert_output_contains "CONTENT_DRIFT"
  assert_output_contains "skills/j-demo/scripts/run.sh"
  assert_output_contains "1 unexpected divergence"
}

@test "a frontmatter field present in the source and absent from the twin is reported" {
  run_generator demo

  # This is the real j-reconcile / j-status / j-uncharted shape: `output_types: text`
  # was added to the bare source long after the twin was last generated.
  sed -i.bak '/^output_types: text$/d' "$PROJECT_DIR/skills/j-demo/SKILL.md"
  rm -f "$PROJECT_DIR/skills/j-demo/SKILL.md.bak"

  run_audit
  [ "$status" -eq 1 ]
  assert_output_contains "SKILL_DRIFT"
  assert_output_contains "skills/j-demo/SKILL.md"
}

@test "a file present in the source but missing from the twin is reported as MISSING_FILE" {
  run_generator demo
  rm "$PROJECT_DIR/skills/j-demo/scripts/run.sh"

  run_audit
  [ "$status" -eq 1 ]
  assert_output_contains "MISSING_FILE"
  assert_output_contains "skills/j-demo/scripts/run.sh"
}

@test "a twin that still carries a bare skills/<name>/ self-reference is reported" {
  run_generator demo

  # The inverse of the path-rewrite test: reverting transform 2 reintroduces exactly
  # the bare-name path reference E50_S11 exists to remove, and must not be silently
  # accepted just because the file "looks like" a path-rewrite difference.
  sed -i.bak 's|skills/j-demo/scripts/run.sh|skills/demo/scripts/run.sh|' \
    "$PROJECT_DIR/skills/j-demo/scripts/run.sh"
  rm -f "$PROJECT_DIR/skills/j-demo/scripts/run.sh.bak"

  run_audit
  [ "$status" -eq 1 ]
  assert_output_contains "CONTENT_DRIFT"
  assert_output_contains "skills/j-demo/scripts/run.sh"
}

# -----------------------------------------------------------------------------
# Exit-code contract.
# -----------------------------------------------------------------------------

@test "exit-code contract: 0 when clean, 1 when a divergence remains, 2 on a bad root" {
  run_generator demo

  run_audit
  [ "$status" -eq 0 ]

  rm "$PROJECT_DIR/skills/j-demo/scripts/run.sh"
  run_audit
  [ "$status" -eq 1 ]

  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$SANDBOX/does-not-exist"
  [ "$status" -eq 2 ]
  assert_output_contains "is not a directory"

  # A directory that exists but has no skills/ tree is an environment error, not a
  # clean audit of zero pairs -- silently passing there would let a mis-pointed
  # mirror-shaped-tree run in E50_S19_T03 report success having compared nothing.
  mkdir -p "$SANDBOX/empty"
  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$SANDBOX/empty"
  [ "$status" -eq 2 ]
  assert_output_contains "no skills/ directory"
}

@test "--min-pairs turns a vacuous clean run into a failure (the fail-open E50_S19_T03 found)" {
  run_generator demo

  # A tree with pairs in it satisfies the floor and still exits 0.
  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$PROJECT_DIR" --min-pairs 1
  [ "$status" -eq 0 ]

  # ...and asking for more pairs than exist is an error, not a pass.
  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$PROJECT_DIR" --min-pairs 2
  [ "$status" -eq 2 ]
  assert_output_contains "only 1 twinned pair(s) were audited"

  # The case that motivated the flag: a public-mirror-shaped tree, where
  # .publicignore has stripped every bare-name source, audits ZERO pairs. Without a
  # floor that is a clean exit 0 which proves nothing at all.
  rm -rf "$PROJECT_DIR/skills/demo"
  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "audited 0 twinned pair(s)"

  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$PROJECT_DIR" --min-pairs 1
  [ "$status" -eq 2 ]
  assert_output_contains "not a pass"
}

@test "--min-pairs rejects a non-numeric or missing argument" {
  run_generator demo

  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$PROJECT_DIR" --min-pairs abc
  [ "$status" -eq 2 ]
  assert_output_contains "expects a non-negative integer"

  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$PROJECT_DIR" --min-pairs
  [ "$status" -eq 2 ]
  assert_output_contains "requires a number"
}

@test "the repo root is taken from the argument, not hardcoded (E50_S19_T03 depends on this)" {
  run_generator demo

  # Run from an unrelated cwd against an explicitly-passed root. If the root were
  # hardcoded or derived from cwd, this would audit the wrong tree.
  cd "$BATS_TEST_TMPDIR"
  run bash "$PROJECT_DIR/scripts/audit-twin-divergence.sh" "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "audited 1 twinned pair(s)"
  assert_output_contains "$PROJECT_DIR/skills"
}

# -----------------------------------------------------------------------------
# Scope: the directories that have no twin, and the hand-maintained init pair.
# -----------------------------------------------------------------------------

@test "the three no-twin directories and an orphan j- directory are skipped without erroring" {
  run_generator demo

  # jenga / jenga-permission-level are hard-excluded from twin generation (E50_S06_T01);
  # index is not a skill at all (no SKILL.md); j-orphan stands in for skills/j-playbook/,
  # already at its sole canonical name with no bare source to compare against.
  mkdir -p "$PROJECT_DIR/skills/jenga" \
           "$PROJECT_DIR/skills/jenga-permission-level" \
           "$PROJECT_DIR/skills/index" \
           "$PROJECT_DIR/skills/j-orphan"
  echo "not a skill" > "$PROJECT_DIR/skills/index/README.md"
  echo "orphan" > "$PROJECT_DIR/skills/j-orphan/SKILL.md"

  run_audit
  [ "$status" -eq 0 ]
  assert_output_contains "skipped skills/jenga/"
  assert_output_contains "skipped skills/jenga-permission-level/"
  assert_output_contains "skipped skills/index/"
  assert_output_contains "skipped skills/j-orphan/"
  assert_output_contains "audited 1 twinned pair(s)"
}

@test "the hand-maintained init pair tolerates its hand-written SKILL.md preamble and description" {
  make_init_pair

  run_audit
  [ "$status" -eq 0 ]
  assert_output_contains "no unexpected divergence"
}

@test "the hand-maintained init pair is still audited for content gaps outside SKILL.md" {
  make_init_pair

  # Excluding this pair outright would create a blind spot exactly where nothing else
  # is watching: j-init/scripts/ ships to the public mirror like every other twin.
  grep -v 'detect_state()' "$PROJECT_DIR/skills/j-init/scripts/init.sh" \
    > "$PROJECT_DIR/skills/j-init/scripts/init.sh.tmp"
  mv "$PROJECT_DIR/skills/j-init/scripts/init.sh.tmp" "$PROJECT_DIR/skills/j-init/scripts/init.sh"

  run_audit
  [ "$status" -eq 1 ]
  assert_output_contains "CONTENT_DRIFT"
  assert_output_contains "skills/j-init/scripts/init.sh"
}

@test "the hand-maintained tolerance reports PREAMBLE_UNCOMPARED rather than silently skipping new source preamble text" {
  make_init_pair

  # The tolerance does not compare the region between H1 and the first '## '. If the
  # source ever puts content there, that must surface as something to review by hand
  # -- an uncompared region nobody is told about is the same fail-open shape this
  # whole script exists to close.
  sed -i.bak 's|^# Init — Project Setup$|# Init — Project Setup\n\nNew preamble prose that the twin never received.|' \
    "$PROJECT_DIR/skills/init/SKILL.md"
  rm -f "$PROJECT_DIR/skills/init/SKILL.md.bak"

  run_audit
  [ "$status" -eq 1 ]
  assert_output_contains "PREAMBLE_UNCOMPARED"
}
