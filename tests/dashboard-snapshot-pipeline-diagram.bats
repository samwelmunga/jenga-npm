#!/usr/bin/env bats
#
# The Jenga pipeline diagram survives the offline snapshot export end to end (E92_S04_T05).
#
# Why this file exists
# ---------------------
# `j.dashboard --snapshot` captures every dashboard route once, inlines the built UI and the captured JSON into one
# HTML file, and the exported page must draw the pipeline diagram from that embedded data over file://, with no server.
# The unit suites prove each piece alone: pipeline-diagram.test.cjs renders PipelineDiagram from a hand-written payload,
# progress-tab.test.cjs proves the tab fetches /v1/pipeline, fails that section on its own and passes the point-in-time
# flag, and the pipeline route / capture tests prove routes.pipeline is written. None of them proves that the REAL
# snapshot.sh output carries that data in a form the diagram can render, so a break between capture, bundle and render
# would pass every one of them.
#
# This suite runs the real skills/j-dashboard/scripts/snapshot.sh (real capture, real UI rebuild, real bundle) over two
# throwaway fixture projects, then renders the embedded routes.pipeline.data with the real PipelineDiagram, and the whole
# Progress tab, through project/app/ui/scripts/progress-view-render.cjs, and asserts on the HTML:
#   busy  one In Progress task and one queued story_rollup trigger (plus a status_review trigger, which must not count)
#         -> `do` and `rollup` active, `todo` and `test` inactive, the point-in-time caption present, no idle caption.
#   idle  an empty board and queue -> no stage active, the idle caption, still the point-in-time caption.
# It also pins that the exported page names no network URL, that a live (non-snapshot) render has no caption, and that the
# other routes are still embedded.
#
# Both snapshots are built once in setup_file (each run rebuilds the UI, which takes seconds); the tests only read them.
# Nothing here touches this repository's own board: the fixtures live in $BATS_FILE_TMPDIR. The suite skips with a message
# when node, the API/UI dependencies or vite are not installed (a consumer install has none of them).

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SNAPSHOT_SH="$REPO_ROOT/skills/j-dashboard/scripts/snapshot.sh"
RENDER="$REPO_ROOT/project/app/ui/scripts/progress-view-render.cjs"

write_item() {
  local root="$1" dir="$2" id="$3" parent_key="$4" parent_id="$5" status="$6"
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
  } > "$root/project/board/$dir/${id}_item.md"
}

# Builds an empty fixture project at $1 (a git repo with the directories and workflow.json a capture needs).
make_project() {
  local root="$1"
  mkdir -p "$root/project/board/epics" "$root/project/board/stories" "$root/project/board/tasks" \
           "$root/project/configs" "$root/project/data" "$root/project/logs" \
           "$root/project/rapports/problems" "$root/project/documentation/plans" \
           "$root/project/documentation/summaries" "$root/project/queue"
  git -C "$root" init -q
  # /v1/progress and /v1/pipeline run scripts that resolve the root from project/configs/workflow.json.
  printf '%s\n' '{}' > "$root/project/configs/workflow.json"
}

# busy: exactly one In Progress task, one queued story_rollup trigger, no todo.md and no tester queue.
#       do=1 rollup=1 todo=0 test=0. The status_review line must not light the rollup stage.
make_project_busy() {
  local r="$1"
  make_project "$r"
  write_item "$r" epics E01 "" "" "In Progress"
  write_item "$r" stories E01_S01 epic_id E01 "In Progress"
  write_item "$r" tasks E01_S01_T01 story_id E01_S01 Passed
  write_item "$r" tasks E01_S01_T02 story_id E01_S01 "In Progress"
  {
    printf '%s\n' '{"type":"story_rollup","story_id":"E01_S01","epic_id":"E01"}'
    printf '%s\n' '{"type":"status_review","session_id":"fixture"}'
  } > "$r/project/queue/scrum_triggers.jsonl"
}

# idle: a board with nothing In Progress, an empty todo.md and an empty queue.
make_project_idle() {
  local r="$1"
  make_project "$r"
  write_item "$r" epics E01 "" "" Passed
  write_item "$r" stories E01_S01 epic_id E01 Passed
  write_item "$r" tasks E01_S01_T01 story_id E01_S01 Passed
  printf '%s\n' '# Todo' '' > "$r/project/todo.md"
  : > "$r/project/queue/scrum_triggers.jsonl"
}

# Prints the reason this suite cannot run, or nothing when it can.
missing_dependency() {
  command -v node >/dev/null 2>&1 || { echo "node is not installed"; return; }
  command -v jq >/dev/null 2>&1 || { echo "jq is not installed"; return; }
  ( cd "$REPO_ROOT/project/app/api" && node -e "require.resolve('express'); require.resolve('cors'); require.resolve('gray-matter')" ) >/dev/null 2>&1 \
    || { echo "project/app/api dependencies are not installed"; return; }
  ( cd "$REPO_ROOT/project/app/ui" && node -e "require.resolve('esbuild'); require.resolve('react-dom/server'); require.resolve('vite')" ) >/dev/null 2>&1 \
    || { echo "project/app/ui dependencies (esbuild, react-dom, vite) are not installed"; return; }
}

setup_file() {
  local why
  why="$(missing_dependency)"
  if [ -n "$why" ]; then
    printf '%s\n' "$why" > "$BATS_FILE_TMPDIR/skip-reason"
    return 0
  fi

  # pwd -P for the macOS /tmp -> /private/tmp symlink reason given in dashboard-snapshot.bats.
  local base
  base="$(cd "$BATS_FILE_TMPDIR" && pwd -P)"
  mkdir -p "$base/busy" "$base/idle" "$base/elsewhere"
  make_project_busy "$base/busy"
  make_project_idle "$base/idle"

  ( cd "$base/elsewhere" && bash "$SNAPSHOT_SH" --out "$base/snap-busy.html" --project-root "$base/busy" ) \
    > "$base/run-busy.out" 2> "$base/run-busy.err" || echo "$?" > "$base/run-busy.failed"
  ( cd "$base/elsewhere" && bash "$SNAPSHOT_SH" --out "$base/snap-idle.html" --project-root "$base/idle" ) \
    > "$base/run-idle.out" 2> "$base/run-idle.err" || echo "$?" > "$base/run-idle.failed"
  printf '%s\n' "$base" > "$BATS_FILE_TMPDIR/base"
}

setup() {
  if [ -f "$BATS_FILE_TMPDIR/skip-reason" ]; then
    skip "$(cat "$BATS_FILE_TMPDIR/skip-reason")"
  fi
  BASE="$(cat "$BATS_FILE_TMPDIR/base")"
  SNAP_BUSY="$BASE/snap-busy.html"
  SNAP_IDLE="$BASE/snap-idle.html"
}

# Prints "true" or "false": the data-active value of stage $2 in the rendered HTML file $1, or "absent".
stage_active() {
  node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const m = html.match(new RegExp("data-stage=\"" + process.argv[2] + "\" data-active=\"(true|false)\""));
    process.stdout.write(m ? m[1] : "absent");
  ' "$1" "$2"
}

# Occurrences of the literal $2 in the file $1.
occurrences() {
  node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    process.stdout.write(String(html.split(process.argv[2]).length - 1));
  ' "$1" "$2"
}

# -----------------------------------------------------------------------------
# The real snapshot.sh runs
# -----------------------------------------------------------------------------

@test "both snapshot runs succeeded and wrote their files" {
  for r in busy idle; do
    if [ -f "$BASE/run-$r.failed" ]; then cat "$BASE/run-$r.out" "$BASE/run-$r.err"; false; fi
  done
  [ -s "$SNAP_BUSY" ]
  [ -s "$SNAP_IDLE" ]
}

# -----------------------------------------------------------------------------
# The embedded data
# -----------------------------------------------------------------------------

@test "the busy snapshot embeds routes.pipeline with do and rollup active and todo and test inactive" {
  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const m = html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/);
    const fail = (msg) => { console.error(msg); process.exit(1); };
    if (!m) fail("no embedded jenga-dashboard-data script");
    const art = JSON.parse(m[1]);
    const env = art.routes && art.routes.pipeline;
    if (!env) fail("routes.pipeline is missing");
    if (env.error) fail("routes.pipeline carries an error: " + JSON.stringify(env.error));
    const stages = env.data && env.data.stages;
    if (!Array.isArray(stages)) fail("routes.pipeline.data.stages is missing");
    console.log(stages.map(s => s.id + "=" + s.count + (s.active ? "+" : "-")).join(" "));
    console.log("active:" + env.data.active.join(","));
    console.log("idle:" + env.data.idle);
  ' "$SNAP_BUSY"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "todo=0- do=1+ test=0- rollup=1+"
  assert_output_contains "active:do,rollup"
  assert_output_contains "idle:false"
}

@test "the other routes are still embedded next to routes.pipeline" {
  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const art = JSON.parse(html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)[1]);
    const missing = ["board", "history", "architecture", "health", "documentation", "rapports", "security", "progress", "pipeline"]
      .filter(k => !(art.routes && art.routes[k]));
    if (missing.length) { console.error("missing routes: " + missing.join(",")); process.exit(1); }
    console.log("all routes embedded");
  ' "$SNAP_BUSY"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "all routes embedded"
}

# -----------------------------------------------------------------------------
# The rendered diagram
# -----------------------------------------------------------------------------

@test "rendering the busy snapshot highlights do and rollup and leaves todo and test inactive" {
  node "$RENDER" --pipeline "$SNAP_BUSY" > "$BATS_TEST_TMPDIR/pipeline-busy.html"
  [ "$(stage_active "$BATS_TEST_TMPDIR/pipeline-busy.html" todo)" = "false" ]
  [ "$(stage_active "$BATS_TEST_TMPDIR/pipeline-busy.html" do)" = "true" ]
  [ "$(stage_active "$BATS_TEST_TMPDIR/pipeline-busy.html" test)" = "false" ]
  [ "$(stage_active "$BATS_TEST_TMPDIR/pipeline-busy.html" rollup)" = "true" ]
  # colour is not the only signal: the "● active" text appears for the two active stages only
  [ "$(occurrences "$BATS_TEST_TMPDIR/pipeline-busy.html" 'pipeline-marker')" = "2" ]
  assert_contains "$(cat "$BATS_TEST_TMPDIR/pipeline-busy.html")" 'Jenga pipeline: Do (1) and Rollup (1) active.'
  assert_not_contains "$(cat "$BATS_TEST_TMPDIR/pipeline-busy.html")" 'data-caption="idle"'
}

@test "the snapshot diagram carries the point-in-time caption" {
  node "$RENDER" --pipeline "$SNAP_BUSY" > "$BATS_TEST_TMPDIR/pipeline-busy.html"
  [ "$(occurrences "$BATS_TEST_TMPDIR/pipeline-busy.html" 'data-caption="snapshot"')" = "1" ]
  assert_contains "$(cat "$BATS_TEST_TMPDIR/pipeline-busy.html")" 'Point-in-time snapshot: reflects the board when it was captured'
}

@test "a live render of the same payload has no point-in-time caption" {
  run node -e '
    const { renderPipelineDiagram, pipelineFromSnapshot } = require(process.argv[1]);
    const data = pipelineFromSnapshot(require("fs").readFileSync(process.argv[2], "utf8"));
    const live = renderPipelineDiagram(data, { pointInTime: false });
    const snap = renderPipelineDiagram(data);
    console.log("live:" + live.includes("Point-in-time") + " snapshot:" + snap.includes("Point-in-time"));
  ' "$RENDER" "$SNAP_BUSY"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "live:false snapshot:true"
}

@test "the idle snapshot shows no active stage, the idle caption and the point-in-time caption" {
  node "$RENDER" --pipeline "$SNAP_IDLE" > "$BATS_TEST_TMPDIR/pipeline-idle.html"
  for s in todo do test rollup; do
    [ "$(stage_active "$BATS_TEST_TMPDIR/pipeline-idle.html" "$s")" = "false" ]
  done
  [ "$(occurrences "$BATS_TEST_TMPDIR/pipeline-idle.html" 'pipeline-marker')" = "0" ]
  [ "$(occurrences "$BATS_TEST_TMPDIR/pipeline-idle.html" 'data-caption="idle"')" = "1" ]
  [ "$(occurrences "$BATS_TEST_TMPDIR/pipeline-idle.html" 'data-caption="snapshot"')" = "1" ]
}

@test "the Progress tab of the busy snapshot shows the four pies and, below them, the diagram" {
  node "$RENDER" --tab "$SNAP_BUSY" > "$BATS_TEST_TMPDIR/tab-busy.html"
  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const titles = [...html.matchAll(/data-chart="([^"]+)"/g)].map(m => m[1]);
    const view = html.indexOf("data-testid=\"progress-view\"");
    const diagram = html.indexOf("data-testid=\"pipeline-diagram\"");
    console.log(titles.join(","));
    console.log(view >= 0 && diagram > view ? "diagram below pies" : "wrong order");
    console.log("errors:" + (html.match(/class="error-message"/g) || []).length);
  ' "$BATS_TEST_TMPDIR/tab-busy.html"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "Tasks,Stories,Epics,Backlog"
  assert_output_contains "diagram below pies"
  assert_output_contains "errors:0"
  [ "$(stage_active "$BATS_TEST_TMPDIR/tab-busy.html" do)" = "true" ]
  [ "$(stage_active "$BATS_TEST_TMPDIR/tab-busy.html" rollup)" = "true" ]
}

@test "the render helper fails on a snapshot that carries no routes.pipeline" {
  printf '%s\n' '{"schema_version":1,"routes":{"progress":{"data":{"charts":{}}}}}' > "$BATS_TEST_TMPDIR/old.json"
  run node "$RENDER" --pipeline "$BATS_TEST_TMPDIR/old.json"
  [ "$status" -eq 1 ]
  assert_output_contains "carries no routes.pipeline.data"
  run node "$RENDER" --tab "$BATS_TEST_TMPDIR/old.json"
  [ "$status" -eq 1 ]
  assert_output_contains "carries no routes.pipeline.data"
}

@test "without a flag the render helper still prints the progress view only" {
  node "$RENDER" "$SNAP_BUSY" > "$BATS_TEST_TMPDIR/view.html"
  assert_contains "$(cat "$BATS_TEST_TMPDIR/view.html")" 'data-testid="progress-view"'
  assert_not_contains "$(cat "$BATS_TEST_TMPDIR/view.html")" 'pipeline-diagram'
}

# -----------------------------------------------------------------------------
# No network
# -----------------------------------------------------------------------------

@test "the snapshots load no external script or stylesheet and the pipeline data and diagram carry no URL" {
  for snap in "$SNAP_BUSY" "$SNAP_IDLE"; do
    run grep -Eq '<(script|link)[^>]*[[:space:]](src|href)="(https?:)?//' "$snap"
    [ "$status" -eq 1 ]
    run node -e '
      const html = require("fs").readFileSync(process.argv[1], "utf8");
      const art = JSON.parse(html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)[1]);
      const urls = [];
      const walk = (v, p) => {
        if (typeof v === "string" && /^https?:\/\//i.test(v)) urls.push(p + " = " + v);
        else if (v && typeof v === "object") for (const k of Object.keys(v)) walk(v[k], p + "." + k);
      };
      walk(art.routes.pipeline, "routes.pipeline");
      if (urls.length) { console.error(urls.join("\n")); process.exit(1); }
      console.log("no url in routes.pipeline");
    ' "$snap"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done

  node "$RENDER" --tab "$SNAP_BUSY" > "$BATS_TEST_TMPDIR/tab-busy.html"
  run grep -Eqi 'https?://' "$BATS_TEST_TMPDIR/tab-busy.html"
  [ "$status" -eq 1 ]
}
