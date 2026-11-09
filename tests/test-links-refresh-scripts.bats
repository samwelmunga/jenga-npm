#!/usr/bin/env bats
# Coverage for the test-links refresh workflow (E83_S04_T03): the definition project/.workflows/test-links-refresh.json,
# its report template, and the two helpers it calls, scripts/test-links-refresh-check.sh (the always-exit-0 wrapper
# around check-test-links.sh, which exits 1 on `stale`) and scripts/test-links-refresh-diff.sh.
#
# Fixture-tree convention (as tests/check-test-links.bats): every case builds its OWN synthetic project tree under
# $BATS_TEST_TMPDIR and drives the helpers with --root; this repository's own links file is never read or written.
# Snapshot files are made under a per-test TMPDIR, so nothing is left in the real temp directory.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/test-links-refresh-check.sh"
DIFF="$REPO_ROOT/scripts/test-links-refresh-diff.sh"
EXTRACT="$REPO_ROOT/scripts/extract-test-links.sh"
DEF="$REPO_ROOT/project/.workflows/test-links-refresh.json"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed"
  [ -f "$CHECK" ] && [ -f "$DIFF" ] && [ -f "$EXTRACT" ] || skip "a test-links script is absent"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  FIX="$BATS_TEST_TMPDIR/proj"
  KG="$FIX/project/knowledge-graph"
  mkdir -p "$KG" "$FIX/tests"
  printf '%s\n' '{"nodes":[{"id":"N1","type":"story"},{"id":"N2","type":"story"}],"edges":[]}' > "$KG/graph.json"
  printf '%s\n' '# arch-node: N1 type=integration' '@test "a" {' '  true' '}' > "$FIX/tests/a.bats"
}

@test "check: a fresh links file gives status fresh, reasons none, a snapshot, and exit 0" {
  bash "$EXTRACT" --root "$FIX" 2>/dev/null
  run bash "$CHECK" --root "$FIX"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "fresh" ]
  [ "$(printf '%s' "$output" | jq -r .reasons)" = "none" ]
  snap="$(printf '%s' "$output" | jq -r .snapshot)"
  [ -f "$snap" ]
  cmp -s "$snap" "$KG/test-links.json"
}

@test "check: a stale verdict (exit 1 in check-test-links.sh) still exits 0 with status stale and the reason" {
  bash "$EXTRACT" --root "$FIX" 2>/dev/null
  printf '%s\n' '# arch-node: N1,N2 type=unit' '@test "a" {' '  true' '}' > "$FIX/tests/a.bats"
  run bash "$REPO_ROOT/scripts/check-test-links.sh" --root "$FIX" --json
  [ "$status" -eq 1 ]
  run bash "$CHECK" --root "$FIX"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "stale" ]
  case "$(printf '%s' "$output" | jq -r .reasons)" in
    test-changed:*) ;;
    *) return 1 ;;
  esac
}

@test "check: no links file is stale with snapshot none; an invalid links file is status error, still exit 0" {
  run bash "$CHECK" --root "$FIX"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "stale" ]
  [ "$(printf '%s' "$output" | jq -r .snapshot)" = "none" ]
  printf '%s\n' 'not json' > "$KG/test-links.json"
  run bash "$CHECK" --root "$FIX"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "error" ]
}

@test "check: usage errors exit 2 with nothing on stdout" {
  run --separate-stderr bash "$CHECK" --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "diff: reports added and changed links, deletes the snapshot, and leaves the links file alone" {
  bash "$EXTRACT" --root "$FIX" 2>/dev/null
  out="$(bash "$CHECK" --root "$FIX")"
  snap="$(printf '%s' "$out" | jq -r .snapshot)"
  printf '%s\n' '# arch-node: N1,N2 type=unit' '@test "a" {' '  true' '}' > "$FIX/tests/a.bats"
  bash "$EXTRACT" --root "$FIX" 2>/dev/null
  before="$(cat "$KG/test-links.json")"
  run bash "$DIFF" "$snap" --root "$FIX"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .added_count)" = "1" ]
  [ "$(printf '%s' "$output" | jq -r .removed_count)" = "0" ]
  [ "$(printf '%s' "$output" | jq -r .changed_count)" = "1" ]
  [ "$(printf '%s' "$output" | jq -r .added)" = "N2 <- tests/a.bats::a" ]
  [ "$(printf '%s' "$output" | jq -r .removed)" = "none" ]
  [ ! -e "$snap" ]
  [ "$(cat "$KG/test-links.json")" = "$before" ]
}

@test "diff: reports removed links, and snapshot none counts every link as added" {
  bash "$EXTRACT" --root "$FIX" 2>/dev/null
  out="$(bash "$CHECK" --root "$FIX")"
  snap="$(printf '%s' "$out" | jq -r .snapshot)"
  printf '%s\n' '@test "a" {' '  true' '}' > "$FIX/tests/a.bats"
  bash "$EXTRACT" --root "$FIX" 2>/dev/null
  run bash "$DIFF" "$snap" --root "$FIX"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .removed_count)" = "1" ]
  [ "$(printf '%s' "$output" | jq -r .removed)" = "N1 <- tests/a.bats::a" ]
  printf '%s\n' '# arch-node: N1 type=integration' '@test "a" {' '  true' '}' > "$FIX/tests/a.bats"
  bash "$EXTRACT" --root "$FIX" 2>/dev/null
  run bash "$DIFF" none --root "$FIX"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .added_count)" = "1" ]
}

@test "diff: a missing snapshot file or missing regenerated file exits 2 with nothing on stdout" {
  bash "$EXTRACT" --root "$FIX" 2>/dev/null
  run --separate-stderr bash "$DIFF" "$BATS_TEST_TMPDIR/nope" --root "$FIX"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  rm -f "$KG/test-links.json"
  run --separate-stderr bash "$DIFF" none --root "$FIX"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "definition: validates, has the four steps in order, an artifact output and data outputs, and every path resolves" {
  [ -f "$DEF" ] || skip "the definition is absent"
  VALIDATE="$REPO_ROOT/scripts/workflow/validate-workflow.sh"
  [ -f "$VALIDATE" ] || skip "validate-workflow.sh is absent"
  run bash "$VALIDATE" "$DEF"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.steps[] | [.id, .type]]' "$DEF")" = '[["check","compute"],["extract","compute"],["diff","compute"],["report","render"]]' ]
  jq -e '[.steps[].outputs[]? | select(.kind == "artifact")] | length == 1' "$DEF" >/dev/null
  jq -e '[.steps[].outputs[]? | select(.kind == "data" and .name == "status")] | length == 1' "$DEF" >/dev/null
  # no absolute path anywhere in the definition
  if jq -r '.. | strings' "$DEF" | grep -q '^/'; then
    echo "absolute path in the definition"
    return 1
  fi
  while IFS= read -r cmd; do
    [ -x "$REPO_ROOT/$cmd" ]
  done < <(jq -r '.steps[] | select(.type == "compute") | .command' "$DEF")
  [ -f "$REPO_ROOT/$(jq -r '.steps[] | select(.type == "render") | .template' "$DEF")" ]
}
