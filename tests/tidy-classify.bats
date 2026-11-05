#!/usr/bin/env bats
#
# j.tidy's worktree/branch enumeration and content-based safety classifier (E56_S06_T01).
#
# ISOLATION - read this before adding a case.
# Every test builds its own throwaway git repository under $BATS_TEST_TMPDIR, with its own TMPDIR
# and with the global/system git config neutralised. NOTHING here runs against this repository's
# own worktrees, and nothing here removes a worktree or deletes a branch anywhere: the subject of
# this suite is read-only by contract. The "classifier mutates nothing" and "this suite leaves the
# real repository alone" cases below are the standing pins for that.
#
# This is load-bearing, not hygiene: a past incident (E72_S08_T02) had one session's mutation
# testing corrupt a sibling session's measurement mid-flight and produce a false pass.
#
load helpers/assertions

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CLASSIFY="$REPO_ROOT/skills/j-tidy/scripts/classify.sh"
TARGET_REF="$REPO_ROOT/skills/j-tidy/scripts/target-ref.sh"

setup() {
  BASE="$BATS_TEST_TMPDIR/venue"
  FIX="$BASE/repo"
  WTDIR="$BASE/wt"
  mkdir -p "$BASE/tmp" "$WTDIR"
  export TMPDIR="$BASE/tmp"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  unset GIT_DIR
  unset GIT_WORK_TREE
  LIVE_PID=""

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

# work <branch> <file> <content> [<from>] : a branch carrying one commit that touches <file>.
work() {
  local br="$1" f="$2" c="$3" from="${4:-main}"
  git -C "$FIX" checkout -q -b "$br" "$from"
  printf '%s\n' "$c" > "$FIX/$f"
  git -C "$FIX" add "$f"
  git -C "$FIX" commit -qm "$br work"
  git -C "$FIX" checkout -q main
}

# merge_plain <branch> : an ordinary merge, so the branch tip becomes an ancestor of main.
merge_plain() { git -C "$FIX" merge -q --no-ff -m "merge $1" "$1"; }

# squash_merge <branch> : how this project's board commits actually land on main. The branch's
# own commits are NOT in main afterwards, so the branch tip is not an ancestor of main.
squash_merge() {
  git -C "$FIX" merge -q --squash "$1" >/dev/null 2>&1 || true
  git -C "$FIX" commit -qm "task($1): squashed"
}

# move_main_on <file> : main gains an unrelated change, so a plain two-dot diff against any
# existing branch is non-empty. This is what makes the content test's intersection necessary.
move_main_on() {
  printf 'later\n' > "$FIX/$1"
  git -C "$FIX" add "$1"
  git -C "$FIX" commit -qm "main moves on"
}

add_wt() { git -C "$FIX" worktree add -q "$WTDIR/$1" "${2:-$1}"; }

# ---------------------------------------------------------------------------
# invocation helpers
# ---------------------------------------------------------------------------

classify()      { run --separate-stderr bash "$CLASSIFY" --repo "$FIX" --no-disk "$@"; }
classify_disk() { run --separate-stderr bash "$CLASSIFY" --repo "$FIX" "$@"; }

rec()      { printf '%s\n' "$output" | awk -F'\t' -v n="$1" '$2 == n { print }'; }
fld()      { rec "$1" | cut -f"$2"; }
verdict()  { fld "$1" 6; }
ahead()    { fld "$1" 7; }
bytes()    { fld "$1" 8; }
pop()      { fld "$1" 4; }
reason()   { fld "$1" 10; }

# ===========================================================================
# the scripts themselves
# ===========================================================================

@test "both scripts exist, are executable and pass bash -n" {
  [ -f "$CLASSIFY" ]
  [ -x "$CLASSIFY" ]
  [ -f "$TARGET_REF" ]
  [ -x "$TARGET_REF" ]
  run bash -n "$CLASSIFY"
  [ "$status" -eq 0 ]
  run bash -n "$TARGET_REF"
  [ "$status" -eq 0 ]
}

@test "shellcheck is clean at the default severity and at -S warning" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run shellcheck "$CLASSIFY" "$TARGET_REF"
  [ "$status" -eq 0 ]
  run shellcheck -S warning "$CLASSIFY" "$TARGET_REF"
  [ "$status" -eq 0 ]
}

@test "no bashism beyond bash 3.2 (no mapfile, no associative arrays, no case-modifying expansion)" {
  local f
  for f in "$CLASSIFY" "$TARGET_REF"; do
    run grep -nE '^[^#]*(mapfile|readarray|declare -A|\$\{[A-Za-z_][A-Za-z_0-9]*\^\^|\$\{[A-Za-z_][A-Za-z_0-9]*,,)' "$f"
    [ "$status" -ne 0 ]
  done
}

# ===========================================================================
# the single target-ref seam
# ===========================================================================

@test "target-ref.sh answers main for every population, executed and sourced" {
  local p
  for p in board-task bundle agent other; do
    run bash "$TARGET_REF" "$p" "some-name"
    [ "$status" -eq 0 ]
    [ "$output" = "main" ]
  done
  run bash -c ". '$TARGET_REF' && tidy_target_ref agent agent-abc123"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  run bash "$TARGET_REF" --default
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "target-ref.sh rejects an unknown population with exit 2 and prints nothing on stdout" {
  run --separate-stderr bash "$TARGET_REF" nonsense
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "unknown population"
}

@test "sourcing target-ref.sh prints nothing and creates nothing" {
  run bash -c ". '$TARGET_REF'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no other j-tidy script hardcodes the target ref - the seam is the only place it is written" {
  # The AC this pins: a classifier that scatters `main` across its comparisons fails E56_S06_T01
  # even when today's verdicts are right, because E56_S01 must be able to retarget by editing one
  # file. Comment lines are excluded; they discuss main by name on purpose.
  # Hardened by the E56_S06_T03 rework. The original pattern excluded `-` from the boundary class
  # and was case-sensitive, so `${TIDY_TARGET:-main}` (the most realistic way the ref gets
  # reintroduced) and `MAIN` both slipped past it, and the glob was *.sh so a new non-.sh script
  # was unpinned. Boundary is now [^A-Za-z0-9_], the match is -i, and the glob is *.
  local f offenders=""
  for f in "$REPO_ROOT"/skills/j-tidy/scripts/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in target-ref.sh) continue ;; esac
    if grep -vE '^[[:space:]]*#' "$f" | grep -qiE '(^|[^A-Za-z0-9_])main([^A-Za-z0-9_]|$)'; then
      offenders="$offenders $(basename "$f")"
    fi
  done
  if [ -n "$offenders" ]; then
    echo "these scripts name the target ref directly instead of calling tidy_target_ref:$offenders" >&2
    return 1
  fi
}

# ===========================================================================
# the four conditions
# ===========================================================================

@test "a clean already-merged worktree is reclaimable" {
  work plain-merged plain.txt plain
  merge_plain plain-merged
  add_wt plain-merged
  classify
  [ "$status" -eq 0 ]
  [ "$(verdict plain-merged)" = "reclaimable" ]
  [ "$(ahead plain-merged)" = "0" ]
  assert_contains "$(reason plain-merged)" "already merged into main"
}

@test "a squash-merged worktree is reclaimable even though main has moved on since" {
  work E01_S01_T01-squashed sq.txt sq
  squash_merge E01_S01_T01-squashed
  move_main_on unrelated.txt
  add_wt E01_S01_T01-squashed
  classify
  [ "$status" -eq 0 ]
  [ "$(verdict E01_S01_T01-squashed)" = "reclaimable" ]
  assert_contains "$(reason E01_S01_T01-squashed)" "squash-merged into main"
}

@test "the squash-merged case is exactly what an ancestry-only check gets wrong" {
  # This is the measurement the story rests on, reproduced as a fixture: ancestry says "not
  # merged" (which is how an ancestry-only classifier reported 0 of 228 reclaimable in this repo
  # on 2026-11-04), while the content test says "carries nothing unique".
  work E01_S01_T01-squashed sq.txt sq
  squash_merge E01_S01_T01-squashed
  move_main_on unrelated.txt
  add_wt E01_S01_T01-squashed

  run git -C "$FIX" merge-base --is-ancestor E01_S01_T01-squashed main
  [ "$status" -ne 0 ]                                   # ancestry: NOT merged
  run git -C "$FIX" rev-list --count main..E01_S01_T01-squashed
  [ "$output" -gt 0 ]                                   # and genuinely ahead

  classify
  [ "$(verdict E01_S01_T01-squashed)" = "reclaimable" ] # content: nothing unique
}

@test "a worktree with unmerged commits is retained, naming the content condition and the paths" {
  work E01_S01_T02-unmerged unmerged.txt secret
  add_wt E01_S01_T02-unmerged
  classify
  [ "$(verdict E01_S01_T02-unmerged)" = "retained" ]
  assert_contains "$(reason E01_S01_T02-unmerged)" "carries content not in main"
  assert_contains "$(reason E01_S01_T02-unmerged)" "unmerged.txt"
}

@test "a worktree with a modified tracked file is retained" {
  work plain-merged plain.txt plain
  merge_plain plain-merged
  add_wt plain-merged
  printf 'dirty\n' > "$WTDIR/plain-merged/base.txt"
  classify
  [ "$(verdict plain-merged)" = "retained" ]
  assert_contains "$(reason plain-merged)" "dirty working tree"
  assert_contains "$(reason plain-merged)" "modified=1"
}

@test "a worktree with only untracked files is retained - untracked counts as dirty" {
  work plain-merged plain.txt plain
  merge_plain plain-merged
  add_wt plain-merged
  printf 'junk\n' > "$WTDIR/plain-merged/junk.txt"
  classify
  [ "$(verdict plain-merged)" = "retained" ]
  assert_contains "$(reason plain-merged)" "untracked=1"
}

@test "a worktree with a live process inside it is retained, naming the liveness check" {
  work plain-merged plain.txt plain
  merge_plain plain-merged
  add_wt plain-merged

  ( cd "$WTDIR/plain-merged" && exec sleep 30 ) &
  LIVE_PID=$!

  # Wait for the shared liveness check to actually see it before asserting, so the case cannot
  # race the OS. The check is the same script the classifier calls.
  local i=0 seen=0
  while [ "$i" -lt 40 ]; do
    if ! "$REPO_ROOT/scripts/check-worktree-liveness.sh" "$WTDIR/plain-merged" >/dev/null 2>&1; then
      seen=1
      break
    fi
    i=$((i + 1))
    sleep 0.1
  done
  [ "$seen" -eq 1 ] || { echo "the liveness check never saw PID $LIVE_PID in the worktree" >&2; return 1; }

  classify
  [ "$(verdict plain-merged)" = "retained" ]
  assert_contains "$(reason plain-merged)" "liveness check exited"
}

@test "an indeterminate condition never yields reclaimable: no main in the repository at all" {
  local alt="$BASE/alt"
  git init -q -b master "$alt"
  git -C "$alt" config user.email test@example.com
  git -C "$alt" config user.name Test
  printf 'a\n' > "$alt/a.txt"
  git -C "$alt" add a.txt
  git -C "$alt" commit -qm a
  git -C "$alt" branch feature

  run --separate-stderr bash "$CLASSIFY" --repo "$alt" --no-disk
  [ "$status" -eq 0 ]
  assert_output_not_contains "reclaimable"
  assert_output_contains "target ref 'main' does not exist"
}

@test "the classifier refuses to run at all when the shared liveness script is unavailable" {
  # Condition 4 would be unevaluable, so nothing could be classified reclaimable. Fail closed and
  # loudly rather than silently degrading to a three-condition classifier.
  local stage="$BASE/stage"
  mkdir -p "$stage/skills/j-tidy/scripts" "$stage/scripts"
  cp "$CLASSIFY" "$TARGET_REF" "$stage/skills/j-tidy/scripts/"
  run --separate-stderr bash "$stage/skills/j-tidy/scripts/classify.sh" --repo "$FIX" --no-disk
  [ "$status" -eq 3 ]
  assert_contains "$stderr" "check-worktree-liveness.sh"
  assert_contains "$stderr" "Refusing to run"
}

# ===========================================================================
# enumeration, populations and the branch/worktree split
# ===========================================================================

@test "an agent-<hash> worktree with no board provenance is classified, not skipped" {
  # The whole reason this enumeration exists: /reconcile matches worktrees by task-ID slug, so it
  # cannot see this population at all, and it is the bulk of the measured 9.5 GB.
  work agent-deadbeef a.txt a
  merge_plain agent-deadbeef
  add_wt agent-deadbeef
  classify
  [ -n "$(rec agent-deadbeef)" ]
  [ "$(pop agent-deadbeef)" = "agent" ]
  [ "$(verdict agent-deadbeef)" = "reclaimable" ]
}

@test "populations are tagged board-task, bundle, agent and other" {
  work E02_S03_T04-slug one.txt one
  work bundle-E02_S03 two.txt two
  work agent-0a1b2c3d three.txt three
  work some-feature four.txt four
  classify
  [ "$(pop E02_S03_T04-slug)" = "board-task" ]
  [ "$(pop bundle-E02_S03)" = "bundle" ]
  [ "$(pop agent-0a1b2c3d)" = "agent" ]
  [ "$(pop some-feature)" = "other" ]
}

@test "a merged branch with no worktree is reclaimable independently of any worktree" {
  # The 350-vs-229 gap: more branches than worktrees, and the surplus is reclaimable on its own.
  work plain-merged plain.txt plain
  merge_plain plain-merged
  git -C "$FIX" branch orphan-merged plain-merged
  classify
  [ "$(fld orphan-merged 1)" = "branch" ]
  [ "$(fld orphan-merged 3)" = "-" ]
  [ "$(verdict orphan-merged)" = "reclaimable" ]
  assert_contains "$(reason orphan-merged)" "no worktree"
}

@test "a branch with no worktree carrying unmerged content is retained" {
  work orphan-unmerged orphan.txt orphan
  classify
  [ "$(fld orphan-unmerged 1)" = "branch" ]
  [ "$(verdict orphan-unmerged)" = "retained" ]
  assert_contains "$(reason orphan-unmerged)" "carries content not in main"
}

@test "a branch that has a worktree is reported once, as the worktree, not twice" {
  work plain-merged plain.txt plain
  merge_plain plain-merged
  add_wt plain-merged
  classify
  [ "$(printf '%s\n' "$output" | awk -F'\t' '$2 == "plain-merged"' | wc -l | tr -d ' ')" = "1" ]
  [ "$(fld plain-merged 1)" = "worktree" ]
}

@test "the primary checkout and the target ref itself are reported but structurally excluded" {
  git -C "$FIX" checkout -q -b work-branch
  classify
  # main now has no worktree, so it reaches the branch pass - and must never be reclaimable.
  [ "$(verdict main)" = "retained" ]
  assert_contains "$(reason main)" "excluded: is the target ref"
  assert_output_contains "excluded: primary checkout"
}

@test "a locked worktree is retained and says so" {
  work plain-merged plain.txt plain
  merge_plain plain-merged
  add_wt plain-merged
  git -C "$FIX" worktree lock "$WTDIR/plain-merged"
  classify
  [ "$(verdict plain-merged)" = "retained" ]
  assert_contains "$(reason plain-merged)" "locked worktree"
  git -C "$FIX" worktree unlock "$WTDIR/plain-merged"
}

# ===========================================================================
# output contract
# ===========================================================================

@test "per-entry disk usage is reported in bytes, and a branch with no worktree reports 0" {
  work plain-merged plain.txt plain
  merge_plain plain-merged
  git -C "$FIX" branch orphan-merged plain-merged
  add_wt plain-merged
  classify_disk
  [ "$status" -eq 0 ]
  local b
  b="$(bytes plain-merged)"
  case "$b" in ''|*[!0-9]*) echo "non-numeric byte count: '$b'" >&2; return 1 ;; esac
  [ "$b" -gt 0 ]
  [ "$(bytes orphan-merged)" = "0" ]
}

@test "--no-disk reports bytes as - instead of guessing" {
  work plain-merged plain.txt plain
  merge_plain plain-merged
  add_wt plain-merged
  classify
  [ "$(bytes plain-merged)" = "-" ]
}

@test "every record carries exactly ten TAB-separated fields and no empty field" {
  work E01_S01_T01-squashed sq.txt sq
  squash_merge E01_S01_T01-squashed
  work E01_S01_T02-unmerged unmerged.txt secret
  add_wt E01_S01_T01-squashed
  add_wt E01_S01_T02-unmerged
  git -C "$FIX" branch orphan-merged main
  classify
  run bash -c "printf '%s\n' \"\$1\" | awk -F'\t' 'NF != 10 { print \"bad field count \" NF \": \" \$0; bad=1 } { for (i = 1; i <= NF; i++) if (\$i == \"\") { print \"empty field \" i \": \" \$0; bad=1 } } END { exit bad }'" _ "$output"
  [ "$status" -eq 0 ]
}

@test "--header labels the fields and is off by default" {
  classify
  assert_output_not_contains "#kind"
  classify --header
  assert_output_contains "#kind"
  assert_output_contains "reason"
}

@test "usage errors exit 2 and an unknown flag is not silently ignored" {
  run --separate-stderr bash "$CLASSIFY" --nonsense
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$CLASSIFY" --repo "$BASE/not-a-directory"
  [ "$status" -eq 2 ]
}

# ===========================================================================
# read-only, and this suite's own blast radius
# ===========================================================================

@test "the classifier mutates nothing: worktrees, branches, ref SHAs and working trees are identical afterwards" {
  work plain-merged plain.txt plain
  merge_plain plain-merged
  work E01_S01_T02-unmerged unmerged.txt secret
  add_wt plain-merged
  add_wt E01_S01_T02-unmerged
  printf 'junk\n' > "$WTDIR/E01_S01_T02-unmerged/junk.txt"

  local before_wt before_refs before_status
  before_wt="$(git -C "$FIX" worktree list --porcelain)"
  before_refs="$(git -C "$FIX" for-each-ref --format='%(refname) %(objectname)')"
  before_status="$(git -C "$FIX" -C "$WTDIR/E01_S01_T02-unmerged" status --porcelain)"

  classify_disk
  [ "$status" -eq 0 ]

  [ "$(git -C "$FIX" worktree list --porcelain)" = "$before_wt" ]
  [ "$(git -C "$FIX" for-each-ref --format='%(refname) %(objectname)')" = "$before_refs" ]
  [ "$(git -C "$WTDIR/E01_S01_T02-unmerged" status --porcelain)" = "$before_status" ]
  [ -d "$WTDIR/plain-merged" ]
  [ -f "$WTDIR/E01_S01_T02-unmerged/junk.txt" ]
}

@test "this suite leaves the real repository's worktrees and branches alone" {
  local before_wt before_br
  before_wt="$(git -C "$REPO_ROOT" worktree list --porcelain)"
  before_br="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' refs/heads)"
  work plain-merged plain.txt plain
  merge_plain plain-merged
  add_wt plain-merged
  classify_disk
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO_ROOT" worktree list --porcelain)" = "$before_wt" ]
  [ "$(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' refs/heads)" = "$before_br" ]
}
