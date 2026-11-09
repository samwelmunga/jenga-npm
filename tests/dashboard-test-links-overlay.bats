#!/usr/bin/env bats
#
# End-to-end check of the read-only test coverage overlay on the Architecture tab (E83_S03_T05).
#
# Why this file exists
# ---------------------
# E83_S03_T01..T04 each have their own unit coverage (parser, SAD map payload, SADMap badge and legend, coverage
# table). None of them proves that the overlay data actually travels from a project's two source files
# (project/knowledge-graph/graph.json and project/knowledge-graph/test-links.json) all the way into the
# self-contained `j.dashboard --snapshot` export. This suite does, against a throwaway fixture project:
#
#   1. API path      the REAL parsers/architecture.js, pointed at the fixture with JENGA_PROJECT_ROOT, returns the
#                    covering test (name, type, file, line) on the `human` node, never renders the board-only node,
#                    and reports testCovered 1.
#   2. Snapshot path the REAL snapshot.sh -> REAL capture-snapshot.js (via a shim, as the budget cases of
#                    dashboard-snapshot.bats do) -> REAL bundler, against the same fixture; the produced HTML
#                    contains the covered test's name, in the embedded /v1/architecture payload.
#   3. No links      with the links file removed, both paths still succeed and report testCovered 0.
#
# What is faked, and what is not
# ------------------------------
# Only the UI bundle is a fixture (a tiny consumer-shaped dist/, exactly as in dashboard-snapshot.bats): the overlay
# data rides in the embedded JSON payload, which is produced by the real server code and inlined by the real bundler.
# One extra case bundles the REAL built dist/ (skipped when it has not been built) to pin that the shipped UI
# bundle carries the coverage table's heading.
#
# Everything is read and written inside $BATS_TEST_TMPDIR; neither this repository's own board, graph nor links file
# is touched. The suite skips with a message when node or the dashboard's API dependencies are not installed.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SNAPSHOT_SRC="$REPO_ROOT/skills/j-dashboard/scripts/snapshot.sh"
RESOLVER_SRC="$REPO_ROOT/skills/j-dashboard/scripts/resolve-app-dir.sh"
BUNDLER_SRC="$REPO_ROOT/project/app/ui/scripts/build-snapshot-html.cjs"
REAL_CAPTURE="$REPO_ROOT/project/app/api/scripts/capture-snapshot.js"

# Names the assertions look for. Unique enough that a hit in the output can only come from the fixture links file.
HUMAN_TEST_NAME="overlay fixture: totals are summed per invoice"
BOARD_TEST_NAME="overlay fixture: board-only story is never rendered"

setup() {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  ( cd "$REPO_ROOT/project/app/api" && node -e "require.resolve('express'); require.resolve('cors'); require.resolve('gray-matter')" ) >/dev/null 2>&1 \
    || skip "project/app/api dependencies are not installed"

  # The fixture project. pwd -P for the macOS /tmp -> /private/tmp symlink reason given in dashboard-snapshot.bats.
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  PROJ="$(cd "$BATS_TEST_TMPDIR/proj" && pwd -P)"
  mkdir -p "$PROJ/project/board/epics" "$PROJ/project/board/stories" "$PROJ/project/board/tasks" \
           "$PROJ/project/configs" "$PROJ/project/data" "$PROJ/project/logs" \
           "$PROJ/project/rapports/problems" "$PROJ/project/knowledge-graph"
  git -C "$PROJ" init -q

  # One verified (`human`) node, one hidden (`board`) node that is NOT an edge endpoint of a verified node, so it
  # stays hidden rather than becoming a ghost stub.
  cat > "$PROJ/project/knowledge-graph/graph.json" <<'EOF'
{
  "nodes": [
    { "id": "ARCH_BILLING", "type": "service", "label": "Billing service", "description": "Computes invoice totals.", "source": "human" },
    { "id": "E99_S01", "type": "story", "label": "Board-only story", "description": "A mechanical board restatement.", "source": "board" }
  ],
  "edges": []
}
EOF
  write_links_file

  # Consumer-shaped snapshot tree: the real script, resolver and bundler, a fixture dist, and a shim that runs the
  # real capture with the same arguments.
  TMP_REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TMP_REPO/skills/j-dashboard/scripts" "$TMP_REPO/project/app/api/scripts" "$TMP_REPO/project/app/ui/scripts"
  TMP_REPO="$(cd "$TMP_REPO" && pwd -P)"
  git -C "$TMP_REPO" init -q
  cp "$SNAPSHOT_SRC" "$TMP_REPO/skills/j-dashboard/scripts/snapshot.sh"
  cp "$RESOLVER_SRC" "$TMP_REPO/skills/j-dashboard/scripts/resolve-app-dir.sh"
  chmod +x "$TMP_REPO/skills/j-dashboard/scripts/snapshot.sh"
  SNAPSHOT="$TMP_REPO/skills/j-dashboard/scripts/snapshot.sh"
  cp "$BUNDLER_SRC" "$TMP_REPO/project/app/ui/scripts/build-snapshot-html.cjs"
  cat > "$TMP_REPO/project/app/api/scripts/capture-snapshot.js" <<SHIM
require('$REAL_CAPTURE');
SHIM
  write_fixture_dist "$TMP_REPO/project/app/ui"

  mkdir -p "$BATS_TEST_TMPDIR/invoking-project"
  INVOKE_DIR="$(cd "$BATS_TEST_TMPDIR/invoking-project" && pwd -P)"
  OUT_HTML="$BATS_TEST_TMPDIR/overlay.html"
}

# The links file: one assertion test linked to the human node, one to the board node. Shape per
# scripts/validate-test-links.sh.
write_links_file() {
  cat > "$PROJ/project/knowledge-graph/test-links.json" <<EOF
{
  "schema_version": 1,
  "generated_from": { "graph_sha256": "absent", "tests": {} },
  "links": [
    { "node_id": "ARCH_BILLING", "test_id": "tests/billing.test.js::$HUMAN_TEST_NAME", "type": "unit",
      "name": "$HUMAN_TEST_NAME", "file": "tests/billing.test.js", "line": 42 },
    { "node_id": "E99_S01", "test_id": "tests/board-only.bats::$BOARD_TEST_NAME", "type": "integration",
      "name": "$BOARD_TEST_NAME", "file": "tests/board-only.bats", "line": 7 }
  ]
}
EOF
}

# A minimal consumer-shaped prebuilt dist/ in $1 (same shape vite emits; see dashboard-snapshot.bats).
write_fixture_dist() {
  local ui_dir="$1"
  mkdir -p "$ui_dir/dist/assets"
  cat > "$ui_dir/dist/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <title>Jenga AI Dashboard</title>
    <script type="module" crossorigin src="/assets/index-fixture.js"></script>
    <link rel="stylesheet" crossorigin href="/assets/index-fixture.css">
  </head>
  <body>
    <div id="root"></div>
  </body>
</html>
EOF
  echo 'console.log("fixture bundle marker");' > "$ui_dir/dist/assets/index-fixture.js"
  echo '.fixture-style-marker { color: red; }' > "$ui_dir/dist/assets/index-fixture.css"
}

# Step 1 helper: the real parseArchitecture() against the fixture project; prints its sad_map as JSON.
api_sad_map() {
  JENGA_PROJECT_ROOT="$PROJ" node -e '
    require(process.argv[1] + "/project/app/api/parsers/architecture.js").parseArchitecture()
      .then((r) => process.stdout.write(JSON.stringify(r.sad_map)))
      .catch((e) => { console.error(e.message); process.exit(1); });
  ' "$REPO_ROOT"
}

# Step 2 helper: run the real snapshot pipeline against the fixture project.
run_snapshot() {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$OUT_HTML' --project-root '$PROJ'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$OUT_HTML" ]
}

# The sad_map embedded in the snapshot HTML, parsed the way the UI's client does, as JSON on stdout.
embedded_sad_map() {
  node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const m = html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/);
    if (!m) { console.error("no embedded snapshot tag"); process.exit(1); }
    const env = JSON.parse(m[1]).routes.architecture;
    if (env.error) { console.error("architecture route carried an error"); process.exit(1); }
    process.stdout.write(JSON.stringify(env.data.sad_map));
  ' "$OUT_HTML"
}

# Asserts, with node, the overlay shape of a sad_map JSON on stdin; $1 = expected testCovered.
check_sad_map() {
  node -e '
    const sad = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const fail = (msg) => { console.error(msg); process.exit(1); };
    const expectedCovered = Number(process.argv[1]);
    const ids = sad.nodes.map((n) => n.id);
    if (ids.length !== 1 || ids[0] !== "ARCH_BILLING") fail("rendered nodes should be exactly [ARCH_BILLING], got " + JSON.stringify(ids));
    const c = sad.coverage;
    if (c.shown !== 1 || c.hidden !== 1 || c.total !== 2) fail("shown/hidden/total changed: " + JSON.stringify(c));
    if (c.testCovered !== expectedCovered) fail("testCovered should be " + expectedCovered + ", got " + c.testCovered);
    const tests = sad.nodes[0].tests;
    if (expectedCovered === 1) {
      if (tests.length !== 1) fail("human node should carry exactly 1 test, got " + tests.length);
      const t = tests[0];
      const want = { name: process.argv[2], type: "unit", file: "tests/billing.test.js", line: 42 };
      for (const k of Object.keys(want)) if (t[k] !== want[k]) fail("test." + k + " should be " + JSON.stringify(want[k]) + ", got " + JSON.stringify(t[k]));
      if (c.testLinksUnrendered !== 1) fail("the board-sourced link should count as unrendered, got " + c.testLinksUnrendered);
    } else {
      if (tests.length !== 0) fail("no links file: human node should carry no tests, got " + tests.length);
      if (c.testLinksUnrendered !== 0) fail("no links file: testLinksUnrendered should be 0, got " + c.testLinksUnrendered);
    }
    console.log("overlay shape ok (testCovered " + c.testCovered + ")");
  ' "$1" "$HUMAN_TEST_NAME"
}

# -----------------------------------------------------------------------------
# Step 1: API path
# -----------------------------------------------------------------------------

@test "api: the human node carries its covering test with name, type, file and line, and testCovered is 1" {
  api_sad_map > "$BATS_TEST_TMPDIR/sad.json"
  run check_sad_map 1 < "$BATS_TEST_TMPDIR/sad.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "overlay shape ok (testCovered 1)"
}

@test "api: the board-sourced link does not turn the hidden board node into a rendered one" {
  api_sad_map > "$BATS_TEST_TMPDIR/sad.json"
  run node -e '
    const sad = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (sad.nodes.some((n) => n.id === "E99_S01")) { console.error("board node was rendered"); process.exit(1); }
    if (JSON.stringify(sad).includes(process.argv[2])) { console.error("board-only test leaked into the payload"); process.exit(1); }
    console.log("board link stayed unrendered");
  ' "$BATS_TEST_TMPDIR/sad.json" "$BOARD_TEST_NAME"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "board link stayed unrendered"
}

# -----------------------------------------------------------------------------
# Step 2: snapshot path
# -----------------------------------------------------------------------------

@test "snapshot: the produced HTML contains the covered test's name" {
  run_snapshot
  run grep -cF -- "$HUMAN_TEST_NAME" "$OUT_HTML"
  [ "$status" -eq 0 ] || { echo "covered test name missing from the snapshot HTML"; false; }
}

@test "snapshot: the embedded architecture payload carries the same overlay as the API path" {
  run_snapshot
  embedded_sad_map > "$BATS_TEST_TMPDIR/embedded-sad.json"
  run check_sad_map 1 < "$BATS_TEST_TMPDIR/embedded-sad.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "overlay shape ok (testCovered 1)"

  # And the unrendered board link's test never ships as a test of anything.
  run grep -cF -- "$BOARD_TEST_NAME" "$OUT_HTML"
  [ "$status" -ne 0 ] || { echo "board-only test name shipped in the export"; false; }
}

@test "snapshot: the real built UI bundle carries the Test coverage heading alongside the overlay data" {
  local real_dist="$REPO_ROOT/project/app/ui/dist"
  [ -f "$real_dist/index.html" ] || skip "project/app/ui/dist not built"
  rm -rf "$TMP_REPO/project/app/ui/dist"
  cp -R "$real_dist" "$TMP_REPO/project/app/ui/dist"

  run_snapshot
  run grep -cF -- "$HUMAN_TEST_NAME" "$OUT_HTML"
  [ "$status" -eq 0 ] || { echo "covered test name missing from the snapshot HTML"; false; }
  run grep -cF -- "Test coverage" "$OUT_HTML"
  [ "$status" -eq 0 ] || { echo "the Test coverage heading is missing from the bundled UI"; false; }
}

# -----------------------------------------------------------------------------
# Step 3: no links file
# -----------------------------------------------------------------------------

@test "no links file: the api path still succeeds with testCovered 0 and no tests anywhere" {
  rm "$PROJ/project/knowledge-graph/test-links.json"
  api_sad_map > "$BATS_TEST_TMPDIR/sad.json"
  run check_sad_map 0 < "$BATS_TEST_TMPDIR/sad.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "overlay shape ok (testCovered 0)"
}

@test "no links file: the snapshot still succeeds, embeds testCovered 0, and ships neither test name" {
  rm "$PROJ/project/knowledge-graph/test-links.json"
  run_snapshot
  embedded_sad_map > "$BATS_TEST_TMPDIR/embedded-sad.json"
  run check_sad_map 0 < "$BATS_TEST_TMPDIR/embedded-sad.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "overlay shape ok (testCovered 0)"

  run grep -cF -- "$HUMAN_TEST_NAME" "$OUT_HTML"
  [ "$status" -ne 0 ] || { echo "covered test name shipped without a links file"; false; }
}
