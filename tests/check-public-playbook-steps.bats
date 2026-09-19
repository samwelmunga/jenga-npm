#!/usr/bin/env bats
#
# Coverage for scripts/check-public-playbook-steps.sh's two E28_S14_T02 extensions:
# the project/.playbooks/ scan, and the terminal-step deny-list.
#
# Why a synthetic sandbox
# -----------------------
# The guard's whole job is to answer questions about the REAL repo's blocklist, so the
# interesting cases cannot be expressed against it: to prove the project-local scan is a real
# scan rather than a vacuous one, a project-local playbook has to be PUBLIC and broken -- and in
# the real repo E28_S14_T01 blocks that directory in full, permanently. Every behavioural test
# below therefore builds a throwaway repo under $BATS_TEST_TMPDIR, the same approach
# tests/gate-twin-parity.bats established. The sandbox is `git init`ed because
# scripts/check-publicignore-match.sh resolves its own repo root via `git rev-parse` from its own
# location, and it is the single source of blocklist semantics the guard delegates to -- stubbing
# it out would test a different program than the one that ships.
#
# One real-repo test is kept at the bottom, asserting only that the guard exits 0 and never
# asserting the counts, which legitimately differ between the private repo and the public mirror
# (brainstorm-to-mirror and project/.playbooks/ are both absent there).

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/skills/jenga/playbooks"

  cp "$REPO_ROOT/scripts/check-public-playbook-steps.sh" "$SANDBOX/scripts/"
  cp "$REPO_ROOT/scripts/check-publicignore-match.sh" "$SANDBOX/scripts/"

  ( cd "$SANDBOX" && git init -q )

  # Baseline blocklist: nothing blocked. Individual tests append what they need.
  printf '# sandbox .publicignore\n' > "$SANDBOX/.publicignore"
}

# write_skill <dir-name>
# Creates skills/<dir-name>/SKILL.md so a step referencing it resolves on disk.
write_skill() {
  mkdir -p "$SANDBOX/skills/$1"
  printf -- '---\nname: j.%s\ndescription: Sandbox fixture skill.\n---\n\n# %s\n' "$1" "$1" \
    > "$SANDBOX/skills/$1/SKILL.md"
}

# write_builtin_playbook <id> <step> [<step>...]
write_builtin_playbook() {
  local id="$1"
  shift
  write_playbook_at "$SANDBOX/skills/jenga/playbooks/$id.json" "$id" "$@"
}

# write_project_playbook <id> <step> [<step>...]
write_project_playbook() {
  local id="$1"
  shift
  mkdir -p "$SANDBOX/project/.playbooks"
  write_playbook_at "$SANDBOX/project/.playbooks/$id.json" "$id" "$@"
}

write_playbook_at() {
  local path="$1" id="$2" steps="" step
  shift 2
  for step in "$@"; do
    if [ -n "$steps" ]; then
      steps="$steps, "
    fi
    steps="$steps\"$step\""
  done
  cat > "$path" <<EOF
{
  "id": "$id",
  "name": "$id",
  "description": "Sandbox fixture playbook.",
  "steps": [$steps]
}
EOF
}

run_guard() {
  run bash "$SANDBOX/scripts/check-public-playbook-steps.sh" "$SANDBOX"
}

# -----------------------------------------------------------------------------
# Branch 1 -- project/.playbooks/ is scanned as a second source
# -----------------------------------------------------------------------------

@test "a blocklisted project-local playbook is classified private and skipped, exit 0" {
  write_skill j-commit
  write_builtin_playbook public-chain j-commit
  write_project_playbook local-chain j-commit
  printf 'project/.playbooks/\n' >> "$SANDBOX/.publicignore"

  run_guard
  [ "$status" -eq 0 ]
  # 1 public (the builtin) checked, 1 private (the project-local) skipped -- the project source
  # was reached and classified, not ignored.
  assert_output_contains "1 public playbook(s) checked"
  assert_output_contains "1 private playbook(s) skipped"
  assert_output_not_contains "VIOLATION"
}

@test "the project-local scan is mechanical, not vacuous: an UNBLOCKED project playbook with a private step is a violation" {
  # This is the case E28_S14_T01's blocklist makes unreachable in the real repo, and the whole
  # reason the scan exists: if anyone unblocks project/.playbooks/ later, the guard must cover it
  # with no further change to this script.
  write_skill j-commit
  write_skill j-self-sync
  printf 'skills/j-self-sync/\n' >> "$SANDBOX/.publicignore"
  write_project_playbook local-chain j-commit j-self-sync

  run_guard
  [ "$status" -eq 1 ]
  assert_output_contains "VIOLATION  project/.playbooks/local-chain.json -> step 'j-self-sync'"
  assert_output_contains "skills/j-self-sync/SKILL.md is blocklisted"
}

@test "project-local playbooks are classified through check-publicignore-match.sh, not a second blocklist implementation" {
  # Proven behaviourally: deleting the single source of blocklist semantics makes the guard
  # refuse to run at all rather than fall back to any local re-derivation.
  write_skill j-commit
  write_project_playbook local-chain j-commit
  rm "$SANDBOX/scripts/check-publicignore-match.sh"

  run_guard
  [ "$status" -eq 2 ]
  assert_output_contains "the single source of blocklist semantics"
}

@test "a missing project/.playbooks/ directory is a no-op, not an error" {
  write_skill j-commit
  write_builtin_playbook public-chain j-commit
  [ ! -d "$SANDBOX/project/.playbooks" ]

  run_guard
  [ "$status" -eq 0 ]
  assert_output_contains "1 public playbook(s) checked"
  assert_output_contains "0 private playbook(s) skipped"
  assert_output_not_contains "project/.playbooks"
}

@test "an empty project/.playbooks/ directory contributes nothing and is not an error" {
  write_skill j-commit
  write_builtin_playbook public-chain j-commit
  mkdir -p "$SANDBOX/project/.playbooks"

  run_guard
  [ "$status" -eq 0 ]
  assert_output_contains "1 public playbook(s) checked"
  assert_output_contains "0 private playbook(s) skipped"
}

@test "a public builtin playbook composing a private project-local playbook is a violation" {
  # load-playbooks.sh merges both sources into one catalog before resolving compositions, so a
  # composed id can legally live in either -- which makes this a real mirror breakage.
  write_skill j-commit
  write_project_playbook local-chain j-commit
  printf 'project/.playbooks/\n' >> "$SANDBOX/.publicignore"
  cat > "$SANDBOX/skills/jenga/playbooks/outer.json" <<'EOF'
{
  "id": "outer",
  "name": "outer",
  "description": "Sandbox fixture playbook.",
  "steps": ["j-commit", {"playbook": "local-chain"}]
}
EOF

  run_guard
  [ "$status" -eq 1 ]
  assert_output_contains "VIOLATION  skills/jenga/playbooks/outer.json -> composes 'local-chain'"
  assert_output_contains "project/.playbooks/local-chain.json is blocklisted"
}

# -----------------------------------------------------------------------------
# Branch 2 -- terminal-step deny-list
# -----------------------------------------------------------------------------

@test "a public playbook containing a deny-listed step is a violation with a non-zero exit" {
  # j-publish's own directory is PUBLIC here, exactly as it is in the real repo. That is the
  # point: the pre-existing blocklist check passes this playbook clean, so only the deny-list
  # can catch it.
  write_skill j-commit
  write_skill j-publish
  write_builtin_playbook ship-it j-commit j-publish

  run bash "$SANDBOX/scripts/check-publicignore-match.sh" skills/j-publish/SKILL.md
  assert_output_contains "PUBLIC"

  run_guard
  [ "$status" -eq 1 ]
  assert_output_contains "VIOLATION"
}

@test "the deny-list violation names the playbook, the offending step, and the policy verbatim" {
  write_skill j-commit
  write_skill j-publish
  write_builtin_playbook ship-it j-commit j-publish

  run_guard
  [ "$status" -eq 1 ]
  assert_output_contains "VIOLATION  skills/jenga/playbooks/ship-it.json -> step 'j-publish'"
  assert_output_contains 'No public playbook may contain a publishing or mirroring step; public build chains terminate at `j-commit`.'
}

@test "the policy sentence the guard emits is the one docs/skill-authoring.md states" {
  # Guards against the guard quoting a paraphrase of the rule it enforces.
  run grep -c 'No public playbook may contain a publishing or mirroring step; public build chains' \
    "$REPO_ROOT/docs/skill-authoring.md"
  [ "$status" -eq 0 ]
  run grep -c 'No public playbook may contain a publishing or mirroring step; public build chains' \
    "$REPO_ROOT/scripts/check-public-playbook-steps.sh"
  [ "$status" -eq 0 ]
}

@test "every seeded deny-list entry is enforced, in both its j- and bare naming form" {
  write_skill j-commit
  local step
  for step in j-publish publish j-mirror-public mirror-public; do
    rm -f "$SANDBOX/skills/jenga/playbooks/"*.json
    write_skill "$step"
    write_builtin_playbook "chain-$step" j-commit "$step"
    run_guard
    [ "$status" -eq 1 ]
    assert_output_contains "step '$step'"
  done
}

@test "a deny-listed step that is ALSO blocklisted yields exactly one violation, the policy one" {
  write_skill j-commit
  write_skill j-mirror-public
  printf 'skills/j-mirror-public/\n' >> "$SANDBOX/.publicignore"
  write_builtin_playbook ship-it j-commit j-mirror-public

  run_guard
  [ "$status" -eq 1 ]
  assert_output_contains "1 violation(s)"
  assert_output_contains "publishing/mirroring step in a public playbook"
  assert_output_not_contains "cannot load in the mirror"
}

@test "a BLOCKED playbook containing a deny-listed step is not reported -- it never ships" {
  write_skill j-commit
  write_skill j-mirror-public
  write_builtin_playbook private-chain j-commit j-mirror-public
  printf 'skills/jenga/playbooks/private-chain.json\n' >> "$SANDBOX/.publicignore"

  run_guard
  [ "$status" -eq 0 ]
  assert_output_contains "1 private playbook(s) skipped"
  assert_output_not_contains "VIOLATION"
}

@test "a public playbook with no deny-listed step still passes" {
  write_skill j-commit
  write_skill j-brainstorm
  write_builtin_playbook clean-chain j-brainstorm j-commit

  run_guard
  [ "$status" -eq 0 ]
  assert_output_contains "every step ships publicly"
}

# -----------------------------------------------------------------------------
# The deny-list is DATA, not a conditional buried in the checking logic
# -----------------------------------------------------------------------------

@test "adding a deny-list entry is a one-line array edit -- no change to the checking logic" {
  write_skill j-commit
  write_skill j-deploy
  write_builtin_playbook ship-it j-commit j-deploy

  # Not on the list yet: clean.
  run_guard
  [ "$status" -eq 0 ]

  # One line appended INSIDE the DENYLISTED_STEPS array, nothing else touched.
  local guard="$SANDBOX/scripts/check-public-playbook-steps.sh"
  perl -0pi -e 's/^DENYLISTED_STEPS=\(\n/DENYLISTED_STEPS=(\n  j-deploy\n/m' "$guard"
  run grep -c 'j-deploy' "$guard"
  assert_output_contains "1"

  run_guard
  [ "$status" -eq 1 ]
  assert_output_contains "step 'j-deploy'"
}

@test "the checking logic names no individual deny-listed skill" {
  # Everything from is_denylisted_step()'s definition onward -- i.e. all of the logic -- must be
  # free of any skill name, so the list stays the single place to edit.
  run bash -c "sed -n '/^is_denylisted_step()/,\$p' '$REPO_ROOT/scripts/check-public-playbook-steps.sh' | grep -v '^[[:space:]]*#' | grep -c -E 'j-publish|mirror-public' || true"
  assert_output_contains "0"
}

# -----------------------------------------------------------------------------
# Real repo
# -----------------------------------------------------------------------------

@test "the guard runs clean against the real repo" {
  # Exit code and the OK prefix only. Counts differ between the private repo and the public
  # mirror (brainstorm-to-mirror and project/.playbooks/ are absent there), so asserting them
  # would make this test a mirror-content assertion rather than a guard assertion.
  run bash "$REPO_ROOT/scripts/check-public-playbook-steps.sh" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  assert_output_contains "check-public-playbook-steps.sh: OK"
}
