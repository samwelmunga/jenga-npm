#!/usr/bin/env bats
#
# Host-tool regression gate: can GitHub Copilot CLI actually load our skills?
# (E50_S07_T04)
#
# WHY THIS EXISTS
# ---------------
# E50_S01 renamed every skill's frontmatter `name:` from `<name>` to `j:<name>`.
# GitHub Copilot CLI validates that *value* when loading a skill and rejects the
# colon outright:
#
#   Skill name must start with an ASCII letter or number and contain only
#   ASCII letters (a-z, A-Z), numbers, hyphens, underscores, dots, and spaces
#
# The result was a total outage — 82 of 82 skills failing to load on Copilot,
# not a partial degradation — and it was shipped to the v3.0.0 stage completely
# undetected. Every check in the suite at the time was internal: frontmatter
# parity, mirror parity, allow-list generation. All of them passed against a
# repo that loaded zero skills in Copilot, because not one of them ever asked a
# host tool whether it could load anything.
#
# THIS GATE WOULD HAVE CAUGHT THE ORIGINAL E50_S01 REGRESSION AT THE MOMENT IT
# WAS INTRODUCED. That is its entire justification: it is deliberately not one
# more internal consistency check. It shells out to the real `copilot` binary
# and reads the real verdict.
#
# HOW IT WORKS (and why it does not just run from the repo root)
# --------------------------------------------------------------
# Three observed properties of `copilot` 1.0.83 shape the design:
#
#   1. `copilot skill list` ALWAYS exits 0 — even with 82 failures. The exit
#      code carries no signal at all; parsing stdout is mandatory.
#   2. Skill discovery is cwd-relative and covers `.github/skills/`,
#      `.agents/skills/` and `.claude/skills/` — but NOT the root `skills/`
#      tree. Running from the repo root therefore cannot validate `skills/`,
#      the canonical source that every other tree is generated from.
#   3. Failure reasons are textually distinct per class, which is what makes
#      an accurate name-validation classifier possible.
#
# So each test stages the SKILL.md files of the tree under test into a
# throwaway sandbox under $BATS_TEST_TMPDIR and runs `copilot skill list` with
# that sandbox as cwd. This lets the gate validate the root `skills/` tree at
# all, keeps runs deterministic, and isolates them from user-level Copilot
# config. Nothing is ever written into this repository's own trees.

# Shared assertion helpers. A bare `[[ ... ]]` does NOT fail a bats test unless
# it is the body's final statement -- `[[` is a shell keyword and never fires
# bats' ERR trap -- so every assertion below goes through a helper function,
# which is an ordinary simple command and does abort on failure. See the header
# of tests/helpers/assertions.bash (E50_S07_T08).
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# The exact validator wording for the failure class this gate is really about
# (the `j:` regression). Matching on it lets an unrelated Copilot-side error —
# "Skill name must not be empty", "missing or malformed YAML frontmatter", or
# anything GitHub adds later — surface under its own diagnostic instead of
# being misreported as a namespace-separator regression.
NAME_VALIDATION_SIGNATURE="Skill name must start with an ASCII letter"

# ---------------------------------------------------------------------------
# Availability guard
#
# A skip here must always be REPORTED, never silent: in an environment without
# a usable Copilot CLI this gate contributes no coverage whatsoever, and that
# fact needs to be visible in the run output rather than mistaken for a pass.
# ---------------------------------------------------------------------------
require_copilot() {
  if ! command -v copilot > /dev/null 2>&1; then
    skip "SKIPPED (no coverage): the 'copilot' CLI is not installed or not on PATH — this Copilot load-regression gate did not run"
  fi

  # `copilot skill list` exits 0 unconditionally, so usability has to be probed
  # from the output shape. An empty sandbox still prints the "Builtin skills:"
  # header when the CLI is working; an unauthenticated or otherwise unusable
  # CLI does not.
  local probe_dir="$BATS_TEST_TMPDIR/copilot-probe"
  mkdir -p "$probe_dir"
  local probe_out
  probe_out="$(cd "$probe_dir" && copilot skill list 2>&1 || true)"
  if [[ "$probe_out" != *"Builtin skills:"* ]]; then
    skip "SKIPPED (no coverage): the 'copilot' CLI is present but unusable (likely unauthenticated) — this Copilot load-regression gate did not run. Probe output: ${probe_out:0:200}"
  fi
}

# ---------------------------------------------------------------------------
# Sandbox staging
#
# stage_tree <sandbox-name> <source-tree>
#   Copies every <source-tree>/*/SKILL.md into a fresh sandbox as
#   .github/skills/<name>/SKILL.md and echoes the sandbox path. Only SKILL.md
#   is staged — frontmatter is all the loader validates, and copying 82 full
#   skill directories would be needless I/O.
# ---------------------------------------------------------------------------
stage_tree() {
  local sandbox="$BATS_TEST_TMPDIR/$1"
  local source_tree="$2"
  local skill_md name

  mkdir -p "$sandbox/.github/skills"
  for skill_md in "$source_tree"/*/SKILL.md; do
    [ -f "$skill_md" ] || continue
    name="$(basename "$(dirname "$skill_md")")"
    mkdir -p "$sandbox/.github/skills/$name"
    cp "$skill_md" "$sandbox/.github/skills/$name/SKILL.md"
  done

  echo "$sandbox"
}

# assert_fully_staged <sandbox> <source-tree>
#   Non-vacuity AND completeness guard, applied to every real-tree assertion.
#
#   An earlier draft only checked that the sandbox was non-empty (`-gt 0`), which
#   the tester correctly flagged as too weak: a partial-staging regression that
#   copied 2 of 82 skills would still have reported green, because the gate can
#   only ever fail on skills it actually staged. Comparing the staged count to
#   the source count closes that hole — silently narrowed coverage now fails
#   loudly instead of masquerading as a pass.
assert_fully_staged() {
  local sandbox="$1" source_tree="$2" expected=0 staged skill_md

  for skill_md in "$source_tree"/*/SKILL.md; do
    [ -f "$skill_md" ] && expected=$((expected + 1))
  done
  staged="$(find "$sandbox/.github/skills" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d '[:space:]')"

  if [ "$expected" -eq 0 ]; then
    echo "STAGING ERROR: no SKILL.md found under $source_tree — this assertion would be vacuous." >&2
    return 1
  fi
  if [ "$staged" -ne "$expected" ]; then
    echo "STAGING ERROR: staged $staged of $expected skills from $source_tree." >&2
    echo "The gate can only fail on skills it actually staged, so a partial stage silently narrows coverage." >&2
    return 1
  fi
  return 0
}

# write_fixture_skill <sandbox-name> <skill-dir-name> <frontmatter-name-value>
#   Synthesizes a single throwaway skill with an arbitrary frontmatter `name:`.
#   Used to prove the gate actually fails on a bad name — E50_S07_T01 is already
#   merged, so the repository's own trees are clean and cannot demonstrate it.
write_fixture_skill() {
  local sandbox="$BATS_TEST_TMPDIR/$1"
  local dir_name="$2"
  local frontmatter_name="$3"

  mkdir -p "$sandbox/.github/skills/$dir_name"
  cat > "$sandbox/.github/skills/$dir_name/SKILL.md" <<FIXTURE_EOF
---
name: $frontmatter_name
description: Throwaway fixture skill for the Copilot load-regression gate.
---
# Fixture

Body content is irrelevant — only the frontmatter \`name:\` value is under test.
FIXTURE_EOF

  echo "$sandbox"
}

# ---------------------------------------------------------------------------
# Failure parsing
#
# failed_lines <sandbox>
#   Runs the CLI in <sandbox> and emits one "<path>: <reason>" line per entry
#   in the "failed to load" section (empty output when nothing failed).
# ---------------------------------------------------------------------------
failed_lines() {
  (cd "$1" && copilot skill list 2>&1) \
    | sed -n '/The following skills failed to load:/,$p' \
    | sed -n 's/^[[:space:]]*•[[:space:]]*//p'
}

# name_validation_failures / other_failures — the classifier split. Keeping
# these separate is what turns "something went wrong in Copilot" into either
# "a skill name is invalid" or "an unrelated Copilot load error", each with its
# own actionable message.
name_validation_failures() {
  failed_lines "$1" | grep -F "$NAME_VALIDATION_SIGNATURE" || true
}

other_failures() {
  failed_lines "$1" | grep -vF "$NAME_VALIDATION_SIGNATURE" || true
}

# assert_tree_loads <sandbox> <human-readable tree label>
#   The gate proper. Fails on name-validation failures and on any other load
#   failure, with a distinct diagnostic for each class.
assert_tree_loads() {
  local sandbox="$1" label="$2" bad other

  bad="$(name_validation_failures "$sandbox")"
  other="$(other_failures "$sandbox")"

  if [ -n "$bad" ]; then
    echo "FAIL [$label]: Copilot rejected these skill names (the E50_S01 regression class)." >&2
    echo "Every listed skill fails to load in Copilot CLI. Check the frontmatter 'name:' value." >&2
    echo "$bad" >&2
  fi
  if [ -n "$other" ]; then
    echo "FAIL [$label]: Copilot reported load failures that are NOT name-validation errors." >&2
    echo "These are a different problem than the E50_S01 separator regression — read the reasons:" >&2
    echo "$other" >&2
  fi

  # Return explicitly: a bare `[ -z "$bad" ]` here would be overwritten by the
  # status of the following `[ -z "$other" ]`, silently letting name-validation
  # failures pass whenever the "other" bucket happened to be empty.
  if [ -n "$bad" ] || [ -n "$other" ]; then
    return 1
  fi
  return 0
}

@test "fixture with a valid 'j.' name loads cleanly in Copilot (control for the negative case below)" {
  require_copilot

  local sandbox
  sandbox="$(write_fixture_skill valid-fixture example j.example)"

  # Without this control, the negative test below could pass for the wrong
  # reason — e.g. a broken sandbox in which nothing loads at all.
  run failed_lines "$sandbox"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gate FAILS a skill whose frontmatter name uses the 'j:' separator (the E50_S01 regression)" {
  require_copilot

  local sandbox
  sandbox="$(write_fixture_skill invalid-fixture example "j:example")"

  # The gate must reject it...
  run assert_tree_loads "$sandbox" "throwaway j: fixture"
  [ "$status" -ne 0 ]

  # ...and must classify it as the name-validation class specifically, not as
  # some generic Copilot error.
  run name_validation_failures "$sandbox"
  [ "$status" -eq 0 ]
  assert_output_contains ".github/skills/example/SKILL.md"
  assert_output_contains "$NAME_VALIDATION_SIGNATURE"

  # Nothing should land in the "other" bucket for this input.
  run other_failures "$sandbox"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "classifier separates non-name-validation load errors from the name-validation class" {
  require_copilot

  # Two failures Copilot reports with different wording: an empty name and
  # malformed frontmatter. Neither is the E50_S01 regression, and neither may
  # be misreported as it.
  local sandbox
  sandbox="$(write_fixture_skill mixed-fixture bad-separator "j:example")"
  write_fixture_skill mixed-fixture empty-name '""' > /dev/null
  mkdir -p "$sandbox/.github/skills/no-frontmatter"
  echo "Body only — no YAML frontmatter at all." \
    > "$sandbox/.github/skills/no-frontmatter/SKILL.md"

  run name_validation_failures "$sandbox"
  [ "$status" -eq 0 ]
  assert_output_contains "bad-separator"
  assert_output_not_contains "empty-name"
  assert_output_not_contains "no-frontmatter"

  run other_failures "$sandbox"
  [ "$status" -eq 0 ]
  assert_output_contains "empty-name"
  assert_output_contains "no-frontmatter"
  assert_output_not_contains "bad-separator"
}

@test "every skill in the canonical skills/ tree loads in Copilot" {
  require_copilot

  local sandbox
  sandbox="$(stage_tree root-skills "$REPO_ROOT/skills")"

  assert_fully_staged "$sandbox" "$REPO_ROOT/skills"
  assert_tree_loads "$sandbox" "skills/"
}

@test "every skill in the .claude/skills/ mirror loads in Copilot" {
  require_copilot

  local sandbox
  sandbox="$(stage_tree claude-mirror "$REPO_ROOT/.claude/skills")"
  assert_fully_staged "$sandbox" "$REPO_ROOT/.claude/skills"
  assert_tree_loads "$sandbox" ".claude/skills/"
}

@test "every skill in the .agents/skills/ mirror loads in Copilot" {
  require_copilot

  local sandbox
  sandbox="$(stage_tree agents-mirror "$REPO_ROOT/.agents/skills")"
  assert_fully_staged "$sandbox" "$REPO_ROOT/.agents/skills"
  assert_tree_loads "$sandbox" ".agents/skills/"
}
