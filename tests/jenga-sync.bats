#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# `jenga sync [--dry-run]` and its sharing with scripts/postinstall.js (E26_S11).
#
# Why this file exists
# ---------------------
# After an upgrade a consumer needs one deterministic command that brings .claude/, .agents/, the Copilot files and
# the Jenga block in CLAUDE.md / AGENTS.md in line with the installed package, because npm or pnpm can skip the
# postinstall hook silently and postinstall alone never regenerated the block. lib/sync.js (syncConsumer) is the one
# implementation behind both entry points; lib/commands/sync.js is the CLI.
#
# What is pinned here
# --------------------
#   1. a second run changes nothing (hash of the whole consumer tree) and says so
#   2. --dry-run writes nothing: not on an empty project, not on a stale one, not into the package either
#   3. text outside the JENGA markers is byte-identical; a file without markers takes the J- collision path
#   4. consumer-owned skills, jenga.cli.json and an extra file inside a package skill directory survive
#   5. a stale project (old version, outdated block) becomes current and the block matches the skills on disk
#   6. postinstall produces the same files and the same per-step lines as sync, and ends with the sync prompt
#   7. inside the package it refuses (exit 1, nothing written); --help lists sync; unknown flags exit 1
#
# Every test drives a private COPY of the package (see helpers/sync-fixture.bash) and a throwaway $BATS_TEST_TMPDIR
# consumer, never this repository's own .agents/ or .claude/.

load helpers/assertions
load helpers/sync-fixture

setup_file() {
  sync_make_package
}

setup() {
  sync_make_consumer
}

# -- 1. idempotent ------------------------------------------------------------

@test "sync: a second run changes nothing and says so" {
  run jenga sync
  [ "$status" -eq 0 ]
  assert_output_contains "Jenga block updated"

  local before after
  before="$(tree_hash "$CONSUMER")"

  run jenga sync
  [ "$status" -eq 0 ]
  assert_output_contains "Nothing changed"
  after="$(tree_hash "$CONSUMER")"
  [ "$before" = "$after" ]
}

@test "sync: mirrors skills and agents into both roots and writes the Copilot files and the Jenga block" {
  run jenga sync
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/.claude/skills/j-do/SKILL.md" ]
  [ -f "$CONSUMER/.agents/skills/j-do/SKILL.md" ]
  [ -f "$CONSUMER/.claude/agents/developer.md" ]
  [ -f "$CONSUMER/.agents/agents/developer.md" ]
  [ -f "$CONSUMER/.github/copilot-instructions.md" ]
  [ -f "$CONSUMER/.github/hooks/jenga.json" ]
  [ -f "$CONSUMER/CLAUDE.md" ]
  [ -f "$CONSUMER/AGENTS.md" ]
  assert_contains "$(cat "$CONSUMER/CLAUDE.md")" "<!-- JENGA:START -->"
  [ "$(cat "$CONSUMER/.jenga-version")" = "$PKG_VERSION" ]
}

# -- 2. --dry-run writes nothing ------------------------------------------------

@test "sync --dry-run on an empty project: lists the pending changes and writes nothing" {
  local pkg_before before after
  pkg_before="$(tree_hash "$PKG")"
  before="$(tree_hash "$CONSUMER")"

  run jenga sync --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "Pending changes"
  assert_output_contains "would add  .claude/skills/j-do/SKILL.md"
  assert_output_contains "would create  CLAUDE.md"
  assert_output_contains "would add  .jenga-version"

  after="$(tree_hash "$CONSUMER")"
  [ "$before" = "$after" ]
  [ ! -e "$CONSUMER/.claude" ]
  [ ! -e "$CONSUMER/.agents" ]
  [ ! -e "$CONSUMER/.jenga-version" ]
  # a real run regenerates lib/skill-allow-list.json inside the package; a dry run must not
  [ "$pkg_before" = "$(tree_hash "$PKG")" ]
}

@test "sync --dry-run on a stale project: lists what would change, writes nothing" {
  run jenga sync
  [ "$status" -eq 0 ]

  # age the project: old version, an outdated block, a shipped skill removed from both mirrors
  echo "4.2.0" > "$CONSUMER/.jenga-version"
  drop_lines "$CONSUMER/CLAUDE.md" '/^- \*\*j-tidy\*\*/'
  remove_dir "$CONSUMER/.claude/skills/j-tidy"
  remove_dir "$CONSUMER/.agents/skills/j-tidy"

  local before after
  before="$(tree_hash "$CONSUMER")"
  run jenga sync --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "Pending changes"
  assert_output_contains "would overwrite  .jenga-version"
  assert_output_contains "would add  .claude/skills/j-tidy/SKILL.md"
  assert_output_contains "would regenerate  CLAUDE.md"
  after="$(tree_hash "$CONSUMER")"
  [ "$before" = "$after" ]
}

@test "sync --dry-run on a synced project: nothing to do" {
  run jenga sync
  [ "$status" -eq 0 ]
  run jenga sync --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "Nothing to do"
}

# -- 3. text outside the markers ------------------------------------------------

@test "sync: text before and after the markers in CLAUDE.md and AGENTS.md is byte-identical" {
  printf '# My project\nline before 1\nline before 2\n' > "$BATS_TEST_TMPDIR/pre"
  printf '\n\nline after 1\nline after 2 (no newline at end)' > "$BATS_TEST_TMPDIR/post"
  local file
  for file in CLAUDE.md AGENTS.md; do
    { cat "$BATS_TEST_TMPDIR/pre"; printf '<!-- JENGA:START -->\nstale block\n<!-- JENGA:END -->'; cat "$BATS_TEST_TMPDIR/post"; } > "$CONSUMER/$file"
  done

  run jenga sync
  [ "$status" -eq 0 ]

  for file in CLAUDE.md AGENTS.md; do
    split_outside_markers "$CONSUMER/$file" "$BATS_TEST_TMPDIR/pre-out" "$BATS_TEST_TMPDIR/post-out"
    cmp "$BATS_TEST_TMPDIR/pre" "$BATS_TEST_TMPDIR/pre-out"
    cmp "$BATS_TEST_TMPDIR/post" "$BATS_TEST_TMPDIR/post-out"
    assert_not_contains "$(cat "$CONSUMER/$file")" "stale block"
    assert_contains "$(block_names "$CONSUMER/$file")" "j-do"
  done
}

@test "sync: a file without markers is handled like jenga init: Jenga's copy goes to J-<NAME>.md, the user's text stays" {
  printf '# Mine\nsome rules\n' > "$CONSUMER/CLAUDE.md"

  run jenga sync
  [ "$status" -eq 0 ]
  assert_output_contains "J-CLAUDE.md"
  assert_output_contains "collision-created-j-file"

  [ -f "$CONSUMER/J-CLAUDE.md" ]
  assert_contains "$(cat "$CONSUMER/J-CLAUDE.md")" "<!-- JENGA:START -->"
  local mine
  mine="$(cat "$CONSUMER/CLAUDE.md")"
  assert_contains "$mine" "# Mine"
  assert_contains "$mine" "some rules"
  assert_not_contains "$mine" "<!-- JENGA:START -->"
  # only a reference to the J- file was added to the user's file
  assert_contains "$mine" "J-CLAUDE.md"

  # AGENTS.md did not exist: written directly
  [ -f "$CONSUMER/AGENTS.md" ]
  [ ! -e "$CONSUMER/J-AGENTS.md" ]

  # and a second run is a no-op for these too
  local before
  before="$(tree_hash "$CONSUMER")"
  run jenga sync
  [ "$status" -eq 0 ]
  [ "$before" = "$(tree_hash "$CONSUMER")" ]
}

# -- 4. consumer-owned files survive ---------------------------------------------

@test "sync: consumer-owned skills, jenga.cli.json and an extra file in a package skill directory are untouched" {
  mkdir -p "$CONSUMER/.agents/skills/j-mine" "$CONSUMER/.claude/skills/j-mine" "$CONSUMER/.agents/skills/j-do"
  printf -- '---\nname: j.mine\ndescription: my own skill\n---\n' > "$CONSUMER/.agents/skills/j-mine/SKILL.md"
  cp "$CONSUMER/.agents/skills/j-mine/SKILL.md" "$CONSUMER/.claude/skills/j-mine/SKILL.md"
  echo "my notes" > "$CONSUMER/.agents/skills/j-do/my-notes.md"
  printf '{ "agentTarget": "claude", "threshold": 7 }\n' > "$CONSUMER/jenga.cli.json"

  local mine_a mine_c notes cli
  mine_a="$(file_hash "$CONSUMER/.agents/skills/j-mine/SKILL.md")"
  mine_c="$(file_hash "$CONSUMER/.claude/skills/j-mine/SKILL.md")"
  notes="$(file_hash "$CONSUMER/.agents/skills/j-do/my-notes.md")"
  cli="$(file_hash "$CONSUMER/jenga.cli.json")"

  # first run: no manifest yet (legacy seeding path); second run: manifest-backed delete pass
  run jenga sync
  [ "$status" -eq 0 ]
  run jenga sync
  [ "$status" -eq 0 ]

  [ "$mine_a" = "$(file_hash "$CONSUMER/.agents/skills/j-mine/SKILL.md")" ]
  [ "$mine_c" = "$(file_hash "$CONSUMER/.claude/skills/j-mine/SKILL.md")" ]
  [ "$notes" = "$(file_hash "$CONSUMER/.agents/skills/j-do/my-notes.md")" ]
  [ "$cli" = "$(file_hash "$CONSUMER/jenga.cli.json")" ]
  # the package's own file next to it is present
  [ -f "$CONSUMER/.agents/skills/j-do/SKILL.md" ]
}

@test "sync --dry-run: consumer-owned files are untouched too" {
  mkdir -p "$CONSUMER/.agents/skills/j-mine"
  printf -- '---\nname: j.mine\n---\n' > "$CONSUMER/.agents/skills/j-mine/SKILL.md"
  printf '{ "a": 1 }\n' > "$CONSUMER/jenga.cli.json"
  local before
  before="$(tree_hash "$CONSUMER")"
  run jenga sync --dry-run
  [ "$status" -eq 0 ]
  [ "$before" = "$(tree_hash "$CONSUMER")" ]
}

# -- 5. a stale project becomes current -------------------------------------------

@test "sync: an outdated Jenga block becomes current and matches the skills on disk; .jenga-version is written" {
  run jenga sync
  [ "$status" -eq 0 ]

  # a project left on an older release: old version, skills missing from the block
  echo "4.2.0" > "$CONSUMER/.jenga-version"
  local file
  for file in CLAUDE.md AGENTS.md; do
    drop_lines "$CONSUMER/$file" '/^- \*\*j-(tidy|break|check-in)\*\*/'
    assert_not_contains "$(block_names "$CONSUMER/$file")" "j-tidy"
  done

  run jenga sync
  [ "$status" -eq 0 ]

  for file in CLAUDE.md AGENTS.md; do
    [ "$(block_names "$CONSUMER/$file")" = "$(dir_names "$CONSUMER/.agents/skills")" ]
    assert_contains "$(block_names "$CONSUMER/$file")" "j-tidy"
    assert_contains "$(block_names "$CONSUMER/$file")" "j-check-in"
  done
  [ "$(cat "$CONSUMER/.jenga-version")" = "$PKG_VERSION" ]
}

# -- 6. postinstall shares the implementation -------------------------------------

@test "postinstall and sync produce the same files and the same per-step lines; postinstall ends with the sync prompt" {
  local A="$BATS_TEST_TMPDIR/via-postinstall" B="$BATS_TEST_TMPDIR/via-sync"
  mkdir -p "$A" "$B"

  run env INIT_CWD="$A" node "$PKG/scripts/postinstall.js"
  [ "$status" -eq 0 ]
  local post_out="$output"
  assert_contains "${lines[${#lines[@]}-1]}" "npx jenga sync"

  run bash -c "cd '$B' && node '$PKG/bin/jenga.js' sync"
  [ "$status" -eq 0 ]
  local sync_out="$output"

  # the Jenga blocks (and whole files) are identical
  [ "$(file_hash "$A/CLAUDE.md")" = "$(file_hash "$B/CLAUDE.md")" ]
  [ "$(file_hash "$A/AGENTS.md")" = "$(file_hash "$B/AGENTS.md")" ]
  [ "$(block_names "$A/AGENTS.md")" = "$(dir_names "$A/.agents/skills")" ]

  # same per-step lines (normalising the consumer path; sync's own closing "N file(s) changed" line is not a step)
  local pl sl
  # Both the path as built and its canonical form are normalised: on macOS $BATS_TEST_TMPDIR is under /var, a symlink to
  # /private/var, and the per-step lines (e.g. the .github/hooks/jenga.json one) print the canonical /private/var path.
  local A_real B_real
  A_real="$(cd "$A" && pwd -P)"
  B_real="$(cd "$B" && pwd -P)"
  pl="$(printf '%s\n' "$post_out" | grep -E '^  (✓|ℹ|⚠) ' | sed -e "s|$A_real|<C>|g" -e "s|$A|<C>|g")"
  sl="$(printf '%s\n' "$sync_out" | grep -E '^  (✓|ℹ|⚠) ' | grep -vE 'file\(s\) changed|Nothing changed' | sed -e "s|$B_real|<C>|g" -e "s|$B|<C>|g")"
  [ -n "$pl" ]
  [ "$pl" = "$sl" ]
}

@test "postinstall prints the sync prompt on the nothing-to-do path too" {
  local A="$BATS_TEST_TMPDIR/pi"
  mkdir -p "$A"
  run env INIT_CWD="$A" node "$PKG/scripts/postinstall.js"
  [ "$status" -eq 0 ]
  run env INIT_CWD="$A" node "$PKG/scripts/postinstall.js"
  [ "$status" -eq 0 ]
  assert_output_contains "Nothing to do"
  assert_contains "${lines[${#lines[@]}-1]}" "npx jenga sync"
}

@test "postinstall regenerates a stale Jenga block (the upgrade gap this story closes)" {
  local A="$BATS_TEST_TMPDIR/upgrade"
  mkdir -p "$A"
  run env INIT_CWD="$A" node "$PKG/scripts/postinstall.js"
  [ "$status" -eq 0 ]
  echo "4.2.0" > "$A/.jenga-version"
  drop_lines "$A/AGENTS.md" '/^- \*\*j-tidy\*\*/'
  assert_not_contains "$(block_names "$A/AGENTS.md")" "j-tidy"

  run env INIT_CWD="$A" node "$PKG/scripts/postinstall.js"
  [ "$status" -eq 0 ]
  assert_contains "$(block_names "$A/AGENTS.md")" "j-tidy"
}

# -- 7. inside the package / usage ------------------------------------------------

@test "sync inside the package itself refuses with a non-zero exit and writes nothing" {
  local before
  before="$(tree_hash "$PKG")"
  run bash -c "cd '$PKG' && node bin/jenga.js sync"
  [ "$status" -ne 0 ]
  assert_output_contains "refused"
  run bash -c "cd '$PKG' && node bin/jenga.js sync --dry-run"
  [ "$status" -ne 0 ]
  [ "$before" = "$(tree_hash "$PKG")" ]
}

@test "jenga --help lists sync and sync --help prints its usage" {
  run jenga --help
  [ "$status" -eq 0 ]
  assert_output_contains "jenga sync [--dry-run]"

  run jenga sync --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: jenga sync [--dry-run]"
}

@test "sync with an unknown argument prints usage and exits 1 without writing" {
  run jenga sync --bogus
  [ "$status" -eq 1 ]
  assert_output_contains "Usage: jenga sync [--dry-run]"
  [ ! -e "$CONSUMER/.claude" ]
  [ ! -e "$CONSUMER/.jenga-version" ]
}
