#!/usr/bin/env bats
#
# Regression coverage for skills/j-dashboard/scripts/snapshot.sh (E47_S04_T03).
#
# Why this file exists
# ---------------------
# snapshot.sh orchestrates `j.dashboard --snapshot`: capture (E47_S04_T02's
# capture-snapshot.js) -> bundle (project/app/ui's `build:snapshot` npm
# script) -> copy the result to the final --out path and report it. This
# suite pins snapshot.sh's OWN orchestration logic -- argument parsing,
# repo-root/API_DIR/UI_DIR resolution, running capture from the ORIGINAL
# invocation cwd (not REPO_ROOT) per E47_S02's "resolve against the invoking
# project" contract, forwarding SNAPSHOT_DATA_FILE and --project-root,
# hard-failing with no output file on either step failing, and the final
# copy + report-path step. It deliberately does NOT exercise the real
# capture-snapshot.js HTTP-capture behavior (E47_S04_T02's own scope, already
# covered by that task's tests) or the real vite single-file bundling
# (verified manually against real repo data during T03 tester verification,
# since it needs a real Vite/React build and isn't practical to fake
# meaningfully in bats) -- a fixture capture-snapshot.js and a fake `npm` on
# PATH stand in for both, so these tests run fast with no real build.
#
# Every test runs against a throwaway git repo under $BATS_TEST_TMPDIR, never
# against this repository's own project/app.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SNAPSHOT_SRC="$REPO_ROOT/skills/j-dashboard/scripts/snapshot.sh"

setup() {
  # pwd -P for the same macOS /tmp -> /private/tmp symlink reason as
  # dashboard-launch.bats.
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  TMP_REPO="$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)"
  mkdir -p "$TMP_REPO/skills/j-dashboard/scripts"
  git -C "$TMP_REPO" init -q

  cp "$SNAPSHOT_SRC" "$TMP_REPO/skills/j-dashboard/scripts/snapshot.sh"
  chmod +x "$TMP_REPO/skills/j-dashboard/scripts/snapshot.sh"
  SNAPSHOT="$TMP_REPO/skills/j-dashboard/scripts/snapshot.sh"

  mkdir -p "$TMP_REPO/project/app/api/scripts"
  mkdir -p "$TMP_REPO/project/app/ui"
  cat > "$TMP_REPO/project/app/ui/package.json" <<'EOF'
{ "name": "fixture-ui" }
EOF

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
fs.writeFileSync(outPath, JSON.stringify({ schema_version: 1, fixture: true }));
console.log('fake capture ok');
EOF

  # Fake `npm` ahead of the real one on PATH -- stands in for the
  # `npm run build:snapshot -- --outDir <dir> --emptyOutDir` bundling step.
  # Logs cwd/args/SNAPSHOT_DATA_FILE, then writes a recognizable
  # index.html into the requested --outDir (unless FAKE_BUILD_FAIL=1).
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
  : > "$NPM_LOG"
  cat > "$FAKE_BIN/npm" <<'EOF'
#!/usr/bin/env bash
echo "CWD:$(pwd)" >> "$NPM_LOG"
echo "ARGS:$*" >> "$NPM_LOG"
echo "SNAPSHOT_DATA_FILE:${SNAPSHOT_DATA_FILE:-}" >> "$NPM_LOG"
# Check existence NOW, while the scratch dir snapshot.sh created it in is
# still alive -- by the time this test's `run` returns, snapshot.sh's own
# `trap ... EXIT` has already deleted it, so a post-hoc `[ -f ... ]` in the
# test itself would always fail regardless of whether the file was ever
# really there.
if [ -n "${SNAPSHOT_DATA_FILE:-}" ] && [ -f "${SNAPSHOT_DATA_FILE:-}" ]; then
  echo "SNAPSHOT_DATA_FILE_EXISTS:1" >> "$NPM_LOG"
else
  echo "SNAPSHOT_DATA_FILE_EXISTS:0" >> "$NPM_LOG"
fi
if [ "${FAKE_BUILD_FAIL:-0}" = "1" ]; then
  echo "fake build failure" >&2
  exit 1
fi
outdir=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--outDir" ]; then
    outdir="$a"
  fi
  prev="$a"
done
if [ -n "$outdir" ]; then
  mkdir -p "$outdir"
  echo "<html><!-- fixture snapshot build --></html>" > "$outdir/index.html"
fi
exit 0
EOF
  chmod +x "$FAKE_BIN/npm"
  export PATH="$FAKE_BIN:$PATH"
  export NPM_LOG
  export CAPTURE_LOG

  # A separate "invoking project" directory, distinct from both TMP_REPO and
  # the CWD bats itself runs tests from -- exercises that snapshot.sh
  # resolves REPO_ROOT/API_DIR/UI_DIR from the script's own location (via
  # git -C "$SKILL_DIR" rev-parse --show-toplevel), completely independent of
  # invocation cwd, while capture still runs from that invocation cwd.
  mkdir -p "$BATS_TEST_TMPDIR/invoking-project"
  INVOKE_DIR="$(cd "$BATS_TEST_TMPDIR/invoking-project" && pwd -P)"
}

@test "happy path: captures, bundles, copies to --out, and reports the final path" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]
  assert_output_contains "Snapshot dashboard written to: $BATS_TEST_TMPDIR/result.html"

  [ -f "$BATS_TEST_TMPDIR/result.html" ]
  run cat "$BATS_TEST_TMPDIR/result.html"
  assert_output_contains "fixture snapshot build"
}

@test "capture runs from the original invocation cwd, not REPO_ROOT or UI_DIR" {
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

@test "SNAPSHOT_DATA_FILE is forwarded to the bundling step and points at the captured artifact" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -eq 0 ]

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  assert_output_contains "ARGS:run build:snapshot -- --outDir"
  assert_output_contains "--emptyOutDir"
  # The captured artifact path is a mktemp -d scratch file, but it must at
  # least be a real, non-blank path that existed (and was readable) at the
  # moment the bundling step ran -- checked by the fake npm itself, since
  # snapshot.sh's own EXIT trap deletes the scratch dir before this test's
  # `run` returns.
  captured_data_file="$(grep '^SNAPSHOT_DATA_FILE:' "$NPM_LOG" | cut -d: -f2-)"
  [ -n "$captured_data_file" ]
  assert_output_contains "SNAPSHOT_DATA_FILE_EXISTS:1"
}

@test "--project-root is forwarded unchanged to capture-snapshot.js" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html' --project-root /some/explicit/root"
  [ "$status" -eq 0 ]

  run cat "$CAPTURE_LOG"
  [ "$status" -eq 0 ]
  assert_output_contains "PROJECT_ROOT_ARG:/some/explicit/root"
}

@test "missing capture-snapshot.js exits non-zero with a clear message, no npm invocation" {
  rm "$TMP_REPO/project/app/api/scripts/capture-snapshot.js"

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -ne 0 ]
  assert_output_contains "capture script not found"

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$BATS_TEST_TMPDIR/result.html" ]
}

@test "missing project/app/ui/package.json exits non-zero with a clear message" {
  rm "$TMP_REPO/project/app/ui/package.json"

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -ne 0 ]
  assert_output_contains "dashboard UI not found"
  [ ! -f "$BATS_TEST_TMPDIR/result.html" ]
}

@test "capture step failure hard-fails with no output file written, npm never invoked" {
  export FAKE_CAPTURE_FAIL=1

  run bash -c "cd '$INVOKE_DIR' && FAKE_CAPTURE_FAIL=1 '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -ne 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/result.html" ]

  run cat "$NPM_LOG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bundling step failure hard-fails with no output file copied to the final path" {
  run bash -c "cd '$INVOKE_DIR' && FAKE_BUILD_FAIL=1 '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -ne 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/result.html" ]
}

@test "bundling step reporting success but producing no index.html is treated as a failure" {
  # Fake npm that "succeeds" (exit 0) without writing index.html anywhere --
  # pins snapshot.sh's own post-bundle existence check, independent of the
  # real vite-plugin-singlefile's behavior.
  cat > "$FAKE_BIN/npm" <<'EOF'
#!/usr/bin/env bash
echo "CWD:$(pwd)" >> "$NPM_LOG"
echo "ARGS:$*" >> "$NPM_LOG"
exit 0
EOF
  chmod +x "$FAKE_BIN/npm"

  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out '$BATS_TEST_TMPDIR/result.html'"
  [ "$status" -ne 0 ]
  assert_output_contains "no index.html was produced"
  [ ! -f "$BATS_TEST_TMPDIR/result.html" ]
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

@test "a relative --out is resolved against the invocation cwd, not REPO_ROOT" {
  run bash -c "cd '$INVOKE_DIR' && '$SNAPSHOT' --out relative-result.html"
  [ "$status" -eq 0 ]
  assert_output_contains "Snapshot dashboard written to: $INVOKE_DIR/relative-result.html"
  [ -f "$INVOKE_DIR/relative-result.html" ]
}
