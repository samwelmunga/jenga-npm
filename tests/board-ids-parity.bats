#!/usr/bin/env bats
#
# E86_S01_T01: the Python and shell board-ID shapes must agree on every case in tests/fixtures/board-id-cases.txt,
# and both must be reachable from the monorepo layout and from node_modules/@jenga-ai/agent/. Line format of the
# fixture: <accept|reject> TAB <string> TAB <epic|story|task|->.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CASES="$REPO/tests/fixtures/board-id-cases.txt"
  PYLIB="$REPO/scripts/lib"
  SHLIB="$REPO/scripts/lib/board-ids.sh"
}

# Prints "<verdict>|<kind>" per fixture line (verdict from the string alone, ignoring the expected columns).
py_verdicts() { # <lib dir>
  python3 - "$1" "$CASES" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import board_ids
for line in open(sys.argv[2], encoding="utf-8").read().split("\n"):
    if not line:
        continue
    s = line.split("\t")[1]
    k = board_ids.classify(s)
    print(("accept" if k else "reject") + "|" + (k or "-"))
PY
}

sh_verdicts() { # <board-ids.sh path>
  bash -c '
    . "$1"
    while IFS= read -r line || [ -n "$line" ]; do
      rest=${line#*$'"'"'\t'"'"'}; id=${rest%$'"'"'\t'"'"'*}
      if k=$(board_id_kind "$id"); then printf "accept|%s\n" "$k"; else printf "reject|-\n"; fi
    done < "$2"
  ' _ "$1" "$CASES"
}

expected() { while IFS= read -r line || [ -n "$line" ]; do
  v=${line%%$'\t'*}; k=${line##*$'\t'}; printf '%s|%s\n' "$v" "$k"; done < "$CASES"; }

@test "fixture has the required accepts and rejects" {
  for s in E1 E01 E99 E100 E1001 E01_S01 E100_S100 E1001_S100_T100; do
    grep -qF "$(printf 'accept\t%s\t' "$s")" "$CASES"
  done
  for s in "" E E1_ E01_T01 e01 E01_S S01 E01_S01_T01_x "E01 " E01__S01; do
    grep -qF "$(printf 'reject\t%s\t-' "$s")" "$CASES"
  done
}

@test "python module matches the fixture's expected verdict and kind on every line" {
  run py_verdicts "$PYLIB"
  [ "$status" -eq 0 ]
  [ "$output" = "$(expected)" ]
}

@test "shell file matches the fixture's expected verdict and kind on every line" {
  run sh_verdicts "$SHLIB"
  [ "$status" -eq 0 ]
  [ "$output" = "$(expected)" ]
}

@test "python and shell agree line for line" {
  py="$(py_verdicts "$PYLIB")"
  sh="$(sh_verdicts "$SHLIB")"
  [ -n "$py" ]
  [ "$py" = "$sh" ]
}

@test "both work from the monorepo layout and the node_modules layout, from an unrelated cwd" {
  for root in "$BATS_TEST_TMPDIR/mono" "$BATS_TEST_TMPDIR/consumer/node_modules/@jenga-ai/agent"; do
    mkdir -p "$root/scripts/lib"
    cp "$PYLIB/board_ids.py" "$PYLIB/board-ids.sh" "$root/scripts/lib/"
  done
  # The documented caller snippets resolve against a project root that holds one of the two layouts.
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"; cd "$BATS_TEST_TMPDIR/elsewhere"
  for proj in "$BATS_TEST_TMPDIR/mono" "$BATS_TEST_TMPDIR/consumer"; do
    run python3 - "$proj" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
for _p in (root / "scripts" / "lib", root / "node_modules" / "@jenga-ai" / "agent" / "scripts" / "lib"):
    if (_p / "board_ids.py").is_file():
        sys.path.insert(0, str(_p))
        break
import board_ids
assert board_ids.classify("E01_S01") == "story", "python import"
PY
    [ "$status" -eq 0 ]
    run bash -c '
      REPO_ROOT=$1
      for _c in "$REPO_ROOT/scripts/lib/board-ids.sh" "$REPO_ROOT/node_modules/@jenga-ai/agent/scripts/lib/board-ids.sh"; do
        if [ -f "$_c" ]; then . "$_c"; break; fi
      done
      board_id_kind E01_S01_T01
    ' _ "$proj"
    [ "$status" -eq 0 ]
    [ "$output" = "task" ]
  done
}

@test "importing prints nothing; python uses the standard library only" {
  run python3 -c "import sys; sys.path.insert(0, '$PYLIB'); import board_ids"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  imports="$(grep -E '^(import|from) ' "$PYLIB/board_ids.py")"
  [ "$imports" = "import re" ]
}

@test "sourcing prints nothing and leaves shell options unchanged" {
  for opts in "set +e +u" "set -eu"; do
    run bash -c "$opts; before=\$-; . '$SHLIB'; after=\$-; [ \"\$before\" = \"\$after\" ] && echo same"
    [ "$status" -eq 0 ]
    [ "$output" = "same" ]
  done
}

@test "npm-reach-files.sh lists both files and .publicignore does not exclude them" {
  command -v npm >/dev/null 2>&1 || skip "npm not installed"
  run bash "$REPO/scripts/npm-reach-files.sh" "$REPO"
  [ "$status" -eq 0 ]
  grep -qx 'scripts/lib/board_ids.py' <<<"$output"
  grep -qx 'scripts/lib/board-ids.sh' <<<"$output"
  command -v rsync >/dev/null 2>&1 || skip "rsync not installed"
  run bash "$REPO/scripts/check-publicignore-match.sh" scripts/lib/board_ids.py scripts/lib/board-ids.sh
  [ "$status" -eq 0 ]
  ! grep -q '^BLOCKED' <<<"$output"
}
