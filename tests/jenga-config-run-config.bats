#!/usr/bin/env bats
#
# run-config.sh: the install-and-rerun entry point for `/jenga-config` (E68_S04_T01).
#
# Everything runs against stubs. No case touches the network or the real ~/.cache.
#   - PATH is `<stub dir>:/usr/bin:/bin`. A symlink to the real `node` is the only toolchain entry in the stub dir,
#     so nvm, homebrew and any global npm prefix are unreachable. A case that needs a `jenga` on PATH writes one into
#     the stub dir; every other case has none, so the wrapper must install.
#   - A stub `npm` records its argv and cwd. For `install --prefix <dir>` it writes a stub bin at
#     <dir>/node_modules/@jenga-ai/agent/bin/jenga.js. It also prints a line on stdout, which the wrapper must route
#     to stderr.
#   - JENGA_CLI_CACHE points into $BATS_TEST_TMPDIR, so the real cache is never read or written.
#
# RECORD is a plain-text log. Each stub appends `CALL <tool>`, then its argv one element per line, then
# `CWD <physical cwd>`. Cases compare the whole log exactly where order and argv matter, so an extra or missing call
# fails the test.
#
# Assertions use `[ ... ]` and `grep`, never a leading `!`. `set -e` ignores a failing `! cmd`, so a negated
# assertion written that way would pass silently.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
SCRIPT="$REPO_ROOT/skills/jenga-config/scripts/run-config.sh"
PINNED="4.2.0"

setup() {
  STUB="$BATS_TEST_TMPDIR/stub-bin"
  CACHE="$BATS_TEST_TMPDIR/cache"
  RECORD="$BATS_TEST_TMPDIR/record.log"
  PROJ="$BATS_TEST_TMPDIR/consumer"
  STUB_CLI_JS="$BATS_TEST_TMPDIR/stub-cli.js"
  mkdir -p "$STUB" "$PROJ/sub/deeper"
  : > "$RECORD"
  ln -s "$(command -v node)" "$STUB/node"

  # Stub bin: records how it was run, then exits with STUB_EXIT (default 0).
  cat > "$STUB_CLI_JS" <<'JS'
const fs = require("fs");
const lines = ["CALL cached", "CWD " + process.cwd(), ...process.argv.slice(2)];
fs.appendFileSync(process.env.RECORD, lines.join("\n") + "\n");
process.exit(Number(process.env.STUB_EXIT || 0));
JS

  # Stub npm: records its call; for `install --prefix <dir>` writes the stub bin into that prefix.
  cat > "$STUB/npm" <<'EOF'
#!/usr/bin/env bash
{ printf 'CALL npm\n'; printf '%s\n' "$@"; printf 'CWD %s\n' "$(pwd -P)"; } >> "$RECORD"
echo "npm-progress-on-stdout"
if [ "${STUB_NPM_FAIL:-0}" = 1 ]; then
  echo "npm ERR! simulated registry failure" >&2
  exit 1
fi
prefix=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--prefix" ]; then prefix="$2"; fi
  shift
done
[ -n "$prefix" ] || exit 1
mkdir -p "$prefix/node_modules/@jenga-ai/agent/bin"
cp "$STUB_CLI_JS" "$prefix/node_modules/@jenga-ai/agent/bin/jenga.js"
EOF
  chmod +x "$STUB/npm"

  PROJ_P="$(cd "$PROJ" && pwd -P)"
  cd "$PROJ"

  # The "absent" cases are only meaningful if no real jenga resolves under the restricted PATH.
  if PATH="/usr/bin:/bin" command -v jenga >/dev/null 2>&1; then
    skip "a real jenga is on /usr/bin or /bin; the absent-jenga cases cannot run"
  fi
}

# run_cfg <args...>: run the wrapper under the restricted PATH with the stub environment.
run_cfg() {
  run --separate-stderr env -i \
    PATH="$STUB:/usr/bin:/bin" \
    HOME="$BATS_TEST_TMPDIR/home" \
    JENGA_CLI_CACHE="$CACHE" \
    RECORD="$RECORD" \
    STUB_CLI_JS="$STUB_CLI_JS" \
    STUB_EXIT="${STUB_EXIT:-0}" \
    STUB_NPM_FAIL="${STUB_NPM_FAIL:-0}" \
    bash "$SCRIPT" "$@"
}

# calls_of <tool>: how many `CALL <tool>` records were written. grep's exit status is ignored; the count is the value.
calls_of() {
  grep -c "^CALL $1\$" "$RECORD" || true
}

# write_jenga_stub: put a `jenga` on PATH that records its call and exits with STUB_EXIT.
write_jenga_stub() {
  cat > "$STUB/jenga" <<'EOF'
#!/usr/bin/env bash
{ printf 'CALL jenga\n'; printf '%s\n' "$@"; printf 'CWD %s\n' "$(pwd -P)"; } >> "$RECORD"
exit "${STUB_EXIT:-0}"
EOF
  chmod +x "$STUB/jenga"
}

# populate_cache: a cache that already holds the stub bin, as after an earlier install.
populate_cache() {
  mkdir -p "$CACHE/node_modules/@jenga-ai/agent/bin"
  cp "$STUB_CLI_JS" "$CACHE/node_modules/@jenga-ai/agent/bin/jenga.js"
}

@test "run-config.sh parses under bash -n and never changes directory" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -cE '(^|[;&|[:space:]])cd[[:space:]]' || true)" -eq 0 ]
}

@test "a jenga already on PATH is used, and neither the cache nor npm is consulted" {
  write_jenga_stub
  populate_cache
  run_cfg get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ "$(calls_of jenga)" -eq 1 ]
  [ "$(calls_of cached)" -eq 0 ]
  [ "$(calls_of npm)" -eq 0 ]
  expected=$(printf 'CALL jenga\nconfig\nget\nscope-thresholds.inline_max_files\nCWD %s\n' "$PROJ_P")
  [ "$(cat "$RECORD")" = "$expected" ]
}

@test "a populated cache runs the cached bin with the same arguments and never calls npm" {
  populate_cache
  run_cfg get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ "$(calls_of npm)" -eq 0 ]
  [ "$(calls_of cached)" -eq 1 ]
  expected=$(printf 'CALL cached\nCWD %s\nconfig\nget\nscope-thresholds.inline_max_files\n' "$PROJ_P")
  [ "$(cat "$RECORD")" = "$expected" ]
}

@test "no cache: exactly one npm install into the cache, then the subcommand reruns through it" {
  run_cfg get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ "$(calls_of npm)" -eq 1 ]
  [ "$(calls_of cached)" -eq 1 ]
  expected=$(printf 'CALL npm\ninstall\n--prefix\n%s\n--ignore-scripts\n--no-audit\n--no-fund\n@jenga-ai/agent@%s\nCWD %s\nCALL cached\nCWD %s\nconfig\nget\nscope-thresholds.inline_max_files\n' \
    "$CACHE" "$PINNED" "$PROJ_P" "$PROJ_P")
  [ "$(cat "$RECORD")" = "$expected" ]
}

@test "npm progress goes to stderr, so stdout carries only the subcommand's output" {
  run_cfg get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "${stderr#*npm-progress-on-stdout}" != "$stderr" ]
}

@test "the install never uses -g or a global location" {
  run_cfg get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ "$(calls_of npm)" -eq 1 ]
  [ "$(grep -c -e '^-g$' -e '^--global$' -e '^--location=global$' "$RECORD" || true)" -eq 0 ]
  [ "$(grep -c -e '^--prefix$' "$RECORD" || true)" -eq 1 ]
}

@test "an npm install failure exits 7 with a stderr message and never runs the subcommand" {
  STUB_NPM_FAIL=1 run_cfg get scope-thresholds.inline_max_files
  [ "$status" -eq 7 ]
  [ "$(calls_of npm)" -eq 1 ]
  [ "$(calls_of cached)" -eq 0 ]
  [ -z "$output" ]
  [ "${stderr#*could not be installed}" != "$stderr" ]
  [ ! -e "$CACHE/node_modules/@jenga-ai/agent/bin/jenga.js" ]
}

@test "subcommand exit codes 2, 3, 4, 5 and 6 pass through unchanged from the cached bin" {
  populate_cache
  for code in 2 3 4 5 6; do
    STUB_EXIT="$code" run_cfg set scope-thresholds.inline_max_files 9
    [ "$status" -eq "$code" ]
  done
}

@test "subcommand exit codes 2, 3, 4, 5 and 6 pass through unchanged from a PATH jenga" {
  write_jenga_stub
  for code in 2 3 4 5 6; do
    STUB_EXIT="$code" run_cfg set scope-thresholds.inline_max_files 9
    [ "$status" -eq "$code" ]
  done
}

@test "works from a subdirectory: the caller's cwd reaches the subcommand unchanged" {
  populate_cache
  cd "$PROJ/sub/deeper"
  deeper_p="$(pwd -P)"
  run_cfg get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ "$(grep -cFx "CWD $deeper_p" "$RECORD")" -eq 1 ]
}

@test "works from a subdirectory on the install path too: npm and the rerun both keep the caller's cwd" {
  cd "$PROJ/sub/deeper"
  deeper_p="$(pwd -P)"
  run_cfg get scope-thresholds.inline_max_files
  [ "$status" -eq 0 ]
  [ "$(grep -cFx "CWD $deeper_p" "$RECORD")" -eq 2 ]
}
