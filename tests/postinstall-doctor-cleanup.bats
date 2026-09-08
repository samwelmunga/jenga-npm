#!/usr/bin/env bats
#
# `jenga doctor` / `jenga clean` interactive orphan cleanup (E26_S08_T02).
#
# Why this file exists
# ---------------------
# E26_S08_T01's manifest-based delete reconciliation is purely forward-looking: a consumer
# already installed before any manifest existed can never have pre-existing orphans cleaned up
# by postinstall alone (see E26_S08's "Scope gap discovered after T01"). This command is the
# manual stopgap — a human runs it, reviews a heuristic-derived candidate list, and confirms
# before anything is deleted. Because there is no manifest provenance guarantee to lean on here,
# the confirmation step is THE load-bearing safety control, not a convenience.
#
# What is pinned here
# --------------------
#   1. Candidate detection: an orphaned Jenga-shaped skill directory and a retired agent file are
#      found; a currently-shipped skill/agent, a consumer file living inside a still-current
#      package skill directory, and a consumer's own non-Jenga-prefixed skill all survive.
#   2. --dry-run never deletes.
#   3. A non-TTY invocation (the real `bin/jenga.js doctor` CLI, piped stdin) never deletes, even
#      when the piped input would otherwise read as an affirmative answer.
#   4. Confirmed deletion actually removes exactly the candidates and prunes the emptied
#      directory, while every survivor above stays untouched.
#   5. Decline deletes nothing.
#   6. A symlink placed inside an otherwise-orphaned directory is never touched (refused, not
#      followed) — boundary/type safety matches the postinstall delete pass.
#
# Tests 4-5 drive the exact same runDoctor()/deleteGroups() code path the real CLI uses, via the
# documented `isInteractive`/`confirmFn` test seam in lib/commands/doctor.js (never reachable from
# the CLI's own argv parsing) — not a parallel reimplementation. This mirrors the same non-TTY
# piped-stdin readline limitation already documented in tests/init.bats: Node's readline cannot be
# driven end-to-end from a non-pty test runner, so the interactive prompt itself is exercised via
# the seam while the CLI-observable behaviors (scan output, --dry-run, real non-TTY refusal) are
# exercised by actually invoking bin/jenga.js.
#
# Every test below runs against a throwaway $BATS_TEST_TMPDIR consumer fixture, never against this
# repository's own .agents/.claude.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  CONSUMER_DIR="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER_DIR/.agents/skills/j-do" \
           "$CONSUMER_DIR/.agents/skills/j-legacy-twin" \
           "$CONSUMER_DIR/.agents/skills/my-custom-skill" \
           "$CONSUMER_DIR/.agents/agents"

  # Currently-shipped skill — must survive untouched. This MUST name a skill that ships in both
  # this monorepo and the public mirror, because doctor's candidacy check reads the installed
  # package's own skills/ listing. `skills/do/` is unusable here: .publicignore blocklists every
  # canonical duplicate of a j-<name>-twinned skill (E28_S09), so it is absent from the mirror and
  # doctor rightly reports it as an orphan there. The j-<name> twin ships in both, so use it.
  cat > "$CONSUMER_DIR/.agents/skills/j-do/SKILL.md" <<'EOF'
---
name: j.do
---
# do
EOF
  # Consumer file living INSIDE a still-current package skill directory — must survive.
  echo "my notes" > "$CONSUMER_DIR/.agents/skills/j-do/my-notes.md"

  # Orphaned Jenga-shaped skill (not shipped by this repo's current skills/) — candidate.
  cat > "$CONSUMER_DIR/.agents/skills/j-legacy-twin/SKILL.md" <<'EOF'
---
name: j.j-legacy-twin
---
# retired twin
EOF
  echo "asset" > "$CONSUMER_DIR/.agents/skills/j-legacy-twin/asset.txt"

  # Consumer's own custom skill (no j./j: prefix) — must survive.
  cat > "$CONSUMER_DIR/.agents/skills/my-custom-skill/SKILL.md" <<'EOF'
---
name: my-custom-skill
---
# custom
EOF

  # Currently-shipped agent file (this repo has agents/developer.md) — must survive.
  echo "# developer" > "$CONSUMER_DIR/.agents/agents/developer.md"
  # Orphaned agent file — candidate.
  echo "# retired" > "$CONSUMER_DIR/.agents/agents/retired-agent.md"
}

run_doctor() {
  cd "$CONSUMER_DIR" && node "$REPO_ROOT/bin/jenga.js" "$@"
}

# Drives the real runDoctor()/deleteGroups() code path with the documented isInteractive/confirmFn
# test seam — NOT a reimplementation of the delete logic. `answer` is "true" or "false".
run_doctor_with_confirmation() {
  local answer="$1"
  node -e "
    import('$REPO_ROOT/lib/commands/doctor.js').then(async (m) => {
      const result = await m.runDoctor([], {
        packageRoot: '$REPO_ROOT',
        targetRoot: '$CONSUMER_DIR',
        isInteractive: true,
        confirmFn: async () => $answer,
      });
      console.log('SEAM_RESULT ' + JSON.stringify(result));
    }).catch((e) => { console.error(e.stack || e.message); process.exit(1); });
  "
}

@test "doctor --dry-run: reports candidates but deletes nothing" {
  run run_doctor doctor --dry-run
  [ "$status" -eq 0 ]
  assert_contains "$output" "skills/j-legacy-twin/"
  assert_contains "$output" "agents/retired-agent.md"
  assert_contains "$output" "no files were deleted"
  [ -f "$CONSUMER_DIR/.agents/skills/j-legacy-twin/SKILL.md" ]
  [ -f "$CONSUMER_DIR/.agents/agents/retired-agent.md" ]
}

@test "doctor --dry-run: current package-owned files and consumer files never listed as candidates" {
  run run_doctor doctor --dry-run
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "skills/j-do/"
  assert_not_contains "$output" "my-custom-skill"
  assert_not_contains "$output" "developer.md"
}

@test "doctor (piped non-TTY stdin, no --dry-run): never deletes even when input reads as 'yes'" {
  # bats' `run` always gives the child a non-TTY stdin, so this exercises the real CLI's own
  # process.stdin.isTTY gate, not the test seam.
  run bash -c "cd '$CONSUMER_DIR' && echo y | node '$REPO_ROOT/bin/jenga.js' doctor"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Non-interactive session detected"
  [ -f "$CONSUMER_DIR/.agents/skills/j-legacy-twin/SKILL.md" ]
  [ -f "$CONSUMER_DIR/.agents/skills/j-legacy-twin/asset.txt" ]
  [ -f "$CONSUMER_DIR/.agents/agents/retired-agent.md" ]
}

@test "doctor clean alias: identical behavior to doctor (same code path)" {
  run bash -c "cd '$CONSUMER_DIR' && echo y | node '$REPO_ROOT/bin/jenga.js' clean"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Non-interactive session detected"
  [ -f "$CONSUMER_DIR/.agents/skills/j-legacy-twin/SKILL.md" ]
}

@test "doctor confirmed (via test seam): deletes exactly the candidates, prunes empty dir, survivors untouched" {
  run run_doctor_with_confirmation true
  [ "$status" -eq 0 ]
  assert_contains "$output" "SEAM_RESULT"
  assert_contains "$output" '"deleted":3'

  # Orphan directory fully removed (both files + the now-empty directory pruned).
  [ ! -e "$CONSUMER_DIR/.agents/skills/j-legacy-twin/SKILL.md" ]
  [ ! -e "$CONSUMER_DIR/.agents/skills/j-legacy-twin/asset.txt" ]
  [ ! -e "$CONSUMER_DIR/.agents/skills/j-legacy-twin" ]
  [ ! -e "$CONSUMER_DIR/.agents/agents/retired-agent.md" ]

  # Survivors untouched.
  [ -f "$CONSUMER_DIR/.agents/skills/j-do/SKILL.md" ]
  [ -f "$CONSUMER_DIR/.agents/skills/j-do/my-notes.md" ]
  [ -f "$CONSUMER_DIR/.agents/skills/my-custom-skill/SKILL.md" ]
  [ -f "$CONSUMER_DIR/.agents/agents/developer.md" ]
}

@test "doctor declined (via test seam): deletes nothing" {
  run run_doctor_with_confirmation false
  [ "$status" -eq 0 ]
  assert_contains "$output" '"deleted":[]'
  [ -f "$CONSUMER_DIR/.agents/skills/j-legacy-twin/SKILL.md" ]
  [ -f "$CONSUMER_DIR/.agents/agents/retired-agent.md" ]
}

@test "doctor: no candidates found reports cleanly and exits 0" {
  rm -rf "$CONSUMER_DIR/.agents/skills/j-legacy-twin" "$CONSUMER_DIR/.agents/agents/retired-agent.md"
  run run_doctor doctor --dry-run
  [ "$status" -eq 0 ]
  assert_contains "$output" "No orphan candidates found"
}

@test "doctor: a symlink inside an orphaned directory is refused, not followed or deleted" {
  ln -s /etc/hosts "$CONSUMER_DIR/.agents/skills/j-legacy-twin/evil-link.txt"
  run run_doctor doctor --dry-run
  [ "$status" -eq 0 ]
  # The symlink itself must never appear as a candidate (lstat-checked, refused rather than
  # followed) — only the two genuine regular files in that directory are counted.
  assert_contains "$output" "skills/j-legacy-twin/ (2 file(s))"

  run run_doctor_with_confirmation true
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER_DIR/.agents/skills/j-legacy-twin/evil-link.txt" ]
}
