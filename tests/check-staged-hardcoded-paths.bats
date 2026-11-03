#!/usr/bin/env bats
#
# scripts/check-staged-hardcoded-paths.sh against a throwaway git repository. The real repository is only read
# (the last test runs the script over this repository's own staged diff and asserts only that it can run).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-staged-hardcoded-paths.sh"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  cd "$PROJ" || return 1
  git init -q -b main
  git config user.email t@example.com
  git config user.name t
  git commit -q --allow-empty -m init
}

stage() { # <path> <content>
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
  git add -- "$1"
}

@test "a clean staged change passes silently" {
  stage lib.sh 'ROOT="$(git rev-parse --show-toplevel)"'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "nothing staged passes" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "a hardcoded macOS home path is reported with file and line" {
  stage run.sh $'echo hi\ncd /Users/bob/work/proj'  # allow-hardcoded-path
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q 'run.sh:2: cd /Users/bob/work/proj' <<<"$output"  # allow-hardcoded-path
  grep -q 'added line(s) hardcode' <<<"$output"
}

@test "a Linux home path, a Windows user path and an absolute file URI are each reported" {
  stage a.js 'const p = "/home/runner/work/x"'  # allow-hardcoded-path
  stage b.js 'const p = "C:\Users\alice\x"'  # allow-hardcoded-path
  stage c.js 'const u = "file:///opt/app/index.html"'  # allow-hardcoded-path
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  grep -q 'a.js:1' <<<"$output"
  grep -q 'b.js:1' <<<"$output"
  grep -q 'c.js:1' <<<"$output"
}

@test "the allow marker skips an intentional literal" {
  stage fixture.sh 'P=/Users/bob/x # allow-hardcoded-path'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Markdown, the board, the site and the mirrors are not scanned" {
  stage notes.md 'see /Users/bob/x'  # allow-hardcoded-path
  stage project/board/tasks/T.md 'path /home/bob/x'  # allow-hardcoded-path
  stage site/reference/a.md 'path /Users/bob/x'  # allow-hardcoded-path
  stage .claude/scripts/s.sh 'cd /Users/bob/x'  # allow-hardcoded-path
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "only added lines count: an existing literal that a later commit leaves alone is not reported" {
  stage old.sh 'cd /Users/bob/x'  # allow-hardcoded-path
  git commit -q -m "add old"
  printf 'cd /Users/bob/x\necho new\n' > old.sh  # allow-hardcoded-path
  git add old.sh
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "relative paths, /tmp and an https URI are fine" {
  stage ok.sh $'cd "$ROOT/scripts"\nT=/tmp/work\ncurl https://example.com/Users/x/'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "outside a git repository it passes instead of failing the commit gate" {
  cd "$BATS_TEST_TMPDIR"
  mkdir -p norepo && cd norepo
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the script does not flag its own source" {
  mkdir -p "$PROJ/scripts"
  cp "$SCRIPT" "$PROJ/scripts/check-staged-hardcoded-paths.sh"
  git add scripts/check-staged-hardcoded-paths.sh
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}
