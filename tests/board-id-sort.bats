#!/usr/bin/env bats
#
# E86_S02_T01: the numeric board-ID ordering. scripts/lib/board_ids.py (board_id_sort_key) and
# scripts/lib/board-ids.sh (board_id_sort) must both reproduce every "expected" list in
# tests/fixtures/board-id-sort-cases.json exactly. The same case file is the contract for the JavaScript form
# (E86_S02_T02). Nothing here touches the sort sites of other scripts.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CASES="$REPO/tests/fixtures/board-id-sort-cases.json"
  PYLIB="$REPO/scripts/lib"
  SHLIB="$REPO/scripts/lib/board-ids.sh"
  CASEDIR="$BATS_TEST_TMPDIR/cases"
  mkdir -p "$CASEDIR"
  # Split the case file into in.<n> and exp.<n> (one name per line); prints the case count.
  N="$(python3 - "$CASES" "$CASEDIR" <<'PY'
import json, sys
cases = json.load(open(sys.argv[1], encoding="utf-8"))
for i, c in enumerate(cases):
    open(f"{sys.argv[2]}/in.{i}", "w", encoding="utf-8").write("".join(n + "\n" for n in c["input"]))
    open(f"{sys.argv[2]}/exp.{i}", "w", encoding="utf-8").write("".join(n + "\n" for n in c["expected"]))
print(len(cases))
PY
)"
}

@test "case file holds at least 6 pairs and covers every rule" {
  [ "$N" -ge 6 ]
  # numeric epics, stories and tasks past 99
  grep -q '"E1001"' "$CASES"
  grep -q '"E10_S100"' "$CASES"
  grep -q '"E10_S1_T100"' "$CASES"
  # filenames order by ID not slug, a missing deeper segment first, non-IDs last, ties by text
  grep -q '"E10_zzz.md"' "$CASES"
  grep -q '"E100_a.md"' "$CASES"
  grep -q '"README.md"' "$CASES"
  grep -q '"E001.md"' "$CASES"
  # every pair is a permutation of its input (the expected list is only a reordering)
  run python3 - "$CASES" <<'PY'
import json, sys
for c in json.load(open(sys.argv[1], encoding="utf-8")):
    assert sorted(c["input"]) == sorted(c["expected"]), c
PY
  [ "$status" -eq 0 ]
}

@test "python board_id_sort_key reproduces every expected list" {
  run python3 - "$PYLIB" "$CASES" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import board_ids
bad = 0
for c in json.load(open(sys.argv[2], encoding="utf-8")):
    got = sorted(c["input"], key=board_ids.board_id_sort_key)
    if got != c["expected"]:
        bad += 1
        print("MISMATCH", c["input"], "->", got, "expected", c["expected"])
sys.exit(1 if bad else 0)
PY
  [ "$status" -eq 0 ]
}

@test "shell board_id_sort reproduces every expected list" {
  i=0
  while [ "$i" -lt "$N" ]; do
    run bash -c '. "$1"; board_id_sort < "$2"' _ "$SHLIB" "$CASEDIR/in.$i"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$CASEDIR/exp.$i")" ]
    i=$((i + 1))
  done
}

@test "shell board_id_sort also reproduces every expected list under /bin/bash (bash 3.2 on macOS)" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  i=0
  while [ "$i" -lt "$N" ]; do
    run /bin/bash -c '. "$1"; board_id_sort < "$2"' _ "$SHLIB" "$CASEDIR/in.$i"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$CASEDIR/exp.$i")" ]
    i=$((i + 1))
  done
}

@test "shell sorting is independent of the caller's locale and handles empty input and a missing final newline" {
  run bash -c '. "$1"; printf "" | board_id_sort' _ "$SHLIB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env LC_ALL=en_US.UTF-8 bash -c '. "$1"; printf "E10_b.md\nE9_a.md\nREADME.md\nE100" | board_id_sort' _ "$SHLIB"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'E9_a.md\nE10_b.md\nE100\nREADME.md')" ]
}

@test "python and shell agree on a wider generated list" {
  list="$BATS_TEST_TMPDIR/wide.txt"
  python3 - "$list" <<'PY'
import random, sys
random.seed(86)
names = []
for e in (1, 2, 9, 10, 11, 99, 100, 101, 1001):
    names += [f"E{e}", f"E{e}_x.md"]
    for s in (1, 2, 10, 100):
        names += [f"E{e}_S{s}", f"E{e}_S{s}_slug.md"]
        for t in (1, 2, 10, 100):
            names += [f"E{e}_S{s}_T{t}", f"E{e}_S{s}_T{t}_slug.md"]
names += ["README.md", "notes.txt", "E10x.md", "E10_S1x.md", "E01", "E001"]
random.shuffle(names)
open(sys.argv[1], "w").write("".join(n + "\n" for n in names))
PY
  py="$(python3 - "$PYLIB" "$list" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import board_ids
names = open(sys.argv[2]).read().split("\n")[:-1]
print("\n".join(sorted(names, key=board_ids.board_id_sort_key)))
PY
)"
  run bash -c '. "$1"; board_id_sort < "$2"' _ "$SHLIB" "$list"
  [ "$status" -eq 0 ]
  [ "$output" = "$py" ]
}

# Keeps the board file names whose leading ID segments (E, S and T) are all exactly three characters (a letter and
# two digits). The ID shape is matched width-agnostically (E[0-9]+), and the width is then compared on the segment
# text with awk, so no strict two-digit ID regex appears in this file (E86 Definition of Done).
equal_width_names() {
  grep -E '^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?_' | awk -F_ '{
    ok = 1
    for (i = 1; i <= NF; i++) { if ($i !~ /^[EST][0-9]+$/) break; if (length($i) != 3) ok = 0 }
    if (ok) print }' || true
}

@test "on two-digit equal-width board listings, numeric order equals plain text order" {
  for dir in epics stories tasks; do
    names="$(cd "$REPO/project/board/$dir" && ls | equal_width_names)"
    [ -n "$names" ] || continue
    text="$(printf '%s\n' "$names" | LC_ALL=C sort)"
    shell_out="$(printf '%s\n' "$names" | bash -c '. "$1"; board_id_sort' _ "$SHLIB")"
    [ "$shell_out" = "$text" ]
    py_out="$(printf '%s\n' "$names" | python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import board_ids
names = sys.stdin.read().split("\n")[:-1]
print("\n".join(sorted(names, key=board_ids.board_id_sort_key)))' "$PYLIB")"
    [ "$py_out" = "$text" ]
  done
  # the epics directory is exactly the case the task names: it must have been checked, not skipped
  [ -n "$(ls "$REPO/project/board/epics" | equal_width_names | head -1)" ]
}

@test "importing the python module and sourcing the shell file print nothing; python still imports only re" {
  run python3 -c "import sys; sys.path.insert(0, '$PYLIB'); import board_ids"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  imports="$(grep -E '^(import|from) ' "$PYLIB/board_ids.py")"
  [ "$imports" = "import re" ]
  for opts in "set +e +u" "set -eu"; do
    run bash -c "$opts; before=\$-; . '$SHLIB'; after=\$-; [ \"\$before\" = \"\$after\" ] && echo same"
    [ "$status" -eq 0 ]
    [ "$output" = "same" ]
  done
  run bash -c ". '$SHLIB'"
  [ -z "$output" ]
}

@test "the sort uses no sort -V and no GNU-only flags" {
  run grep -nE 'sort[^|]* -V|sort[^|]* --version-sort|gawk|--stable' "$SHLIB"
  [ "$status" -eq 1 ]
}
