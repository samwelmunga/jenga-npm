#!/usr/bin/env bats
#
# Coverage for skills/j-test/scripts/baseline-permissions.sh (E72_S07_T02).
#
# That script is the SOLE decider of two things: whether the working tree sits at
# the level-2 (Guarded) baseline, and which test files declare that they need it.
# Both feed the scope test gate's exclusion, so a wrong answer here changes the
# pass/fail verdict of every future gate run — in either direction.
#
# Everything is driven against a FIXTURE ROOT built in setup(), never against the
# real repository. Two reasons: the real tree is baseline-clean (measured
# 2026-11-01), so the unsatisfied branch is unreachable from ambient state; and
# E72_S07 explicitly reserves the session's permission level to the user, so a
# test must never elevate it to create the condition.
#
# Assertions use `[ ]` and tests/helpers/assertions.bash only; a line starting
# with `[[` is banned repo-wide by tests/bats-assertion-convention.bats.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
L2="$REPO_ROOT/templates/permission-levels/level-2-guarded.json"
L5="$REPO_ROOT/templates/permission-levels/level-5-unrestricted.json"

# Two roots, and the suite keeps them APART (E72_S07_T02, fix round 3).
#
# The script under test is run from a throwaway PACKAGE tree ($PKG) that is a
# different directory from the PROJECT fixture root ($FX) every case passes to
# --root. That is the shipped npm shape — package under
# node_modules/@jenga-ai/agent/, project root separate — and running the real
# in-checkout script instead made the two roots the same directory, so the suite
# could not see the difference between them. It therefore passed 27/27 while the
# script resolved the baseline TEMPLATE from --root, which hard-blocked every
# scoped and every full gate run in every npm-installed project.
#
# $PKG deliberately carries NO templates/ of its own. So, by default:
#   - the project override at $FX/templates/... is what every case resolves
#   - removing it leaves the template in NEITHER place, which is the exit-2 case
#   - pkg_ship_template() adds the shipped copy, for the npm-layout cases
setup() {
  FX="$BATS_TEST_TMPDIR/root"
  PKG="$BATS_TEST_TMPDIR/pkg"
  SCRIPT="$PKG/skills/j-test/scripts/baseline-permissions.sh"
  mkdir -p "$PKG/skills/j-test/scripts"
  cp "$REPO_ROOT/skills/j-test/scripts/baseline-permissions.sh" "$SCRIPT"

  mkdir -p "$FX/templates/permission-levels" "$FX/.claude" "$FX/.agents" "$FX/tests"
  cp "$L2" "$FX/templates/permission-levels/level-2-guarded.json"
  # Start satisfied; individual tests diverge what they need to.
  cp "$L2" "$FX/.claude/settings.json"
  cp "$L2" "$FX/.agents/settings.json"
  printf '{"session_level":2}\n' > "$FX/.jenga-permission-level.json"
}

elevate() { cp "$L5" "$FX/$1"; }

# pkg_ship_template [<source template>]: put the baseline template where the npm
# package ships it. Defaults to the real level-2 template.
pkg_ship_template() {
  mkdir -p "$PKG/templates/permission-levels"
  cp "${1:-$L2}" "$PKG/templates/permission-levels/level-2-guarded.json"
}

# drop_project_override: the consumer layout — a project root with no templates/.
drop_project_override() { rm -rf "$FX/templates"; }

mark_file() {
  printf '#!/usr/bin/env bats\n# jenga:requires-baseline-permissions: %s\n@test "t" { true; }\n' \
    "$2" > "$FX/tests/$1"
}

plain_file() {
  printf '#!/usr/bin/env bats\n@test "t" { true; }\n' > "$FX/tests/$1"
}

# the signal ---------------------------------------------------------------------------------------------------------

@test "check is satisfied when both settings files match the level-2 baseline" {
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 0 ]
}

@test "check is unsatisfied when .claude/settings.json is elevated" {
  elevate ".claude/settings.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 1 ]
}

@test "check is unsatisfied when .agents/settings.json is elevated" {
  elevate ".agents/settings.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 1 ]
}

@test "the verdict is the field diff, NOT session_level: a stale 2 over loosened files is still unsatisfied" {
  # This is the whole reason check_permission_level_invariant refuses to gate on
  # session_level: it goes stale in both directions. If this test ever passes
  # with status 0, the script has started trusting the wrong signal.
  elevate ".claude/settings.json"
  printf '{"session_level":2}\n' > "$FX/.jenga-permission-level.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 1 ]
}

@test "the verdict is the field diff, NOT session_level: a stale 5 over baseline files is still satisfied" {
  printf '{"session_level":5}\n' > "$FX/.jenga-permission-level.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 0 ]
}

@test "a changed field outside permissions.deny / autoMode.allow does not false-positive" {
  # settings.json also carries defaultMode, env and hooks, which change for
  # unrelated legitimate reasons. A whole-file diff would wrongly report these.
  jq '.defaultMode = "acceptEdits" | .env.SOMETHING = "1"' "$L2" > "$FX/.claude/settings.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 0 ]
}

@test "deny-list order does not matter" {
  jq '.permissions.deny |= reverse' "$L2" > "$FX/.claude/settings.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 0 ]
}

@test "an absent settings file is a harmless skip, not a failure" {
  rm -f "$FX/.agents/settings.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 0 ]
}

@test "a present but unparseable settings file fails closed" {
  printf 'not json at all' > "$FX/.agents/settings.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 1 ]
}

@test "a level-2 baseline template missing from BOTH places is exit 2, never a satisfied verdict" {
  # $PKG ships none (see setup), so removing the project override leaves the
  # template nowhere: an inability to evaluate, which is never a pass.
  rm -f "$FX/templates/permission-levels/level-2-guarded.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 2 ]
}

@test "exit 2 for a template missing from both places names both roots it looked in" {
  rm -f "$FX/templates/permission-levels/level-2-guarded.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 2 ]
  assert_output_contains "$FX"
  assert_output_contains "$PKG"
}

@test "reason propagates exit 2 for a template missing from both places" {
  rm -f "$FX/templates/permission-levels/level-2-guarded.json"
  run bash "$SCRIPT" reason --root "$FX"
  [ "$status" -eq 2 ]
}

# the npm layout: the template is package-relative, the settings are project-relative ------------------------------

@test "the shipped package template is used when the project carries no templates/ override" {
  # The regression this pins: a consumer project never carries templates/, and
  # resolving the baseline from --root alone exit-2'd every gate run there.
  pkg_ship_template
  drop_project_override
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 0 ]
}

@test "an elevated settings file is still caught through the shipped package template" {
  pkg_ship_template
  drop_project_override
  elevate ".claude/settings.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 1 ]
}

@test "a project templates/ override is preferred over the shipped package copy" {
  # The package ships the real level-2; the project overrides it with a level-5
  # document. The settings files are level-2, so honouring the override must
  # flip the verdict to unsatisfied. Reading the shipped copy instead would
  # leave it satisfied, which is how the two layers are told apart.
  pkg_ship_template "$L2"
  cp "$L5" "$FX/templates/permission-levels/level-2-guarded.json"
  run bash "$SCRIPT" check --root "$FX"
  [ "$status" -eq 1 ]
}

@test "list never reads the baseline template, so its absence from both places is harmless" {
  rm -f "$FX/templates/permission-levels/level-2-guarded.json"
  mark_file "marked.bats" "needs the baseline"
  run bash "$SCRIPT" list --root "$FX"
  [ "$status" -eq 0 ]
  assert_output_contains "tests/marked.bats"
}

@test "reason is empty when satisfied" {
  run bash "$SCRIPT" reason --root "$FX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reason names the divergent file and reports session_level as a diagnostic" {
  elevate ".claude/settings.json"
  printf '{"session_level":5}\n' > "$FX/.jenga-permission-level.json"
  run bash "$SCRIPT" reason --root "$FX"
  [ "$status" -eq 0 ]
  assert_output_contains ".claude/settings.json"
  assert_output_contains "level-2"
  assert_output_contains "session_level reads 5"
  assert_output_contains "diagnostic only"
}

@test "reason names both files when both diverge" {
  elevate ".claude/settings.json"
  elevate ".agents/settings.json"
  run bash "$SCRIPT" reason --root "$FX"
  assert_output_contains ".claude/settings.json"
  assert_output_contains ".agents/settings.json"
}

# the marker ---------------------------------------------------------------------------------------------------------

@test "list prints path and reason for a marked file, and nothing for an unmarked one" {
  mark_file "marked.bats" "needs a real push at the baseline"
  plain_file "plain.bats"
  run bash "$SCRIPT" list --root "$FX"
  [ "$status" -eq 0 ]
  assert_output_contains "tests/marked.bats"
  assert_output_contains "needs a real push at the baseline"
  assert_output_not_contains "plain.bats"
}

@test "list is empty and exit 0 when no file is marked" {
  plain_file "plain.bats"
  run bash "$SCRIPT" list --root "$FX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list is byte-sorted" {
  mark_file "zebra.bats" "z"
  mark_file "alpha.bats" "a"
  run bash "$SCRIPT" list --root "$FX"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -n 1 | cut -f1)" = "tests/alpha.bats" ]
}

@test "a marker past the first 40 lines is ignored" {
  {
    printf '#!/usr/bin/env bats\n'
    i=1
    while [ "$i" -le 45 ]; do printf '# filler %s\n' "$i"; i=$((i + 1)); done
    printf '# jenga:requires-baseline-permissions: too late to count\n'
  } > "$FX/tests/late.bats"
  run bash "$SCRIPT" list --root "$FX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a marker with an empty reason is exit 2 and prints NO listing" {
  # The empty-reason rule exists so a suite can never be quietly excluded from a
  # gate without saying why. A partial list would let a consumer act on a set
  # that silently omitted the broken file, so nothing is printed at all.
  mark_file "good.bats" "a real reason"
  printf '#!/usr/bin/env bats\n# jenga:requires-baseline-permissions:   \n' > "$FX/tests/bad.bats"
  run bash "$SCRIPT" list --root "$FX"
  [ "$status" -eq 2 ]
  assert_output_not_contains "tests/good.bats"
}

@test "an empty reason is reported as exit 2 by check-file too, never as unmarked" {
  printf '#!/usr/bin/env bats\n# jenga:requires-baseline-permissions:\n' > "$FX/tests/bad.bats"
  run bash "$SCRIPT" check-file "$FX/tests/bad.bats"
  [ "$status" -eq 2 ]
}

@test "check-file distinguishes marked, unmarked and absent" {
  mark_file "marked.bats" "r"
  plain_file "plain.bats"
  run bash "$SCRIPT" check-file "$FX/tests/marked.bats"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" check-file "$FX/tests/plain.bats"
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" check-file "$FX/tests/nope.bats"
  [ "$status" -eq 1 ]
}

@test "reason-file prints the reason of a marked file" {
  mark_file "marked.bats" "the stated cause"
  run bash "$SCRIPT" reason-file "$FX/tests/marked.bats"
  [ "$status" -eq 0 ]
  [ "$output" = "the stated cause" ]
}

@test "a tests directory that does not exist is exit 0 with no output" {
  rm -rf "$FX/tests"
  run bash "$SCRIPT" list --root "$FX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# the three real suites carry the marker -----------------------------------------------------------------------------

@test "the three baseline-sensitive suites in this repository are marked" {
  run bash "$SCRIPT" list --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # All three drive skills/j-mirror-public/scripts/mirror.sh, a private skill, so they are blocklisted
  # from the public mirror: assert each one only where it exists in this tree.
  local suite
  for suite in tests/mirror-permission-level-invariant.bats \
               tests/mirror-staging-branch-push.bats \
               tests/mirror-test-subject-invariant.bats; do
    if [ -f "$REPO_ROOT/$suite" ]; then
      assert_output_contains "$suite"
    fi
  done
}

@test "every marker in this repository states a reason" {
  # Guards against someone adding a bare marker: list would exit 2 rather than
  # silently excluding a suite with no stated cause.
  run bash "$SCRIPT" list --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

# usage --------------------------------------------------------------------------------------------------------------

@test "--help exits 0 and documents the marker" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "jenga:requires-baseline-permissions"
}

@test "an unknown subcommand and a missing subcommand are both exit 2" {
  run bash "$SCRIPT" wibble
  [ "$status" -eq 2 ]
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "a non-directory --root is exit 2" {
  run bash "$SCRIPT" check --root "$FX/tests/nope"
  [ "$status" -eq 2 ]
}
