#!/usr/bin/env bats
#
# Mixed-history fixture tests for scripts/commits-for-item.sh (E79_S02_T03).
#
# What this file is for: the resolver reads history, so what it returns depends on the SHAPE history has when a
# consumer asks. This file builds six shapes in throwaway repositories (rebase, amend, cherry-pick, squash,
# fast-forward, --no-ff), each mixing the three kinds of commit the board has to cope with:
#
#   EST form        task(E10_S01_T01): add retry
#   trailer form    ASD-001 add backoff      + a `Jenga-Task: E10_S01_T02` trailer in the body
#   bare template   ASD-001 tidy up          (template-form subject, no trailer: not attributable)
#
# It DOCUMENTS the resolver's behaviour; where that behaviour is lossy it says so and asserts the lossy outcome
# rather than hiding it. In particular the squash tests that drop the trailer pin the Open Decision 3 / Phase 3
# trigger of project/documentation/commit-traceability-contract.md: if a squash-merge loses the trailer, the task
# silently has no commits and only --require-nonempty makes that loud.
#
# "The same set" after a rewrite means equal by `git patch-id --stable`, never equal by SHA (contract, section 2:
# SHAs change under rebase, amend and cherry-pick). Tests that rewrite history therefore assert both the new SHAs
# and, where the patch is unchanged, patch-id equality with the pre-rewrite commits.
#
# NOT in scope here: per-form and anchoring unit coverage (tests/commits-for-item.bats) and the differential proof
# against the legacy `git log --grep` (E79_S02_T02).
#
# Every repository is created under $BATS_TEST_TMPDIR and the resolver is pointed at it with --repo; nothing here
# touches this repository's history, board or event log. Each fixture sets user.name, user.email and
# commit.gpgsign=false locally, and setup() hides the global and system git config, so the file passes on a machine
# with no global git identity.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/commits-for-item.sh"

setup() {
  # No global identity, no signing, no hooks: the fixture alone decides how git behaves.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  FIX="$BATS_TEST_TMPDIR/fixture"
  git init -q -b main "$FIX"
  git -C "$FIX" config user.email test@example.com
  git -C "$FIX" config user.name "Test"
  git -C "$FIX" config commit.gpgsign false
  git -C "$FIX" config core.hooksPath /dev/null
  CLOCK=1700000000
}

# --------------------------------------------------------------------------------------------------------------
# Fixture helpers
# --------------------------------------------------------------------------------------------------------------

# commit_file <subject> [<body>] : add a new, uniquely named file and commit it, with a strictly increasing commit
# date so "newest first" is deterministic. Real file changes (not empty commits) so that rebase and cherry-pick
# replay them instead of dropping them, and unique names so they never conflict. Do not call inside $( ): CLOCK
# must advance in the test's own shell. Read the new commit with head_sha.
commit_file() {
  CLOCK=$((CLOCK + 60))
  local when="$CLOCK +0000" name="f${CLOCK}.txt"
  printf '%s\n' "$1" >"$FIX/$name"
  git -C "$FIX" add "$name"
  if [ $# -ge 2 ]; then
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$FIX" commit -q -m "$1" -m "$2"
  else
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$FIX" commit -q -m "$1"
  fi
}

head_sha() { git -C "$FIX" rev-parse HEAD; }

# start_feature : a base commit on main, then a `feat` branch checked out from it.
start_feature() {
  commit_file "chore: base"
  git -C "$FIX" checkout -q -b feat
}

# patch_ids <sha>... : the sorted `git patch-id --stable` values of those commits.
patch_ids() {
  local s
  for s in "$@"; do
    git -C "$FIX" show "$s" | git patch-id --stable | cut -d' ' -f1
  done | sort
}

# resolve <args...> : run the resolver against the fixture. stdout in $output, stderr in $stderr.
resolve() { run --separate-stderr bash "$SCRIPT" "$@" --repo "$FIX"; }

# assert_resolved <sha>... : the last `resolve` succeeded and printed exactly these SHAs (any order). With no
# arguments it asserts an empty, successful result.
assert_resolved() {
  local want got
  want="$(printf '%s\n' "$@" | sort)"
  got="$(printf '%s\n' "$output" | sort)"
  if [ "$status" -ne 0 ] || [ "$want" != "$got" ]; then
    printf 'expected exit 0 and exactly:\n%s\n--- got (exit %s) ---\n%s\n' "$want" "$status" "$got"
    return 1
  fi
}

# --------------------------------------------------------------------------------------------------------------
# The fixtures are isolated from this repository and from the machine's git configuration
# --------------------------------------------------------------------------------------------------------------

@test "fixture lives under BATS_TEST_TMPDIR, apart from the working repository, with local identity and signing off" {
  local tmp top
  tmp="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  top="$(cd "$(git -C "$FIX" rev-parse --show-toplevel)" && pwd -P)"
  case "$top" in "$tmp"/*) ;; *) printf 'fixture toplevel %s is not under %s\n' "$top" "$tmp"; return 1 ;; esac
  [ "$top" != "$(cd "$REPO_ROOT" && pwd -P)" ]
  [ "$(git -C "$FIX" config --local user.email)" = "test@example.com" ]
  [ "$(git -C "$FIX" config --local user.name)" = "Test" ]
  [ "$(git -C "$FIX" config --local commit.gpgsign)" = "false" ]
  # Global and system config are hidden, so no machine-wide identity can be what makes these tests pass.
  [ "$GIT_CONFIG_GLOBAL" = "/dev/null" ]
  [ "$GIT_CONFIG_NOSYSTEM" = "1" ]
}

# --------------------------------------------------------------------------------------------------------------
# Mixed linear history (the baseline every rewrite below is compared against)
# --------------------------------------------------------------------------------------------------------------

@test "mixed linear history: EST, trailer and bare template commits interleave; only attributable ones resolve, newest first" {
  commit_file "task(E10_S01_T01): add retry";            local est1; est1="$(head_sha)"
  commit_file "ASD-001 add backoff" "Jenga-Task: E10_S01_T01"; local trl1; trl1="$(head_sha)"
  commit_file "ASD-001 tidy up";                          local bare; bare="$(head_sha)"
  commit_file "task(E10_S01_T01): add tests";            local est2; est2="$(head_sha)"
  commit_file "ASD-001 add docs" "Jenga-Task: E10_S01_T02, E10_S01_T01"; local trl2; trl2="$(head_sha)"
  commit_file "task(E10_S01_T02): other task";           local other; other="$(head_sha)"

  resolve E10_S01_T01
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s\n%s' "$trl2" "$est2" "$trl1" "$est1")" ]
  assert_output_not_contains "$bare"
  assert_output_not_contains "$other"
}

# --------------------------------------------------------------------------------------------------------------
# 1. Rebase
# --------------------------------------------------------------------------------------------------------------

@test "rebase: the rewritten SHAs resolve for the task, the pre-rebase SHAs do not, and the patches are unchanged" {
  start_feature
  commit_file "task(E10_S01_T01): add retry";                 local old_est; old_est="$(head_sha)"
  commit_file "ASD-001 add backoff" "Jenga-Task: E10_S01_T02"; local old_trl; old_trl="$(head_sha)"
  commit_file "ASD-001 tidy up";                               local old_bare; old_bare="$(head_sha)"
  local before; before="$(patch_ids "$old_est" "$old_trl")"

  git -C "$FIX" checkout -q main
  commit_file "chore: main moves on"
  git -C "$FIX" checkout -q feat
  git -C "$FIX" rebase -q main

  local new_bare new_trl new_est
  new_bare="$(git -C "$FIX" rev-parse feat)"
  new_trl="$(git -C "$FIX" rev-parse feat~1)"
  new_est="$(git -C "$FIX" rev-parse feat~2)"
  [ "$new_est" != "$old_est" ]
  [ "$new_trl" != "$old_trl" ]

  resolve E10_S01_T01
  assert_resolved "$new_est"
  assert_output_not_contains "$old_est"
  resolve E10_S01_T02
  assert_resolved "$new_trl"
  assert_output_not_contains "$old_trl"
  # The bare template commit was never attributable, before or after the rewrite.
  assert_output_not_contains "$new_bare"
  assert_output_not_contains "$old_bare"
  # Same set by patch-id, not by SHA.
  [ "$(patch_ids "$new_est" "$new_trl")" = "$before" ]
}

@test "rebase -i --autosquash: a fixup! commit is folded away, so the task keeps one commit per real change" {
  start_feature
  commit_file "task(E10_S01_T01): add retry";  local target; target="$(head_sha)"
  commit_file "task(E10_S01_T01): add tests"
  printf 'fix\n' >"$FIX/fix.txt"
  git -C "$FIX" add fix.txt
  git -C "$FIX" commit -q --fixup="$target"

  # Before the rewrite the fixup! subject names the task too, so it counts: three commits.
  resolve E10_S01_T01
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]

  GIT_SEQUENCE_EDITOR=true git -C "$FIX" rebase -q -i --autosquash main

  resolve E10_S01_T01
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  assert_output_not_contains "$target"
  [ -z "$(git -C "$FIX" log --all --format=%s | grep '^fixup!' || true)" ]
}

# --------------------------------------------------------------------------------------------------------------
# 2. Amend
# --------------------------------------------------------------------------------------------------------------

@test "amend: the amended commit is found and the pre-amend SHA is not, for EST and trailer commits alike" {
  commit_file "chore: base"
  commit_file "task(E10_S01_T01): add retry";                  local old_est; old_est="$(head_sha)"
  printf 'more\n' >"$FIX/more-est.txt"
  git -C "$FIX" add more-est.txt
  git -C "$FIX" commit -q --amend --no-edit
  local new_est; new_est="$(head_sha)"
  [ "$new_est" != "$old_est" ]

  commit_file "ASD-001 add backoff" "Jenga-Task: E10_S01_T02"; local old_trl; old_trl="$(head_sha)"
  printf 'more\n' >"$FIX/more-trl.txt"
  git -C "$FIX" add more-trl.txt
  git -C "$FIX" commit -q --amend --no-edit
  local new_trl; new_trl="$(head_sha)"
  [ "$new_trl" != "$old_trl" ]

  resolve E10_S01_T01
  assert_resolved "$new_est"
  assert_output_not_contains "$old_est"
  resolve E10_S01_T02
  assert_resolved "$new_trl"
  assert_output_not_contains "$old_trl"
}

@test "amend that rewords but keeps the id in the subject: still found, under the new SHA" {
  commit_file "chore: base"
  commit_file "task(E10_S01_T01): add retry"; local old; old="$(head_sha)"
  git -C "$FIX" commit -q --amend -m "task(E10_S01_T01): add retry with backoff"
  local new; new="$(head_sha)"

  resolve E10_S01_T01
  assert_resolved "$new"
  assert_output_not_contains "$old"
}

@test "amend that drops the id from a commit with no trailer: attribution is lost, and --require-nonempty says so" {
  commit_file "chore: base"
  commit_file "task(E10_S01_T01): add retry"
  git -C "$FIX" commit -q --amend -m "add retry"

  resolve E10_S01_T01
  assert_resolved
  resolve E10_S01_T01 --require-nonempty
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "E10_S01_T01"
}

@test "amend that moves the id into a Jenga-Task trailer: attribution is kept" {
  commit_file "chore: base"
  commit_file "task(E10_S01_T01): add retry"
  git -C "$FIX" commit -q --amend -m "ASD-001 add retry" -m "Jenga-Task: E10_S01_T01"
  local new; new="$(head_sha)"

  resolve E10_S01_T01
  assert_resolved "$new"
}

# --------------------------------------------------------------------------------------------------------------
# 3. Cherry-pick
# --------------------------------------------------------------------------------------------------------------

@test "cherry-pick: the copy and the original BOTH resolve (--all counts each as a separate commit), with equal patches" {
  start_feature
  commit_file "task(E10_S01_T01): add retry";                  local est; est="$(head_sha)"
  commit_file "ASD-001 add backoff" "Jenga-Task: E10_S01_T02"; local trl; trl="$(head_sha)"
  git -C "$FIX" checkout -q main
  commit_file "chore: main moves on"
  git -C "$FIX" cherry-pick "$est" "$trl" >/dev/null
  local copy_trl copy_est
  copy_trl="$(head_sha)"
  copy_est="$(git -C "$FIX" rev-parse HEAD~1)"
  [ "$copy_est" != "$est" ]
  [ "$copy_trl" != "$trl" ]

  # Documented, not fixed: a cherry-pick doubles the task's commit count while the original branch still exists.
  resolve E10_S01_T01
  assert_resolved "$est" "$copy_est"
  resolve E10_S01_T02
  assert_resolved "$trl" "$copy_trl"
  [ "$(patch_ids "$est")" = "$(patch_ids "$copy_est")" ]
  [ "$(patch_ids "$trl")" = "$(patch_ids "$copy_trl")" ]
}

@test "cherry-pick -x: the '(cherry picked from commit ...)' line does not hide the trailer or the EST id" {
  start_feature
  commit_file "task(E10_S01_T01): add retry";                  local est; est="$(head_sha)"
  commit_file "ASD-001 add backoff" "Jenga-Task: E10_S01_T02"; local trl; trl="$(head_sha)"
  git -C "$FIX" checkout -q main
  git -C "$FIX" cherry-pick -x "$est" "$trl" >/dev/null
  local copy_trl copy_est
  copy_trl="$(head_sha)"
  copy_est="$(git -C "$FIX" rev-parse HEAD~1)"
  assert_contains "$(git -C "$FIX" log -1 --format=%B "$copy_trl")" "(cherry picked from commit $trl)"

  resolve E10_S01_T01
  assert_resolved "$est" "$copy_est"
  resolve E10_S01_T02
  assert_resolved "$trl" "$copy_trl"
}

@test "cherry-pick with the original branch deleted: only the copy remains, and it still resolves" {
  start_feature
  commit_file "task(E10_S01_T01): add retry";                  local est; est="$(head_sha)"
  commit_file "ASD-001 add backoff" "Jenga-Task: E10_S01_T02"; local trl; trl="$(head_sha)"
  git -C "$FIX" checkout -q main
  git -C "$FIX" cherry-pick "$est" "$trl" >/dev/null
  local copy_trl copy_est
  copy_trl="$(head_sha)"
  copy_est="$(git -C "$FIX" rev-parse HEAD~1)"
  git -C "$FIX" branch -q -D feat

  resolve E10_S01_T01
  assert_resolved "$copy_est"
  assert_output_not_contains "$est"
  resolve E10_S01_T02
  assert_resolved "$copy_trl"
  assert_output_not_contains "$trl"
}

# --------------------------------------------------------------------------------------------------------------
# 4. Squash
#
# Open Decision 3 (commit-traceability-contract.md, section 7) turns on these outcomes. A squash-merge replaces the
# task's commits with ONE new commit, so the resolver can only find the task if that commit's message still names it.
# --------------------------------------------------------------------------------------------------------------

@test "squash: a squash commit that keeps the Jenga-Task trailer in its body is found, alone, once the task branch is gone" {
  start_feature
  commit_file "ASD-001 add retry" "Jenga-Task: E10_S01_T01"
  commit_file "ASD-001 add tests" "Jenga-Task: E10_S01_T01"
  git -C "$FIX" checkout -q main
  git -C "$FIX" merge -q --squash feat
  git -C "$FIX" commit -q -m "ASD-001 add retry (#12)" -m "Jenga-Task: E10_S01_T01"
  local squash; squash="$(head_sha)"
  git -C "$FIX" branch -q -D feat

  resolve E10_S01_T01
  assert_resolved "$squash"
  resolve E10_S01_T01 --require-nonempty
  assert_resolved "$squash"
}

@test "squash: a squash commit whose body lists the EST subjects is found through them" {
  start_feature
  commit_file "task(E10_S01_T01): add retry"
  commit_file "task(E10_S01_T01): add tests"
  git -C "$FIX" checkout -q main
  git -C "$FIX" merge -q --squash feat
  git -C "$FIX" commit -q -m "Add retry (#12)" -m "* task(E10_S01_T01): add retry
* task(E10_S01_T01): add tests"
  local squash; squash="$(head_sha)"
  git -C "$FIX" branch -q -D feat

  resolve E10_S01_T01
  assert_resolved "$squash"
}

@test "squash: a squash commit that DROPS the trailer is not found; --require-nonempty exits non-zero naming the id (Open Decision 3 trigger)" {
  start_feature
  commit_file "ASD-001 add retry" "Jenga-Task: E10_S01_T01"
  commit_file "ASD-001 add tests" "Jenga-Task: E10_S01_T01"
  git -C "$FIX" checkout -q main
  git -C "$FIX" merge -q --squash feat
  git -C "$FIX" commit -q -m "ASD-001 add retry (#12)"
  local squash; squash="$(head_sha)"
  git -C "$FIX" branch -q -D feat
  # The squash commit exists and holds the task's net change, yet nothing ties it to the task.
  [ "$(git -C "$FIX" show --stat --format= "$squash" | grep -c 'f[0-9]*\.txt')" -eq 2 ]

  # Documented, deliberately not papered over: the resolver cannot attribute the squash commit. Without the flag the
  # empty result is a silent success (today's behaviour); with it the loss is loud. This is the case Phase 3's
  # trailer-preservation work (and Open Decision 3, option B) exists to close.
  resolve E10_S01_T01
  assert_resolved
  resolve E10_S01_T01 --require-nonempty
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_contains "$stderr" "E10_S01_T01"
  assert_contains "$stderr" "no commit carries"
}

@test "squash: while the task branch still exists, --all finds the original commits (not the squash commit)" {
  start_feature
  commit_file "ASD-001 add retry" "Jenga-Task: E10_S01_T01";  local o1; o1="$(head_sha)"
  commit_file "ASD-001 add tests" "Jenga-Task: E10_S01_T01";  local o2; o2="$(head_sha)"
  git -C "$FIX" checkout -q main
  git -C "$FIX" merge -q --squash feat
  git -C "$FIX" commit -q -m "ASD-001 add retry (#12)"
  local squash; squash="$(head_sha)"

  resolve E10_S01_T01
  assert_resolved "$o1" "$o2"
  assert_output_not_contains "$squash"
}

# --------------------------------------------------------------------------------------------------------------
# 5. Fast-forward and 6. --no-ff
# --------------------------------------------------------------------------------------------------------------

@test "fast-forward merge: the task's commits resolve under their original SHAs and no merge commit is created" {
  start_feature
  commit_file "task(E10_S01_T01): add retry";                  local est; est="$(head_sha)"
  commit_file "ASD-001 add backoff" "Jenga-Task: E10_S01_T01"; local trl; trl="$(head_sha)"
  commit_file "ASD-001 tidy up";                               local bare; bare="$(head_sha)"
  git -C "$FIX" checkout -q main
  git -C "$FIX" merge -q --ff-only feat
  git -C "$FIX" branch -q -d feat
  [ "$(git -C "$FIX" rev-parse main)" = "$bare" ]
  [ "$(git -C "$FIX" rev-list --merges --count --all)" -eq 0 ]

  resolve E10_S01_T01
  assert_resolved "$est" "$trl"
  assert_output_not_contains "$bare"
}

@test "--no-ff merge: the task's commits resolve; the merge commit, even one naming the task, is excluded by --no-merges" {
  start_feature
  commit_file "task(E10_S01_T01): add retry";                  local est; est="$(head_sha)"
  commit_file "ASD-001 add backoff" "Jenga-Task: E10_S01_T01"; local trl; trl="$(head_sha)"
  git -C "$FIX" checkout -q main
  commit_file "chore: main moves on"
  git -C "$FIX" merge -q --no-ff --no-edit feat -m "merge: E10_S01_T01-add-retry into main" -m "Jenga-Task: E10_S01_T01"
  local merge; merge="$(head_sha)"
  git -C "$FIX" branch -q -d feat
  # A real merge commit with two parents.
  [ "$(git -C "$FIX" rev-list --parents -n 1 "$merge" | wc -w | tr -d ' ')" -eq 3 ]
  # Without --no-merges a message search WOULD find it; the resolver's exclusion is what keeps it out.
  local naive; naive="$(git -C "$FIX" log --all --extended-regexp --grep='E10_S01_T01([^0-9_]|$)' --pretty=format:%H)"
  assert_contains "$naive" "$merge"

  resolve E10_S01_T01
  assert_resolved "$est" "$trl"
  assert_output_not_contains "$merge"
}

# --------------------------------------------------------------------------------------------------------------
# Template-form subjects: never attributable by their ref
# --------------------------------------------------------------------------------------------------------------

@test "template-form subject with no trailer: not attributable to any task, and its ref is not a valid id" {
  commit_file "chore: base"
  commit_file "ASD-001 add retry"

  resolve E10_S01_T01
  assert_resolved
  resolve E10_S01_T01 --require-nonempty
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "E10_S01_T01"
  # The ref is a display label, never a trace key: asking for it is a usage error raised before git runs.
  resolve ASD-001
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "malformed id"
}

@test "two tasks sharing one ref (ASD-001) resolve independently by their trailers; story and epic ids do not collect task trailers" {
  commit_file "chore: base"
  commit_file "ASD-001 add retry" "Jenga-Task: E10_S01_T01";   local r1; r1="$(head_sha)"
  commit_file "ASD-001 add backoff" "Jenga-Task: E10_S01_T02"; local b1; b1="$(head_sha)"
  commit_file "ASD-001 tidy up" "Jenga-Task: E10_S01_T01";     local r2; r2="$(head_sha)"
  commit_file "ASD-001 add docs";                               local bare; bare="$(head_sha)"

  resolve E10_S01_T01
  assert_resolved "$r1" "$r2"
  resolve E10_S01_T02
  assert_resolved "$b1"
  resolve E10_S01_T03
  assert_resolved
  # Exact-value trailer matching plus id anchoring: a story or epic query does not sweep up its children.
  resolve E10_S01
  assert_resolved
  resolve E10
  assert_resolved
  assert_output_not_contains "$bare"
}

# --------------------------------------------------------------------------------------------------------------
# Rewrites over mixed history combine
# --------------------------------------------------------------------------------------------------------------

@test "rebase then amend over mixed history: only the final SHAs resolve, for an EST task and a trailer task" {
  start_feature
  commit_file "task(E10_S01_T01): add retry"
  commit_file "ASD-001 add backoff" "Jenga-Task: E10_S01_T02"
  local old_t01 old_t02
  old_t01="$(git -C "$FIX" rev-parse feat~1)"
  old_t02="$(head_sha)"
  git -C "$FIX" checkout -q main
  commit_file "chore: main moves on"
  git -C "$FIX" checkout -q feat
  git -C "$FIX" rebase -q main
  printf 'more\n' >"$FIX/more.txt"
  git -C "$FIX" add more.txt
  git -C "$FIX" commit -q --amend --no-edit
  local final_t02 final_t01
  final_t02="$(head_sha)"
  final_t01="$(git -C "$FIX" rev-parse feat~1)"

  resolve E10_S01_T01
  assert_resolved "$final_t01"
  assert_output_not_contains "$old_t01"
  resolve E10_S01_T02
  assert_resolved "$final_t02"
  assert_output_not_contains "$old_t02"
}
