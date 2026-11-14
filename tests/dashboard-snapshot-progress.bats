#!/usr/bin/env bats
#
# /v1/progress and /v1/pipeline in the offline dashboard snapshot (E92_S03_T02, extended by E92_S04_T03).
#
# Why this file exists
# ---------------------
# `j.dashboard --snapshot` calls every dashboard route once (project/app/api/scripts/capture-snapshot.js) and embeds the
# envelopes; the UI client (project/app/ui/src/api/client.js) reads them back by mapping a request path to the artifact's
# routes.<key>. The two files each hold one copy of that path-to-key map, and both say "keep these in sync". If they drift,
# a route is captured but the client throws "no embedded snapshot data" in the exported file, which no live run shows.
#
# Pinned here:
#   1. a real capture over a fixture project yields routes.progress and routes.pipeline holding the /v1/progress and
#      /v1/pipeline envelopes;
#   2. the two key maps are equal, and a deliberate difference (a changed key, a missing path, an extra path) fails the
#      comparison, so the guard is proven to be able to fail;
#   3. in snapshot mode the real client.js resolves get('/v1/progress') and get('/v1/pipeline') from the embedded data
#      without calling fetch.
#
# Nothing here touches the live board: the fixture project is built in $BATS_TEST_TMPDIR and the capture server binds
# 127.0.0.1 on an OS-assigned port. The suite skips with a message when node or the API dependencies are not installed.

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

@test "capture: a run over a fixture project writes routes.progress holding the /v1/progress envelope" {
  local out="$BATS_TEST_TMPDIR/snapshot-data.json"
  run bash -c "cd '$BATS_TEST_TMPDIR' && node '$CAPTURE_SRC' --project-root '$PROJ' --out '$out'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "progress"
  [ -f "$out" ]

  run node -e '
    const art = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const env = art.routes.progress;
    const fail = (m) => { console.error(m); process.exit(1); };
    if (!env) fail("routes.progress is missing");
    if (env.error) fail("routes.progress carries an error: " + JSON.stringify(env.error));
    if (!env.data || typeof env.data !== "object") fail("routes.progress.data is missing");
    const charts = env.data.charts;
    if (!charts) fail("routes.progress.data.charts is missing");
    for (const k of ["tasks", "stories", "epics", "backlog"]) if (!(k in charts)) fail("charts." + k + " is missing");
    console.log("progress envelope ok");
  ' "$out"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "progress envelope ok"
}

@test "capture: a run over a fixture project writes routes.pipeline holding the /v1/pipeline envelope" {
  local out="$BATS_TEST_TMPDIR/snapshot-data.json"
  run bash -c "cd '$BATS_TEST_TMPDIR' && node '$CAPTURE_SRC' --project-root '$PROJ' --out '$out'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "pipeline"
  [ -f "$out" ]

  run node -e '
    const art = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const env = art.routes.pipeline;
    const fail = (m) => { console.error(m); process.exit(1); };
    if (!env) fail("routes.pipeline is missing");
    if (env.error) fail("routes.pipeline carries an error: " + JSON.stringify(env.error));
    if (!env.data || typeof env.data !== "object") fail("routes.pipeline.data is missing");
    for (const k of ["schema_version", "stages", "active", "idle", "skipped"]) if (!(k in env.data)) fail("data." + k + " is missing");
    console.log("pipeline envelope ok");
  ' "$out"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "pipeline envelope ok"
}

@test "key maps: capture-snapshot.js and client.js hold the same path-to-key map, including /v1/progress" {
  run key_maps_differ "$CAPTURE_SRC" "$CLIENT_SRC"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "key maps equal"
  grep -qF "'/v1/progress': 'progress'" "$CAPTURE_SRC"
  grep -qF "'/v1/progress': 'progress'" "$CLIENT_SRC"
}

@test "key maps: both files hold /v1/pipeline under the key pipeline, and the capture lists the route" {
  run key_maps_differ "$CAPTURE_SRC" "$CLIENT_SRC"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF "'/v1/pipeline': 'pipeline'" "$CAPTURE_SRC"
  grep -qF "'/v1/pipeline': 'pipeline'" "$CLIENT_SRC"
  grep -E "^const ROUTES = \[.*'/v1/pipeline'" "$CAPTURE_SRC"
}

@test "key maps: the guard fails when the client lacks /v1/pipeline" {
  cp "$CAPTURE_SRC" "$BATS_TEST_TMPDIR/capture.js"
  grep -vF "'/v1/pipeline': 'pipeline'" "$CLIENT_SRC" > "$BATS_TEST_TMPDIR/client.js"
  run key_maps_differ "$BATS_TEST_TMPDIR/capture.js" "$BATS_TEST_TMPDIR/client.js"
  [ "$status" -ne 0 ]
  assert_output_contains "client.js lacks /v1/pipeline"
}

@test "key maps: the guard fails when the pipeline key differs between the two files" {
  cp "$CAPTURE_SRC" "$BATS_TEST_TMPDIR/capture.js"
  sed "s|'/v1/pipeline': 'pipeline'|'/v1/pipeline': 'pipelineX'|" "$CLIENT_SRC" > "$BATS_TEST_TMPDIR/client.js"
  run key_maps_differ "$BATS_TEST_TMPDIR/capture.js" "$BATS_TEST_TMPDIR/client.js"
  [ "$status" -ne 0 ]
  assert_output_contains "/v1/pipeline"
}

@test "key maps: the guard fails when a key differs between the two files" {
  cp "$CAPTURE_SRC" "$BATS_TEST_TMPDIR/capture.js"
  sed "s|'/v1/progress': 'progress'|'/v1/progress': 'progressX'|" "$CLIENT_SRC" > "$BATS_TEST_TMPDIR/client.js"
  run key_maps_differ "$BATS_TEST_TMPDIR/capture.js" "$BATS_TEST_TMPDIR/client.js"
  [ "$status" -ne 0 ]
  assert_output_contains "/v1/progress"
}

@test "key maps: the guard fails when the client lacks a path the capture has" {
  cp "$CAPTURE_SRC" "$BATS_TEST_TMPDIR/capture.js"
  grep -vF "'/v1/progress': 'progress'" "$CLIENT_SRC" > "$BATS_TEST_TMPDIR/client.js"
  run key_maps_differ "$BATS_TEST_TMPDIR/capture.js" "$BATS_TEST_TMPDIR/client.js"
  [ "$status" -ne 0 ]
  assert_output_contains "client.js lacks /v1/progress"
}

@test "key maps: the guard fails when the client has a path the capture lacks" {
  cp "$CLIENT_SRC" "$BATS_TEST_TMPDIR/client.js"
  grep -vF "'/v1/progress': 'progress'" "$CAPTURE_SRC" > "$BATS_TEST_TMPDIR/capture.js"
  run key_maps_differ "$BATS_TEST_TMPDIR/capture.js" "$BATS_TEST_TMPDIR/client.js"
  [ "$status" -ne 0 ]
  assert_output_contains "capture-snapshot.js lacks /v1/progress"
}

@test "client: in snapshot mode get('/v1/progress') resolves from the embedded data without calling fetch" {
  # Import the real client.js as an ES module with its one Vite-only expression (import.meta.env) neutralised, a stub
  # document that carries the embedded <script id="jenga-dashboard-data"> element, and a fetch that fails the test.
  local work="$BATS_TEST_TMPDIR/client-run"
  mkdir -p "$work"
  sed 's|import\.meta\.env\.VITE_API_BASE_URL|undefined|' "$CLIENT_SRC" > "$work/client.mjs"
  cat > "$work/run.mjs" <<'JS'
const envelope = { data: { schema_version: 1, charts: { tasks: { marker: 'embedded-progress' } } }, meta: {}, error: null };
let fetchCalls = 0;
globalThis.fetch = () => { fetchCalls += 1; return Promise.reject(new Error('fetch must not be called in snapshot mode')); };
globalThis.document = {
  getElementById: (id) => (id === 'jenga-dashboard-data'
    ? { textContent: JSON.stringify({ schema_version: 1, routes: { progress: envelope } }) }
    : null),
};
const { get } = await import('./client.mjs');
const data = await get('/v1/progress');
if (JSON.stringify(data) !== JSON.stringify(envelope.data)) { console.error('unexpected data: ' + JSON.stringify(data)); process.exit(1); }
if (fetchCalls !== 0) { console.error('fetch was called ' + fetchCalls + ' time(s)'); process.exit(1); }
console.log('client resolved /v1/progress from embedded data');
JS
  run node "$work/run.mjs"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "client resolved /v1/progress from embedded data"
}

@test "client: in snapshot mode get('/v1/pipeline') resolves from the embedded data without calling fetch" {
  local work="$BATS_TEST_TMPDIR/client-run-pipeline"
  mkdir -p "$work"
  sed 's|import\.meta\.env\.VITE_API_BASE_URL|undefined|' "$CLIENT_SRC" > "$work/client.mjs"
  cat > "$work/run.mjs" <<'JS'
const envelope = { data: { schema_version: 1, stages: [], active: ['marker-embedded-pipeline'], idle: [], skipped: [] }, meta: {}, error: null };
let fetchCalls = 0;
globalThis.fetch = () => { fetchCalls += 1; return Promise.reject(new Error('fetch must not be called in snapshot mode')); };
globalThis.document = {
  getElementById: (id) => (id === 'jenga-dashboard-data'
    ? { textContent: JSON.stringify({ schema_version: 1, routes: { pipeline: envelope } }) }
    : null),
};
const { get } = await import('./client.mjs');
const data = await get('/v1/pipeline');
if (JSON.stringify(data) !== JSON.stringify(envelope.data)) { console.error('unexpected data: ' + JSON.stringify(data)); process.exit(1); }
if (fetchCalls !== 0) { console.error('fetch was called ' + fetchCalls + ' time(s)'); process.exit(1); }
console.log('client resolved /v1/pipeline from embedded data');
JS
  run node "$work/run.mjs"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "client resolved /v1/pipeline from embedded data"
}
