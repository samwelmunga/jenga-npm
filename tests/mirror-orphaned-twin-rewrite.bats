#!/usr/bin/env bats
#
# Regression coverage for mirror.sh's rewrite_orphaned_twin_names (E50_S07_T07).
#
# Why this file exists
# --------------------
# E28_S11 added `rewrite_orphaned_twin_names` to
# skills/mirror-public/scripts/mirror.sh. Every skill has a generated
# `skills/j-<name>/` twin carrying a *secondary* identifier, distinct from the
# canonical `skills/<name>/` directory's *primary* one. E28_S09/E28_S10
# blocklist the canonical directory for a large set of skills, so only the twin
# ships publicly for those -- which leaves the primary identifier resolving to
# nothing on the public package. The function's job is to spot that during a
# mirror run and rewrite the shipped twin's frontmatter to the primary form.
#
# It did so by exact string equality against a hardcoded `name: j:j-<name>`.
# E50_S07_T01 then moved every twin to `name: j.j-<name>`, so the gate could no
# longer be satisfied by any twin: the function `continue`d on every input, on
# every root, on every run. Dead code -- silently, and fail-open. The E28_S11
# regression was live again for 34 skills. Full analysis:
#   project/rapports/problems/E50_S07_T06-mirror-orphaned-twin-rewrite-dead-code.md
#
# The trap the fix had to avoid was the same one E50_S07_T02 documented in
# mcp/router/prefix.js: repairing *only* the gate would have turned a silent
# no-op into an active republication of the original outage, because the awk
# replacement still emitted `name: j:<name>` -- the legacy form Copilot rejects
# outright, and the exact identifier this story exists to eliminate. So both
# halves are pinned here: `rewrites an orphaned twin ... j. identifier` is the
# red-state test for the gate, and `never emits the legacy j: separator` is the
# one that fails under a gate-only fix.
#
# Widen, do not swap
# ------------------
# Per E50 Decision 2 the legacy `j:` form is a *permanent* alias that never
# stops resolving, so a twin mirrored from an older private checkout can still
# carry `name: j:j-<name>`. The gate accepts both separators and always *emits*
# the canonical `j.`. This matches lib/generate-skill-allow-list.js's `/^j[.:]/i`
# (E50_S07_T01) and mcp/router/prefix.js's SEPARATORS class (E50_S07_T02).
# `accepts the legacy j: separator on the read side` is what pins that down: it
# fails under a naive `:` -> `.` swap, which would only relocate the hole.
#
# Design
# ------
# mirror.sh cannot be sourced -- see the header of
# tests/helpers/mirror-orphaned-twin-rewrite.sh, which explains how the real
# function is extracted from the real script and run against a sandbox tree
# under $BATS_TEST_TMPDIR. No test here touches this repository's own skills/.

# Shared assertion helpers. A bare `[[ ... ]]` does NOT fail a bats test unless
# it is the body's final statement -- `[[` is a shell keyword and never fires
# bats' ERR trap -- so every assertion below goes through a helper function,
# which is an ordinary simple command and does abort on failure. See the header
# of tests/helpers/assertions.bash (E50_S07_T08).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HARNESS="$REPO_ROOT/tests/helpers/mirror-orphaned-twin-rewrite.sh"
MIRROR_SH="$REPO_ROOT/skills/mirror-public/scripts/mirror.sh"

# Writes a minimal but realistically-shaped SKILL.md at $1 with `name:` = $2.
write_skill_md() {
  local path="$1" name="$2"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<SKILL_EOF
---
name: $name
description: Sandbox fixture for the orphaned-twin rewrite regression suite.
---
# Fixture

Body content is irrelevant to the function under test, which only rewrites the
frontmatter \`name:\` line.
SKILL_EOF
}

# Builds one shipped-tree skills root under $1 covering every branch of the
# function: an orphaned twin on each separator, a paired twin, and a twin with
# an unrecognized name shape.
populate_skills_root() {
  local root="$1"

  # Canonical blocklisted (no sibling dir) + current canonical separator.
  # This is the case that produced 34 broken skills.
  write_skill_md "$root/j-orphan/SKILL.md" "j.j-orphan"

  # Canonical blocklisted + legacy separator, e.g. a twin mirrored from an
  # older private checkout. Must still be rewritten, and to `j.`.
  write_skill_md "$root/j-legacy/SKILL.md" "j:j-legacy"

  # Both canonical and twin ship: the two identifiers must stay distinct.
  write_skill_md "$root/paired/SKILL.md" "j.paired"
  write_skill_md "$root/j-paired/SKILL.md" "j.j-paired"

  # Unrecognized frontmatter shape: leave it alone rather than guessing.
  write_skill_md "$root/j-weird/SKILL.md" "something-else-entirely"
}

setup() {
  WT="$BATS_TEST_TMPDIR/worktree"
  populate_skills_root "$WT/skills"
  populate_skills_root "$WT/.claude/skills"
  populate_skills_root "$WT/.agents/skills"
}

run_rewrite() {
  run bash "$HARNESS" "$MIRROR_SH" "$WT"
}

name_of() {
  grep -m1 '^name:' "$1"
}

# The substring assertions used below (assert_output_contains /
# assert_output_not_contains) were originally defined inline here, by this
# suite, after three of its own assertions were found silently inert. E50_S07_T08
# measured the same class across four more files and extracted them to
# tests/helpers/assertions.bash, loaded at the top of this file, so the whole
# suite shares one convention and one liveness-mutation hook. The rationale is
# preserved in that file's header.

# -----------------------------------------------------------------------------
# The red-state test: fails against the dead-code gate, passes after the fix.
# -----------------------------------------------------------------------------

@test "rewrites an orphaned twin to its primary j. identifier" {
  run_rewrite
  [ "$status" -eq 0 ]
  [ "$(name_of "$WT/skills/j-orphan/SKILL.md")" = "name: j.orphan" ]
}

# -----------------------------------------------------------------------------
# The gate-only-fix test. Fails against a fix that repairs the gate while
# leaving the awk `new` value on the legacy separator -- that is what it is here
# for. It also fails in the pre-fix red state, though not for the "nothing was
# written" reason one might expect: the pre-fix gate matches the j-legacy
# fixture exactly (it is still on `name: j:j-legacy`) and rewrites it to
# `name: j:legacy`. So the pre-fix code is not a uniform no-op across the real
# shipped tree -- it is a no-op on roots already migrated to `j.` and an active
# emitter of the Copilot-invalid `j:` form on roots still carrying the legacy
# separator, which is what .claude/skills/ and .agents/skills/ do until
# E50_S07_T05 resyncs them.
# -----------------------------------------------------------------------------

@test "never emits the legacy j: separator" {
  run_rewrite
  [ "$status" -eq 0 ]
  run grep -rn '^name: j:' "$WT"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# Widen-don't-swap: fails under a naive : -> . swap of the gate.
# -----------------------------------------------------------------------------

@test "accepts the legacy j: separator on the read side and still emits j." {
  run_rewrite
  [ "$status" -eq 0 ]
  [ "$(name_of "$WT/skills/j-legacy/SKILL.md")" = "name: j.legacy" ]
}

# -----------------------------------------------------------------------------
# Branches that must NOT be rewritten.
# -----------------------------------------------------------------------------

@test "leaves a twin untouched when its canonical directory also ships" {
  run_rewrite
  [ "$status" -eq 0 ]
  [ "$(name_of "$WT/skills/j-paired/SKILL.md")" = "name: j.j-paired" ]
  [ "$(name_of "$WT/skills/paired/SKILL.md")" = "name: j.paired" ]
}

@test "leaves an unrecognized frontmatter name shape untouched" {
  run_rewrite
  [ "$status" -eq 0 ]
  [ "$(name_of "$WT/skills/j-weird/SKILL.md")" = "name: something-else-entirely" ]
}

@test "rewrites only the frontmatter name line, leaving the rest of the file intact" {
  run_rewrite
  [ "$status" -eq 0 ]
  run grep -c '^description: Sandbox fixture' "$WT/skills/j-orphan/SKILL.md"
  [ "$output" = "1" ]
  run grep -c '^# Fixture' "$WT/skills/j-orphan/SKILL.md"
  [ "$output" = "1" ]
}

# -----------------------------------------------------------------------------
# Applied identically across all three shipped-tree roots.
# -----------------------------------------------------------------------------

@test "applies across skills/, .claude/skills/ and .agents/skills/" {
  run_rewrite
  [ "$status" -eq 0 ]
  [ "$(name_of "$WT/.claude/skills/j-orphan/SKILL.md")" = "name: j.orphan" ]
  [ "$(name_of "$WT/.agents/skills/j-orphan/SKILL.md")" = "name: j.orphan" ]
  [ "$(name_of "$WT/.claude/skills/j-legacy/SKILL.md")" = "name: j.legacy" ]
  [ "$(name_of "$WT/.agents/skills/j-legacy/SKILL.md")" = "name: j.legacy" ]
}

@test "a missing shipped-tree root is a harmless logged no-op" {
  rm -rf "$WT/.agents"
  run_rewrite
  [ "$status" -eq 0 ]
  assert_output_contains ".agents/skills does not exist -- skipping"
  [ "$(name_of "$WT/skills/j-orphan/SKILL.md")" = "name: j.orphan" ]
}

# -----------------------------------------------------------------------------
# The log line must report what was actually rewritten, not a hardcoded legacy
# string. Under the pre-fix code this reported `j:j-<name> -> j:<name>` in a
# branch that could never be reached.
# -----------------------------------------------------------------------------

@test "logs the separators actually used, per rewritten twin" {
  run_rewrite
  [ "$status" -eq 0 ]
  assert_output_contains "name: j.j-orphan -> name: j.orphan"
  assert_output_contains "name: j:j-legacy -> name: j.legacy"
  assert_output_not_contains "-> name: j:"
}

@test "is idempotent: a second pass over an already-rewritten tree rewrites nothing" {
  run_rewrite
  [ "$status" -eq 0 ]
  run_rewrite
  [ "$status" -eq 0 ]
  [ "$(name_of "$WT/skills/j-orphan/SKILL.md")" = "name: j.orphan" ]
  assert_output_not_contains "orphaned-twin rewrite: $WT/skills/j-orphan"
}

# -----------------------------------------------------------------------------
# Harness integrity. If mirror.sh is refactored such that the function can no
# longer be extracted, every test above would trivially "pass" against an empty
# sandbox. This asserts the harness is really running the real function.
# -----------------------------------------------------------------------------

@test "harness extracts the real function from the real mirror.sh" {
  printf '#!/usr/bin/env bash\necho "no such function here"\n' \
    > "$BATS_TEST_TMPDIR/not-a-script.sh"
  run bash "$HARNESS" "$BATS_TEST_TMPDIR/not-a-script.sh" "$WT"
  [ "$status" -eq 90 ]
  assert_output_contains "extraction contract broken"
}

# -----------------------------------------------------------------------------
# Loud-failure tally (rapport Suggested Next Step 4).
#
# The defect's real damage was not that it skipped -- it was that skipping
# everything looked identical to a clean run. These pin the counters that make
# that state audible.
# -----------------------------------------------------------------------------

@test "reports a seen/rewritten/unrecognized tally" {
  run_rewrite
  [ "$status" -eq 0 ]
  # Per root: j-orphan + j-legacy rewritten, j-weird unrecognized, j-paired not
  # an orphan at all. Three roots.
  assert_output_contains "9 orphaned twin(s) -- 6 rewritten, 0 already primary, 3 unrecognized"
}

@test "warns loudly when an orphaned twin matches no known frontmatter shape" {
  run_rewrite
  [ "$status" -eq 0 ]
  assert_output_contains "WARNING -- 3 orphaned twin(s) matched no known frontmatter shape"
  assert_output_contains "will resolve to NOTHING on the public package"
}

@test "does not warn when every orphaned twin is handled" {
  rm -rf "$WT/skills/j-weird" "$WT/.claude/skills/j-weird" "$WT/.agents/skills/j-weird"
  run_rewrite
  [ "$status" -eq 0 ]
  assert_output_contains "6 orphaned twin(s) -- 6 rewritten, 0 already primary, 0 unrecognized"
  assert_output_not_contains "WARNING"
}

@test "an already-rewritten tree counts as primary, not as a failure" {
  rm -rf "$WT/skills/j-weird" "$WT/.claude/skills/j-weird" "$WT/.agents/skills/j-weird"
  run_rewrite
  [ "$status" -eq 0 ]
  run_rewrite
  [ "$status" -eq 0 ]
  assert_output_contains "0 rewritten, 6 already primary, 0 unrecognized"
  assert_output_not_contains "WARNING"
}
