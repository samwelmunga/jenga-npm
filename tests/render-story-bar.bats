#!/usr/bin/env bats
#
# Coverage for scripts/render-story-bar.sh (E92_S06_T23): the after-story progress line, Proposal A of
# project/documentation/prototypes/E92_S06/bars-prototype.html.
#
# The renderer is fed hand-written board-progress JSON (the E92_S01 contract); it never reads the real board.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RSB="$REPO_ROOT/scripts/render-story-bar.sh"
LABELS="$REPO_ROOT/scripts/lib/progress-labels.sh"

setup() {
  unset NO_COLOR JENGA_PROGRESS_LANG LC_CTYPE COLUMNS
  export LANG="en_US.UTF-8"
  unset LC_ALL
  ESC=$'\033'
}

# mk <id> <done> <in_progress> <failed> <pending> <rejected> <unknown> <denominator>: a board-progress --story document.
mk() {
  printf '{"schema_version":1,"scope":{"type":"story","ids":["%s"]},"levels":{"tasks":{"counts":{},"totals":{"done":%s,"in_progress":%s,"failed":%s,"pending":%s,"rejected":%s,"unknown":%s,"denominator":%s}}},"warnings":[]}\n' "$@" > "$BATS_TEST_TMPDIR/in.json"
}
render() { bash "$RSB" --file "$BATS_TEST_TMPDIR/in.json" "$@"; }

# Longest visible line of the input on stdin: ANSI escapes removed, every character one cell.
maxw() { python3 -c 'import sys,re; print(max(len(re.sub(r"\x1b\[[0-9;]*m","",l.rstrip("\n"))) for l in sys.stdin))'; }

@test "executable, passes bash -n and prints its usage with --help" {
  [ -x "$RSB" ]
  bash -n "$RSB"
  run bash "$RSB" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"render-story-bar.sh [--id"* ]]
}

@test "all tasks done: a green star, a fully green bar and N/N · 100 %" {
  mk E92_S01 4 0 0 0 0 0 4
  run render --cols 80 --color never
  [ "$status" -eq 0 ]
  [ "$output" = "E92_S01  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━★ 4/4 · 100 %" ]
  run render --cols 80 --color always
  [ "$status" -eq 0 ]
  [[ "$output" == *"${ESC}[32m★${ESC}[0m"* ]]
  [[ "$output" == *"${ESC}[32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ESC}[0m"* ]]
  [[ "$output" != *"${ESC}[31m"* ]]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
}

@test "finished with a failed task: a RED star, red failed cells, not fully green, and a failed count" {
  mk E92_S03 3 0 1 0 0 0 4
  run render --cols 80 --color always
  [ "$status" -eq 0 ]
  [[ "$output" == *"${ESC}[31m★${ESC}[0m"* ]]
  [[ "$output" != *"${ESC}[32m★"* ]]
  [[ "$output" == *"${ESC}[32m"*"${ESC}[31m━"* ]]            # green cells, then red filled cells
  [[ "$output" != *"${ESC}[32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ESC}[0m"* ]]
  plain="$(printf '%s' "$output" | sed "s/${ESC}\[[0-9;]*m//g")"
  [[ "$plain" == *"3/4 · 75 %"* ]]
  [[ "$plain" == *"✕ 1 failed"* ]]
}

@test "an unfinished story gets a flag, not a star, with yellow in-progress cells, grey dashed pending cells and the count" {
  mk E92_S06 2 1 0 3 0 0 6
  run render --cols 100 --color always
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚑"* ]]
  [[ "$output" != *"★"* ]]
  [[ "$output" == *"${ESC}[33m━"* ]]
  [[ "$output" == *"${ESC}[90m╌"* ]]
  plain="$(printf '%s' "$output" | sed "s/${ESC}\[[0-9;]*m//g")"
  [[ "$plain" == *"2/6 · 33 %"* ]]
  [[ "$plain" == *"◉ 1 in progress"* ]]
}

@test "every bucket has its own colour: green, yellow, red and grey in one bar" {
  mk E1_S1 4 3 2 3 0 0 12
  run render --cols 100 --color always
  [[ "$output" == *"${ESC}[32m━"* ]]
  [[ "$output" == *"${ESC}[33m━"* ]]
  [[ "$output" == *"${ESC}[31m━"* ]]
  [[ "$output" == *"${ESC}[90m╌"* ]]
}

@test "optional counts appear in order: in progress, failed, ready, rejected, each only when above 0" {
  mk E1_S1 3 2 1 1 2 0 7
  run render --cols 120 --color never --ready 4
  plain="$output"
  [[ "$plain" == *"◉ 2 in progress  ✕ 1 failed  + 4 ready  ⊘ 2 rejected"* ]]
  mk E1_S1 3 0 0 1 0 0 4
  run render --cols 120 --color never
  [[ "$output" != *"◉"* && "$output" != *"✕"* && "$output" != *"⊘"* && "$output" != *"ready"* ]]
}

@test "failed is singular or plural in the label library's words (two failed tasks)" {
  mk E1_S1 2 0 2 0 0 0 4
  run render --cols 120 --color never
  [[ "$output" == *"✕ 2 failed"* ]]
  JENGA_PROGRESS_LANG=sv run render --cols 120 --color never
  [[ "$output" == *"✕ 2 misslyckade"* ]]
  mk E1_S1 3 0 1 0 0 0 4
  JENGA_PROGRESS_LANG=sv run render --cols 120 --color never
  [[ "$output" == *"✕ 1 misslyckad"* && "$output" != *"misslyckade"* ]]
}

@test "the bar is 8 to 30 cells: 30 on a wide terminal, never below 8 when it fits, shrinking in between" {
  mk E1_S1 4 0 0 0 0 0 4
  for cols in 40 50 60 80 120 200; do
    run render --cols "$cols" --color never
    n="$(printf '%s' "$output" | head -n 1 | python3 -c 'import sys; print(sys.stdin.read().count("━"))')"
    [ "$n" -ge 8 ] && [ "$n" -le 30 ] || { echo "cols=$cols cells=$n"; false; }
  done
  run render --cols 200 --color never
  [ "$(printf '%s' "$output" | python3 -c 'import sys; print(sys.stdin.read().count("━"))')" -eq 30 ]
  run render --cols 40 --color never
  [ "$(printf '%s' "$output" | python3 -c 'import sys; print(sys.stdin.read().count("━"))')" -eq 20 ]   # 40 - "E1_S1  " - star - " 4/4 · 100 %"
  # in between: wider terminal, wider bar (counts share the line, so the bar gives them room first)
  mk E1_S1 3 1 0 0 0 0 4
  run render --cols 60 --color never
  a="$(printf '%s' "$output" | head -n 1 | python3 -c 'import sys; l=sys.stdin.read(); print(l.count("━")+l.count("╌"))')"
  run render --cols 90 --color never
  b="$(printf '%s' "$output" | head -n 1 | python3 -c 'import sys; l=sys.stdin.read(); print(l.count("━")+l.count("╌"))')"
  [ "$a" -lt "$b" ]
}

@test "the cell counts add up to the bar width and a non-zero bucket is never invisible" {
  mk E1_S1 1 1 1 97 0 0 100
  run render --cols 80 --color always
  [[ "$output" == *"${ESC}[32m━"* && "$output" == *"${ESC}[33m━"* && "$output" == *"${ESC}[31m━"* && "$output" == *"${ESC}[90m╌"* ]]
  plain="$(printf '%s' "$output" | head -n 1 | sed "s/${ESC}\[[0-9;]*m//g")"
  n="$(printf '%s' "$plain" | python3 -c 'import sys; l=sys.stdin.read(); print(l.count("━")+l.count("╌"))')"
  [ "$n" -ge 8 ] && [ "$n" -le 30 ]
}

@test "counts wrap to a second line instead of truncating, and no line is wider than the terminal" {
  mk E1_S1 3 2 1 1 2 0 7
  for cols in 40 44 50 60 70 80; do
    run render --cols "$cols" --color never --ready 4
    [ "$(printf '%s\n' "$output" | maxw)" -le "$cols" ] || { echo "cols=$cols"; printf '%s\n' "$output"; false; }
    for want in "◉ 2 in progress" "✕ 1 failed" "+ 4 ready" "⊘ 2 rejected"; do
      [[ "$output" == *"$want"* ]] || { echo "cols=$cols missing $want"; printf '%s\n' "$output"; false; }
    done
  done
  run render --cols 50 --color never --ready 4
  [ "${#lines[@]}" -ge 2 ]
  [[ "${lines[1]}" == "       "[!\ ]* ]]   # continuation lines are indented under the bar (id E1_S1 + 2 spaces = 7)
}

@test "under 40 columns the output is text-only: no bar, no star, no flag" {
  mk E92_S01 4 0 0 0 0 0 4
  run render --cols 39 --color never
  [ "$output" = "E92_S01 4/4 · 100 %" ]
  mk E92_S03 3 0 1 0 0 0 4
  run render --cols 20 --color never
  [[ "$output" != *"━"* && "$output" != *"╌"* && "$output" != *"★"* && "$output" != *"⚑"* ]]
  [ "$(printf '%s\n' "$output" | maxw)" -le 20 ]
}

@test "NO_COLOR and a non-TTY stdout produce no escape sequence; --color always still forces colour" {
  mk E92_S03 3 1 1 0 0 0 5
  NO_COLOR=1 run render --cols 80
  [[ "$output" != *"$ESC"* ]]
  run render --cols 80 --color auto
  [[ "$output" != *"$ESC"* ]]                       # bats' stdout is not a TTY
  run render --cols 80 --color never
  [[ "$output" != *"$ESC"* ]]
  NO_COLOR=1 run render --cols 80 --color always
  [[ "$output" == *"$ESC"* ]]
}

@test "a non-UTF-8 locale prints ASCII only: no byte above 0x7f in any layout" {
  mk E1_S1 3 2 1 1 2 0 7
  for cols in 30 45 80; do
    LC_ALL=C run render --cols "$cols" --color always --ready 3
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' ')" = "0" ] || { echo "cols=$cols"; false; }
  done
  mk E92_S01 4 0 0 0 0 0 4
  LC_ALL=C run render --cols 80 --color never
  [ "$output" = "E92_S01  $(printf '#%.0s' $(seq 1 30))* 4/4 - 100 %" ]
  mk E92_S03 3 0 1 0 0 0 4
  LC_ALL=C run render --cols 80 --color never
  [[ "$output" == *"! 1 failed"* ]]
  [ "$(printf '%s\n' "$output" | maxw)" -le 80 ]
}

@test "width comes from --cols, then COLUMNS, then 80" {
  mk E1_S1 4 0 0 0 0 0 4
  run render --color never
  [ "$(printf '%s' "$output" | python3 -c 'import sys; print(sys.stdin.read().count("━"))')" -eq 30 ]
  COLUMNS=40 run render --color never
  [ "$(printf '%s' "$output" | python3 -c 'import sys; print(sys.stdin.read().count("━"))')" -eq 20 ]
  COLUMNS=30 run render --color never
  [ "$output" = "E1_S1 4/4 · 100 %" ]
  COLUMNS=30 run render --color never --cols 120
  [[ "$output" == *"━"* ]]                           # --cols wins over COLUMNS
}

@test "words come from the label library: a changed library word changes the line, Swedish is selectable" {
  mk E1_S1 2 1 1 0 1 0 5
  JENGA_PROGRESS_LANG=sv run render --cols 120 --color never --ready 2
  [[ "$output" == *"◉ 1 pågår"* && "$output" == *"✕ 1 misslyckad"* && "$output" == *"+ 2 redo"* && "$output" == *"⊘ 1 avvisade"* ]]
  TREE="$BATS_TEST_TMPDIR/tree"; mkdir -p "$TREE/scripts/lib"
  cp "$RSB" "$TREE/scripts/"
  python3 - "$LABELS" "$TREE/scripts/lib/progress-labels.sh" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
a = "en:sl_failed_one)  printf '%s\\n' 'failed'"
assert a in s
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(a, a.replace("'failed'", "'KAPUTT'")))
PY
  run bash "$TREE/scripts/render-story-bar.sh" --file "$BATS_TEST_TMPDIR/in.json" --cols 120 --color never
  [[ "$output" == *"✕ 1 KAPUTT"* ]]
}

@test "the renderer holds no status name and no label word of its own" {
  run grep -nE "Passed|Pending|In Progress|Failed|Merged|Blocked|Rejected" "$RSB"
  [ "$status" -ne 0 ]
  # the words that appear on the line are not literals in the code (comments excluded)
  run bash -c "grep -v '^[[:space:]]*#' '$RSB' | grep -nE \"'(failed|rejected|ready|in progress|misslyckad[e]?|avvisade|redo|pågår)'\""
  [ "$status" -ne 0 ]
}

@test "denominator 0 prints an all-dashed bar and a flag, without dividing by zero" {
  mk E1_S1 0 0 0 0 0 0 0
  run render --cols 80 --color never
  [ "$status" -eq 0 ]
  [[ "$output" == "E1_S1  "*"⚑ 0/0 · 0 %" ]]
  [[ "$output" != *"━"* && "$output" != *"★"* ]]
}

@test "--id overrides the scope id; a missing id is an error" {
  mk E92_S01 4 0 0 0 0 0 4
  run render --cols 80 --color never --id X_S9
  [[ "$output" == "X_S9  "* ]]
  printf '{"levels":{"tasks":{"totals":{"done":1,"in_progress":0,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":1}}}}' > "$BATS_TEST_TMPDIR/in.json"
  run --separate-stderr render --cols 80
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run render --cols 80 --id Z_S1 --color never
  [ "$status" -eq 0 ]
}

@test "bad input exits 2 with nothing on stdout" {
  printf 'not json' > "$BATS_TEST_TMPDIR/in.json"
  run --separate-stderr render --cols 80
  [ "$status" -eq 2 ]; [ -z "$output" ]; [ -n "$stderr" ]
  printf '{"levels":{"tasks":{"totals":{"done":-1}}}}' > "$BATS_TEST_TMPDIR/in.json"
  run --separate-stderr render --cols 80
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr bash "$RSB" --file /nonexistent
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$RSB" --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$RSB" --cols 0 --file "$BATS_TEST_TMPDIR/in.json"
  [ "$status" -eq 2 ]
}

@test "reads stdin when no --file is given, and prints exactly one newline-terminated line when nothing wraps" {
  mk E92_S01 4 0 0 0 0 0 4
  run bash -c "cat '$BATS_TEST_TMPDIR/in.json' | bash '$RSB' --cols 80 --color never | wc -l | tr -d ' '"
  [ "$output" = "1" ]
}

@test "the four new keys exist in both languages and in the JSON exporter" {
  for lang in en sv; do
    for k in sl_failed_one sl_failed_many sl_ready sl_rejected; do
      run bash -c ". '$LABELS'; progress_label $k $lang"
      [ "$status" -eq 0 ]; [ -n "$output" ]
    done
  done
  JENGA_PROGRESS_LANG=sv run bash "$REPO_ROOT/scripts/progress-labels-json.sh"
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin)["labels"]; assert d["sl_rejected"]=="avvisade" and d["sl_ready"]=="redo"'
  run grep -c 'E92_S06_T23' "$LABELS"
  [ "$output" -ge 2 ]
}
