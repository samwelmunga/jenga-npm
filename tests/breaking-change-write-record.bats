#!/usr/bin/env bats
#
# Coverage for skills/j-breaking-change/scripts/write-record.sh (E91_S01_T01).
#
# Every test runs in a sandbox tree built under BATS_TEST_TMPDIR: a copy of scripts/resolve-root.sh and
# skills/j-breaking-change/, a project/configs/workflow.json and fake epic files. The script finds its resolver at
# <root>/scripts/ and resolves the documentation path from the current directory, so no record ever lands in the live repo.

bats_require_minimum_version 1.5.0


REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  SB="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SB/scripts" "$SB/skills" "$SB/project/configs" "$SB/project/board/epics"
  cp "$REPO_ROOT/scripts/resolve-root.sh" "$SB/scripts/"
  cp -R "$REPO_ROOT/skills/j-breaking-change" "$SB/skills/"
  cp "$REPO_ROOT/project/configs/workflow.json" "$SB/project/configs/"
  WR="$SB/skills/j-breaking-change/scripts/write-record.sh"
  BD="$SB/project/documentation/breaking-changes"
  printf -- '---\nid: E1\ntitle: "Epic One: the \\"first\\""\n---\n' > "$SB/project/board/epics/E1_one.md"
  printf -- '---\nid: E10\ntitle: "Ten"\n---\n' > "$SB/project/board/epics/E10_ten.md"
  printf -- '---\nid: E34\ntitle: Thirty four\n---\n' > "$SB/project/board/epics/E34_x.md"
  cd "$SB"
}

file_count() { find "$SB" -type f | wc -l | tr -d ' '; }

@test "writes the record under the resolved documentation path (default tree)" {
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason "why" --epics E1,E34 --baseline v5.0.1
  [ "$status" -eq 0 ]
  [ "$output" = "$BD/v6.0.0.md" ]
  [ -f "$BD/v6.0.0.md" ]
}

@test "writes the record under a relocated paths.documentation" {
  sed -i.bak 's#"documentation": "project/documentation"#"documentation": "internal/notes"#' "$SB/project/configs/workflow.json"
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason "why" --epics E1
  [ "$status" -eq 0 ]
  [ "$output" = "$SB/internal/notes/breaking-changes/v6.0.0.md" ]
  [ -f "$SB/internal/notes/breaking-changes/v6.0.0.md" ]
  [ ! -e "$SB/project/documentation" ]
}

@test "record has version, UTC date, baseline, epics, verbatim reason and one line per epic" {
  reason=$'Reason: with "quotes" and \\ back\nsecond line   spaced'
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason "$reason" --epics E1,E34 --baseline v5.0.1 --details "det: x"
  [ "$status" -eq 0 ]
  f="$BD/v6.0.0.md"
  [ "$(sed -n 1p "$f")" = "---" ]
  [ "$(sed -n 2p "$f")" = "version: v6.0.0" ]
  [ "$(sed -n 3p "$f")" = "date: $(date -u +%Y-%m-%d)" ]
  [ "$(sed -n 4p "$f")" = "baseline: v5.0.1" ]
  [ "$(sed -n 5p "$f")" = "epics: E1, E34" ]
  got="$(awk '/^## Reason$/{r=1;next} /^## Affected epics$/{r=0} r' "$f")"
  [ "$got" = "$(printf '\n%s\n' "$reason")" ]
  epics="$(awk '/^## Affected epics$/{r=1;next} /^## Details$/{r=0} r && /^E[0-9]+ - /' "$f")"
  [ "$epics" = "$(printf 'E1 - Epic One: the "first"\nE34 - Thirty four')" ]
}

@test "an unknown epic id exits 4 and creates nothing" {
  before="$(file_count)"
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason r --epics E999
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [ "$(file_count)" = "$before" ]
}

@test "E1 does not match E10_x.md (trailing underscore rule)" {
  rm "$SB/project/board/epics/E1_one.md"
  before="$(file_count)"
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason r --epics E1
  [ "$status" -eq 4 ]
  [ "$(file_count)" = "$before" ]
}

@test "an empty or blank reason exits 2 and creates nothing" {
  before="$(file_count)"
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason "" --epics E1
  [ "$status" -eq 2 ]
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason $'  \n\t' --epics E1
  [ "$status" -eq 2 ]
  [ "$(file_count)" = "$before" ]
}

@test "a malformed version exits 2 and creates nothing" {
  before="$(file_count)"
  for v in 6.0.0 v6 v6.0 v6.0.0. v6.0.0- 'v6.0.0 ' 'v6.0.0/../x' '../v6.0.0' V6.0.0; do
    run --separate-stderr /bin/bash "$WR" --version "$v" --reason r --epics E1
    [ "$status" -eq 2 ]
  done
  [ "$(file_count)" = "$before" ]
}

@test "a version containing a newline is malformed: exits 2 and creates nothing" {
  before="$(file_count)"
  run --separate-stderr /bin/bash "$WR" --version $'v6.0.0\njunk' --reason r --epics E1
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(file_count)" = "$before" ]
}

@test "a baseline containing a newline is refused and cannot inject header lines" {
  before="$(file_count)"
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason r --epics E1 --baseline $'v5.0.0\nepics: E999'
  [ "$status" -eq 2 ]
  [ "$(file_count)" = "$before" ]
}

@test "a second call without --replace exits 5 and leaves the record byte-identical" {
  /bin/bash "$WR" --version v6.0.0 --reason orig --epics E1 >/dev/null
  sum="$(cksum < "$BD/v6.0.0.md")"
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason changed --epics E10
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [ "$(cksum < "$BD/v6.0.0.md")" = "$sum" ]
  [ "$(ls -A "$BD")" = "v6.0.0.md" ]
}

@test "--replace overwrites an existing record" {
  /bin/bash "$WR" --version v6.0.0 --reason orig --epics E1 >/dev/null
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason changed --epics E10 --replace
  [ "$status" -eq 0 ]
  grep -q '^changed$' "$BD/v6.0.0.md"
  grep -q '^E10 - Ten$' "$BD/v6.0.0.md"
  [ "$(ls -A "$BD")" = "v6.0.0.md" ]
}

@test "success prints exactly one stdout line and nothing on stderr" {
  run --separate-stderr /bin/bash "$WR" --version v6.0.0-rc.1 --reason r --epics E1
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ -z "$stderr" ]
}

@test "a reserved heading inside the reason is refused (exit 2)" {
  run --separate-stderr /bin/bash "$WR" --version v6.0.0 --reason $'a\n## Details\nb' --epics E1
  [ "$status" -eq 2 ]
  [ ! -e "$BD" ]
}

@test "the script parses and shellcheck is clean" {
  /bin/bash -n "$WR"
  if command -v shellcheck >/dev/null 2>&1; then shellcheck "$WR"; fi
}
