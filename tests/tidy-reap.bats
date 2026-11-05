#!/usr/bin/env bats
#
# j.tidy's gated reaping path and its /reconcile wiring (E56_S06_T03).
#
# THIS SUITE'S SUBJECT DELETES THINGS, so read the isolation rules before adding a case.
#
#   - Every case builds its own throwaway git repository under $BATS_TEST_TMPDIR, with its own
#     TMPDIR and the global/system git config neutralised. NO CASE REMOVES A WORKTREE OR DELETES A
#     BRANCH IN THE REAL REPOSITORY, and the last case in this file is the standing pin for that:
#     it snapshots this repository's worktree and branch lists around a full reap run.
#   - Every case that asserts a removal ALSO asserts that the other entries in the same fixture are
#     still present afterwards. The dangerous failure here is a false positive, and a test that only
#     checks "the thing I wanted gone is gone" cannot see one.
#
# A past incident (E72_S08_T02) had one session's mutation testing corrupt a sibling session's
# measurement mid-flight and produce a false pass; with a destructive subject the equivalent mistake
# would delete a sibling's work, not just mismeasure it.
#
load helpers/assertions

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TIDY_DIR="$REPO_ROOT/skills/j-tidy/scripts"
REAP="$TIDY_DIR/reap.sh"
CLASSIFY="$TIDY_DIR/classify.sh"
SKILL="$REPO_ROOT/skills/j-tidy/SKILL.md"
RECONCILE="$REPO_ROOT/skills/j-reconcile/SKILL.md"

setup() {
  BASE="$BATS_TEST_TMPDIR/venue"
  mkdir -p "$BASE/tmp" "$BASE/wt"
  # Physically resolved: git records a worktree's path symlink-resolved (macOS reports /var/... as
  # /private/var/...), so an unresolved $WTDIR would never match `git worktree list --porcelain`.
  BASE="$(CDPATH='' cd -P -- "$BASE" && pwd -P)"
  FIX="$BASE/repo"
  WTDIR="$BASE/wt"
  export TMPDIR="$BASE/tmp"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  unset GIT_DIR
  unset GIT_WORK_TREE
  LIVE_PID=""
  # Belt and braces: if any case ever reached for the guard's override, this would make it visible
  # rather than silently effective.
  unset WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS

  git init -q -b main "$FIX"
  git -C "$FIX" config user.email test@example.com
  git -C "$FIX" config user.name Test
  git -C "$FIX" config commit.gpgsign false
  git -C "$FIX" config core.hooksPath /dev/null
  printf 'base\n' > "$FIX/base.txt"
  git -C "$FIX" add base.txt
  git -C "$FIX" commit -qm "base"
}

teardown() {
  [ -n "${LIVE_PID:-}" ] && kill "$LIVE_PID" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# fixture helpers
# ---------------------------------------------------------------------------

merged() {
  git -C "$FIX" checkout -q -b "$1" main
  printf '%s\n' "$1" > "$FIX/$1.txt"
  git -C "$FIX" add "$1.txt"
  git -C "$FIX" commit -qm "$1 work"
  git -C "$FIX" checkout -q main
  git -C "$FIX" merge -q --no-ff -m "merge $1" "$1"
}

unmerged() {
  git -C "$FIX" checkout -q -b "$1" main
  printf '%s\n' "$1" > "$FIX/$1.txt"
  git -C "$FIX" add "$1.txt"
  git -C "$FIX" commit -qm "$1 work"
  git -C "$FIX" checkout -q main
}

squashed() {
  git -C "$FIX" checkout -q -b "$1" main
  printf 'one\n' > "$FIX/$1.txt"
  git -C "$FIX" add "$1.txt"
  git -C "$FIX" commit -qm "$1 part 1"
  printf 'one\ntwo\n' > "$FIX/$1.txt"
  git -C "$FIX" commit -qam "$1 part 2"
  git -C "$FIX" checkout -q main
  git -C "$FIX" merge -q --squash "$1" >/dev/null 2>&1 || true
  git -C "$FIX" commit -qm "task($1): squashed"
}

add_wt() { git -C "$FIX" worktree add -q "$WTDIR/$1" "$1"; }

# reap: runs the subject and ALSO stashes its stdout in $REAPOUT, because every `run` after it
# overwrites $output - which silently turned several assertions here into assertions about the
# output of `git worktree list` the first time this suite was written.
reap() {
  run --separate-stderr bash "$REAP" --repo "$FIX" "$@"
  REAPOUT="$output"
  REAPSTATUS="$status"
}

wt_exists()     { git -C "$FIX" worktree list --porcelain | grep -q "^worktree $WTDIR/$1$"; }
branch_exists() { git -C "$FIX" show-ref --verify --quiet "refs/heads/$1"; }

# ===========================================================================
# the script, and the bypasses it must not contain
# ===========================================================================

@test "reap.sh exists, is executable, passes bash -n and is shellcheck clean" {
  [ -f "$REAP" ]
  [ -x "$REAP" ]
  run bash -n "$REAP"
  [ "$status" -eq 0 ]
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run shellcheck "$REAP"
  [ "$status" -eq 0 ]
  run shellcheck -S warning "$REAP"
  [ "$status" -eq 0 ]
}

@test "no script in the skill calls git worktree remove, uses the guard override, or has a -D fallback" {
  # The three bypasses E56_S06_T03 forbids, checked over executable lines only (the headers discuss
  # all three by name on purpose). Any hit here fails the task outright.
  # `env -u WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS` is the one permitted mention on an executable
  # line: it STRIPS the override rather than using it, and the E56_S06_T03 rework added it
  # precisely so an inherited export cannot disable the guard's liveness check. Setting,
  # exporting or passing the variable is still forbidden, so the exemption is anchored to the
  # `env -u` form and nothing else.
  # The exemption is a SUBSTRING removal, not a whole-line drop, and the glob is * rather than
  # *.sh. Both were defects in the first version of this hardening (found by the T03
  # re-verification pass): `grep -v` discarded the entire line, so one appended line reading
  #   env -u WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS true; git worktree remove --force "$path"
  # carried all three forbidden bypasses and still left this pin green; and *.sh left a
  # hypothetical reaper.py unpinned while the sibling seam pin had already been widened to *.
  local f hits=""
  for f in "$TIDY_DIR"/*; do
    [ -f "$f" ] || continue
    if grep -vE '^[[:space:]]*#' "$f" \
      | sed 's/env -u WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS//g' \
      | grep -qE 'git worktree remove|--force-ignore-liveness|WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS|git branch -D|branch +-D'; then
      hits="$hits $(basename "$f")"
    fi
  done
  if [ -n "$hits" ]; then
    echo "these scripts bypass the remove guard or fall back to -D:$hits" >&2
    return 1
  fi
}

@test "removal is routed through worktree-remove-guard.sh by name, with the override stripped" {
  run grep -qE '^[^#]*GUARD=.*worktree-remove-guard\.sh' "$REAP"
  [ "$status" -eq 0 ]
  # The guard is invoked via `env -u`, so an exported override in the caller's environment cannot
  # reach it (E56_S06_T03 rework). Pinning the exact call shape keeps a future edit from quietly
  # dropping the sanitisation back to a bare "$GUARD" "$path".
  run grep -qE '^[^#]*env -u WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS "\$GUARD" "\$path"' "$REAP"
  [ "$status" -eq 0 ]
}

@test "a mode is mandatory and the two modes are mutually exclusive" {
  reap
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "one of --auto or --confirm"
  reap --auto --confirm foo
  [ "$status" -eq 2 ]
  reap --confirm foo --auto
  [ "$status" -eq 2 ]
}

@test "--confirm refuses a glob, 'all', and a flag-shaped name" {
  local n
  for n in '*' 'E01_*' all ALL; do
    reap --confirm "$n"
    [ "$status" -eq 2 ]
    assert_contains "$stderr" "ONE literal entry name"
  done
}

@test "--confirm refuses a name matching no entry, and one matching more than one" {
  merged wt-a
  add_wt wt-a
  reap --confirm no-such-entry
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "matches no entry"
  # A duplicate-name stream is synthesised, since git itself cannot produce two identical names.
  printf '%s\n' \
    "branch	dup	-	other	main	retained	1	0	1	carries content not in main: 1 path(s) [x ]" \
    "branch	dup	-	other	main	retained	1	0	1	carries content not in main: 1 path(s) [x ]" \
    > "$BASE/dup.tsv"
  reap --confirm dup --records "$BASE/dup.tsv"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "matches 2 entries"
}

# ===========================================================================
# --auto: provably safe only
# ===========================================================================

@test "--auto removes a clean already-merged worktree and deletes its branch" {
  merged wt-merged
  unmerged wt-unmerged
  add_wt wt-merged
  add_wt wt-unmerged

  reap --auto
  [ "$status" -eq 0 ]
  assert_output_contains "removed	wt-merged"

  run wt_exists wt-merged
  [ "$status" -ne 0 ]
  run branch_exists wt-merged
  [ "$status" -ne 0 ]
  # and the unmerged one is untouched - the false-positive check
  run wt_exists wt-unmerged
  [ "$status" -eq 0 ]
  run branch_exists wt-unmerged
  [ "$status" -eq 0 ]
  [ -f "$WTDIR/wt-unmerged/wt-unmerged.txt" ]
}

@test "--auto removes a squash-merged worktree, and git branch -d keeping the branch is a partial outcome" {
  squashed E01_S01_T01-sq
  add_wt E01_S01_T01-sq

  reap --auto
  [ "$status" -eq 0 ]
  assert_output_contains "removed-worktree-branch-kept	E01_S01_T01-sq"
  assert_output_contains "no -D fallback"

  run wt_exists E01_S01_T01-sq
  [ "$status" -ne 0 ]
  # git refused -d because the squashed commits are not in main; the branch stays, by design
  run branch_exists E01_S01_T01-sq
  [ "$status" -eq 0 ]
  assert_contains "$REAPOUT" "removed, branch kept           1"
  assert_contains "$REAPOUT" "removed (worktree + branch)    0"
}

@test "--auto never touches a retained entry, whatever its shape" {
  unmerged wt-unmerged
  merged wt-dirty
  merged wt-untracked
  add_wt wt-unmerged
  add_wt wt-dirty
  add_wt wt-untracked
  printf 'dirty\n' > "$WTDIR/wt-dirty/base.txt"
  printf 'junk\n' > "$WTDIR/wt-untracked/junk.txt"

  reap --auto
  [ "$status" -eq 0 ]
  assert_output_not_contains "removed	wt-unmerged"
  assert_output_not_contains "removed	wt-dirty"
  assert_output_not_contains "removed	wt-untracked"
  run wt_exists wt-unmerged
  [ "$status" -eq 0 ]
  run wt_exists wt-dirty
  [ "$status" -eq 0 ]
  run wt_exists wt-untracked
  [ "$status" -eq 0 ]
  [ -f "$WTDIR/wt-dirty/base.txt" ]
  [ -f "$WTDIR/wt-untracked/junk.txt" ]
  assert_contains "$REAPOUT" "Retained entries were not considered here"
}

@test "--auto with nothing reclaimable removes nothing and still exits 0" {
  unmerged wt-unmerged
  add_wt wt-unmerged
  reap --auto
  [ "$status" -eq 0 ]
  assert_output_contains "removed (worktree + branch)    0"
  run wt_exists wt-unmerged
  [ "$status" -eq 0 ]
}

@test "a branch with no worktree is reclaimed independently of any worktree removal" {
  merged wt-merged
  git -C "$FIX" branch orphan-merged wt-merged
  unmerged orphan-unmerged
  # no worktrees at all in this case
  reap --auto
  [ "$status" -eq 0 ]
  assert_output_contains "branch-deleted	orphan-merged"
  run branch_exists orphan-merged
  [ "$status" -ne 0 ]
  run branch_exists orphan-unmerged
  [ "$status" -eq 0 ]
  # Two merged branches exist with no worktree here - orphan-merged and the wt-merged it was cut
  # from - and both are reclaimable on their own, which is the point of the case.
  run branch_exists wt-merged
  [ "$status" -ne 0 ]
  assert_contains "$REAPOUT" "branches deleted (no worktree) 2"
  assert_contains "$REAPOUT" "removed (worktree + branch)    0"
}

@test "the structurally excluded entries are refused in --auto and in --confirm alike" {
  merged wt-merged
  add_wt wt-merged
  reap --auto
  assert_not_contains "$REAPOUT" "removed	main"
  [ -d "$FIX" ]
  [ -f "$FIX/base.txt" ]

  git -C "$FIX" checkout -q -b work-branch
  reap --confirm main
  [ "$REAPSTATUS" -ne 0 ]
  assert_contains "$REAPOUT" "structurally excluded and never removable"
  run branch_exists main
  [ "$status" -eq 0 ]
}

# ===========================================================================
# --confirm: one named retained entry at a time
# ===========================================================================

@test "--confirm removes one named retained entry and leaves every other entry alone" {
  unmerged wt-one
  unmerged wt-two
  add_wt wt-one
  add_wt wt-two

  reap --confirm wt-one
  [ "$status" -eq 0 ]
  assert_output_contains "wt-one"
  run wt_exists wt-one
  [ "$status" -ne 0 ]
  # the entry nobody confirmed is untouched, worktree and branch
  run wt_exists wt-two
  [ "$status" -eq 0 ]
  run branch_exists wt-two
  [ "$status" -eq 0 ]
  [ -f "$WTDIR/wt-two/wt-two.txt" ]
}

@test "declining is the absence of a --confirm call: the entry is completely untouched" {
  # This is the gate's actual mechanism, asserted as behaviour: a reap run that was told about an
  # entry but never confirmed it leaves the worktree, the branch, the files and the ref SHA alone.
  unmerged wt-keep
  add_wt wt-keep
  local before_sha before_status
  before_sha="$(git -C "$FIX" rev-parse refs/heads/wt-keep)"
  before_status="$(git -C "$WTDIR/wt-keep" status --porcelain)"

  reap --auto
  [ "$status" -eq 0 ]

  run wt_exists wt-keep
  [ "$status" -eq 0 ]
  run branch_exists wt-keep
  [ "$status" -eq 0 ]
  [ "$(git -C "$FIX" rev-parse refs/heads/wt-keep)" = "$before_sha" ]
  [ "$(git -C "$WTDIR/wt-keep" status --porcelain)" = "$before_status" ]
  [ -f "$WTDIR/wt-keep/wt-keep.txt" ]
}

@test "--confirm on a reclaimable entry is skipped and points at --auto" {
  merged wt-merged
  add_wt wt-merged
  reap --confirm wt-merged
  assert_output_contains "skipped"
  assert_output_contains "--auto handles reclaimable ones"
  run wt_exists wt-merged
  [ "$status" -eq 0 ]
}

# ===========================================================================
# the guard, and re-verification
# ===========================================================================

@test "a live process inside a worktree stops the removal: the entry survives, named and reported" {
  # End-to-end, with a real process. Note which defence fires: the per-entry RE-VERIFICATION runs
  # the same liveness check the guard would, so a stale "reclaimable" record is caught before the
  # guard is even reached. The guard is the second line of defence, for a process that starts in
  # the window between the two - a race this case deliberately does not try to hit, since the
  # guard's own response is pinned by the next case instead.
  merged wt-live
  add_wt wt-live

  ( cd "$WTDIR/wt-live" && exec sleep 30 ) &
  LIVE_PID=$!
  local i=0 seen=0
  while [ "$i" -lt 40 ]; do
    if ! "$REPO_ROOT/scripts/check-worktree-liveness.sh" "$WTDIR/wt-live" >/dev/null 2>&1; then
      seen=1
      break
    fi
    i=$((i + 1))
    sleep 0.1
  done
  [ "$seen" -eq 1 ] || { echo "the liveness check never saw PID $LIVE_PID" >&2; return 1; }

  # Authorised from a record stream captured BEFORE the process started, so the entry genuinely
  # reaches the removal path rather than being filtered out at selection time.
  printf 'worktree\twt-live\t%s\tother\tmain\treclaimable\t0\t4096\t0\talready merged into main (ancestor); clean; no live process\n' \
    "$WTDIR/wt-live" > "$BASE/stale.tsv"

  reap --auto --records "$BASE/stale.tsv"
  assert_contains "$REAPOUT" "wt-live"
  assert_contains "$REAPOUT" "liveness"
  assert_not_contains "$REAPOUT" "removed	wt-live"
  run wt_exists wt-live
  [ "$status" -eq 0 ]
  [ -d "$WTDIR/wt-live" ]
  [ -f "$WTDIR/wt-live/base.txt" ]
}

@test "a guard refusal is reported as refused, skipped, and never retried with force" {
  # The guard's response is what reap.sh owns, so this case stages a guard that always refuses and
  # records every invocation. It asserts the three things the task requires: the refusal is
  # reported, the entry is skipped, and there is NO second call - with or without an override.
  merged wt-blocked
  add_wt wt-blocked

  local stage="$BASE/stub"
  mkdir -p "$stage/skills/j-tidy/scripts" "$stage/scripts"
  cp "$TIDY_DIR"/*.sh "$stage/skills/j-tidy/scripts/"
  cp "$REPO_ROOT/scripts/check-worktree-liveness.sh" "$stage/scripts/"
  cat > "$stage/scripts/worktree-remove-guard.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BASE/guard-calls.log"
printf 'env=%s\n' "\${WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS:-unset}" >> "$BASE/guard-calls.log"
echo "worktree-remove-guard.sh: BLOCKED - not removing (stubbed refusal)" >&2
exit 1
EOF
  chmod +x "$stage/scripts/worktree-remove-guard.sh"

  run --separate-stderr bash "$stage/skills/j-tidy/scripts/reap.sh" --repo "$FIX" --auto
  [ "$status" -eq 1 ]
  assert_output_contains "refused	wt-blocked"
  assert_output_contains "not retried with force"
  assert_output_contains "refused by the remove guard    1"
  assert_output_contains "NOT counted as removals"

  # exactly one invocation, and the override was never set for it
  [ "$(grep -c "wt-blocked" "$BASE/guard-calls.log" | tr -d ' ')" = "1" ]
  run grep -q 'force-ignore-liveness' "$BASE/guard-calls.log"
  [ "$status" -ne 0 ]
  run grep -q 'env=unset' "$BASE/guard-calls.log"
  [ "$status" -eq 0 ]

  # and the worktree and its branch are both still there
  run wt_exists wt-blocked
  [ "$status" -eq 0 ]
  run branch_exists wt-blocked
  [ "$status" -eq 0 ]
}

@test "a stale record is re-verified against the live state and skipped when the verdict changed" {
  merged wt-changed
  add_wt wt-changed
  # Captured clean...
  printf 'worktree\twt-changed\t%s\tother\tmain\treclaimable\t0\t4096\t0\talready merged into main (ancestor); clean; no live process\n' \
    "$WTDIR/wt-changed" > "$BASE/stale.tsv"
  # ...then the tree goes dirty before the reap runs.
  printf 'oops\n' > "$WTDIR/wt-changed/base.txt"

  reap --auto --records "$BASE/stale.tsv"
  assert_output_contains "state changed since classification"
  assert_output_contains "dirty working tree"
  run wt_exists wt-changed
  [ "$status" -eq 0 ]
  [ "$(cat "$WTDIR/wt-changed/base.txt")" = "oops" ]
}

@test "a record naming an entry that no longer exists is skipped, not acted on" {
  printf 'worktree\tghost\t%s/ghost\tother\tmain\treclaimable\t0\t4096\t0\talready merged into main (ancestor); clean; no live process\n' \
    "$WTDIR" > "$BASE/ghost.tsv"
  reap --auto --records "$BASE/ghost.tsv"
  assert_output_contains "skipped	ghost"
  assert_output_contains "re-verification found no such entry"
}

@test "classify.sh --only emits just that entry and keeps the same verdict as a full pass" {
  merged wt-a
  unmerged wt-b
  add_wt wt-a
  add_wt wt-b

  run --separate-stderr bash "$CLASSIFY" --repo "$FIX" --no-disk --only wt-a
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  [ "$(printf '%s' "$output" | cut -f2)" = "wt-a" ]
  [ "$(printf '%s' "$output" | cut -f6)" = "reclaimable" ]

  run --separate-stderr bash "$CLASSIFY" --repo "$FIX" --no-disk --only wt-b
  [ "$(printf '%s' "$output" | cut -f6)" = "retained" ]

  run --separate-stderr bash "$CLASSIFY" --repo "$FIX" --no-disk --only nothing-named-this
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===========================================================================
# dry run and reporting
# ===========================================================================

@test "--dry-run selects and reports but touches nothing" {
  merged wt-merged
  git -C "$FIX" branch orphan-merged wt-merged
  add_wt wt-merged
  local before_wt before_refs
  before_wt="$(git -C "$FIX" worktree list --porcelain)"
  before_refs="$(git -C "$FIX" for-each-ref --format='%(refname) %(objectname)')"

  reap --auto --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "would-remove	wt-merged"
  assert_output_contains "would-remove	orphan-merged"
  assert_output_contains "DRY RUN - nothing was touched."
  assert_output_contains "disk that would be reclaimed"

  [ "$(git -C "$FIX" worktree list --porcelain)" = "$before_wt" ]
  [ "$(git -C "$FIX" for-each-ref --format='%(refname) %(objectname)')" = "$before_refs" ]
  [ -d "$WTDIR/wt-merged" ]
}

@test "the summary keeps successes, refusals, failures and skips in separate counters" {
  merged wt-merged
  add_wt wt-merged
  reap --auto
  assert_output_contains "removed (worktree + branch)"
  assert_output_contains "removed, branch kept"
  assert_output_contains "branches deleted (no worktree)"
  assert_output_contains "branches kept (git refused -d)"
  assert_output_contains "refused by the remove guard"
  assert_output_contains "FAILED"
  assert_output_contains "skipped"
  assert_output_contains "disk reclaimed"
  assert_output_contains "disk retained (still in use)"
}

@test "a classification failure means nothing is touched" {
  merged wt-merged
  add_wt wt-merged
  local stage="$BASE/stage"
  mkdir -p "$stage/skills/j-tidy/scripts" "$stage/scripts"
  cp "$TIDY_DIR"/*.sh "$stage/skills/j-tidy/scripts/"
  cp "$REPO_ROOT/scripts/worktree-remove-guard.sh" "$stage/scripts/"
  # ...but NOT check-worktree-liveness.sh, so the classifier refuses to run.
  run --separate-stderr bash "$stage/skills/j-tidy/scripts/reap.sh" --repo "$FIX" --auto
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "nothing was touched"
  run wt_exists wt-merged
  [ "$status" -eq 0 ]
}

@test "reap.sh refuses to run at all without the remove guard" {
  local stage="$BASE/stage2"
  mkdir -p "$stage/skills/j-tidy/scripts" "$stage/scripts"
  cp "$TIDY_DIR"/*.sh "$stage/skills/j-tidy/scripts/"
  cp "$REPO_ROOT/scripts/check-worktree-liveness.sh" "$stage/scripts/"
  run --separate-stderr bash "$stage/skills/j-tidy/scripts/reap.sh" --repo "$FIX" --auto
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "worktree-remove-guard.sh"
  assert_contains "$stderr" "refusing to remove anything"
}

# ===========================================================================
# the skill's own wiring
# ===========================================================================

@test "SKILL.md documents the per-entry confirmation and names both reap modes" {
  local body
  body="$(cat "$SKILL")"
  run grep -qE 'reap\.sh"? --auto' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -qE 'reap\.sh"? --confirm' "$SKILL"
  [ "$status" -eq 0 ]
  assert_contains "$body" "one at a time"
  assert_contains "$body" "crucial_level"
  assert_contains "$body" "Never batch these."
  # the gate's mechanism must be stated, not implied
  assert_contains "$body" "declining leaves the entry untouched"
}

@test "/reconcile invokes the skill as a step rather than carrying a copy of the sweep" {
  run grep -q 'j\.tidy' "$RECONCILE"
  [ "$status" -eq 0 ]
  run grep -q 'skills/j-tidy/SKILL\.md' "$RECONCILE"
  [ "$status" -eq 0 ]
  # No sweep logic of its own: /reconcile must not grow its own classifier or removal call.
  run grep -nE '^[^#>|]*(classify\.sh|reap\.sh|worktree-remove-guard\.sh)' "$RECONCILE"
  [ "$status" -ne 0 ]
}

@test "the /reconcile sweep step sits after the orphaned-branch merge step" {
  local merge_line sweep_line summary_line
  merge_line="$(grep -n 'On confirmation, merge the branch into the current branch' "$RECONCILE" | head -1 | cut -d: -f1)"
  sweep_line="$(grep -n '^### 6\.6\.' "$RECONCILE" | head -1 | cut -d: -f1)"
  summary_line="$(grep -n '^### 7\. Print a summary' "$RECONCILE" | head -1 | cut -d: -f1)"
  [ -n "$merge_line" ]
  [ -n "$sweep_line" ]
  [ -n "$summary_line" ]
  [ "$sweep_line" -gt "$merge_line" ]
  [ "$sweep_line" -lt "$summary_line" ]
}

@test "the lifecycle document records the conditions, the squash-merge case, the thresholds and the non-goal" {
  local doc="$REPO_ROOT/project/documentation/worktree-lifecycle.md"
  [ -f "$doc" ]
  assert_contains "$(cat "$doc")" "four safety conditions"
  assert_contains "$(cat "$doc")" "squash-merge"
  assert_contains "$(cat "$doc")" "tidy-config.json"
  assert_contains "$(cat "$doc")" "Unwatched deletion"
}

# ===========================================================================
# E56_S06_T03 rework - the non-unique "(detached)" name, and the two adjacent holes
#
# These three cases are the regression set for the defect the verification pass found: --auto
# re-verified by NAME, read only the first matching record, and every detached worktree is named
# "(detached)". With two of them it could validate entry A and then hand entry B to the guard,
# which checks liveness but not dirtiness - so uncommitted work in B was destroyed.
# ===========================================================================

# detach <name> - a worktree at $WTDIR/<name> with a DETACHED HEAD, so classify.sh names it
# "(detached)". Two of these is an ordinary state: the native EnterWorktree tool produces them.
detach() {
  git -C "$FIX" worktree add -q --detach "$WTDIR/$1" main
}

@test "a detached worktree that went dirty after classification is never selected for removal" {
  # THE REPRODUCTION, and the exact shape matters - a careless version of this case passes against
  # the old name-based code and pins nothing.
  #
  # `--only "(detached)"` returns one record PER detached worktree, in enumeration order, and the
  # old code took NR==1. So the FIRST entry processed always got its own record and looked correct;
  # the hazard is the SECOND, which reads the first's verdict - but only while the first is still
  # present. In a plain --auto the first entry is removed during its own turn, so the second then
  # matches only itself and the bug hides. It is exposed whenever the first entry survives its
  # turn: a guard refusal, a skip, or --dry-run.
  #
  # --dry-run is used here because it makes the misfire deterministic and needs no live process or
  # timing. The old code marked BOTH entries would-remove, including the dirty one; the fixed code
  # addresses each by path and sees the dirty one's real state.
  detach det-a
  detach det-b

  run bash "$CLASSIFY" --repo "$FIX" --no-disk
  [ "$status" -eq 0 ]
  local records="$BATS_TEST_TMPDIR/records.tsv"
  printf '%s\n' "$output" > "$records"
  # Both reclaimable at classification time, or this case is not testing what it claims.
  [ "$(awk -F'\t' '$2 == "(detached)" && $6 == "reclaimable"' "$records" | grep -c .)" -eq 2 ]

  # The window: uncommitted work that exists nowhere else.
  printf 'uncommitted work nobody else has\n' > "$WTDIR/det-b/precious.txt"

  reap --records "$records" --auto --dry-run

  # det-b must NOT be offered for removal; det-a still may be, since it is genuinely clean.
  [ "$(grep -cE "^would-remove.*det-b" <<<"$REAPOUT")" -eq 0 ]
  [ "$(grep -cE "^skipped.*det-b" <<<"$REAPOUT")" -eq 1 ]
  assert_contains "$REAPOUT" "dirty working tree"

  # Nothing was touched, this being a dry run.
  [ -f "$WTDIR/det-b/precious.txt" ]
  wt_exists det-a
  wt_exists det-b
}

@test "a dirty detached worktree survives a real --auto when a sibling entry is refused" {
  # The live-fire counterpart of the case above: det-a is clean and reclaimable but the guard
  # refuses it, so it is still present when det-b's turn comes. Under the old NR==1 code det-b
  # then inherited det-a's `reclaimable` verdict and was handed to the guard - which checks
  # liveness, not dirtiness - and the uncommitted work was destroyed.
  detach det-a
  detach det-b

  run bash "$CLASSIFY" --repo "$FIX" --no-disk
  [ "$status" -eq 0 ]
  local records="$BATS_TEST_TMPDIR/records.tsv"
  printf '%s\n' "$output" > "$records"

  printf 'uncommitted work nobody else has\n' > "$WTDIR/det-b/precious.txt"

  # A guard that refuses det-a and would remove anything else, so a misfire on det-b is fatal.
  local stage="$BASE/stub-refuse"
  mkdir -p "$stage/skills/j-tidy/scripts" "$stage/scripts"
  cp "$TIDY_DIR"/*.sh "$stage/skills/j-tidy/scripts/"
  cp "$REPO_ROOT/scripts/check-worktree-liveness.sh" "$stage/scripts/"
  cat > "$stage/scripts/worktree-remove-guard.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$BASE/refuse-calls.log"
case "\$1" in
  *det-a) echo "worktree-remove-guard.sh: BLOCKED - stubbed refusal" >&2; exit 1 ;;
esac
exec git -C "$FIX" worktree remove --force "\$1"
EOF
  chmod +x "$stage/scripts/worktree-remove-guard.sh"

  run --separate-stderr bash "$stage/skills/j-tidy/scripts/reap.sh" \
    --repo "$FIX" --records "$records" --auto

  # The work survives, and the guard was never even asked about det-b.
  [ -f "$WTDIR/det-b/precious.txt" ]
  assert_contains "$(cat "$WTDIR/det-b/precious.txt")" "uncommitted work nobody else has"
  wt_exists det-b
  run grep -q 'det-b' "$BASE/refuse-calls.log"
  [ "$status" -ne 0 ]
}

@test "--auto refuses an entry it cannot address unambiguously instead of guessing" {
  # Defence in depth, independent of --only-path: an entry that cannot be addressed uniquely must
  # be skipped, never resolved by taking the first match. Forced by stripping the path from BOTH
  # detached records, so neither can be re-verified by path and the name is shared.
  detach det-a
  detach det-b

  run bash "$CLASSIFY" --repo "$FIX" --no-disk
  [ "$status" -eq 0 ]
  local records="$BATS_TEST_TMPDIR/records.tsv"
  printf '%s\n' "$output" \
    | awk -F'\t' -v OFS='\t' '$2 == "(detached)" { $3 = "-" } { print }' > "$records"
  # Both are reclaimable and pathless, so both are candidates that cannot be addressed.
  [ "$(awk -F'\t' '$2 == "(detached)" && $6 == "reclaimable" && $3 == "-"' "$records" | grep -c .)" -eq 2 ]

  reap --records "$records" --auto

  # Neither is removed, and the reason says why rather than reporting a clean sweep.
  wt_exists det-a
  wt_exists det-b
  [ "$(grep -cE '^skipped.*(ambiguous|cannot be re-verified)' <<<"$REAPOUT")" -eq 2 ]
}

@test "an exported WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS never reaches the guard" {
  # The guard honours that variable from its own environment, so without `env -u` at the call site
  # any session with it exported turned --auto into an unconditional force-remove while every "no
  # override is used" pin stayed green - those pins only prove reap.sh never SETS it.
  #
  # Tested through the stub guard rather than a live process, because that is the only way to
  # OBSERVE what the guard received: a real live process makes classify.sh mark the entry
  # `retained`, so it is never a candidate and the guard is never called at all. The exposure this
  # closes is the narrow race where a process appears after re-verification, which cannot be timed
  # reliably in a test - so the assertion is on the environment the guard is handed.
  merged wt-env
  add_wt wt-env

  local stage="$BASE/stub-env"
  mkdir -p "$stage/skills/j-tidy/scripts" "$stage/scripts"
  cp "$TIDY_DIR"/*.sh "$stage/skills/j-tidy/scripts/"
  cp "$REPO_ROOT/scripts/check-worktree-liveness.sh" "$stage/scripts/"
  cat > "$stage/scripts/worktree-remove-guard.sh" <<EOF
#!/usr/bin/env bash
printf 'env=%s\n' "\${WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS:-unset}" >> "$BASE/guard-env.log"
echo "worktree-remove-guard.sh: BLOCKED - not removing (stubbed refusal)" >&2
exit 1
EOF
  chmod +x "$stage/scripts/worktree-remove-guard.sh"

  # Exported in the caller's environment, exactly as a real operator's shell would have it.
  export WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS=1
  run --separate-stderr bash "$stage/skills/j-tidy/scripts/reap.sh" --repo "$FIX" --auto
  unset WORKTREE_REMOVE_FORCE_IGNORE_LIVENESS

  # The guard was called, and it saw the variable as unset despite the caller exporting it.
  [ -f "$BASE/guard-env.log" ]
  run grep -q 'env=unset' "$BASE/guard-env.log"
  [ "$status" -eq 0 ]
  run grep -q 'env=1' "$BASE/guard-env.log"
  [ "$status" -ne 0 ]

  # And the stubbed refusal was honoured rather than forced past.
  run wt_exists wt-env
  [ "$status" -eq 0 ]
}

# ===========================================================================
# blast radius
# ===========================================================================

@test "this suite leaves the real repository's worktrees and branches alone" {
  local before_wt before_br
  before_wt="$(git -C "$REPO_ROOT" worktree list --porcelain)"
  before_br="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname) %(objectname)' refs/heads)"

  merged wt-merged
  git -C "$FIX" branch orphan-merged wt-merged
  add_wt wt-merged
  reap --auto
  [ "$status" -eq 0 ]

  [ "$(git -C "$REPO_ROOT" worktree list --porcelain)" = "$before_wt" ]
  [ "$(git -C "$REPO_ROOT" for-each-ref --format='%(refname) %(objectname)' refs/heads)" = "$before_br" ]
}
