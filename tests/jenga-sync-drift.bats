#!/usr/bin/env bats
#
# Drift warnings in `jenga status` and `jenga doctor` (E26_S11_T05).
#
# Why this file exists
# ---------------------
# When npm or pnpm blocks scripts/postinstall.js nothing is reported, and the project quietly stays on the old
# framework files. lib/sync-drift.js makes the next `jenga status` / `jenga doctor` say so and point at
# `npx jenga sync`. It is a warning only: it must never change an exit code, modify a file, or fire on a project
# that is current.
#
# What is pinned here
# --------------------
#   1. a .jenga-version that differs from the package version (or is missing) warns, in both commands, also when
#      the router is not running (status used to exit before printing anything else) and when it is running
#   2. a stale skills list warns: a skill on disk the block does not list, and a skill the block lists that is gone
#   3. no warning on a freshly synced project, on a project without a Jenga block, or inside the package itself
#   4. the J- collision case (J-CLAUDE.md holds the block) is checked against the J- file
#   5. drift never changes the exit code, never modifies the project, and doctor still performs its orphan scan
#
# The skills list is compared with the directory the generator itself reads (.claude/skills, else .agents/skills),
# so that a project that was just synced can never warn; the test for a skill present in only one mirror root pins
# that choice.
#
# Every test runs a private copy of the package against a throwaway $BATS_TEST_TMPDIR consumer (see
# helpers/sync-fixture.bash), never this repository's own .agents/ or .claude/.

load helpers/assertions
load helpers/sync-fixture

setup_file() {
  sync_make_package
  # one fully synced consumer, copied into every test
  SYNCED="$BATS_FILE_TMPDIR/synced"
  mkdir -p "$SYNCED"
  ( cd "$SYNCED" && node "$BATS_FILE_TMPDIR/pkg-base/bin/jenga.js" sync >/dev/null )
  [ -f "$SYNCED/.jenga-version" ]
}

setup() {
  sync_make_consumer
  SYNCED="$BATS_FILE_TMPDIR/synced"
  cp -R "$SYNCED/." "$CONSUMER/"
}

# -- 1. version drift -------------------------------------------------------------

@test "status: an older .jenga-version warns and points to jenga sync, even though the router is not running" {
  echo "4.2.0" > "$CONSUMER/.jenga-version"
  run jenga status
  [ "$status" -eq 0 ]
  assert_output_contains ".jenga-version is 4.2.0"
  assert_output_contains "$PKG_VERSION is installed"
  assert_output_contains "npx jenga sync"
  assert_output_contains "Router is not running"
}

@test "doctor: an older .jenga-version warns and points to jenga sync" {
  echo "4.2.0" > "$CONSUMER/.jenga-version"
  run jenga doctor --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains ".jenga-version is 4.2.0"
  assert_output_contains "npx jenga sync"
}

@test "status and doctor: a missing .jenga-version warns that the framework files were never synced" {
  rm "$CONSUMER/.jenga-version"
  run jenga status
  [ "$status" -eq 0 ]
  assert_output_contains ".jenga-version not found"
  assert_output_contains "npx jenga sync"
  run jenga doctor --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains ".jenga-version not found"
}

@test "status: the version warning also shows when the router is running" {
  echo "4.2.0" > "$CONSUMER/.jenga-version"
  mkdir -p "$CONSUMER/.jenga"
  echo "$$" > "$CONSUMER/.jenga/router.pid"
  run jenga status
  [ "$status" -eq 0 ]
  assert_output_contains "Router running"
  assert_output_contains ".jenga-version is 4.2.0"
}

# -- 2. skills-list drift ---------------------------------------------------------

@test "status and doctor: a skill on disk that the block does not list warns, naming the skill" {
  local root
  for root in .claude .agents; do
    mkdir -p "$CONSUMER/$root/skills/j-extra"
    printf -- '---\nname: j.extra\ndescription: added later\n---\n' > "$CONSUMER/$root/skills/j-extra/SKILL.md"
  done

  run jenga status
  [ "$status" -eq 0 ]
  assert_output_contains "skills list in CLAUDE.md differs"
  assert_output_contains "skills list in AGENTS.md differs"
  assert_output_contains "not listed: j-extra"
  assert_output_contains "npx jenga sync"

  run jenga doctor --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "not listed: j-extra"
  assert_output_contains "npx jenga sync"
}

@test "status and doctor: a skill the block lists but that was removed from disk warns, naming the skill" {
  remove_dir "$CONSUMER/.claude/skills/j-tidy"
  remove_dir "$CONSUMER/.agents/skills/j-tidy"

  run jenga status
  [ "$status" -eq 0 ]
  assert_output_contains "listed but not installed: j-tidy"
  assert_output_contains "npx jenga sync"

  run jenga doctor --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "listed but not installed: j-tidy"
}

@test "status: a block that lists a skill name the package never had warns" {
  sed -i.bak 's/^- \*\*j-tidy\*\*/- **j-tidy-gone**/' "$CONSUMER/AGENTS.md"
  run jenga status
  [ "$status" -eq 0 ]
  assert_output_contains "skills list in AGENTS.md differs"
  assert_output_contains "not listed: j-tidy"
  assert_output_contains "listed but not installed: j-tidy-gone"
  assert_output_not_contains "skills list in CLAUDE.md differs"
}

@test "status: a skill that lives in only one mirror root does not warn after a sync (the generator reads .claude/skills first)" {
  mkdir -p "$CONSUMER/.agents/skills/j-only-agents"
  printf -- '---\nname: j.only-agents\ndescription: copilot-only skill\n---\n' > "$CONSUMER/.agents/skills/j-only-agents/SKILL.md"
  run jenga sync
  [ "$status" -eq 0 ]
  run jenga status
  [ "$status" -eq 0 ]
  assert_output_not_contains "npx jenga sync"
}

# -- 3. no false positives --------------------------------------------------------

@test "status and doctor: a freshly synced project produces no drift warning" {
  run jenga status
  [ "$status" -eq 0 ]
  assert_output_not_contains "npx jenga sync"
  assert_output_not_contains "⚠"

  run jenga doctor --dry-run
  [ "$status" -eq 0 ]
  assert_output_not_contains "npx jenga sync"
  assert_output_not_contains "⚠"
}

@test "status and doctor: a project without a Jenga block is not drift" {
  rm "$CONSUMER/CLAUDE.md" "$CONSUMER/AGENTS.md"
  run jenga status
  [ "$status" -eq 0 ]
  assert_output_not_contains "npx jenga sync"
  run jenga doctor --dry-run
  [ "$status" -eq 0 ]
  assert_output_not_contains "npx jenga sync"

  # the same when the files exist but carry no markers
  printf '# Mine\n' > "$CONSUMER/CLAUDE.md"
  printf '# Mine\n' > "$CONSUMER/AGENTS.md"
  run jenga status
  [ "$status" -eq 0 ]
  assert_output_not_contains "npx jenga sync"
}

@test "status and doctor inside the package itself: no drift warning" {
  run bash -c "cd '$PKG' && node bin/jenga.js status"
  [ "$status" -eq 0 ]
  assert_output_not_contains "npx jenga sync"
  run bash -c "cd '$PKG' && node bin/jenga.js doctor --dry-run"
  [ "$status" -eq 0 ]
  assert_output_not_contains "npx jenga sync"
}

# -- 4. J- collision --------------------------------------------------------------

@test "the J- collision case is checked against J-CLAUDE.md, not CLAUDE.md" {
  local C="$BATS_TEST_TMPDIR/collision"
  mkdir -p "$C"
  printf '# Mine\nsome rules\n' > "$C/CLAUDE.md"
  ( cd "$C" && node "$PKG/bin/jenga.js" sync >/dev/null )
  [ -f "$C/J-CLAUDE.md" ]

  run bash -c "cd '$C' && node '$PKG/bin/jenga.js' status"
  [ "$status" -eq 0 ]
  assert_output_not_contains "npx jenga sync"

  # make the J- file's block stale: the warning names the J- file
  drop_lines "$C/J-CLAUDE.md" '/^- \*\*j-tidy\*\*/'
  run bash -c "cd '$C' && node '$PKG/bin/jenga.js' status"
  [ "$status" -eq 0 ]
  assert_output_contains "skills list in J-CLAUDE.md differs"
  assert_output_contains "not listed: j-tidy"
  assert_output_not_contains "skills list in CLAUDE.md differs"

  # the user's own CLAUDE.md has no block, so editing it never counts as drift
  run bash -c "cd '$C' && node '$PKG/bin/jenga.js' sync >/dev/null && printf 'more text\n' >> CLAUDE.md && node '$PKG/bin/jenga.js' status"
  [ "$status" -eq 0 ]
  assert_output_not_contains "npx jenga sync"
}

# -- 5. exit codes, no side effects, orphan scan ----------------------------------

@test "drift never changes the exit code or modifies the project, and doctor still performs its orphan scan" {
  echo "4.2.0" > "$CONSUMER/.jenga-version"
  drop_lines "$CONSUMER/AGENTS.md" '/^- \*\*j-tidy\*\*/'
  # a retired, Jenga-shaped skill that is no longer shipped: an orphan candidate for doctor
  mkdir -p "$CONSUMER/.agents/skills/j-legacy-twin"
  printf -- '---\nname: j.j-legacy-twin\n---\n# retired\n' > "$CONSUMER/.agents/skills/j-legacy-twin/SKILL.md"

  local before
  before="$(tree_hash "$CONSUMER")"

  run jenga status
  [ "$status" -eq 0 ]
  assert_output_contains "npx jenga sync"

  run jenga doctor --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "npx jenga sync"
  assert_output_contains "orphan scan"
  assert_output_contains "skills/j-legacy-twin/"
  assert_output_contains "no files were deleted"

  [ "$before" = "$(tree_hash "$CONSUMER")" ]
}
