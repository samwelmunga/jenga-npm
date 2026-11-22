#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# The four progress pie charts survive the offline snapshot export end to end (E92_S03_T07).
#
# Why this file exists
# ---------------------
# `j.dashboard --snapshot` captures every dashboard route once, inlines the built UI and the captured JSON into one
# HTML file, and the exported page must draw the charts from that embedded data over file://, with no server. The unit
# suites prove each piece alone: progress-view.test.cjs renders ProgressView from a hand-written payload,
# progress-tab.test.cjs proves the client answers from routes.progress in snapshot mode, and
# dashboard-snapshot-progress.bats proves the capture writes routes.progress. None of them proves that the REAL
# snapshot.sh output carries that data in a form the view can render, so a break between capture, bundle and render
# would pass every one of them.
#
# This suite runs the real skills/j-dashboard/scripts/snapshot.sh (real capture, real UI rebuild, real bundle) over
# throwaway fixture projects, then renders the embedded routes.progress.data with the real ProgressView through
# project/app/ui/scripts/progress-view-render.cjs and asserts on the HTML: four charts, the legend counts, the
# Rejected slice and legend row, and the Nothing to show state. It also pins that nothing in the exported page names a
# network URL or a charting-library CDN, and that --out, --project-root and --data-url behave as before.
#
# The three fixture snapshots are built once in setup_file (each run rebuilds the UI, which takes seconds); the tests
# only read them. Nothing here touches this repository's own board: the fixtures live in $BATS_FILE_TMPDIR.
# The suite skips with a message when node, the API/UI dependencies or vite are not installed (a consumer install
# has none of them; the consumer path of snapshot.sh is covered by dashboard-snapshot.bats).

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
  # /v1/progress runs board-progress.sh, which resolves the root from project/configs/workflow.json.
  printf '%s\n' '{}' > "$root/project/configs/workflow.json"
}

# A: rejected items, queued backlog.
#    tasks: Passed 2, In Progress 1, Failed 1, Pending 1, Rejected 2 (denominator 5)
#    stories: Passed 2, In Progress 1, Pending 1; epics: Passed 1, In Progress 1
#    backlog (todo.md): one Pending task, one In Progress task
make_project_a() {
  local r="$1"
  make_project "$r"
  write_item "$r" epics E01 "" "" "In Progress"
  write_item "$r" epics E02 "" "" Passed
  write_item "$r" stories E01_S01 epic_id E01 Passed
  write_item "$r" stories E01_S02 epic_id E01 "In Progress"
  write_item "$r" stories E01_S03 epic_id E01 Pending
  write_item "$r" stories E02_S01 epic_id E02 Passed
  write_item "$r" tasks E01_S01_T01 story_id E01_S01 Passed
  write_item "$r" tasks E01_S01_T02 story_id E01_S01 Passed
  write_item "$r" tasks E01_S02_T01 story_id E01_S02 "In Progress"
  write_item "$r" tasks E01_S02_T02 story_id E01_S02 Failed
  write_item "$r" tasks E01_S03_T01 story_id E01_S03 Pending
  write_item "$r" tasks E01_S03_T02 story_id E01_S03 Rejected
  write_item "$r" tasks E01_S03_T03 story_id E01_S03 Rejected
  printf '%s\n' '# Todo' '' 'Queued pending mission: E01_S03_T01' 'Queued running mission: E01_S02_T01' > "$r/project/todo.md"
}

# B and C: nothing rejected. tasks: Passed 1, Pending 1; one story, one epic.
make_project_plain() {
  local r="$1"
  make_project "$r"
  write_item "$r" epics E01 "" "" "In Progress"
  write_item "$r" stories E01_S01 epic_id E01 "In Progress"
  write_item "$r" tasks E01_S01_T01 story_id E01_S01 Passed
  write_item "$r" tasks E01_S01_T02 story_id E01_S01 Pending
}

# Prints the reason this suite cannot run, or nothing when it can.
missing_dependency() {
  command -v node >/dev/null 2>&1 || { echo "node is not installed"; return; }
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
  local base other
  base="$(cd "$BATS_FILE_TMPDIR" && pwd -P)"
  mkdir -p "$base/a" "$base/b" "$base/c" "$base/elsewhere"
  make_project_a "$base/a"
  make_project_plain "$base/b"
  make_project_plain "$base/c"          # c has no project/todo.md at all
  printf '%s\n' '# Todo' '' > "$base/b/project/todo.md"   # b has an empty todo.md
  other="$base/elsewhere"

  # A: invoked from a directory that is not the project, with --out, --project-root and --data-url.
  ( cd "$other" && bash "$SNAPSHOT_SH" --out "$base/snap-a.html" --project-root "$base/a" --data-url ) \
    > "$base/run-a.out" 2> "$base/run-a.err" || echo "$?" > "$base/run-a.failed"
  # B: invoked from the project itself with no flags: the default --out is <cwd>/jenga.html.
  ( cd "$base/b" && bash "$SNAPSHOT_SH" ) > "$base/run-b.out" 2> "$base/run-b.err" || echo "$?" > "$base/run-b.failed"
  # C: --project-root again, with the todo.md missing.
  ( cd "$other" && bash "$SNAPSHOT_SH" --out "$base/snap-c.html" --project-root "$base/c" ) \
    > "$base/run-c.out" 2> "$base/run-c.err" || echo "$?" > "$base/run-c.failed"
  printf '%s\n' "$base" > "$BATS_FILE_TMPDIR/base"
}

setup() {
  if [ -f "$BATS_FILE_TMPDIR/skip-reason" ]; then
    skip "$(cat "$BATS_FILE_TMPDIR/skip-reason")"
  fi
  BASE="$(cat "$BATS_FILE_TMPDIR/base")"
  SNAP_A="$BASE/snap-a.html"
  SNAP_B="$BASE/b/jenga.html"
  SNAP_C="$BASE/snap-c.html"
}

# The text of the chart section titled $2 ("Tasks", "Stories", "Epics", "Backlog") in the rendered view $1.
chart_section() {
  node -e '
    const fs = require("fs");
    const sections = fs.readFileSync(process.argv[1], "utf8").split("<section ").slice(1);
    const hit = sections.find(s => s.includes("data-chart=\"" + process.argv[2] + "\""));
    if (!hit) { console.error("no chart titled " + process.argv[2]); process.exit(1); }
    process.stdout.write("<section " + hit);
  ' "$1" "$2"
}

# The legend count shown for slice key $3 ("done", "rejected", ...) in chart $2 of rendered view $1, or "absent".
legend_count() {
  chart_section "$1" "$2" | node -e '
    const html = require("fs").readFileSync(0, "utf8");
    const m = html.match(new RegExp("<li [^>]*data-legend=\"" + process.argv[1] + "\".*?progress-legend-count\">(\\d+)<"));
    process.stdout.write(m ? m[1] : "absent");
  ' "$3"
}

# Renders the progress view of snapshot $1 into $2.
render_to() {
  node "$RENDER" "$1" > "$2"
}

# -----------------------------------------------------------------------------
# The real snapshot.sh runs
# -----------------------------------------------------------------------------

@test "the three snapshot runs succeeded and wrote their files" {
  for r in a b c; do
    if [ -f "$BASE/run-$r.failed" ]; then cat "$BASE/run-$r.out" "$BASE/run-$r.err"; false; fi
  done
  [ -s "$SNAP_A" ]
  [ -s "$SNAP_B" ]
  [ -s "$SNAP_C" ]
}

# -----------------------------------------------------------------------------
# The embedded data and the rendered view
# -----------------------------------------------------------------------------

@test "the snapshot HTML embeds routes.progress with the four charts' data" {
  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const m = html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/);
    const fail = (msg) => { console.error(msg); process.exit(1); };
    if (!m) fail("no embedded jenga-dashboard-data script");
    const art = JSON.parse(m[1]);
    const env = art.routes && art.routes.progress;
    if (!env) fail("routes.progress is missing");
    if (env.error) fail("routes.progress carries an error: " + JSON.stringify(env.error));
    const charts = env.data && env.data.charts;
    if (!charts) fail("routes.progress.data.charts is missing");
    for (const k of ["tasks", "stories", "epics", "backlog"]) if (!(k in charts)) fail("charts." + k + " is missing");
    console.log("embedded progress data ok");
  ' "$SNAP_A"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "embedded progress data ok"
}

@test "rendering the embedded data gives four charts in order with the fixture's legend counts" {
  render_to "$SNAP_A" "$BATS_TEST_TMPDIR/view-a.html"
  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const titles = [...html.matchAll(/data-chart="([^"]+)"/g)].map(m => m[1]);
    console.log(titles.join(","));
    console.log((html.match(/data-testid="progress-chart"/g) || []).length);
  ' "$BATS_TEST_TMPDIR/view-a.html"
  [ "$status" -eq 0 ]
  assert_output_contains "Tasks,Stories,Epics,Backlog"
  assert_output_contains "4"

  # tasks: Passed 2, In Progress 1, Failed 1, Pending 1, Rejected 2
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Tasks done)" = "2" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Tasks in_progress)" = "1" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Tasks failed)" = "1" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Tasks pending)" = "1" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Tasks rejected)" = "2" ]
  # stories: Passed 2, In Progress 1, Pending 1; epics: Passed 1, In Progress 1
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Stories done)" = "2" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Stories in_progress)" = "1" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Stories pending)" = "1" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Stories failed)" = "absent" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Epics done)" = "1" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Epics in_progress)" = "1" ]
  # headline of the tasks chart: 2 done of the 5 counted (rejected is not in the denominator)
  assert_contains "$(cat "$BATS_TEST_TMPDIR/view-a.html")" "2 of 5 done"
}

@test "a fixture with Rejected items has the Rejected slice and its own legend row" {
  render_to "$SNAP_A" "$BATS_TEST_TMPDIR/view-a.html"
  chart_section "$BATS_TEST_TMPDIR/view-a.html" Tasks > "$BATS_TEST_TMPDIR/tasks-a.html"
  assert_contains "$(cat "$BATS_TEST_TMPDIR/tasks-a.html")" 'data-slice="rejected"'
  assert_contains "$(cat "$BATS_TEST_TMPDIR/tasks-a.html")" 'data-legend="rejected"'
  assert_contains "$(cat "$BATS_TEST_TMPDIR/tasks-a.html")" 'Rejected (not counted)'
  assert_contains "$(cat "$BATS_TEST_TMPDIR/tasks-a.html")" 'var(--color-progress-rejected)'
  # no other chart has rejected items, so none shows the slice
  for c in Stories Epics Backlog; do
    [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" "$c" rejected)" = "absent" ]
  done
}

@test "a fixture without Rejected items has no Rejected slice, legend row, label or colour" {
  for snap in "$SNAP_B" "$SNAP_C"; do
    render_to "$snap" "$BATS_TEST_TMPDIR/view.html"
    assert_not_contains "$(cat "$BATS_TEST_TMPDIR/view.html")" 'data-slice="rejected"'
    assert_not_contains "$(cat "$BATS_TEST_TMPDIR/view.html")" 'data-legend="rejected"'
    assert_not_contains "$(cat "$BATS_TEST_TMPDIR/view.html")" 'Rejected (not counted)'
    assert_not_contains "$(cat "$BATS_TEST_TMPDIR/view.html")" 'color-progress-rejected'
  done
}

@test "an empty todo.md renders Nothing to show for the Backlog chart only" {
  render_to "$SNAP_B" "$BATS_TEST_TMPDIR/view-b.html"
  chart_section "$BATS_TEST_TMPDIR/view-b.html" Backlog > "$BATS_TEST_TMPDIR/backlog-b.html"
  assert_contains "$(cat "$BATS_TEST_TMPDIR/backlog-b.html")" 'Nothing to show'
  assert_not_contains "$(cat "$BATS_TEST_TMPDIR/backlog-b.html")" '<svg'
  # the three board charts still have items
  for c in Tasks Stories Epics; do
    chart_section "$BATS_TEST_TMPDIR/view-b.html" "$c" > "$BATS_TEST_TMPDIR/section.html"
    assert_not_contains "$(cat "$BATS_TEST_TMPDIR/section.html")" 'Nothing to show'
    assert_contains "$(cat "$BATS_TEST_TMPDIR/section.html")" '<svg'
  done
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-b.html" Tasks done)" = "1" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-b.html" Tasks pending)" = "1" ]
}

@test "a missing todo.md renders Nothing to show for the Backlog chart" {
  [ ! -e "$BASE/c/project/todo.md" ]
  render_to "$SNAP_C" "$BATS_TEST_TMPDIR/view-c.html"
  chart_section "$BATS_TEST_TMPDIR/view-c.html" Backlog > "$BATS_TEST_TMPDIR/backlog-c.html"
  assert_contains "$(cat "$BATS_TEST_TMPDIR/backlog-c.html")" 'Nothing to show'
  assert_not_contains "$(cat "$BATS_TEST_TMPDIR/backlog-c.html")" '<svg'
}

@test "queued todo.md entries render a non-empty Backlog chart" {
  render_to "$SNAP_A" "$BATS_TEST_TMPDIR/view-a.html"
  chart_section "$BATS_TEST_TMPDIR/view-a.html" Backlog > "$BATS_TEST_TMPDIR/backlog-a.html"
  assert_not_contains "$(cat "$BATS_TEST_TMPDIR/backlog-a.html")" 'Nothing to show'
  assert_contains "$(cat "$BATS_TEST_TMPDIR/backlog-a.html")" '<svg'
  # the two queued tasks: one Pending, one In Progress
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Backlog pending)" = "1" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Backlog in_progress)" = "1" ]
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Backlog done)" = "absent" ]
}

@test "the render helper fails on a snapshot that carries no routes.progress" {
  printf '%s\n' '{"schema_version":1,"routes":{"board":{"data":[]}}}' > "$BATS_TEST_TMPDIR/old.json"
  run node "$RENDER" "$BATS_TEST_TMPDIR/old.json"
  [ "$status" -eq 1 ]
  assert_output_contains "carries no routes.progress.data"
}

# -----------------------------------------------------------------------------
# No network for chart data
# -----------------------------------------------------------------------------

@test "the snapshot loads no external script or stylesheet and names no charting-library CDN" {
  for snap in "$SNAP_A" "$SNAP_B" "$SNAP_C"; do
    run grep -Eq '<(script|link)[^>]*[[:space:]](src|href)="(https?:)?//' "$snap"
    [ "$status" -eq 1 ]
    for cdn in cdn.jsdelivr.net unpkg.com cdnjs.cloudflare.com d3js.org cdn.plot.ly code.highcharts.com cdn.jsdelivr; do
      run grep -Fq "$cdn" "$snap"
      [ "$status" -eq 1 ]
    done
  done
}

@test "no value of the embedded data is a network URL, and the rendered charts carry none" {
  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const m = html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/);
    const art = JSON.parse(m[1]);
    const urls = [];
    const walk = (v, p) => {
      if (typeof v === "string" && /^https?:\/\//i.test(v)) urls.push(p + " = " + v);
      else if (v && typeof v === "object") for (const k of Object.keys(v)) walk(v[k], p + "." + k);
    };
    walk(art.routes.progress, "routes.progress");
    if (urls.length) { console.error(urls.join("\n")); process.exit(1); }
    console.log("no url in routes.progress");
  ' "$SNAP_A"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  render_to "$SNAP_A" "$BATS_TEST_TMPDIR/view-a.html"
  run grep -Eqi 'https?://' "$BATS_TEST_TMPDIR/view-a.html"
  [ "$status" -eq 1 ]
}

# -----------------------------------------------------------------------------
# --out, --project-root and --data-url are unchanged
# -----------------------------------------------------------------------------

@test "--out is honoured and reported; with no --out the default is <cwd>/jenga.html" {
  grep -Fq "Snapshot dashboard written to: $BASE/snap-a.html" "$BASE/run-a.out"
  grep -Fq "Snapshot dashboard written to: $BASE/b/jenga.html" "$BASE/run-b.out"
  grep -Fq "Snapshot dashboard written to: $BASE/snap-c.html" "$BASE/run-c.out"
  [ ! -e "$BASE/elsewhere/jenga.html" ]
}

@test "--project-root reads the named project, not the invocation directory" {
  # run A and C were started from $BASE/elsewhere, which has no board; their charts still show the named project.
  render_to "$SNAP_A" "$BATS_TEST_TMPDIR/view-a.html"
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-a.html" Tasks rejected)" = "2" ]
  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const art = JSON.parse(html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)[1]);
    console.log(art.project_root);
  ' "$SNAP_A"
  [ "$status" -eq 0 ]
  assert_output_contains "$BASE/a"
}

@test "--data-url prints a data URI that decodes to the --out file" {
  local uri
  uri="$(grep -E '^data:text/html;base64,' "$BASE/run-a.out")"
  [ -n "$uri" ]
  printf '%s' "${uri#data:text/html;base64,}" | base64 -d > "$BATS_TEST_TMPDIR/decoded.html" 2>/dev/null \
    || printf '%s' "${uri#data:text/html;base64,}" | base64 -D > "$BATS_TEST_TMPDIR/decoded.html"
  cmp "$BATS_TEST_TMPDIR/decoded.html" "$SNAP_A"
  # and the decoded page still carries the progress data
  render_to "$BATS_TEST_TMPDIR/decoded.html" "$BATS_TEST_TMPDIR/view-decoded.html"
  [ "$(legend_count "$BATS_TEST_TMPDIR/view-decoded.html" Tasks done)" = "2" ]
  # the runs without --data-url print no data URI
  run grep -c '^data:text/html' "$BASE/run-b.out"
  [ "$output" = "0" ]
}
