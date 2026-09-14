#!/usr/bin/env bats
#
# Regression coverage for skills/j-dashboard/scripts/snapshot.sh (E47_S04_T03)
# and its bundling step, project/app/ui/scripts/build-snapshot-html.cjs.
#
# Why this file exists
# ---------------------
# snapshot.sh orchestrates `j.dashboard --snapshot`: capture (E47_S04_T02's
# capture-snapshot.js) -> bundle (inline the built dist/ plus the captured
# JSON into one self-contained HTML) -> copy to the final --out path and
# report it. This suite pins snapshot.sh's OWN orchestration logic --
# argument parsing, project/app resolution, running capture from the ORIGINAL
# invocation cwd (not the resolved app dir) per E47_S02's "resolve against the
# invoking project" contract, forwarding --project-root, hard-failing with no
# output file when a step fails, and the final copy + report-path step.
#
# What changed, and why it matters for these tests
# ------------------------------------------------
# The bundling step used to be `npm run build:snapshot` (vite build --mode
# snapshot), and THIS SUITE FAKED `npm` ON PATH to stand in for it. That fake
# is precisely why a total, shipped-to-users breakage stayed invisible: the
# published tarball carries project/app/ui/dist/** and scripts/** but no
# package.json, vite.config.js, or src/, so there was no vite to run on any
# consumer install and `--snapshot` failed 100% of the time there -- while
# every test here passed, because the fake npm cheerfully wrote an index.html.
#
# So the fixture is now shaped like a CONSUMER install by default (prebuilt
# dist/, no UI sources, no node_modules) and runs the REAL
# build-snapshot-html.cjs. The fake npm is still on PATH, but only so tests can
# assert that npm is *not* invoked. Faking less is the whole point.
#
# It still deliberately does NOT exercise the real capture-snapshot.js
# HTTP-capture behavior (E47_S04_T02's own scope, covered by that task's
# tests) -- a fixture capture-snapshot.js stands in for it.
#
# Every test runs against a throwaway git repo under $BATS_TEST_TMPDIR, never
# against this repository's own project/app.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SNAPSHOT_SRC="$REPO_ROOT/skills/j-dashboard/scripts/snapshot.sh"
RESOLVER_SRC="$REPO_ROOT/skills/j-dashboard/scripts/resolve-app-dir.sh"
BUNDLER_SRC="$REPO_ROOT/project/app/ui/scripts/build-snapshot-html.cjs"

# Writes a minimal but REALISTIC prebuilt dist/ into $1 -- the same shape vite
# actually emits: root-absolute /assets/ refs, a type="module" script, and a
# crossorigin stylesheet link.
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
  cat > "$ui_dir/dist/assets/index-fixture.js" <<'JSEOF'
console.log("fixture bundle marker");
// Mirrors DOMPurify's XHTML wrapper, verbatim in shape: a '</head>' living
// inside a JS string literal. The real dist bundle ships this, so the fixture
// must too -- without it, an injection anchored on the FIRST '</head>' looks
// correct here and splices the payload into the bundle's source in production.
var fixtureWrapper = '<html xmlns="http://www.w3.org/1999/xhtml"><head></head><body>' + "x" + "</body></html>";
console.log("fixture bundle tail marker", fixtureWrapper);
JSEOF
  echo '.fixture-style-marker { color: red; }' > "$ui_dir/dist/assets/index-fixture.css"
}

setup() {
  # pwd -P for the same macOS /tmp -> /private/tmp symlink reason as
  # dashboard-launch.bats.
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  TMP_REPO="$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)"
  mkdir -p "$TMP_REPO/skills/j-dashboard/scripts"
  git -C "$TMP_REPO" init -q

  cp "$SNAPSHOT_SRC" "$TMP_REPO/skills/j-dashboard/scripts/snapshot.sh"
  # snapshot.sh delegates project/app resolution to its sibling
  # resolve-app-dir.sh, exactly as the real skill directory ships both.
  cp "$RESOLVER_SRC" "$TMP_REPO/skills/j-dashboard/scripts/resolve-app-dir.sh"
  chmod +x "$TMP_REPO/skills/j-dashboard/scripts/snapshot.sh"
  SNAPSHOT="$TMP_REPO/skills/j-dashboard/scripts/snapshot.sh"

  mkdir -p "$TMP_REPO/project/app/api/scripts"
  mkdir -p "$TMP_REPO/project/app/ui/scripts"

  # The REAL bundler, not a fake -- see the header. Consumer-shaped fixture:
  # a prebuilt dist/ and no UI sources/node_modules, so the rebuild sub-step
  # is skipped and the inliner is what actually produces the output.
  cp "$BUNDLER_SRC" "$TMP_REPO/project/app/ui/scripts/build-snapshot-html.cjs"
  write_fixture_dist "$TMP_REPO/project/app/ui"

  # Fixture capture-snapshot.js -- a real (tiny) node script, not a faked
  # `node` binary, since we want snapshot.sh's actual `node <script>` call
  # to run for real and exercise its own args/exit-code handling. Logs its
  # cwd and args so tests can assert ORIG_CWD / --project-root forwarding;
  # writes a recognizable JSON artifact to --out; honors
  # FAKE_CAPTURE_FAIL=1 to simulate a hard capture failure.
  CAPTURE_LOG="$BATS_TEST_TMPDIR/capture.log"
  : > "$CAPTURE_LOG"
  cat > "$TMP_REPO/project/app/api/scripts/capture-snapshot.js" <<EOF
#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2);
function getArg(name) {
  const idx = args.indexOf(name);
  return idx >= 0 ? args[idx + 1] : undefined;
}
const outPath = getArg('--out');
const projectRoot = getArg('--project-root');
fs.writeFileSync('$CAPTURE_LOG',
  'CWD:' + process.cwd() + '\\n' +
  'PROJECT_ROOT_ARG:' + (projectRoot || '') + '\\n' +
  'OUT:' + (outPath || '') + '\\n');
if (process.env.FAKE_CAPTURE_FAIL === '1') {
  console.error('fake capture failure');
  process.exit(1);
}
if (!outPath) {
  console.error('missing --out');
  process.exit(1);
}
fs.writeFileSync(outPath, JSON.stringify({
  schema_version: 1,
  fixture: true,
  routes: { board: { data: ['fixture-board-entry'] } },
}));
console.log('fake capture ok');
EOF

  # Fake \`npm\` ahead of the real one on PATH. In the consumer-shaped default
  # fixture nothing should invoke it at all -- tests assert that. The
  # monorepo-shaped test below opts into it deliberately.
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
  : > "$NPM_LOG"
  cat > "$FAKE_BIN/npm" <<'EOF'
#!/usr/bin/env bash
echo "CWD:$(pwd)" >> "$NPM_LOG"
echo "ARGS:$*" >> "$NPM_LOG"
if [ "${FAKE_BUILD_FAIL:-0}" = "1" ]; then
  echo "fake build failure" >&2
  exit 1
fi
# Stand in for `vite build`: refresh dist/ with a distinguishable marker so
# tests can tell a rebuilt dist from the pre-existing fixture one.
if [ "$1" = "run" ] && [ "$2" = "build" ]; then
  mkdir -p "$(pwd)/dist/assets"
  echo 'console.log("REBUILT bundle marker");' > "$(pwd)/dist/assets/index-fixture.js"
fi
exit 0
EOF
  chmod +x "$FAKE_BIN/npm"
  export PATH="$FAKE_BIN:$PATH"
  export NPM_LOG
  export CAPTURE_LOG

  # A separate "invoking project" directory, distinct from both TMP_REPO and
  # the CWD bats itself runs tests from -- exercises that snapshot.sh
  # resolves the app dir from the script's own location, completely
  # independent of invocation cwd, while capture still runs from that cwd.
  mkdir -p "$BATS_TEST_TMPDIR/invoking-project"
  INVOKE_DIR="$(cd "$BATS_TEST_TMPDIR/invoking-project" && pwd -P)"
}

# -----------------------------------------------------------------------------
# Orchestration
# -----------------------------------------------------------------------------

@test "happy path: captures, bundles, copies to --out, and reports the final path" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]
  assert_output_contains "Snapshot dashboard written to: $BATS_TEST_TMPDIR/result.html"

  [ -f "$BATS_TEST_TMPDIR/result.html" ]
  run cat "$BATS_TEST_TMPDIR/result.html"
  assert_output_contains "fixture bundle marker"
}

@test "capture runs from the original invocation cwd, not the resolved app dir" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]

  run cat "$CAPTURE_LOG"
  [ "$status" -eq 0 ]
  assert_output_contains "CWD:$INVOKE_DIR"
}

@test "default --out is <invocation cwd>/jenga.html when --out is not given" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT'"
  [ "$status" -eq 0 ]
  assert_output_contains "Snapshot dashboard written to: $INVOKE_DIR/jenga.html"
  [ -f "$INVOKE_DIR/jenga.html" ]
}

@test "--project-root is forwarded unchanged to capture-snapshot.js" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html' --project-root /some/explicit/root"
  [ "$status" -eq 0 ]

  run cat "$CAPTURE_LOG"
  [ "$status" -eq 0 ]
  assert_output_contains "PROJECT_ROOT_ARG:/some/explicit/root"
}

@test "a relative --out is resolved against the invocation cwd, not the app dir" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out relative-result.html"
  [ "$status" -eq 0 ]
  assert_output_contains "Snapshot dashboard written to: $INVOKE_DIR/relative-result.html"
  [ -f "$INVOKE_DIR/relative-result.html" ]
}

@test "-h/--help prints usage and exits 0 without invoking capture or npm" {
  run "$SNAPSHOT" --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: snapshot.sh"

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run cat "$CAPTURE_LOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# -----------------------------------------------------------------------------
# project/app resolution -- the consumer-install defect
# -----------------------------------------------------------------------------

# The defect this pins: snapshot.sh used to compute API_DIR/UI_DIR as
# "$(git rev-parse --show-toplevel)/project/app/...", which is only ever
# correct inside this monorepo. On a consumer install the dashboard lives at
# <consumer>/node_modules/@jenga-ai/agent/project/app, so `--snapshot` died
# with "capture script not found" 100% of the time there.
@test "consumer install: resolves project/app from node_modules/@jenga-ai/agent" {
  # Shape the fixture like a real consumer: the skill was mirrored into
  # .claude/skills/ by postinstall, and the app only exists inside the package.
  PKG_ROOT="$TMP_REPO/node_modules/@jenga-ai/agent"
  mkdir -p "$PKG_ROOT/project/app"
  cp -R "$TMP_REPO/project/app/api" "$PKG_ROOT/project/app/api"
  cp -R "$TMP_REPO/project/app/ui" "$PKG_ROOT/project/app/ui"
  rm -rf "$TMP_REPO/project"

  mkdir -p "$TMP_REPO/.claude/skills/j-dashboard/scripts"
  cp "$SNAPSHOT_SRC" "$TMP_REPO/.claude/skills/j-dashboard/scripts/snapshot.sh"
  cp "$RESOLVER_SRC" "$TMP_REPO/.claude/skills/j-dashboard/scripts/resolve-app-dir.sh"
  chmod +x "$TMP_REPO/.claude/skills/j-dashboard/scripts/snapshot.sh"

  run bash -c "cd '$INVOKE_DIR' && '$TMP_REPO/.claude/skills/j-dashboard/scripts/snapshot.sh' --out '$BATS_TEST_TMPDIR/consumer.html'"
  [ "$status" -eq 0 ]
  assert_output_contains "Snapshot dashboard written to: $BATS_TEST_TMPDIR/consumer.html"

  run cat "$BATS_TEST_TMPDIR/consumer.html"
  assert_output_contains "fixture bundle marker"
  assert_output_contains "jenga-dashboard-data"
}

@test "consumer install: no npm is invoked at all when the UI has no sources" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]

  # The whole point of the rewrite: with only a prebuilt dist/ present there is
  # nothing to build, so no build tooling may be required.
  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Pins the EXACT shape npm actually ships (root package.json's `files`
# allowlist includes project/app/ui/package.json and dist/**/scripts/**, but
# never src/** or node_modules/**) -- not just "no package.json at all" like
# the test above. This is the case the E06_S07/snapshot-staleness fix
# (guarding on `-d "$UI_DIR/src"`) must stay inert for: a shipped
# package.json with no src/ and no node_modules/vite must neither attempt an
# npm build (there is nothing installed to build with) nor trip the
# staleness check (which would permanently block every consumer install,
# with no way for them to "npm install" their way out of it).
@test "published package shape: shipped ui/package.json with no src/ still skips npm and staleness check" {
  cat > "$TMP_REPO/project/app/ui/package.json" <<'EOF'
{ "name": "jenga-dashboard", "private": true, "scripts": { "build": "vite build" } }
EOF

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]
  assert_output_contains "Snapshot dashboard written to: $BATS_TEST_TMPDIR/result.html"

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run cat "$BATS_TEST_TMPDIR/result.html"
  assert_output_contains "fixture bundle marker"
}

@test "monorepo: rebuilds dist first when UI sources and node_modules are present" {
  # Opt the fixture into the monorepo shape: sources + an installed vite.
  cat > "$TMP_REPO/project/app/ui/package.json" <<'EOF'
{ "name": "fixture-ui", "scripts": { "build": "vite build" } }
EOF
  mkdir -p "$TMP_REPO/project/app/ui/node_modules/vite"

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  assert_output_contains "ARGS:run build"
  assert_output_contains "CWD:$TMP_REPO/project/app/ui"

  # A snapshot must never be taken from a stale dist -- the rebuilt marker,
  # not the pre-existing fixture one, must be what got inlined.
  run cat "$BATS_TEST_TMPDIR/result.html"
  assert_output_contains "REBUILT bundle marker"
}

# Regression coverage for the bug this suite originally missed: a dev checkout
# (has UI sources) whose node_modules/vite is absent -- e.g. never installed,
# or pruned -- used to silently skip the rebuild AND skip any staleness check,
# so a stale dist/ got bundled into the snapshot with no warning at all. A
# previously-generated jenga.html could permanently bake in a fixed-in-source
# bug this way.
@test "dev checkout with stale dist and no installed vite refuses to bundle silently" {
  mkdir -p "$TMP_REPO/project/app/ui/src"
  # dist/index.html (written by write_fixture_dist in setup) is pinned to a
  # fixed old timestamp; the src file is left at "now", making it newer --
  # touch -t is portable across macOS/BSD and GNU, unlike relative-touch flags.
  touch -t 202001010000 "$TMP_REPO/project/app/ui/dist/index.html"
  echo "export default 1" > "$TMP_REPO/project/app/ui/src/App.jsx"
  # package.json present (looks buildable) but node_modules/vite is not --
  # the rebuild sub-step is skipped, landing in the new staleness check.
  cat > "$TMP_REPO/project/app/ui/package.json" <<'EOF'
{ "name": "fixture-ui", "scripts": { "build": "vite build" } }
EOF

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -ne 0 ]
  assert_output_contains "refusing to bundle a possibly-stale snapshot"
  [ ! -f "$BATS_TEST_TMPDIR/result.html" ]

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dev checkout with no installed vite but dist is not stale proceeds normally" {
  mkdir -p "$TMP_REPO/project/app/ui/src"
  # src file pinned older than dist/index.html (created at "now" in setup) --
  # dist is not stale, so the rebuild-less path should proceed normally.
  echo "export default 1" > "$TMP_REPO/project/app/ui/src/App.jsx"
  touch -t 202001010000 "$TMP_REPO/project/app/ui/src/App.jsx"

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]
  assert_output_contains "Snapshot dashboard written to: $BATS_TEST_TMPDIR/result.html"
}

# -----------------------------------------------------------------------------
# Failure modes -- never a partial or broken snapshot
# -----------------------------------------------------------------------------

@test "missing capture-snapshot.js exits non-zero with a clear message, no output file" {
  rm "$TMP_REPO/project/app/api/scripts/capture-snapshot.js"

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -ne 0 ]
  assert_output_contains "dashboard app not found"
  [ ! -f "$BATS_TEST_TMPDIR/result.html" ]
}

@test "an unbuilt UI (no dist/index.html) exits non-zero with an actionable message" {
  rm -rf "$TMP_REPO/project/app/ui/dist"

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -ne 0 ]
  assert_output_contains "has not been built"
  [ ! -f "$BATS_TEST_TMPDIR/result.html" ]
}

@test "capture step failure hard-fails with no output file written" {
  run bash -c "cd '$INVOKE_DIR' && FAKE_CAPTURE_FAIL=1 '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -ne 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/result.html" ]
}

@test "bundling step failure hard-fails with no output file copied to the final path" {
  # A dist/ whose index.html references an asset that is not on disk -- the
  # real inliner must refuse rather than emit a half-inlined file.
  rm "$TMP_REPO/project/app/ui/dist/assets/index-fixture.js"

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -ne 0 ]
  assert_output_contains "not found on disk"
  [ ! -f "$BATS_TEST_TMPDIR/result.html" ]
}

# -----------------------------------------------------------------------------
# Bundling output -- is the artifact actually self-contained?
# -----------------------------------------------------------------------------

@test "output inlines JS and CSS and leaves no local asset references behind" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]

  run cat "$BATS_TEST_TMPDIR/result.html"
  assert_output_contains "fixture bundle marker"
  assert_output_contains "fixture-style-marker"
  # The <script src>/<link href> pointing at /assets/ must be gone entirely --
  # a file:// recipient has no server to fetch them from.
  ! grep -q 'src="/assets/' "$BATS_TEST_TMPDIR/result.html"
  ! grep -q 'href="/assets/' "$BATS_TEST_TMPDIR/result.html"
}

@test "output preserves type=\"module\" on the inlined bundle" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]
  # The dist bundle is ESM; inlining it as a classic script silently breaks it.
  run grep -c '<script type="module">' "$BATS_TEST_TMPDIR/result.html"
  [ "$status" -eq 0 ]
}

@test "output embeds the captured data as parseable JSON the UI can read" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]

  # Parse it the same way src/api/client.js does, so a malformed or
  # double-escaped payload fails here rather than in the recipient's browser.
  run node -e "
    const fs = require('fs');
    const html = fs.readFileSync('$BATS_TEST_TMPDIR/result.html', 'utf8');
    const m = html.match(/<script id=\"jenga-dashboard-data\" type=\"application\/json\">([\s\S]*?)<\/script>/);
    if (!m) { console.error('no embedded snapshot tag'); process.exit(1); }
    const data = JSON.parse(m[1]);
    if (data.routes.board.data[0] !== 'fixture-board-entry') {
      console.error('unexpected payload'); process.exit(1);
    }
    console.log('embedded data ok');
  "
  [ "$status" -eq 0 ]
  assert_output_contains "embedded data ok"
}

@test "embedded data containing '</script>' cannot break out of its own tag" {
  # Board content legitimately contains HTML-ish text. If it is not escaped it
  # closes the JSON tag early and the whole page stops parsing.
  cat > "$TMP_REPO/project/app/api/scripts/capture-snapshot.js" <<'EOF'
#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2);
const outPath = args[args.indexOf('--out') + 1];
fs.writeFileSync(outPath, JSON.stringify({
  routes: { board: { data: ['</script><img src=x onerror=alert(1)>'] } },
}));
EOF

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]

  # The raw sequence must not appear inside the JSON payload -- only escaped.
  run node -e "
    const fs = require('fs');
    const html = fs.readFileSync('$BATS_TEST_TMPDIR/result.html', 'utf8');
    const m = html.match(/<script id=\"jenga-dashboard-data\" type=\"application\/json\">([\s\S]*?)<\/script>/);
    if (!m) { console.error('no embedded snapshot tag'); process.exit(1); }
    const data = JSON.parse(m[1]);
    if (data.routes.board.data[0] !== '</script><img src=x onerror=alert(1)>') {
      console.error('payload did not round-trip'); process.exit(1);
    }
    console.log('escaped payload round-tripped');
  "
  [ "$status" -eq 0 ]
  assert_output_contains "escaped payload round-tripped"
}

@test "a '</head>' inside the inlined bundle cannot steal the payload's injection point" {
  # Regression: the bundler injected the payload with a FIRST-match
  # /<\/head>/i, but step 1 inlines the ESM bundle into the head, and that
  # bundle carries its own '</head>' inside a JS string (DOMPurify's XHTML
  # wrapper -- see write_fixture_dist). The payload therefore landed in the
  # middle of the bundle's source, and its trailing '</script>' closed the
  # module element early, spilling the rest of the bundle onto the page as
  # visible text. Asserting only that the payload parses is NOT enough: it
  # round-trips fine from inside the wreckage. Pin the structure instead.
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]

  run node -e "
    const fs = require('fs');
    const html = fs.readFileSync('$BATS_TEST_TMPDIR/result.html', 'utf8');

    // The module element must survive intact: it opens once, and its whole
    // body -- including the bundle's '</head>' literal and everything after
    // it -- must still be inside it.
    const mod = html.match(/<script type=\"module\">([\s\S]*?)<\/script>/);
    if (!mod) { console.error('no inlined module element'); process.exit(1); }
    if (!mod[1].includes('<head></head>')) {
      console.error('bundle body was truncated before its </head> literal');
      process.exit(1);
    }
    if (!mod[1].includes('fixture bundle tail marker')) {
      console.error('bundle tail escaped the module element');
      process.exit(1);
    }

    // The payload must sit in the DOCUMENT head -- after the module closes and
    // before the document's own </head> -- not nested inside the bundle.
    const dataAt = html.indexOf('<script id=\"jenga-dashboard-data\"');
    const modEndAt = html.indexOf('</script>', html.indexOf('<script type=\"module\">'));
    const headEndAt = html.lastIndexOf('</head>');
    if (dataAt < 0) { console.error('no embedded snapshot tag'); process.exit(1); }
    if (!(modEndAt < dataAt && dataAt < headEndAt)) {
      console.error('payload is not between the module close and </head>');
      process.exit(1);
    }

    // And nothing may have leaked into the rendered body as text. Slice from
    // the document's own </head> (headEndAt), NOT from the first '<body>':
    // the bundle's XHTML wrapper string contains a literal '<body>' too, and
    // indexOf would find THAT one and drag the whole bundle into this check.
    const body = html.slice(headEndAt);
    if (/fixtureWrapper|createHTML|\bvar \w+ =/.test(body)) {
      console.error('bundle source leaked into the body as visible text');
      process.exit(1);
    }

    // No placeholder may survive into the shipped file.
    if (html.includes('__JENGA_SNAPSHOT_DATA__')) {
      console.error('injection placeholder was not consumed');
      process.exit(1);
    }
    console.log('payload landed in the document head, bundle intact');
  "
  [ "$status" -eq 0 ]
  assert_output_contains "payload landed in the document head, bundle intact"
}

# -----------------------------------------------------------------------------
# --data-url delivery mode (E47_S04_T04)
# -----------------------------------------------------------------------------

@test "--data-url prints a data:text/html;base64 URI in addition to the plain path" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html' --data-url"
  [ "$status" -eq 0 ]
  assert_output_contains "Snapshot dashboard written to: $BATS_TEST_TMPDIR/result.html"
  assert_output_contains "data:text/html;base64,"
}

@test "--data-url payload round-trips to the exact same bytes as the on-disk output file" {
  OUT_FILE="$BATS_TEST_TMPDIR/roundtrip-result.html"
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$OUT_FILE' --data-url"
  [ "$status" -eq 0 ]

  uri_line="$(printf '%s\n' "$output" | grep '^data:text/html;base64,')"
  [ -n "$uri_line" ]
  encoded="${uri_line#data:text/html;base64,}"
  echo -n "$encoded" | base64 -d > "$BATS_TEST_TMPDIR/decoded.html" 2>/dev/null \
    || echo -n "$encoded" | base64 --decode > "$BATS_TEST_TMPDIR/decoded.html"

  run diff "$OUT_FILE" "$BATS_TEST_TMPDIR/decoded.html"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--data-url without --out still encodes the default jenga.html correctly" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --data-url"
  [ "$status" -eq 0 ]
  assert_output_contains "data:text/html;base64,"
  [ -f "$INVOKE_DIR/jenga.html" ]
}

@test "--data-url refuses with no URI printed when the encoded size exceeds the threshold" {
  # Force a near-zero threshold via the testability override documented in
  # snapshot.sh's header -- avoids generating a real multi-megabyte fixture
  # just to exercise the refusal branch.
  run bash -c "cd '$INVOKE_DIR' && SNAPSHOT_MAX_DATA_URL_BYTES=1 '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/oversized-result.html' --data-url"
  [ "$status" -ne 0 ]
  assert_output_contains "exceeds the 1-byte threshold"
  ! printf '%s\n' "$output" | grep -q '^data:text/html;base64,'
  # The plain --out file itself is still written by Step 3, which runs before
  # the --data-url branch -- only the URI emission is refused, not the whole
  # snapshot. Confirm that distinction explicitly.
  [ -f "$BATS_TEST_TMPDIR/oversized-result.html" ]
}

@test "--data-url is not implied by default -- plain invocation prints no data: URI" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/no-data-url-result.html'"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q '^data:text/html;base64,'
}

@test "bundling step failure with --data-url still hard-fails before any data: URI is printed" {
  rm "$TMP_REPO/project/app/ui/dist/assets/index-fixture.js"

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/fail-result.html' --data-url"
  [ "$status" -ne 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/fail-result.html" ]
  ! printf '%s\n' "$output" | grep -q '^data:text/html;base64,'
}
