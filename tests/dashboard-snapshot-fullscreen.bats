#!/usr/bin/env bats
#
# The large / fullscreen view of the epic progress map in the offline snapshot (E92_S07_T09).
#
# The button, the large view and its Fullscreen API guards are part of the bundled UI, so a snapshot contains them without
# any change to the snapshot scripts. What has to hold, and is pinned here:
#   1. the four new label keys (fullscreen_enter, fullscreen_exit, fullscreen_hint, fullscreen_layer) reach both captured
#      label tables, in English and, with JENGA_PROGRESS_LANG=sv, in Swedish. The words are taken from
#      scripts/progress-labels-json.sh at run time, never copied into this file;
#   2. a snapshot HTML built from a fresh build of the UI carries the toggle marker, the large-view attributes and the new
#      CSS selectors. Minification does not keep comments or the task id, so the assertions are on selectors and test ids that
#      survive it (dt-fs-toggle, data-fullscreen, data-dt-fullscreen, dt-fs-btn); the label words are NOT in the script (the
#      UI hard-codes none) and ARE in the embedded payload;
#   3. the snapshot's inline script loads without throwing where file:// gives it nothing: no document.fullscreenEnabled, no
#      requestFullscreen and a localStorage whose accessor throws. A regex over the call sites would be brittle, so the script
#      is run in a Node vm with a stub document. A second run with the API present and a recorder proves nothing requests
#      fullscreen on its own at load. Two controls prove the harness can fail (a throwing script, a requesting script);
#   4. the story did not touch the snapshot export: snapshot.sh and build-snapshot-html.cjs carry no fullscreen code and no
#      E92_S07 commit. The sibling snapshot and label bats are run unchanged by whoever verifies this task.
# The structure is checked, not a browser; opening the file in a browser is the manual check recorded in the task summary.
# The fixture project and the build live in $BATS_FILE_TMPDIR; the capture server binds 127.0.0.1 on an OS-assigned port.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAPTURE_SRC="$REPO_ROOT/project/app/api/scripts/capture-snapshot.js"
LABELS_JSON="$REPO_ROOT/scripts/progress-labels-json.sh"
BUILD_SNAPSHOT="$REPO_ROOT/project/app/ui/scripts/build-snapshot-html.cjs"
SNAPSHOT_SH="$REPO_ROOT/skills/j-dashboard/scripts/snapshot.sh"

FS_KEYS="fullscreen_enter fullscreen_exit fullscreen_hint fullscreen_layer"

write_item() {
  local dir="$1" id="$2" parent_key="$3" parent_id="$4" status="$5"
  {
    echo "---"
    echo "id: $id"
    [ -z "$parent_key" ] || echo "$parent_key: $parent_id"
    echo "title: \"Title of $id\""
    echo "status: $status"
    echo "date_created: \"2026-11-13\""
    echo "---"
    echo
    echo "Body of $id."
  } > "$PROJ/project/board/$dir/${id}_item.md"
}

# Skips unless the capture server and the UI build can run here. Same guards as dashboard-snapshot-zoom-motion.bats.
require_build_tools() {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  command -v npx >/dev/null 2>&1 || skip "npx is not installed"
  ( cd "$REPO_ROOT/project/app/api" && node -e "require.resolve('express'); require.resolve('cors'); require.resolve('gray-matter')" ) >/dev/null 2>&1 \
    || skip "project/app/api dependencies are not installed"
  local ui="$REPO_ROOT/project/app/ui"
  ( cd "$ui" && node -e "require.resolve('react'); require.resolve('vite/package.json', { paths: ['$REPO_ROOT/project/app', '$ui'] })" ) >/dev/null 2>&1 \
    || skip "project/app/ui dependencies are not installed"
}

# Creates the fixture project once per file ($PROJ), like the zoom/motion bats does per test. pwd -P for the macOS
# /tmp -> /private/tmp symlink reason given in dashboard-snapshot.bats.
make_fixture() {
  mkdir -p "$BATS_FILE_TMPDIR/proj"
  PROJ="$(cd "$BATS_FILE_TMPDIR/proj" && pwd -P)"
  [ -d "$PROJ/project/board/tasks" ] && return 0
  mkdir -p "$PROJ/project/board/epics" "$PROJ/project/board/stories" "$PROJ/project/board/tasks" \
           "$PROJ/project/configs" "$PROJ/project/data" "$PROJ/project/logs" \
           "$PROJ/project/rapports/problems" "$PROJ/project/documentation/plans" "$PROJ/project/documentation/summaries" \
           "$PROJ/project/queue"
  git -C "$PROJ" init -q
  # /v1/progress runs board-progress.sh, which resolves the root from project/configs/workflow.json (E92_S03_T02).
  printf '%s\n' '{}' > "$PROJ/project/configs/workflow.json"
  write_item epics E01 "" "" "In Progress"
  write_item stories E01_S01 epic_id E01 "In Progress"
  write_item tasks E01_S01_T01 story_id E01_S01 Passed
  write_item tasks E01_S01_T02 story_id E01_S01 "In Progress"
  write_item tasks E01_S01_T03 story_id E01_S01 Pending
  printf '%s\n' '# Todo' '' > "$PROJ/project/todo.md"
}

# capture_fixture <lang>: captures the fixture into $BATS_FILE_TMPDIR/data-<lang>.json (lang "sv" sets JENGA_PROGRESS_LANG).
capture_fixture() {
  local lang="$1" out="$BATS_FILE_TMPDIR/data-$1.json"
  [ -f "$out" ] && return 0
  make_fixture
  if [ "$lang" = "sv" ]; then
    run env JENGA_PROGRESS_LANG=sv bash -c "cd '$BATS_FILE_TMPDIR' && node '$CAPTURE_SRC' --project-root '$PROJ' --out '$out'"
  else
    run env -u JENGA_PROGRESS_LANG bash -c "cd '$BATS_FILE_TMPDIR' && node '$CAPTURE_SRC' --project-root '$PROJ' --out '$out'"
  fi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$out" ]
}

# build_snapshot <lang>: one fresh vite build per file, then the single-file snapshot for <lang>. Sets SNAP.
build_snapshot() {
  local lang="$1" ui="$REPO_ROOT/project/app/ui" dist="$BATS_FILE_TMPDIR/dist"
  SNAP="$BATS_FILE_TMPDIR/snapshot-$lang.html"
  capture_fixture "$lang"
  if [ ! -f "$dist/index.html" ]; then
    run bash -c "cd '$ui' && npx vite build --outDir '$dist' --emptyOutDir"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  fi
  [ -f "$SNAP" ] && return 0
  run node "$BUILD_SNAPSHOT" --dist "$dist" --data "$BATS_FILE_TMPDIR/data-$lang.json" --out "$SNAP"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# expected_words <lang>: the four fullscreen label words for <lang> as one JSON object, taken from the exporter.
expected_words() {
  local lang="$1"
  JENGA_PROGRESS_LANG="$lang" bash "$LABELS_JSON" | node -e '
    const labels = JSON.parse(require("fs").readFileSync(0, "utf8")).labels;
    const out = {};
    for (const k of process.argv[1].split(" ")) {
      if (typeof labels[k] !== "string" || labels[k] === "") { console.error("exporter lacks " + k); process.exit(1); }
      out[k] = labels[k];
    }
    console.log(JSON.stringify(out));
  ' "$FS_KEYS"
}

# check_payload_words <artifact-or-html> <lang>: both embedded label tables carry exactly the exporter's four words.
# A captured artifact is JSON; a snapshot HTML carries the same JSON inside <script id="jenga-dashboard-data">.
check_payload_words() {
  local words
  words="$(expected_words "$2")" || return 1
  node -e '
    const raw = require("fs").readFileSync(process.argv[1], "utf8");
    const m = raw.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/);
    const art = JSON.parse(m ? m[1] : raw);
    const want = JSON.parse(process.argv[2]);
    for (const route of ["progressCards", "progressGraph"]) {
      const labels = art.routes[route] && art.routes[route].data && art.routes[route].data.labels;
      if (!labels) { console.error(route + " carries no labels"); process.exit(1); }
      for (const [k, v] of Object.entries(want)) {
        if (labels[k] !== v) { console.error(route + "." + k + " is " + JSON.stringify(labels[k]) + ", expected " + JSON.stringify(v)); process.exit(1); }
      }
    }
    if (want.fullscreen_enter === want.fullscreen_exit) { console.error("enter and exit wording are identical"); process.exit(1); }
    console.log("payload ok: " + want.fullscreen_enter + " / " + want.fullscreen_exit);
  ' "$1" "$words"
}

# The inline module script of a snapshot: the bundled UI (the one <script type="module">).
module_script() {
  node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const m = html.match(/<script type="module">([\s\S]*?)<\/script>/);
    if (!m) { console.error("no inline module script"); process.exit(1); }
    process.stdout.write(m[1]);
  ' "$1"
}

# The inline <style> of a snapshot (the bundled CSS).
inline_style() {
  node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const parts = [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(m => m[1]);
    if (!parts.length) { console.error("no inline style"); process.exit(1); }
    process.stdout.write(parts.join("\n"));
  ' "$1"
}

# write_vm_harness: writes the minimal Node vm loader to $VM_HARNESS.
# Usage of the result: node "$VM_HARNESS" <snapshot.html> bare|api   -> one JSON line on stdout.
#   bare: no document.fullscreenEnabled, no requestFullscreen anywhere, no exitFullscreen, localStorage/sessionStorage accessors throw.
#   api : document.fullscreenEnabled is true and every element has a requestFullscreen that records the call.
# There is no DOM library in this repo, so document and every element are one permissive Proxy stub (nodeType 1, a few
# safe tree properties, anything else a child stub). That is enough for React to boot into the root; what the run proves is
# that the snapshot's script loads and that the guarded Fullscreen/storage accesses do not throw or fire on their own.
write_vm_harness() {
  VM_HARNESS="$BATS_TEST_TMPDIR/vm-load.cjs"
  cat > "$VM_HARNESS" <<'EOF'
'use strict'
const fs = require('fs')
const vm = require('vm')
const html = fs.readFileSync(process.argv[2], 'utf8')
const withApi = process.argv[3] === 'api'
const mod = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1]
// the classic inline scripts (pre-paint theme and Animations preference) read localStorage and run before the module
const classic = [...html.slice(0, html.indexOf('<script type="module">')).matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1])
const data = html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)[1]
const result = { errors: [], requests: [], exits: [], created: 0, dataRead: 0, storageTouched: 0 }
const note = (e) => result.errors.push(String((e && e.message) || e))

const TREE = ['firstChild', 'lastChild', 'nextSibling', 'previousSibling', 'parentNode', 'parentElement', 'children', 'childNodes']
const mkStub = () => {
  const kids = {}
  return new Proxy(function () {}, {
    get(_, k) {
      if (k === 'nodeType') return 1
      if (k === 'ownerDocument') return doc
      if (k === 'dataset' || k === 'style') return kids[k] || (kids[k] = {})
      if (k === 'textContent') return ''
      if (TREE.includes(k)) return null
      if (k === 'requestFullscreen' || k === 'webkitRequestFullscreen') {
        return withApi ? function () { result.requests.push(String(k)); return Promise.resolve() } : undefined
      }
      if (k === 'getAttribute' || k === 'querySelector' || k === 'closest') return () => null
      if (k === 'querySelectorAll') return () => []
      if (k === 'getBoundingClientRect') return () => ({ width: 800, height: 600, top: 0, left: 0, right: 800, bottom: 600 })
      if (typeof k === 'symbol') return k === Symbol.toPrimitive ? () => '' : undefined
      return kids[k] || (kids[k] = mkStub())
    },
    set(_, k, v) { kids[k] = v; return true },
    apply() { return mkStub() },
  })
}
const root = mkStub()
const doc = {
  documentElement: mkStub(), body: mkStub(), head: mkStub(), readyState: 'complete', title: '', activeElement: null,
  createElement() { result.created++; return mkStub() }, createElementNS() { result.created++; return mkStub() },
  createTextNode: () => mkStub(), createComment: () => mkStub(),
  getElementById(id) { if (id === 'jenga-dashboard-data') { result.dataRead++; return { textContent: data } } return root },
  querySelector: () => null, querySelectorAll: () => [], addEventListener() {}, removeEventListener() {},
}
if (withApi) {
  doc.fullscreenEnabled = true
  doc.exitFullscreen = () => { result.exits.push('exitFullscreen'); return Promise.resolve() }
}
const mq = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} })
const win = {
  document: doc, location: { protocol: 'file:', href: 'file:///snapshot.html', hash: '', search: '' }, matchMedia: mq,
  addEventListener() {}, removeEventListener() {}, innerWidth: 1280, innerHeight: 800, navigator: { userAgent: 'node' },
  requestAnimationFrame: cb => setTimeout(cb, 0), cancelAnimationFrame: clearTimeout, getComputedStyle: () => ({ getPropertyValue: () => '' }),
  setTimeout, clearTimeout, setInterval, clearInterval, queueMicrotask, MessageChannel, performance,
  history: { replaceState() {}, pushState() {} }, console: { log() {}, warn() {}, info() {}, debug() {}, error: (...a) => note(a.join(' ')) },
}
for (const n of ['HTMLIFrameElement', 'HTMLElement', 'Element', 'Node', 'Event', 'HTMLInputElement', 'HTMLTextAreaElement', 'HTMLSelectElement', 'SVGElement']) win[n] = class {}
for (const n of ['localStorage', 'sessionStorage']) {
  Object.defineProperty(win, n, { get() { result.storageTouched++; throw new Error(n + ' access denied (file://)') } })
}
win.window = win; win.self = win; win.globalThis = win
const ctx = vm.createContext(win)
process.on('uncaughtException', note)
process.on('unhandledRejection', note)
try {
  classic.forEach((code, i) => new vm.Script(code, { filename: 'snapshot-prepaint-' + i + '.js' }).runInContext(ctx))
  new vm.Script(mod, { filename: 'snapshot-inline.js' }).runInContext(ctx)
} catch (e) { note(e) }
// React renders on a later macrotask and the app's effects follow; give it time to boot into the stub root.
setTimeout(() => { console.log(JSON.stringify(result)); process.exit(0) }, 600)
EOF
}

# vm_load <html> <bare|api>: runs the harness, leaves its JSON line in $output.
vm_load() {
  write_vm_harness
  run node "$VM_HARNESS" "$1" "$2"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# json_field <json> <expression over r>: prints the evaluated expression.
json_field() {
  node -e 'const r = JSON.parse(process.argv[1]); console.log(String(eval(process.argv[2])))' "$1" "$2"
}

@test "capture: both embedded label tables carry the four fullscreen words exactly as the exporter prints them (English)" {
  require_build_tools
  capture_fixture en
  run check_payload_words "$BATS_FILE_TMPDIR/data-en.json" en
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "payload ok:"
}

@test "capture: with JENGA_PROGRESS_LANG=sv both embedded label tables carry the four Swedish words, which differ from English" {
  require_build_tools
  capture_fixture sv
  run check_payload_words "$BATS_FILE_TMPDIR/data-sv.json" sv
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "payload ok:"
  [ "$(expected_words sv)" != "$(expected_words en)" ]
}

@test "snapshot HTML: the bundled script carries the toggle marker, the large-view attributes and the label keys, and no label word" {
  require_build_tools
  build_snapshot en
  local script
  script="$(module_script "$SNAP")"
  for marker in dt-fs-toggle data-fullscreen data-dt-fullscreen dt-fs-btn dt-fs-hint $FS_KEYS; do
    assert_contains "$script" "$marker"
  done
  # data-fullscreen carries both modes; the page-scroll lock is set on <html> by the fallback layer only
  assert_contains "$script" "native"
  assert_contains "$script" "fallback"
  # no word is hard-coded in the UI: the English words live in the payload only
  local key word
  for key in $FS_KEYS; do
    word="$(expected_words en | node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8"))[process.argv[1]])' "$key")"
    assert_not_contains "$script" "$word"
  done
}

@test "snapshot HTML: the bundled CSS carries the large-view selectors that survive minification" {
  require_build_tools
  build_snapshot en
  local css
  css="$(inline_style "$SNAP")"
  for marker in 'data-dt-fullscreen' 'data-fullscreen' 'dt-fs-btn' 'dt-fs-hint'; do
    assert_contains "$css" "$marker"
  done
  # a hex literal in the new block would break the theme tokens (E92 decision); the block's own selectors carry none
  run node -e '
    const css = process.argv[1];
    const rules = css.split("}").filter(r => /dt-fs-|data-fullscreen|data-dt-fullscreen/.test(r));
    if (!rules.length) { console.error("no large-view rules"); process.exit(1); }
    const bad = rules.filter(r => /#[0-9a-fA-F]{3,8}\b/.test(r));
    if (bad.length) { console.error("hex literal in: " + bad[0]); process.exit(1); }
    console.log("large-view rules: " + rules.length + ", no hex literal");
  ' "$css"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "no hex literal"
}

@test "snapshot HTML: the embedded payload carries the four English words and, for an sv capture, the four Swedish words" {
  require_build_tools
  build_snapshot en
  run check_payload_words "$BATS_FILE_TMPDIR/snapshot-en.html" en
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "payload ok:"
  build_snapshot sv
  run check_payload_words "$BATS_FILE_TMPDIR/snapshot-sv.html" sv
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_contains "payload ok:"
}

@test "snapshot HTML: the Fullscreen API names are in the bundle, so the vm load below is not vacuous" {
  require_build_tools
  build_snapshot en
  local script
  script="$(module_script "$SNAP")"
  for api in requestFullscreen fullscreenEnabled fullscreenchange exitFullscreen; do
    assert_contains "$script" "$api"
  done
  # the page is one file: no external script, stylesheet or modulepreload is left
  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const ext = html.match(/<script[^>]+\bsrc=|<link[^>]+rel="(?:stylesheet|modulepreload)"/g);
    if (ext) { console.error("external reference: " + ext[0]); process.exit(1); }
    console.log("single file");
  ' "$SNAP"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "vm: the snapshot loads without throwing with no document.fullscreenEnabled, no requestFullscreen and a throwing localStorage" {
  require_build_tools
  build_snapshot en
  vm_load "$SNAP" bare
  local result="$output"
  [ "$(json_field "$result" 'r.errors.length')" = "0" ] || { echo "$result"; false; }
  # the run is real: the pre-paint scripts hit the throwing storage (and swallowed it), React created elements, the app read the embedded data
  [ "$(json_field "$result" 'r.storageTouched > 0')" = "true" ] || { echo "$result"; false; }
  [ "$(json_field "$result" 'r.created > 0')" = "true" ] || { echo "$result"; false; }
  [ "$(json_field "$result" 'r.dataRead > 0')" = "true" ] || { echo "$result"; false; }
  # nothing requested fullscreen (there was no API to call; a call would have thrown)
  [ "$(json_field "$result" 'r.requests.length')" = "0" ]
}

@test "vm: with the Fullscreen API present, loading the snapshot requests fullscreen zero times" {
  require_build_tools
  build_snapshot en
  vm_load "$SNAP" api
  local result="$output"
  [ "$(json_field "$result" 'r.errors.length')" = "0" ] || { echo "$result"; false; }
  [ "$(json_field "$result" 'r.created > 0')" = "true" ] || { echo "$result"; false; }
  [ "$(json_field "$result" 'r.requests.length')" = "0" ] || { echo "$result"; false; }
  [ "$(json_field "$result" 'r.exits.length')" = "0" ]
}

@test "vm control: the harness reports a script that throws and a script that requests fullscreen at load" {
  require_build_tools
  build_snapshot en
  local bad="$BATS_TEST_TMPDIR/throwing.html" req="$BATS_TEST_TMPDIR/requesting.html"
  node -e '
    const fs = require("fs");
    const html = fs.readFileSync(process.argv[1], "utf8");
    const at = html.indexOf("<script type=\"module\">") + "<script type=\"module\">".length;
    fs.writeFileSync(process.argv[2], html.slice(0, at) + "document.nothingHere.x;" + html.slice(at));
    fs.writeFileSync(process.argv[3], html.slice(0, at) + "document.documentElement.requestFullscreen();" + html.slice(at));
  ' "$SNAP" "$bad" "$req"
  vm_load "$bad" bare
  [ "$(json_field "$output" 'r.errors.length > 0')" = "true" ] || { echo "$output"; false; }
  vm_load "$req" api
  [ "$(json_field "$output" 'r.requests.length > 0')" = "true" ] || { echo "$output"; false; }
}

@test "snapshot export: snapshot.sh and build-snapshot-html.cjs carry no fullscreen code and no E92_S07 commit" {
  local f
  for f in "$SNAPSHOT_SH" "$BUILD_SNAPSHOT"; do
    [ -f "$f" ]
    run grep -ci "fullscreen" "$f"
    [ "$output" = "0" ] || { echo "$f mentions fullscreen"; false; }
  done
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  run git -C "$REPO_ROOT" log --format='%h %s' -- skills/j-dashboard/scripts/snapshot.sh project/app/ui/scripts/build-snapshot-html.cjs
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_not_contains "E92_S07"
}
