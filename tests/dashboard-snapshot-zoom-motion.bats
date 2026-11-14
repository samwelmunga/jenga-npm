#!/usr/bin/env bats
#
# The overlay tree's zoom controls and the dashboard's Animations toggle in the offline snapshot (E92_S06_T21).
#
# Both are part of the bundled UI, so a snapshot contains them without any change to the snapshot scripts. What has to
# hold, and is pinned here:
#   1. the new label keys (zoom_*, motion_*) reach the captured payloads: routes.progressCards.data.labels (which the top
#      bar's toggle reads through the progress client) and routes.progressGraph.data.labels (which the tree reads), in
#      English and, with JENGA_PROGRESS_LANG=sv, in Swedish;
#   2. a snapshot HTML built from a fresh build of the UI carries the inline pre-paint script for the stored motion
#      preference, the toggle and the zoom controls, and still embeds the labels. The structure is checked, not a
#      browser; opening it from file:// is the manual check recorded in the task summary.
# The fixture project lives in $BATS_TEST_TMPDIR; the capture server binds 127.0.0.1 on an OS-assigned port.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAPTURE_SRC="$REPO_ROOT/project/app/api/scripts/capture-snapshot.js"

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

NEW_KEYS="zoom_group zoom_out zoom_in zoom_fit zoom_actual zoom_percent zoom_hint motion_label motion_auto motion_off motion_activate motion_os_reduced"

# Asserts that both captured label tables carry every new key, non-empty. $1 = the artifact file.
check_label_keys() {
  node -e '
    const art = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const keys = process.argv[2].split(" ");
    for (const route of ["progressCards", "progressGraph"]) {
      const labels = art.routes[route] && art.routes[route].data && art.routes[route].data.labels;
      if (!labels) { console.error(route + " carries no labels"); process.exit(1); }
      for (const k of keys) if (typeof labels[k] !== "string" || labels[k] === "") { console.error(route + " lacks label " + k); process.exit(1); }
    }
    console.log("labels ok: " + art.routes.progressCards.data.labels.motion_label + " / " + art.routes.progressGraph.data.labels.zoom_out);
  ' "$1" "$NEW_KEYS"
}

@test "capture: both embedded label tables carry the zoom and motion keys (English)" {
  capture_fixture
  run check_label_keys "$CAP_OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "labels ok: Animations / Zoom out"
}

@test "capture: with JENGA_PROGRESS_LANG=sv both embedded label tables carry the Swedish words" {
  export JENGA_PROGRESS_LANG=sv
  capture_fixture
  run check_label_keys "$CAP_OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "labels ok: Animationer / Zooma ut"
}

@test "snapshot HTML: a fresh build carries the pre-paint motion script, the toggle, the zoom controls and the labels" {
  command -v npx >/dev/null 2>&1 || skip "npx is not installed"
  local ui="$REPO_ROOT/project/app/ui"
  ( cd "$ui" && node -e "require.resolve('react'); require.resolve('vite/package.json', { paths: ['$REPO_ROOT/project/app', '$ui'] })" ) >/dev/null 2>&1 \
    || skip "project/app/ui dependencies are not installed"
  capture_fixture
  local dist="$BATS_TEST_TMPDIR/dist" html="$BATS_TEST_TMPDIR/snapshot.html"
  run bash -c "cd '$ui' && npx vite build --outDir '$dist' --emptyOutDir"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run node "$ui/scripts/build-snapshot-html.cjs" --dist "$dist" --data "$CAP_OUT" --out "$html"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # the inline pre-paint script survives the single-file inlining and sits before the app script
  grep -q "jenga-dashboard-motion" "$html"
  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const first = html.indexOf("jenga-dashboard-motion");
    const app = html.indexOf("jenga-dashboard-data");
    if (first < 0 || !/getItem\(.jenga-dashboard-motion.\)\s*===\s*.off./.test(html.slice(first - 80, first + 160))) { console.error("pre-paint script missing"); process.exit(1); }
    if (first > html.indexOf("<div id=\"root\">")) { console.error("pre-paint script is after the app root"); process.exit(1); }
    for (const marker of ["motion-toggle", "dt-zoom-controls", "data-zoom", "data-motion-state", "zoom_percent", "motion_label"]) {
      if (!html.includes(marker)) { console.error("snapshot lacks " + marker); process.exit(1); }
    }
    const art = JSON.parse(html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)[1]);
    if (art.routes.progressCards.data.labels.motion_off !== "Off") { console.error("embedded labels lack motion_off"); process.exit(1); }
    if (app < 0) { console.error("no embedded data"); process.exit(1); }
    console.log("snapshot carries the toggle, the zoom controls and the labels");
  ' "$html"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "snapshot carries the toggle, the zoom controls and the labels"
}
