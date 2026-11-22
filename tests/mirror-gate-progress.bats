#!/usr/bin/env bats
# bats file_tags=tier:fast
#
# Coverage for the [i/N] progress output of mirror.sh's check_test_subject_invariant
# (E77_S06_T07), written by E77_S06_T09. Since E95_S02_T08 the gate runs files several at a
# time (scripts/parallel-files.sh), so a progress line is printed as each file FINISHES
# (completion order, with its status and seconds), and tier:manual files are skipped and named.
#
# Follows the pattern of tests/mirror-never-public-refs.bats: every scenario runs a COPY of
# mirror.sh (plus its assets and the shared rule scripts) inside a throwaway git repo under
# $BATS_FILE_TMPDIR, with a SYNTHETIC .publicignore and a SYNTHETIC ship set. The shipping
# tests are three trivial fixture .bats files. The real repo, its real .publicignore and the
# real suite are never read or modified, and every push goes to a fresh LOCAL bare remote
# (MIRROR_PUBLIC_URL_OVERRIDE) with a private scratch worktree. The gate is skipped under bats
# unless MIRROR_TEST_SUBJECT_GATE=1, so every run below sets it; it launches only the three
# fixture files, never the real suite. A fourth fixture, tests/d.bats, is tagged tier:manual and
# FAILS if run: a passing gate therefore proves it was skipped.
#
# setup_file runs each scenario once (passing, one failing file, and a COPY of mirror.sh with
# the progress line removed as the negative control) and the cases read the saved results.
# MGP_STRIP_PROGRESS=1 makes the passing and failing scenarios use the stripped copy too, which
# must turn the progress cases red.
#
# The subject is private-only tooling, so per .publicignore's rule "a test may never outlive its
# subject" each setup skips when the subject is not there. Blocked-skill names are not written
# literally. The nested-suite guard (JENGA_NESTED_SUITE_RUN, tests/helpers/nested-suite.bash) is
# respected: inside a nested suite run the gate would skip, so this file skips visibly.

load helpers/nested-suite

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
REAL_SKILL_DIR="$REPO_ROOT/skills/j-mirror-public"
OK_LINE="test-subject-invariant: all 3 shipping test file(s) pass in a mirror-shaped tree — OK"

# build_repo <name> <strip 0|1> <failing-file or empty>: a scratch repo with a copy of mirror.sh
build_repo() {
  local name="$1" strip="$2" failing="$3" dir="$BATS_FILE_TMPDIR/$1"
  mkdir -p "$dir/skills/j-mirror-public/scripts" "$dir/skills/j-mirror-public/assets" "$dir/scripts" "$dir/tests" \
    "$dir/templates/permission-levels"
  cp "$REAL_SKILL_DIR"/scripts/*.sh "$dir/skills/j-mirror-public/scripts/"
  cp "$REAL_SKILL_DIR"/assets/* "$dir/skills/j-mirror-public/assets/"
  cp "$REPO_ROOT/scripts/never-public-refs.sh" "$REPO_ROOT/scripts/npm-reach-files.sh" \
    "$REPO_ROOT/scripts/parallel-files.sh" "$dir/scripts/"
  mkdir -p "$dir/skills/j-test/scripts"
  cp "$REPO_ROOT/skills/j-test/scripts/manual-only.sh" "$dir/skills/j-test/scripts/"
  cp "$REPO_ROOT/templates/permission-levels/level-2-guarded.json" "$dir/templates/permission-levels/"
  printf '%s\n' '{"name":"fixture","version":"1.0.0","files":["skills/","agents/","hooks/","scripts/","templates/","lib/"]}' > "$dir/package.json"
  if [ "$strip" = "1" ]; then
    # the negative control: the same mirror.sh with the progress line removed, in the COPY only
    grep -vF '[$file_index/$shipped_count]' "$dir/skills/j-mirror-public/scripts/mirror.sh" > "$dir/mirror.stripped"
    mv "$dir/mirror.stripped" "$dir/skills/j-mirror-public/scripts/mirror.sh"
  fi
  printf '%s\n' '.git/' 'project/' '.mirror-worktrees/' > "$dir/.publicignore"
  printf '# readme\n' > "$dir/README.md"
  local t
  for t in a b c; do
    printf '#!/usr/bin/env bats\n@test "fixture %s ok" { true; }\n' "$t" > "$dir/tests/$t.bats"
  done
  printf '#!/usr/bin/env bats\n# bats file_tags=tier:manual\n@test "manual, must never run" { false; }\n' > "$dir/tests/d.bats"
  if [ -n "$failing" ]; then
    printf '#!/usr/bin/env bats\n@test "boom" { false; }\n' > "$dir/tests/$failing.bats"
  fi
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.invalid
  git -C "$dir" config user.name t
  git -C "$dir" add -A
  git -C "$dir" commit -q -m scratch
  git init --bare -q -b main "$BATS_FILE_TMPDIR/$name.git"
}

# push <name> <out-file>: run the repo's mirror.sh copy end to end against its local bare remote
push() {
  local name="$1" out="$2"
  env MIRROR_TEST_SUBJECT_GATE=1 MIRROR_PUBLIC_URL_OVERRIDE="$BATS_FILE_TMPDIR/$name.git" \
    MIRROR_WORKTREE_PATH_OVERRIDE="$BATS_FILE_TMPDIR/$name-worktree" \
    bash "$BATS_FILE_TMPDIR/$name/skills/j-mirror-public/scripts/mirror.sh" > "$out" 2>&1
  echo "$?" > "$out.rc"
}

setup_file() {
  [ -f "$REAL_SKILL_DIR/scripts/mirror.sh" ] || skip "subject not shipped"
  skip_if_nested_suite_run "real push would start a nested suite run"
  set +e
  cksum < "$REPO_ROOT/.publicignore" > "$BATS_FILE_TMPDIR/pi.before"
  STRIP="${MGP_STRIP_PROGRESS:-0}"
  build_repo pass "$STRIP" ""
  push pass "$BATS_FILE_TMPDIR/pass.out"
  build_repo fail "$STRIP" b
  push fail "$BATS_FILE_TMPDIR/fail.out"
  build_repo control 1 ""
  push control "$BATS_FILE_TMPDIR/control.out"
  # the real .publicignore and tests/ are never touched: hash them around the scenarios
  cksum < "$REPO_ROOT/.publicignore" > "$BATS_FILE_TMPDIR/pi.after"
}

setup() {
  [ -f "$REAL_SKILL_DIR/scripts/mirror.sh" ] || skip "subject not shipped"
  D="$BATS_FILE_TMPDIR"
}

# PROGRESS_RE: one finished file's line, '[i/3] <file> ok|FAILED (exit s) <d>s (elapsed <m>m<s>s)'
PROGRESS_RE='test-subject-invariant: \[[1-3]/3\] tests/[abc]\.bats (ok|FAILED \(exit [0-9]+\)) [0-9]+s \(elapsed [0-9]+m[0-9]+s\)'

# progress_ok <out-file>: three progress lines (completion order), numbered 1, 2, 3 in that
# order, each naming a different one of a, b, c with its status, seconds and elapsed time
progress_ok() {
  local out="$1" lines
  lines="$(grep -E "$PROGRESS_RE" "$out")" || return 1
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = "3" ] || return 1
  [ "$(printf '%s\n' "$lines" | sed -E 's/.*\[([1-3])\/3\].*/\1/' | tr -d '\n')" = "123" ] || return 1
  [ "$(printf '%s\n' "$lines" | sed -E 's/.*\] (tests\/[abc]\.bats) .*/\1/' | sort | tr '\n' ' ')" = "tests/a.bats tests/b.bats tests/c.bats " ]
}

@test "E77_S06_T07: with 3 shipping files the gate prints [1/3] [2/3] [3/3] lines as files finish, each naming a different file" {
  progress_ok "$D/pass.out" || { echo "no ordered progress lines"; cat "$D/pass.out"; return 1; }
}

@test "E77_S06_T07: each progress line carries the file's status, its own seconds and the elapsed time as <m>m<s>s" {
  [ "$(grep -cE "$PROGRESS_RE" "$D/pass.out")" = "3" ]
  [ "$(grep -cE 'test-subject-invariant: \[[1-3]/3\] tests/[abc]\.bats ok [0-9]+s ' "$D/pass.out")" = "3" ]
  # E95_S02_T08: the gate says how many files run at once
  grep -qE 'test-subject-invariant: running 3 shipping test file\(s\) in a mirror-shaped tree, up to [0-9]+ at once' "$D/pass.out"
}

@test "E77_S06_T07: the progress line of a file is printed right before that file's failure line" {
  grep -q 'FAIL tests/b.bats' "$D/fail.out"
  progress="$(grep -nE '\[[1-3]/3\] tests/b\.bats FAILED \(exit 1\) ' "$D/fail.out" | head -1 | cut -d: -f1)"
  failure="$(grep -nF 'FAIL tests/b.bats' "$D/fail.out" | head -1 | cut -d: -f1)"
  [ -n "$progress" ]
  [ "$failure" -eq $((progress + 1)) ]
}

@test "E77_S06_T07: with one failing file of 3 the refusal still names exactly that file and its first not ok line, exit 1" {
  [ "$(cat "$D/fail.out.rc")" = "1" ]
  grep -qF 'test-subject-invariant: the following test file(s) ship to the public mirror but FAIL there:' "$D/fail.out"
  [ "$(grep -c '^  - tests/' "$D/fail.out")" = "1" ]
  grep -qF '  - tests/b.bats: not ok 1 boom' "$D/fail.out"
  grep -qF 'No rsync write, commit, or push has occurred.' "$D/fail.out"
  # a refusal pushes nothing
  run git --git-dir="$D/fail.git" show-ref
  [ "$status" -ne 0 ]
  # the progress lines are there on a failing run as well
  progress_ok "$D/fail.out"
}

@test "E77_S06_T07: an all-passing run still ends the gate with the existing OK line, byte for byte, and pushes" {
  [ "$(cat "$D/pass.out.rc")" = "0" ]
  # E95_S02_T08: the tier:manual fixture (which would fail) was skipped, and the skip is named in the log
  grep -qF 'test-subject-invariant: skipping 1 tier:manual file(s) (never run automatically):' "$D/pass.out"
  grep -qF 'test-subject-invariant:   skipped (tier:manual) tests/d.bats' "$D/pass.out"
  if grep -q 'tests/d.bats ok\|tests/d.bats FAILED\|FAIL tests/d.bats' "$D/pass.out"; then echo "tier:manual file ran"; return 1; fi
  [ "$(grep -cF "mirror.sh: $OK_LINE" "$D/pass.out")" = "1" ]
  run git --git-dir="$D/pass.git" show-ref
  [ "$status" -eq 0 ]
}

@test "E77_S06_T07: negative control: a copy of mirror.sh with the progress line removed prints no [i/N] line, so these cases would catch a regression" {
  # the stripped copy still runs the gate and passes it
  grep -qF "mirror.sh: $OK_LINE" "$D/control.out"
  [ "$(cat "$D/control.out.rc")" = "0" ]
  # but the progress cases' own check fails on its output
  if progress_ok "$D/control.out"; then
    echo "the progress check accepted an output with no progress lines"
    return 1
  fi
  [ "$(grep -c 'test-subject-invariant: \[' "$D/control.out")" = "0" ]
  # and the control copy no longer has the real script's progress line
  grep -qF '[$file_index/$shipped_count]' "$REAL_SKILL_DIR/scripts/mirror.sh"
  if grep -qF '[$file_index/$shipped_count]' "$D/control/skills/j-mirror-public/scripts/mirror.sh"; then
    echo "the control copy still has the progress line"
    return 1
  fi
}

@test "E77_S06_T07: the real .publicignore is untouched by every scenario" {
  [ "$(cat "$D/pi.before")" = "$(cat "$D/pi.after")" ]
  # and the fixtures wrote nothing into the real tests/ directory
  [ -z "$(git -C "$REPO_ROOT" status --porcelain -- tests/a.bats tests/b.bats tests/c.bats tests/d.bats)" ]
}
