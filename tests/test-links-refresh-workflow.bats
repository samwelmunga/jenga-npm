#!/usr/bin/env bats
#
# E83_S04_T04: end-to-end proof that the test-links refresh workflow (project/.workflows/test-links-refresh.json) runs
# through the real E80 workflow scripts and does what the story promises: leaves a fresh links file byte-identical,
# regenerates a stale one, reports a link whose graph node was removed, and publishes its report and data outputs
# through the artifact registry.
#
# Harness: tests/helpers/workflow-fixture.bash (E80_S06_T03). wf_setup builds the isolated project tree $PROJ (the E80
# scripts, the resolver, the minimal workflow.json) and wf_fresh runs every command in a clean process selecting that
# tree with JENGA_PROJECT_ROOT; this file reimplements none of that run-state setup. It only adds what the refresh run
# needs on top (the definition, its template, the five test-links scripts, a graph and annotated test files) and drives
# the run the way skills/j-workflow/SKILL.md does: run-state.sh start, then next-step.sh. Every step here is compute or
# render, which next-step.sh executes itself, so one call takes the run from start to `complete`.
#
# Isolation: the repository is only READ. The fixture project, the run state, the artifact registry and the scratch
# directory the scripts use for their temp files (TMPDIR is pointed at $PROJ/tmp for every call) all live under
# $BATS_TEST_TMPDIR. teardown() fails the case if this repository's own links file or graph changed.
#
# The fixture annotation lines are emitted with printf so that none of them begins a line of THIS file: the repository's
# own extractor scans tests/*.bats for `arch-node:` annotations and must not see any here.
#
# Mirror safety: skips, naming the path, when the E80 harness, scripts/workflow/ or any file the refresh run needs is
# not in the tree.

bats_require_minimum_version 1.5.0

load helpers/assertions
# The harness is loaded only when present, so a tree without it skips (setup) instead of failing at load time.
if [ -f "$(dirname "$BATS_TEST_FILENAME")/helpers/workflow-fixture.bash" ]; then
  load helpers/workflow-fixture
fi

WORKFLOW_ID="test-links-refresh"

setup() {
  if ! type wf_setup >/dev/null 2>&1; then
    skip "tests/helpers/workflow-fixture.bash (the E80_S06_T03 harness) is not in this tree"
  fi
  if [ ! -d "$WF_REPO_ROOT/scripts/workflow" ]; then
    skip "scripts/workflow/ is not in this tree"
  fi
  wf_setup

  local f
  for f in project/.workflows/test-links-refresh.json project/.workflows/templates/test-links-refresh-report.md \
           scripts/check-test-links.sh scripts/extract-test-links.sh scripts/validate-test-links.sh \
           scripts/test-links-refresh-check.sh scripts/test-links-refresh-diff.sh scripts/workflow/artifacts.sh; do
    wf_require "$f"
  done

  # What the refresh run needs on top of wf_setup's tree: read-only copies from the repo, executable bits kept.
  cp "$WF_REPO_ROOT/project/.workflows/$WORKFLOW_ID.json" "$PROJ/project/.workflows/"
  cp "$WF_REPO_ROOT/project/.workflows/templates/test-links-refresh-report.md" "$PROJ/project/.workflows/templates/"
  for f in check-test-links extract-test-links validate-test-links test-links-refresh-check test-links-refresh-diff; do
    cp "$WF_REPO_ROOT/scripts/$f.sh" "$PROJ/scripts/$f.sh"
    chmod +x "$PROJ/scripts/$f.sh"
  done

  KG="$PROJ/project/knowledge-graph"
  LINKS="$KG/test-links.json"
  GRAPH="$KG/graph.json"
  mkdir -p "$PROJ/tmp" "$KG" "$PROJ/tests"

  # The fixture graph and two annotated test files (N3 is a node no test links to).
  graph_with_nodes N1 N2 N3
  printf '%s\n' '# arch-node: N1 type=unit' '@test "first" {' '  true' '}' > "$PROJ/tests/a.bats"
  printf '%s\n' '# arch-node: N2 type=integration' '@test "second" {' '  true' '}' > "$PROJ/tests/b.bats"

  # The links file the refresh starts from: produced by the real extractor, inside the fixture project.
  fx bash "$PROJ/scripts/extract-test-links.sh" >/dev/null 2>&1
  [ -f "$LINKS" ]

  # Guard for teardown: this repository's own links file and graph must be untouched.
  GUARD_BEFORE="$(repo_guard)"
}

teardown() {
  if [ -n "${GUARD_BEFORE+x}" ]; then
    [ "$(repo_guard)" = "$GUARD_BEFORE" ]
  fi
}

# fx <command...>: one clean process (wf_fresh) whose scratch directory is under the fixture tree, so no script of the
# run writes a temp file outside $BATS_TEST_TMPDIR.
fx() { wf_fresh "${WF_SESSION:-sess-a}" env TMPDIR="$PROJ/tmp" "$@"; }

# graph_with_nodes <id>...: writes the fixture graph with exactly those nodes.
graph_with_nodes() {
  local id json=""
  for id in "$@"; do
    json="$json{\"id\":\"$id\",\"type\":\"story\"},"
  done
  printf '{"nodes":[%s],"edges":[]}\n' "${json%,}" > "$GRAPH"
}

# repo_guard: a checksum of this repository's own links file and graph (or the word "absent" for a missing one).
repo_guard() {
  local f
  for f in project/knowledge-graph/test-links.json project/knowledge-graph/graph.json; do
    if [ -f "$WF_REPO_ROOT/$f" ]; then cksum < "$WF_REPO_ROOT/$f"; else echo "absent"; fi
  done
}

# sha_of <file>: SHA-256 of a file.
sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

# links_hash <test file path>: the links file's recorded hash for that test file.
links_hash() { jq -r --arg f "$1" '.generated_from.tests[$f]' "$LINKS"; }

# run_refresh: starts the workflow and calls next-step.sh once. All four steps are compute or render, so that one call
# must end in the `complete` signal; on anything else the whole signal (a `halted` one carries the failure note) is
# shown. Sets RUN.
run_refresh() {
  local out
  RUN="$(fx bash "$(wf_script run-state.sh)" start "$WORKFLOW_ID")"
  [ -n "$RUN" ]
  out="$(fx bash "$(wf_script next-step.sh)" "$RUN")"
  if [ "$(printf '%s' "$out" | jq -r .signal)" != "complete" ]; then
    echo "next-step did not complete the run: $out"
    return 1
  fi
  [ "$(wf_status "$RUN" | jq -r .status)" = "completed" ]
}

# latest <name> [--path]: the registry's latest completed-run record (or file path) for one of the workflow's outputs.
latest() { fx bash "$(wf_script artifacts.sh)" latest "$WORKFLOW_ID" "$@"; }

# report_text: the latest report artifact's content.
report_text() { cat "$(latest report --path)"; }

@test "1. fresh fixture: the run completes, the links file is byte-identical, the report says fresh with zero changes" {
  local before="$BATS_TEST_TMPDIR/links.before"
  cp "$LINKS" "$before"

  run_refresh

  cmp -s "$before" "$LINKS"
  local rep
  rep="$(report_text)"
  assert_contains "$rep" "- Status: fresh"
  assert_contains "$rep" "| 0 | 0 | 0 |"
  assert_not_contains "$rep" "node-missing"
  assert_not_contains "$rep" "test-changed"
}

@test "2. an edited linked test file: the links file is regenerated and the report lists the changed link" {
  local before="$BATS_TEST_TMPDIR/links.before" old_hash new_hash
  cp "$LINKS" "$before"
  old_hash="$(links_hash tests/a.bats)"
  [ "$old_hash" = "$(sha_of "$PROJ/tests/a.bats")" ]

  # the annotation's type changes from unit to integration: same link identity, different record
  printf '%s\n' '# arch-node: N1 type=integration' '@test "first" {' '  true' '}' > "$PROJ/tests/a.bats"

  run_refresh

  run ! cmp -s "$before" "$LINKS"
  new_hash="$(links_hash tests/a.bats)"
  [ "$new_hash" != "$old_hash" ]
  [ "$new_hash" = "$(sha_of "$PROJ/tests/a.bats")" ]
  [ "$(jq -r '.links[] | select(.node_id == "N1") | .type' "$LINKS")" = "integration" ]
  # the untouched test file keeps its hash
  [ "$(links_hash tests/b.bats)" = "$(sha_of "$PROJ/tests/b.bats")" ]

  local rep
  rep="$(report_text)"
  assert_contains "$rep" "- Status: stale"
  assert_contains "$rep" "test-changed: file=tests/a.bats"
  assert_contains "$rep" "| 0 | 0 | 1 |"
  assert_contains "$rep" "N1 <- tests/a.bats::first"
}

@test "3. a node removed from the graph: the report shows node-missing and the regenerated file still validates" {
  graph_with_nodes N1 N3

  run_refresh

  local rep
  rep="$(report_text)"
  assert_contains "$rep" "- Status: stale"
  assert_contains "$rep" "node-missing: node_id=N2"
  assert_contains "$rep" "graph-changed:"
  # the extractor warns about a dangling node id but still writes the link (no silent drop), and the file is valid
  [ "$(jq -r '[.links[] | select(.node_id == "N2")] | length' "$LINKS")" = "1" ]
  [ "$(jq -r .generated_from.graph_sha256 "$LINKS")" = "$(sha_of "$GRAPH")" ]
  run fx bash "$PROJ/scripts/validate-test-links.sh" "$LINKS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # and the graph-aware check names the dangling link, so the validator is not being satisfied by an empty file
  run fx bash "$PROJ/scripts/validate-test-links.sh" --graph "$GRAPH" "$LINKS"
  [ "$status" -eq 1 ]
  assert_output_contains "dangling-node"
}

@test "4. the registry returns the report as the workflow's latest artifact and the data outputs are retrievable" {
  printf '%s\n' '# arch-node: N1 type=integration' '@test "first" {' '  true' '}' > "$PROJ/tests/a.bats"

  run_refresh

  # the report: the latest artifact of the workflow, produced by this run's render step
  local rec file
  rec="$(latest report)"
  [ "$(printf '%s' "$rec" | jq -r .run_id)" = "$RUN" ]
  [ "$(printf '%s' "$rec" | jq -r .kind)" = "artifact" ]
  [ "$(printf '%s' "$rec" | jq -r .step_id)" = "report" ]
  file="$(latest report --path)"
  [ -f "$file" ]
  [ "$(printf '%s' "$rec" | jq -r .sha256)" = "$(sha_of "$file")" ]
  assert_contains "$(cat "$file")" "# Test-links refresh report"
  # compared by physical path: on macOS $BATS_TEST_TMPDIR is /var/... while the scripts resolve it to /private/var/...
  local fixture_root
  fixture_root="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  case "$file" in
    "$fixture_root"/*) ;;
    *) echo "artifact path is outside the fixture tree: $file"; return 1 ;;
  esac

  # the data outputs, retrieved the way E80_S04's tests do: the record, then the published file
  rec="$(latest status)"
  [ "$(printf '%s' "$rec" | jq -r .kind)" = "data" ]
  [ "$(printf '%s' "$rec" | jq -r .run_id)" = "$RUN" ]
  [ "$(printf '%s' "$rec" | jq -r .step_id)" = "check" ]
  [ "$(cat "$(latest status --path)")" = "stale" ]
  [ "$(cat "$(latest changed_count --path)")" = "1" ]
  [ "$(cat "$(latest added_count --path)")" = "0" ]
  [ "$(cat "$(latest removed_count --path)")" = "0" ]
  assert_contains "$(cat "$(latest changed --path)")" "N1 <- tests/a.bats::first"

  # the declared outputs the story relies on are each in the registry exactly once for this run
  run fx bash "$(wf_script artifacts.sh)" list --workflow "$WORKFLOW_ID" --run "$RUN"
  [ "$status" -eq 0 ]
  local n
  for n in report status reasons added_count removed_count changed_count; do
    [ "$(printf '%s' "$output" | jq -r --arg n "$n" '[.[] | select(.name == $n)] | length')" = "1" ]
  done
}
