#!/usr/bin/env bats
#
# /v1/progress-cards and /v1/progress-graph in the offline dashboard snapshot (E92_S06_T06).
#
# Same mechanism as dashboard-snapshot-progress.bats (E92_S03_T02 / E92_S04_T03): capture-snapshot.js embeds each route's
# full envelope under routes.<key>, and client.js maps a request path back to that key. Pinned here:
#   1. a real capture over a fixture project yields routes.progressCards and routes.progressGraph, each a full
#      {data, meta, error} envelope with no error, and routes.progressGraph.data.tasks present (graph captured without a
#      query, so it is the whole board);
#   2. the two key maps stay equal and carry both new paths; a deliberate difference fails the comparison;
#   3. in snapshot mode the real client.js resolves both paths from the embedded data without calling fetch;
#   4. the snapshot HTML builds with both routes embedded next to the others.
# The fixture project lives in $BATS_TEST_TMPDIR; the capture server binds 127.0.0.1 on an OS-assigned port.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAPTURE_SRC="$REPO_ROOT/project/app/api/scripts/capture-snapshot.js"
CLIENT_SRC="$REPO_ROOT/project/app/ui/src/api/client.js"

write_item() {
  local dir="$1" id="$2" parent_key="$3" parent_id="$4" status="$5"
  {
    echo "---"
    echo "id: $id"
    [ -z "$parent_key" ] || echo "$parent_key: $parent_id"
    echo "title: \"Title of $id\""
    echo "status: $status"
    echo "date_created: \"2026-11-12\""
    echo "---"
    echo
    echo "Body of $id."
  } > "$PROJ/project/board/$dir/${id}_item.md"
}

# Prints the capture map and the client map as JSON objects, one per line, from the two files given.
# $1 = capture-snapshot.js, $2 = client.js. Exits non-zero (with a message) when either map cannot be found.
key_maps_differ() {
  node -e '
    const fs = require("fs");
    const grab = (file, name) => {
      const m = fs.readFileSync(file, "utf8").match(new RegExp("const " + name + " = (\\{[\\s\\S]*?\\n\\s*\\})"));
      if (!m) { console.error("cannot find " + name + " in " + file); process.exit(2); }
      return new Function("return " + m[1])();
    };
    const a = grab(process.argv[1], "ROUTE_KEYS");
    const b = grab(process.argv[2], "SNAPSHOT_ROUTE_KEYS");
    const problems = [];
    for (const p of Object.keys(a)) if (!(p in b)) problems.push("client.js lacks " + p);
    for (const p of Object.keys(b)) if (!(p in a)) problems.push("capture-snapshot.js lacks " + p);
    for (const p of Object.keys(a)) if (p in b && a[p] !== b[p]) problems.push(p + ": capture key " + a[p] + " but client key " + b[p]);
    if (problems.length) { console.error(problems.join("\n")); process.exit(1); }
    console.log("key maps equal (" + Object.keys(a).length + " paths)");
  ' "$1" "$2"
}

setup() {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  ( cd "$REPO_ROOT/project/app/api" && node -e "require.resolve('express'); require.resolve('cors'); require.resolve('gray-matter')" ) >/dev/null 2>&1 \
    || skip "project/app/api dependencies are not installed"

  # pwd -P for the macOS /tmp -> /private/tmp symlink reason given in dashboard-snapshot.bats.
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  PROJ="$(cd "$BATS_TEST_TMPDIR/proj" && pwd -P)"
  mkdir -p "$PROJ/project/board/epics" "$PROJ/project/board/stories" "$PROJ/project/board/tasks" \
           "$PROJ/project/configs" "$PROJ/project/data" "$PROJ/project/logs" \
           "$PROJ/project/rapports/problems" "$PROJ/project/documentation/plans" "$PROJ/project/documentation/summaries"
  git -C "$PROJ" init -q
  # /v1/progress runs board-progress.sh, which resolves the root from project/configs/workflow.json (E92_S03_T02);
  # a real project always has one, and capture aborts on any route error.
  printf '%s\n' '{}' > "$PROJ/project/configs/workflow.json"

  write_item epics E01 "" "" "In Progress"
  write_item stories E01_S01 epic_id E01 "In Progress"
  write_item tasks E01_S01_T01 story_id E01_S01 Passed
  write_item tasks E01_S01_T02 story_id E01_S01 "In Progress"
  write_item tasks E01_S01_T03 story_id E01_S01 Pending
  printf '%s\n' '# Todo' '' > "$PROJ/project/todo.md"
  mkdir -p "$PROJ/project/queue"
}


capture_fixture() {
  CAP_OUT="$BATS_TEST_TMPDIR/snapshot-data.json"
  run bash -c "cd '$BATS_TEST_TMPDIR' && node '$CAPTURE_SRC' --project-root '$PROJ' --out '$CAP_OUT'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$CAP_OUT" ]
}

@test "capture: routes.progressCards is a full envelope with no error" {
  capture_fixture
  run node -e '
    const art = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const env = art.routes.progressCards;
    const fail = (m) => { console.error(m); process.exit(1); };
    if (!env) fail("routes.progressCards is missing");
    for (const k of ["data", "meta", "error"]) if (!(k in env)) fail("envelope lacks " + k);
    if (env.error) fail("routes.progressCards carries an error: " + JSON.stringify(env.error));
    if (!env.data || typeof env.data !== "object") fail("routes.progressCards.data is missing");
    console.log("progressCards envelope ok");
  ' "$CAP_OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "progressCards envelope ok"
}

@test "capture: routes.progressGraph is a full envelope whose data.tasks is present" {
  capture_fixture
  run node -e '
    const art = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const env = art.routes.progressGraph;
    const fail = (m) => { console.error(m); process.exit(1); };
    if (!env) fail("routes.progressGraph is missing");
    for (const k of ["data", "meta", "error"]) if (!(k in env)) fail("envelope lacks " + k);
    if (env.error) fail("routes.progressGraph carries an error: " + JSON.stringify(env.error));
    if (!env.data || !("tasks" in env.data)) fail("routes.progressGraph.data.tasks is missing");
    console.log("progressGraph envelope ok");
  ' "$CAP_OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "progressGraph envelope ok"
}

@test "capture: the new routes sit next to the existing ones and ROUTES lists both paths" {
  capture_fixture
  run node -e '
    const art = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const missing = ["board", "progress", "pipeline", "progressCards", "progressGraph"].filter(k => !art.routes[k]);
    if (missing.length) { console.error("missing: " + missing.join(",")); process.exit(1); }
    console.log("routes ok");
  ' "$CAP_OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -E "^const ROUTES = \[.*'/v1/progress-cards'.*'/v1/progress-graph'" "$CAPTURE_SRC"
}

@test "key maps: both files carry /v1/progress-cards and /v1/progress-graph and are equal" {
  run key_maps_differ "$CAPTURE_SRC" "$CLIENT_SRC"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for f in "$CAPTURE_SRC" "$CLIENT_SRC"; do
    grep -qF "'/v1/progress-cards': 'progressCards'" "$f"
    grep -qF "'/v1/progress-graph': 'progressGraph'" "$f"
  done
}

@test "key maps: the guard fails when the client lacks /v1/progress-graph" {
  cp "$CAPTURE_SRC" "$BATS_TEST_TMPDIR/capture.js"
  grep -vF "'/v1/progress-graph': 'progressGraph'" "$CLIENT_SRC" > "$BATS_TEST_TMPDIR/client.js"
  run key_maps_differ "$BATS_TEST_TMPDIR/capture.js" "$BATS_TEST_TMPDIR/client.js"
  [ "$status" -ne 0 ]
  assert_output_contains "client.js lacks /v1/progress-graph"
}

@test "key maps: the guard fails when the progress-cards key differs" {
  cp "$CAPTURE_SRC" "$BATS_TEST_TMPDIR/capture.js"
  sed "s|'/v1/progress-cards': 'progressCards'|'/v1/progress-cards': 'cardsX'|" "$CLIENT_SRC" > "$BATS_TEST_TMPDIR/client.js"
  run key_maps_differ "$BATS_TEST_TMPDIR/capture.js" "$BATS_TEST_TMPDIR/client.js"
  [ "$status" -ne 0 ]
  assert_output_contains "/v1/progress-cards"
}

run_client_case() {
  # $1 = request path, $2 = route key
  local work="$BATS_TEST_TMPDIR/client-run-$2"
  mkdir -p "$work"
  sed 's|import\.meta\.env\.VITE_API_BASE_URL|undefined|' "$CLIENT_SRC" > "$work/client.mjs"
  cat > "$work/run.mjs" <<JS
const envelope = { data: { schema_version: 1, marker: 'embedded-$2' }, meta: {}, error: null };
let fetchCalls = 0;
globalThis.fetch = () => { fetchCalls += 1; return Promise.reject(new Error('fetch must not be called in snapshot mode')); };
globalThis.document = {
  getElementById: (id) => (id === 'jenga-dashboard-data'
    ? { textContent: JSON.stringify({ schema_version: 1, routes: { $2: envelope } }) }
    : null),
};
const { get } = await import('./client.mjs');
const data = await get('$1');
if (JSON.stringify(data) !== JSON.stringify(envelope.data)) { console.error('unexpected data: ' + JSON.stringify(data)); process.exit(1); }
if (fetchCalls !== 0) { console.error('fetch was called ' + fetchCalls + ' time(s)'); process.exit(1); }
console.log('client resolved $1 from embedded data');
JS
  run node "$work/run.mjs"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "client resolved $1 from embedded data"
}

@test "client: in snapshot mode get('/v1/progress-cards') resolves from the embedded data without calling fetch" {
  run_client_case /v1/progress-cards progressCards
}

@test "client: in snapshot mode get('/v1/progress-graph') resolves from the embedded data without calling fetch" {
  run_client_case /v1/progress-graph progressGraph
}

@test "snapshot HTML: the bundled file embeds routes.progressCards and routes.progressGraph" {
  local ui="$REPO_ROOT/project/app/ui"
  [ -d "$ui/dist" ] || skip "project/app/ui/dist is not built"
  capture_fixture
  local html="$BATS_TEST_TMPDIR/snapshot.html"
  run node -e '
    const { execFileSync } = require("child_process");
    const ui = process.argv[1], data = process.argv[2], out = process.argv[3];
    execFileSync("node", [ui + "/scripts/build-snapshot-html.cjs", "--dist", ui + "/dist", "--data", data, "--out", out], { stdio: "pipe" });
    const html = require("fs").readFileSync(out, "utf8");
    const art = JSON.parse(html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)[1]);
    if (!art.routes.progressCards || !art.routes.progressGraph) { console.error("routes missing in html"); process.exit(1); }
    console.log("html embeds both routes");
  ' "$ui" "$CAP_OUT" "$html"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "html embeds both routes"
}

# ---- E92_S12_T04: the undecomposed story (ghost band) end to end through the offline snapshot ----------------------------------
#
# E02 has three stories: E02_S01 decomposed (two tasks), E02_S02 and E02_S03 with no task file. E03 has two stories and no task at
# all. The capture is the real one (real board-progress.sh --graph behind the real route); the render is the real EpicTreeBody, the
# component the epic overlay mounts, over the captured payload (project/app/ui/scripts/render-captured-epic-tree.cjs). Nothing here
# reimplements the rule: a regression in the flag, the model or the drawing fails one of these.
RENDER_SRC="$REPO_ROOT/project/app/ui/scripts/render-captured-epic-tree.cjs"

write_ghost_fixture() {
  write_item epics E02 "" "" "In Progress"
  write_item stories E02_S01 epic_id E02 "In Progress"
  write_item stories E02_S02 epic_id E02 Pending
  write_item stories E02_S03 epic_id E02 Pending
  write_item tasks E02_S01_T01 story_id E02_S01 Passed
  write_item tasks E02_S01_T02 story_id E02_S01 Pending
  write_item epics E03 "" "" Pending
  write_item stories E03_S01 epic_id E03 Pending
  write_item stories E03_S02 epic_id E03 Pending
}

render_requires() {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  ( cd "$REPO_ROOT/project/app/ui" && node -e "require.resolve('esbuild'); require.resolve('react'); require.resolve('react-dom/server')" ) >/dev/null 2>&1 \
    || skip "project/app/ui dependencies are not installed"
}

# $1 = a snapshot data JSON or a snapshot HTML, $2 = epic id; leaves the facts as one JSON line in $output
render_epic() {
  run node "$RENDER_SRC" --data "$1" --epic "$2"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "ghost bands: the captured routes.progressGraph.data.stories[] carries decomposed true, false, false for the three stories" {
  write_ghost_fixture
  capture_fixture
  run node -e '
    const art = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const stories = art.routes.progressGraph.data.stories;
    const by = Object.fromEntries(stories.map(s => [s.id, s]));
    const got = ["E02_S01", "E02_S02", "E02_S03"].map(id => by[id] && by[id].decomposed);
    const fail = m => { console.error(m); process.exit(1); };
    if (JSON.stringify(got) !== "[true,false,false]") fail("decomposed for E02_S01..S03 is " + JSON.stringify(got));
    // the same story order as captured: ids ascend, so the three stories sit in this order
    const order = stories.filter(s => s.epic_id === "E02").map(s => s.id);
    if (JSON.stringify(order) !== JSON.stringify(["E02_S01", "E02_S02", "E02_S03"])) fail("order " + order);
    // the fixture story of the default setup is decomposed too (it has counted tasks); the flag is a real boolean, never a string
    if (by.E01_S01.decomposed !== true) fail("E01_S01 decomposed is " + by.E01_S01.decomposed);
    for (const s of stories) if (typeof s.decomposed !== "boolean" && s.decomposed !== null) fail(s.id + " decomposed is not true, false or null");
    // the invariant of the documentation: an epic is fully decomposed exactly when none of its stories is undecomposed
    const ep = art.routes.progressGraph.data.epics.find(e => e.id === "E02");
    const decomposedCount = stories.filter(s => s.epic_id === "E02" && s.decomposed === true).length;
    if (!ep.epic_progress || ep.epic_progress.stories !== 3 || ep.epic_progress.decomposed !== decomposedCount) {
      fail("epic_progress " + JSON.stringify(ep.epic_progress) + " disagrees with the per-story flags (" + decomposedCount + " true)");
    }
    console.log("decomposed flags ok");
  ' "$CAP_OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "decomposed flags ok"
}

@test "ghost bands: the real tree over the captured payload draws three bands, two dashed and labelled, no task node in those two" {
  render_requires
  write_ghost_fixture
  capture_fixture
  render_epic "$CAP_OUT" E02
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/facts.json"
  run node -e '
    const f = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const labels = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8")).routes.progressGraph.data.labels;
    const fail = m => { console.error(m); process.exit(1); };
    if (f.empty) fail("the epic with tasks must not show the empty state");
    if (f.bands.length !== 3) fail("expected three bands, got " + f.bands.length);
    if (JSON.stringify(f.bands.map(b => b.story)) !== JSON.stringify(["E02_S01", "E02_S02", "E02_S03"])) fail("band order " + JSON.stringify(f.bands));
    const ghostBands = f.bands.filter(b => b.ghost).map(b => b.story);
    if (JSON.stringify(ghostBands) !== JSON.stringify(["E02_S02", "E02_S03"])) fail("dashed bands " + ghostBands);
    for (const b of f.bands) if (b.ghost !== b.undecomposed) fail("band " + b.story + " class and data attribute disagree");
    if (f.starts.length !== 3) fail("expected three start nodes, got " + f.starts.length);
    // the words come from the captured payload (its labels), never from the component
    if (!labels.story_undecomposed || !labels.story_undecomposed_aria) fail("the captured payload lacks the two undecomposed labels");
    for (const id of ["E02_S02", "E02_S03"]) {
      const s = f.starts.find(x => x.story === id);
      if (!s || !s.ghost || !s.undecomposed) fail(id + " start node is not a ghost start node");
      if (s.count !== "0/0") fail(id + " count is " + s.count);
      if (s.text !== labels.story_undecomposed) fail(id + " text " + JSON.stringify(s.text) + " is not the captured label");
      const aria = labels.story_undecomposed_aria.replace("%s", id + " Title of " + id);
      if (s.aria !== aria) fail(id + " aria " + JSON.stringify(s.aria) + " is not " + JSON.stringify(aria));
      if (f.taskNodes.some(n => n.indexOf(id + "_T") === 0)) fail("a task node inside the undecomposed story " + id);
    }
    const s1 = f.starts.find(x => x.story === "E02_S01");
    if (s1.ghost || s1.undecomposed || s1.text !== null || s1.aria !== null) fail("the decomposed story start node must be drawn as before");
    if (JSON.stringify(f.taskNodes.slice().sort()) !== JSON.stringify(["E02_S01_T01", "E02_S01_T02"])) fail("task nodes " + JSON.stringify(f.taskNodes));
    if (f.ghostEdges !== 2) fail("expected one ghost edge per ghost band, got " + f.ghostEdges);
    console.log("ghost bands rendered ok");
  ' "$BATS_TEST_TMPDIR/facts.json" "$CAP_OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "ghost bands rendered ok"
}

@test "ghost bands: the --snapshot HTML embeds the payload and the ghost bands render from it alone, no server" {
  render_requires
  local ui="$REPO_ROOT/project/app/ui"
  [ -d "$ui/dist" ] || skip "project/app/ui/dist is not built"
  write_ghost_fixture
  capture_fixture
  local html="$BATS_TEST_TMPDIR/snapshot.html"
  run node "$ui/scripts/build-snapshot-html.cjs" --dist "$ui/dist" --data "$CAP_OUT" --out "$html"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # the page reads its data from the embedded element and calls no server: the same element is the render input here
  run grep -c '<script id="jenga-dashboard-data" type="application/json">' "$html"
  [ "$output" = "1" ]
  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const art = JSON.parse(html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)[1]);
    const by = Object.fromEntries(art.routes.progressGraph.data.stories.map(s => [s.id, s.decomposed]));
    if (JSON.stringify([by.E02_S01, by.E02_S02, by.E02_S03]) !== "[true,false,false]") { console.error("embedded flags " + JSON.stringify(by)); process.exit(1); }
    console.log("html embeds the decomposed flags");
  ' "$html"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "html embeds the decomposed flags"
  render_epic "$html" E02
  run node -e '
    const f = JSON.parse(process.argv[1]);
    const ghost = f.starts.filter(s => s.ghost);
    if (f.bands.length !== 3 || f.bands.filter(b => b.ghost).length !== 2 || ghost.length !== 2) { console.error(JSON.stringify(f)); process.exit(1); }
    if (ghost.some(s => !s.text || !s.aria)) { console.error("a ghost start node lacks its label or aria text"); process.exit(1); }
    if (f.taskNodes.some(n => /^E02_S0[23]_/.test(n))) { console.error("a task node in a ghost band"); process.exit(1); }
    console.log("ghost bands render from the snapshot file");
  ' "$output"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "ghost bands render from the snapshot file"
}

@test "ghost bands: an epic whose stories are all undecomposed has no task node and keeps the empty state" {
  render_requires
  write_ghost_fixture
  capture_fixture
  run node -e '
    const art = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const g = art.routes.progressGraph.data;
    const flags = g.stories.filter(s => s.epic_id === "E03").map(s => s.decomposed);
    if (JSON.stringify(flags) !== "[false,false]") { console.error("E03 flags " + JSON.stringify(flags)); process.exit(1); }
    if (g.tasks.some(t => t.epic_id === "E03")) { console.error("E03 must have no task"); process.exit(1); }
    console.log("E03 has two undecomposed stories and no task");
  ' "$CAP_OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  render_epic "$CAP_OUT" E03
  run node -e '
    const f = JSON.parse(process.argv[1]);
    // T02 left the empty rule alone (lib/progress/dependency-structure.js: no task node, no tree): no band, no start node, no ghost edge
    if (!f.empty || f.bands.length !== 0 || f.starts.length !== 0 || f.taskNodes.length !== 0 || f.ghostEdges !== 0) { console.error(JSON.stringify(f)); process.exit(1); }
    console.log("all-undecomposed epic keeps the empty state");
  ' "$output"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "all-undecomposed epic keeps the empty state"
}
