#!/usr/bin/env bats
#
# Regression coverage for skills/j-gitignore/scripts/*.
#
# Why this file exists
# ---------------------
# j.gitignore is the RETROACTIVE repair path for projects scaffolded before the
# stray-EOF template fix (E31_S07_T02/T03, E42_S06_T01) — that fix repaired
# assets/.gitignore_template only, which helps new scaffolds and does nothing
# for a project already on disk. Every test here runs against a throwaway git
# repo under $BATS_TEST_TMPDIR with its own bare "origin", so nothing touches a
# real repository, remote, or network.
#
# The two properties worth pinning hardest, because getting either wrong is
# destructive and silent:
#   1. repair-gitignore.sh preserves everything outside its managed block.
#   2. untrack-jenga-files.sh NEVER removes a file from disk.
#
# Also pins bash 3.2 compatibility: macOS ships 3.2.57, which has no negative
# array subscripts. An earlier draft used ${arr[-1]} to trim trailing blank
# lines and spun forever there rather than failing loudly.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS="$REPO_ROOT/skills/j-gitignore/scripts"
AUDIT="$SCRIPTS/audit-gitignore.sh"
REPAIR="$SCRIPTS/repair-gitignore.sh"
UNTRACK="$SCRIPTS/untrack-jenga-files.sh"

# A project reproducing the pre-fix scaffold: stray EOF terminator, loose
# visibility-script entries, and Jenga files already tracked and pushed.
setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"

  git init -q --bare "$ORIGIN"
  git init -q "$PROJ"
  cd "$PROJ" || return 1
  git config user.email test@example.com
  git config user.name "Test"

  printf '# macOS\n.DS_Store\n\n# Env\n.env\nnode_modules/\nEOF\n' > .gitignore
  printf 'project/\n' >> .gitignore

  mkdir -p .agents/skills .github/hooks project/board
  echo 'x'    > .agents/skills/b.md
  echo '{}'   > .github/hooks/jenga.json
  echo '{}'   > jenga.config.json
  echo '3.5.0' > .jenga-version
  echo 'mine' > CLAUDE.md
  echo 'src'  > index.js

  git add -A
  git commit -q -m "init"
  git remote add origin "$ORIGIN"
  git push -q -u origin HEAD
}

# ─── audit ───────────────────────────────────────────────────────────────────

@test "audit reports the stray EOF terminator with its line number" {
  run bash "$AUDIT" "$PROJ"
  assert_output_contains "stray 'EOF' terminator"
  assert_output_contains "line 7"
}

@test "audit exits 10 when there are findings and 0 once clean" {
  run bash "$AUDIT" "$PROJ"
  [ "$status" -eq 10 ]
  assert_output_contains "AUDIT_RESULT=findings"

  bash "$REPAIR" ignored "$PROJ" >/dev/null
  bash "$UNTRACK" "$PROJ" --commit >/dev/null

  run bash "$AUDIT" "$PROJ"
  [ "$status" -eq 0 ]
  assert_output_contains "AUDIT_RESULT=clean"
}

@test "audit reports a tracked path as not ignored even with the entry present" {
  # .gitignore has no effect on an already-tracked file. Reporting these two
  # columns independently is the whole point — it is the usual reason someone
  # says "I ignored it and it still gets committed".
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  run bash "$AUDIT" "$PROJ"
  assert_output_contains "TRACKED"
}

@test "audit refuses a directory that is not a git repo" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run bash "$AUDIT" "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 1 ]
  assert_output_contains "Not a git repository"
}

@test "audit reports no-upstream rather than guessing a remote" {
  cd "$PROJ" || return 1
  git checkout -q -b orphan-branch
  run bash "$AUDIT" "$PROJ"
  assert_output_contains "no upstream"
}

# ─── repair: the stray EOF (§1) ──────────────────────────────────────────────

@test "repair removes the stray EOF line" {
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  run grep -cE '^[[:space:]]*EOF[[:space:]]*$' "$PROJ/.gitignore"
  [ "$output" = "0" ]
}

@test "repair --keep-eof leaves a literal EOF entry alone" {
  bash "$REPAIR" ignored "$PROJ" --keep-eof >/dev/null
  run grep -cE '^[[:space:]]*EOF[[:space:]]*$' "$PROJ/.gitignore"
  [ "$output" = "1" ]
}

# ─── repair: entries and preservation ────────────────────────────────────────

@test "repair preserves every user pattern outside the managed block" {
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  run cat "$PROJ/.gitignore"
  assert_output_contains ".DS_Store"
  assert_output_contains ".env"
  assert_output_contains "node_modules/"
  assert_output_contains "# macOS"
}

@test "repair folds loose visibility-script entries into the block, no duplicates" {
  bash "$REPAIR" ignored "$PROJ" --tiers scaffold,board >/dev/null
  run grep -cxF "project/" "$PROJ/.gitignore"
  [ "$output" = "1" ]
}

@test "repair is idempotent — a second run reports no change needed" {
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  cp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/first"
  run bash "$REPAIR" ignored "$PROJ"
  assert_output_contains "Already correct"
  run diff -q "$BATS_TEST_TMPDIR/first" "$PROJ/.gitignore"
  [ "$status" -eq 0 ]
}

@test "repair --dry-run shows the diff but writes nothing" {
  cp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/before"
  run bash "$REPAIR" ignored "$PROJ" --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "nothing written"
  run diff -q "$BATS_TEST_TMPDIR/before" "$PROJ/.gitignore"
  [ "$status" -eq 0 ]
}

@test "repair visible mode removes the block and restores the original file" {
  cp "$PROJ/.gitignore" "$BATS_TEST_TMPDIR/before"
  bash "$REPAIR" ignored "$PROJ" --tiers scaffold,board >/dev/null
  bash "$REPAIR" visible "$PROJ" --tiers scaffold,board >/dev/null
  run grep -c "jenga:gitignore" "$PROJ/.gitignore"
  [ "$output" = "0" ]
  # The stray EOF and the absorbed loose entry are gone by design; the user's
  # own patterns must all still be there.
  run cat "$PROJ/.gitignore"
  assert_output_contains ".DS_Store"
  assert_output_contains "node_modules/"
}

@test "repair creates a .gitignore when none exists" {
  rm -f "$PROJ/.gitignore"
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  run grep -cxF ".claude/" "$PROJ/.gitignore"
  [ "$output" = "1" ]
}

@test "repair visible is a no-op when there is no .gitignore" {
  rm -f "$PROJ/.gitignore"
  run bash "$REPAIR" visible "$PROJ"
  [ "$status" -eq 0 ]
  assert_output_contains "nothing to do"
}

@test "repair refuses to write when the managed block is unterminated" {
  printf '\n%s\n.claude/\n' "# >>> jenga:gitignore >>>" >> "$PROJ/.gitignore"
  run bash "$REPAIR" ignored "$PROJ"
  [ "$status" -eq 3 ]
  assert_output_contains "Unterminated managed block"
}

@test "repair rejects an invalid mode and an invalid tier" {
  run bash "$REPAIR" bogus "$PROJ"
  [ "$status" -eq 2 ]
  run bash "$REPAIR" ignored "$PROJ" --tiers nope
  [ "$status" -eq 2 ]
}

@test "repair completes rather than hanging on bash 3.2 array semantics" {
  # Trailing blank lines exercise the trim loop that ${arr[-1]} spun forever in.
  printf '\n\n\n' >> "$PROJ/.gitignore"
  run bash "$REPAIR" ignored "$PROJ"
  [ "$status" -eq 0 ]
}

# ─── untrack ─────────────────────────────────────────────────────────────────

@test "untrack stops tracking but never deletes from disk" {
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  bash "$UNTRACK" "$PROJ" --commit >/dev/null

  cd "$PROJ" || return 1
  run git ls-files -- jenga.config.json
  [ -z "$output" ]

  # The critical property: still present in the working tree.
  [ -f "$PROJ/jenga.config.json" ]
  [ -f "$PROJ/.jenga-version" ]
  [ -d "$PROJ/.agents" ]
  [ -f "$PROJ/.github/hooks/jenga.json" ]
}

@test "untrack leaves non-Jenga files tracked" {
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  bash "$UNTRACK" "$PROJ" --commit >/dev/null
  cd "$PROJ" || return 1
  run git ls-files -- index.js
  assert_output_contains "index.js"
}

@test "untrack leaves hybrid-tier files alone by default" {
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  bash "$UNTRACK" "$PROJ" --commit >/dev/null
  cd "$PROJ" || return 1
  run git ls-files -- CLAUDE.md
  assert_output_contains "CLAUDE.md"
}

@test "untrack --dry-run changes nothing" {
  cd "$PROJ" || return 1
  before="$(git ls-files)"
  run bash "$UNTRACK" "$PROJ" --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "nothing changed"
  [ "$(git ls-files)" = "$before" ]
}

@test "untrack without --commit leaves the removals staged only" {
  cd "$PROJ" || return 1
  head_before="$(git rev-parse HEAD)"
  bash "$UNTRACK" "$PROJ" >/dev/null
  [ "$(git rev-parse HEAD)" = "$head_before" ]
  run git diff --cached --name-only
  assert_output_contains "jenga.config.json"
}

@test "untrack refuses when unrelated changes are already staged" {
  cd "$PROJ" || return 1
  echo "change" >> index.js
  git add index.js
  run bash "$UNTRACK" "$PROJ" --commit
  [ "$status" -eq 4 ]
  assert_output_contains "Refusing to run"
}

@test "untrack folds a staged .gitignore in rather than refusing" {
  cd "$PROJ" || return 1
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  git add .gitignore
  run bash "$UNTRACK" "$PROJ" --commit
  [ "$status" -eq 0 ]
  assert_output_contains "folding the ignore-rule change"
}

@test "untrack --push without --commit is rejected" {
  run bash "$UNTRACK" "$PROJ" --push
  [ "$status" -eq 4 ]
  assert_output_contains "requires --commit"
}

@test "untrack --push removes the paths from origin's tip but keeps history" {
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  run bash "$UNTRACK" "$PROJ" --commit --push
  [ "$status" -eq 0 ]

  git clone -q "$ORIGIN" "$BATS_TEST_TMPDIR/clone"
  [ ! -e "$BATS_TEST_TMPDIR/clone/jenga.config.json" ]
  [ ! -e "$BATS_TEST_TMPDIR/clone/.agents" ]
  [ -f "$BATS_TEST_TMPDIR/clone/index.js" ]

  # History is explicitly NOT rewritten — this is documented, not incidental.
  cd "$BATS_TEST_TMPDIR/clone" || return 1
  run git log --all --oneline -- jenga.config.json
  assert_output_contains "init"
}

@test "untrack reports nothing to do when no catalog path is tracked" {
  bash "$REPAIR" ignored "$PROJ" >/dev/null
  bash "$UNTRACK" "$PROJ" --commit >/dev/null
  run bash "$UNTRACK" "$PROJ" --commit
  [ "$status" -eq 0 ]
  assert_output_contains "nothing to untrack"
}

@test "untrack refuses to push when the branch has no upstream" {
  cd "$PROJ" || return 1
  git checkout -q -b no-upstream
  run bash "$UNTRACK" "$PROJ" --commit --push
  [ "$status" -eq 3 ]
  assert_output_contains "no upstream"
  # The commit itself must still have succeeded.
  run git log -1 --pretty=%s
  assert_output_contains "untrack Jenga-owned files"
}
