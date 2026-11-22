#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for skills/j-uncharted/scripts/resolve-segment-target.sh (E43_S01_T02).
#
# The script reports one of THREE board-linkage states: linked, unlinked and not_checked. Conflating not_checked with unlinked
# asserts an absence that was never verified; it caused E40_S05_T02's round-1 failure and a wrong document row in run-engine.sh.
# Each state is asserted below, and not_checked is asserted as DISTINCT from unlinked on all three of its causes (the target is
# the repository root, the target is outside the repository, there is no board directory).
#
# Fixture: tests/fixtures/uncharted-segment/board-repo/tree (a miniature repository with one board task that references
# src/linked) with the recorded expectations in expected.json beside it. The tree is copied into $BATS_TEST_TMPDIR and handed to
# the script through its documented --repo-root argument, so the live repository and its project/board are never read.
#
# Naming (project/documentation/bats-fixture-convention.md, rule 2): `--paths-from` (batch mode) and `--board-dir` change what
# the script does and are named in the tests that use them. `--repo-root <fixture>` and `--json-only` are the fixture mechanism /
# an output filter and are not.

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/uncharted

FIXTURE_DIR="$UNCHARTED_FIXTURES/uncharted-segment/board-repo"

setup() {
  uncharted_sandbox
  uncharted_tree "$FIXTURE_DIR/tree" repo git
  REPO="$TREE"
  RESOLVE="$SCRIPTS/resolve-segment-target.sh"
  cd "$REPO"
}

# resolve_projection: one row per result with only the fields a linkage claim rests on.
resolve_projection() {
  jq -S '[.results[] | {argument, kind, status: .board_linkage.status, items: .board_linkage.items}]'
}

@test "every case directory under tests/fixtures/uncharted-segment has an expected.json and a tree" {
  local dir
  for dir in "$UNCHARTED_FIXTURES"/uncharted-segment/*/; do
    [ -f "$dir/expected.json" ] || { echo "missing expected.json in $dir"; return 1; }
    [ -d "$dir/tree" ] || { echo "missing tree in $dir"; return 1; }
  done
}

@test "linked, unlinked and not_checked are each reported for the fixture paths named in expected.json" {
  local arg expected_status expected_items row
  while IFS=$'\t' read -r arg expected_status expected_items; do
    run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only "$arg" </dev/null
    [ "$status" -eq 0 ] || { echo "'$arg' exited $status"; return 1; }
    row="$(jq -c '.results[0] | {status: .board_linkage.status, items: .board_linkage.items}' <<<"$output")"
    [ "$row" = "{\"status\":\"$expected_status\",\"items\":$expected_items}" ] \
      || { echo "'$arg': expected status $expected_status items $expected_items, got $row"; return 1; }
  done < <(jq -r '.single[] | [.argument, .status, (.items | tojson)] | @tsv' "$FIXTURE_DIR/expected.json")
}

@test "a linked path names the board item that references it and counts its referencing files" {
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only src/linked </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.results[0].board_linkage | .status == "linked" and .items == ["E01_S01_T01"]
             and .match_count == 1 and (.files | length) == .match_count' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "unlinked is a verified absence: the board was read and nothing referenced the path" {
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only src/unlinked </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.results[0].board_linkage | .status == "unlinked" and .match_count == 0 and .items == [] and .files == []' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "not_checked is distinct from unlinked when the target is the repository root" {
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only . </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.results[0] | .target_type == "repo_root" and .board_linkage.status == "not_checked"
             and .board_linkage.status != "unlinked" and (.board_linkage.reason | contains("repository root"))' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "not_checked is distinct from unlinked when the target is outside the repository" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  printf 'x\n' >"$BATS_TEST_TMPDIR/elsewhere/file.txt"
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only "$BATS_TEST_TMPDIR/elsewhere" </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.results[0] | .in_repo == false and .board_linkage.status == "not_checked"
             and .board_linkage.status != "unlinked" and (.board_linkage.reason | contains("outside"))' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "not_checked is distinct from unlinked under --board-dir pointing at a directory that does not exist" {
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --board-dir "$REPO/no-such-board" --json-only src/linked </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.results[0].board_linkage | .status == "not_checked" and .status != "unlinked" and .match_count == 0
             and (.reason | startswith("no board directory"))' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "invariant: every record's linkage status is one of the three states, linked iff match_count > 0, and not_checked always carries a reason" {
  local arg
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  for arg in src/linked src/linked/handler.js src/unlinked lib/quiet . "$BATS_TEST_TMPDIR/elsewhere"; do
    run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only "$arg" </dev/null
    [ "$status" -eq 0 ]
    run jq -e '.results[0].board_linkage as $l
               | ($l.status | IN("linked", "unlinked", "not_checked"))
               and (($l.status == "linked") == ($l.match_count > 0))
               and (($l.status != "not_checked") or ($l.reason | length > 0))' <<<"$output"
    [ "$status" -eq 0 ] || { echo "invariant broken for '$arg'"; return 1; }
  done
}

@test "linkage is a path-boundary test, not a substring test: src/link is NOT linked by a board item that names src/linked" {
  mkdir -p "$REPO/src/link"
  printf 'x\n' >"$REPO/src/link/a.js"
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only src/link </dev/null
  [ "$status" -eq 0 ]
  run jq -e '.results[0].board_linkage.status == "unlinked"' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "single mode prints the resolved absolute path on line 1 and, with --json-only, nothing but the JSON" {
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" src/linked </dev/null
  [ "$status" -eq 0 ]
  local first="${lines[0]}" target
  target="$(printf '%s\n' "${lines[@]:1}" | jq -r '.results[0].target')"
  [ "$first" = "$target" ]
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only src/linked </dev/null
  jq -e . <<<"$output" >/dev/null
}

@test "batch mode via --paths-from - (stdin) returns one record per path, with the same statuses as single mode" {
  run --separate-stderr bash -c \
    'printf "src/linked/handler.js\nsrc/unlinked/orphan.js\n# a comment\n\n.\n" | bash "$1" --repo-root "$2" --paths-from -' _ "$RESOLVE" "$REPO"
  [ "$status" -eq 0 ]
  local batch="$output"
  run jq -e '.batch == true and (.results | length) == 3' <<<"$batch"
  [ "$status" -eq 0 ]
  # invariant: batch and single mode agree path by path
  local arg single
  for arg in src/linked/handler.js src/unlinked/orphan.js .; do
    run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only "$arg" </dev/null
    single="$(jq -c '.results[0].board_linkage.status' <<<"$output")"
    run jq -c --arg a "$arg" '.results[] | select(.argument == $a) | .board_linkage.status' <<<"$batch"
    [ "$output" = "$single" ] || { echo "batch/single disagree for '$arg': $output vs $single"; return 1; }
  done
}

@test "batch mode via --paths-from <file> reads the same list from a file" {
  printf 'src/linked/handler.js\nsrc/unlinked/orphan.js\n' >"$BATS_TEST_TMPDIR/paths.txt"
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --paths-from "$BATS_TEST_TMPDIR/paths.txt" </dev/null
  [ "$status" -eq 0 ]
  run jq -r '[.results[].board_linkage.status] | join(",")' <<<"$output"
  [ "$output" = "linked,unlinked" ]
}

@test "batch mode via --paths-from - exits 2 when one input path does not exist, and still writes a record for every line" {
  run --separate-stderr bash -c \
    'printf "src/linked/handler.js\nsrc/missing.js\n" | bash "$1" --repo-root "$2" --paths-from -' _ "$RESOLVE" "$REPO"
  [ "$status" -eq 2 ]
  run jq -e '(.results | length) == 2' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "a free-text description exits 2 and still writes JSON with kind=description and a candidates array" {
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only "linked handler" </dev/null
  [ "$status" -eq 2 ]
  run jq -e '.results[0] | .kind == "description" and .target == null and (.candidates | type == "array")' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "a free-text description ranks tracked paths that match its tokens, and --limit caps them" {
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only --limit 1 "linked handler" </dev/null
  [ "$status" -eq 2 ]
  run jq -e '(.results[0].candidates | length) == 1 and (.results[0].candidates[0].path | contains("linked"))' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "exit 1 for a usage error: no argument, an unknown flag, two arguments" {
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$RESOLVE" --no-such-flag src </dev/null
  [ "$status" -eq 1 ]
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" src/linked src/unlinked </dev/null
  [ "$status" -eq 1 ]
}

@test "exit 0 for --help" {
  run --separate-stderr bash "$RESOLVE" --help </dev/null
  [ "$status" -eq 0 ]
  assert_output_contains "resolve-segment-target.sh"
}

@test "exit 3 when the path exists but is not readable" {
  mkdir -p "$REPO/src/sealed"
  printf 'x\n' >"$REPO/src/sealed/a.js"
  chmod 000 "$REPO/src/sealed"
  run --separate-stderr bash "$RESOLVE" --repo-root "$REPO" --json-only src/sealed </dev/null
  chmod 755 "$REPO/src/sealed"
  [ "$status" -eq 3 ]
}
