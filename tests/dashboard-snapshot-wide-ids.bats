#!/usr/bin/env bats
#
# The offline dashboard snapshot of a mixed-width board (E86_S05_T06, audit group 5 of E86_S05).
#
# Why this file exists
# ---------------------
# `j.dashboard --snapshot` captures /v1/board, /v1/ideas, /v1/rapports and the other routes once each, then inlines the
# result into one self-contained HTML file (skills/j-dashboard/scripts/snapshot.sh). The board parsers are pinned by
# project/app/api/parsers/board.mixed-width.test.js and dashboard-wide-ids.test.js; this suite proves the same board
# survives the whole export path: a project holding epics E01, E10, E99, E100 and E1001, with the stories E100_S10 and
# E100_S100, the tasks E100_S100_T100 and E1001_S100_T100, a todo.md that queues two of them, an idea
# `PROMOTED: E1001` and rapports, plans and summaries named for wide IDs, gives a snapshot whose HTML contains
# `E1001`, `E100_S100_T100` and `E01`, and whose embedded board payload groups every story and task under its own parent.
#
# What is faked, and what is not
# ------------------------------
# Same shape as tests/dashboard-test-links-overlay.bats: the REAL snapshot.sh, resolver and bundler, and the REAL
# capture-snapshot.js (through a shim), against a throwaway project; only the UI bundle is a tiny consumer-shaped fixture
# dist/, because the ids ride in the embedded JSON payload that the real server code produces and the real bundler inlines.
# The committed repository has no prebuilt project/app/ui/dist (it is a build output), so rendering the IDs in a browser
# is NOT exercised here; an extra case bundles the real built dist/ when one exists and skips with a message otherwise.
#
# No network (the capture server binds 127.0.0.1 on an OS-assigned port) and everything is written inside
# $BATS_TEST_TMPDIR. The suite skips with a message when node or the dashboard's API dependencies are not installed.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SNAPSHOT_SRC="$REPO_ROOT/skills/j-dashboard/scripts/snapshot.sh"
RESOLVER_SRC="$REPO_ROOT/skills/j-dashboard/scripts/resolve-app-dir.sh"
BUNDLER_SRC="$REPO_ROOT/project/app/ui/scripts/build-snapshot-html.cjs"
REAL_CAPTURE="$REPO_ROOT/project/app/api/scripts/capture-snapshot.js"

# One board item: file name, id, optional parent key and id, status, title.
write_item() {
  local dir="$1" id="$2" parent_key="$3" parent_id="$4" status="$5"
  {
    echo "---"
    echo "id: $id"
    [ -z "$parent_key" ] || echo "$parent_key: $parent_id"
    echo "title: \"Title of $id\""
    echo "status: $status"
    echo "date_created: \"2026-11-06\""
    echo "---"
    echo
    echo "Body of $id."
  } > "$PROJ/project/board/$dir/${id}_item.md"
}

setup() {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  ( cd "$REPO_ROOT/project/app/api" && node -e "require.resolve('express'); require.resolve('cors'); require.resolve('gray-matter')" ) >/dev/null 2>&1 \
    || skip "project/app/api dependencies are not installed"

  # The fixture project. pwd -P for the macOS /tmp -> /private/tmp symlink reason given in dashboard-snapshot.bats.
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  PROJ="$(cd "$BATS_TEST_TMPDIR/proj" && pwd -P)"
  mkdir -p "$PROJ/project/board/epics" "$PROJ/project/board/stories" "$PROJ/project/board/tasks" \
           "$PROJ/project/configs" "$PROJ/project/data" "$PROJ/project/logs" \
           "$PROJ/project/rapports/problems" "$PROJ/project/documentation/plans" "$PROJ/project/documentation/summaries"
  git -C "$PROJ" init -q

  local e
  for e in E01 E10 E99 E100 E1001; do write_item epics "$e" "" "" "In Progress"; done
  write_item stories E01_S1 epic_id E01 Passed
  write_item stories E10_S1 epic_id E10 "In Progress"
  write_item stories E10_S2 epic_id E10 Pending
  write_item stories E99_S1 epic_id E99 Merged
  write_item stories E100_S10 epic_id E100 "In Progress"
  write_item stories E100_S100 epic_id E100 "In Progress"
  write_item stories E1001_S100 epic_id E1001 "In Progress"
  write_item tasks E100_S10_T10 story_id E100_S10 "In Progress"
  write_item tasks E100_S100_T100 story_id E100_S100 Pending
  write_item tasks E1001_S100_T100 story_id E1001_S100 Pending

  printf '%s\n' '# Todo' '' \
    'Queue the wide task: E100_S100_T100' \
    'Queue the other wide task: E1001_S100_T100' > "$PROJ/project/todo.md"
  printf '%s\n' '# Ideas' '' 'Ship the wide-id board <!-- PROMOTED: E1001 -->' > "$PROJ/project/ideas.md"
  printf '%s\n' '# Problem Rapport' '' '**Related Task:** E100_S100_T100' > "$PROJ/project/rapports/problems/E100_S100_T100-wide.md"
  printf '%s\n' '# Plan' '' '**Task ID:** E1001_S100_T100' > "$PROJ/project/documentation/plans/E1001_S100_T100-plan.md"
  printf '%s\n' '# Summary' '' '**Task ID:** E1001_S100_T100' > "$PROJ/project/documentation/summaries/E1001_S100_T100-summary.md"

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
  OUT_HTML="$BATS_TEST_TMPDIR/wide.html"
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

# Run the real snapshot pipeline against the fixture project.
run_snapshot() {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$OUT_HTML' --project-root '$PROJ'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$OUT_HTML" ]
}

# Asserts, with node, the embedded payload: the board tree, the queued flags, the promoted idea and the file names.
check_embedded_payload() {
  node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const m = html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/);
    if (!m) { console.error("no embedded snapshot tag"); process.exit(1); }
    const routes = JSON.parse(m[1]).routes;
    const fail = (msg) => { console.error(msg); process.exit(1); };
    for (const k of ["board", "ideas", "rapports"]) if (!routes[k] || routes[k].error) fail(k + " route missing or errored");

    const board = routes.board.data;
    const same = (got, want, what) => { if (JSON.stringify(got) !== JSON.stringify(want)) fail(what + ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)); };
    same(board.map((e) => e.id), ["E01", "E10", "E99", "E100", "E1001"], "epics in numeric order");
    const epic = (id) => board.find((e) => e.id === id);
    same(epic("E10").stories.map((s) => s.id), ["E10_S1", "E10_S2"], "E10 owns only its own stories");
    same(epic("E100").stories.map((s) => s.id), ["E100_S10", "E100_S100"], "E100 owns S10 and S100");
    same(epic("E100").stories[1].tasks.map((t) => t.id), ["E100_S100_T100"], "E100_S100 owns T100");
    same(epic("E100").stories[0].tasks.map((t) => t.id), ["E100_S10_T10"], "E100_S10 owns only its own task");
    same(epic("E1001").stories[0].tasks.map((t) => t.id), ["E1001_S100_T100"], "E1001_S100 owns its T100");
    same(epic("E01").stories.map((s) => s.id), ["E01_S1"], "E01 keeps its zero-padded id");

    const queued = [];
    for (const e of board) { if (e._queued) queued.push(e.id); for (const s of e.stories) { if (s._queued) queued.push(s.id); for (const t of s.tasks) if (t._queued) queued.push(t.id); } }
    same(queued.sort(), ["E100_S100_T100", "E1001_S100_T100"].sort(), "queued flags from todo.md");

    const promoted = routes.ideas.data.filter((i) => i.state === "promoted");
    same(promoted.map((i) => i.boardId), ["E1001"], "PROMOTED: E1001 read as exactly E1001");

    const files = routes.rapports.data.filter((e) => e.category !== "idea").map((e) => e.file).sort();
    same(files, ["E1001_S100_T100-plan.md", "E1001_S100_T100-summary.md", "problems/E100_S100_T100-wide.md"], "rapport, plan and summary file names");
    console.log("embedded wide-id payload ok");
  ' "$OUT_HTML"
}

@test "snapshot: the HTML contains E1001, E100_S100_T100 and E01" {
  run_snapshot
  run grep -cF -- "E1001" "$OUT_HTML"
  [ "$status" -eq 0 ] || { echo "E1001 missing from the snapshot HTML"; false; }
  run grep -cF -- "E100_S100_T100" "$OUT_HTML"
  [ "$status" -eq 0 ] || { echo "E100_S100_T100 missing from the snapshot HTML"; false; }
  run grep -cF -- '"id":"E01"' "$OUT_HTML"
  [ "$status" -eq 0 ] || { echo 'epic E01 (as "id":"E01") missing from the snapshot HTML'; false; }
  run grep -cF -- "E1001_S100_T100" "$OUT_HTML"
  [ "$status" -eq 0 ] || { echo "E1001_S100_T100 missing from the snapshot HTML"; false; }
}

@test "snapshot: the embedded payload groups every wide story and task under its own parent" {
  run_snapshot
  run check_embedded_payload
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "embedded wide-id payload ok"
}

@test "snapshot: the real built UI bundle still carries the wide ids in the embedded data" {
  local real_dist="$REPO_ROOT/project/app/ui/dist"
  [ -f "$real_dist/index.html" ] || skip "project/app/ui/dist not built; the committed repo carries no prebuilt UI bundle"
  rm -rf "$TMP_REPO/project/app/ui/dist"
  cp -R "$real_dist" "$TMP_REPO/project/app/ui/dist"
  run_snapshot
  run check_embedded_payload
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "embedded wide-id payload ok"
}
