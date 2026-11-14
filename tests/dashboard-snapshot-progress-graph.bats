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
