#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for the per-file timing script (E77_S06_T04), written by E77_S06_T08.
#
# Fixture only. A throwaway git work tree under $BATS_FILE_TMPDIR holds a synthetic
# tests/ of tiny .bats files (fast, failing, sleeping), a synthetic .publicignore and
# a synthetic timing log; the script is pointed at it with --root and --log. The real
# suite, the real log and the real .publicignore are never read or written, and no case
# times more than three one-second fixture files.
#
# The subject is private-only tooling, so per .publicignore's rule "a test may never
# outlive its subject" each setup skips when the subject is not there. A stub `uptime`
# makes the load-average cases deterministic on a busy or a quiet machine.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-mirror-public/scripts/time-shipping-tests.sh"

make_fixture() {
  local root="$1"
  mkdir -p "$root/tests/fixtures" "$root/scripts" "$root/logs"
  printf '#!/usr/bin/env bash\n:\n' > "$root/scripts/helper.sh"
  printf '%s\n' '#!/usr/bin/env bats' '@test "one" { true; }' '@test "two" { true; }' > "$root/tests/fast.bats"
  printf '%s\n' '#!/usr/bin/env bats' \
    '@test "uses the helper" { [ -f scripts/helper.sh ]; }' \
    '# a literal that names nothing: scripts/does-not-exist.sh' \
    '@test "fails" { false; }' > "$root/tests/failing.bats"
  printf '%s\n' '#!/usr/bin/env bats' '@test "slow" { sleep 1; }' > "$root/tests/sleeps.bats"
  printf '%s\n' '#!/usr/bin/env bats' '@test "never runs" { false; }' > "$root/tests/fixtures/inert.bats"
  printf '%s\n' 'tests/sleeps.bats' > "$root/.publicignore"
  git -C "$root" init -q -b main
  git -C "$root" config user.email t@example.invalid
  git -C "$root" config user.name t
  git -C "$root" add -A
  git -C "$root" commit -q -m fixture
}

setup_file() {
  [ -f "$SCRIPT" ] || skip "subject not shipped"
  BASE="$BATS_FILE_TMPDIR/base"
  export BASE
  make_fixture "$BASE"
  # the baseline run (3 files), shared by the read-only cases, taken with a stub `uptime`
  # reporting a quiet machine so the "no load warning" case is deterministic
  mkdir -p "$BATS_FILE_TMPDIR/quietbin"
  printf '#!/bin/sh\necho " 12:00  up 1 day, 3 users, load averages: 0.40 1.00 1.00"\n' > "$BATS_FILE_TMPDIR/quietbin/uptime"
  chmod +x "$BATS_FILE_TMPDIR/quietbin/uptime"
  PATH="$BATS_FILE_TMPDIR/quietbin:$PATH" bash "$SCRIPT" --root "$BASE" --log "$BASE/logs/test-timings.jsonl" > "$BATS_FILE_TMPDIR/base.out" 2>&1
  echo "$?" > "$BATS_FILE_TMPDIR/base.rc"
}

setup() {
  [ -f "$SCRIPT" ] || skip "subject not shipped"
  ROOT="$BATS_TEST_TMPDIR/root"
  cp -R "$BASE" "$ROOT"
  LOGF="$ROOT/logs/test-timings.jsonl"
}

# a failed watchdog must not leave the hanging fixture process behind
teardown() { pkill -f "sleep 327[0-9]" > /dev/null 2>&1 || true; }

timer() { bash "$SCRIPT" --root "$ROOT" --log "$LOGF" "$@"; }

# a fake `uptime` printing the given 1-minute load, for the load-average cases
stub_uptime() {
  mkdir -p "$BATS_TEST_TMPDIR/stubbin"
  printf '#!/bin/sh\necho " 12:00  up 1 day, 3 users, load averages: %s 1.00 1.00"\n' "$1" > "$BATS_TEST_TMPDIR/stubbin/uptime"
  chmod +x "$BATS_TEST_TMPDIR/stubbin/uptime"
  STUB_PATH="$BATS_TEST_TMPDIR/stubbin:$PATH"
}

record_of() { grep "\"suite\":\"$1\"" "$LOGF" | tail -1; }
record_of_base() { grep "\"suite\":\"$1\"" "$BASE/logs/test-timings.jsonl" | tail -1; }

@test "E77_S06_T04: the baseline run exits 0 and appends one record per fixture file" {
  [ "$(cat "$BATS_FILE_TMPDIR/base.rc")" = "0" ]
  [ "$(wc -l < "$BASE/logs/test-timings.jsonl" | tr -d ' ')" = "3" ]
  run jq -r '.suite' "$BASE/logs/test-timings.jsonl"
  [ "$(printf '%s\n' "$output" | sort | tr '\n' ' ')" = "tests/failing.bats tests/fast.bats tests/sleeps.bats " ]
}

@test "E77_S06_T04: records carry the right test counts, pass/fail counts and status" {
  LOGF="$BASE/logs/test-timings.jsonl"
  f="$(record_of tests/fast.bats)"
  [ "$(echo "$f" | jq -r '[.tests,.passed,.failed,.status] | join(",")')" = "2,2,0,passed" ]
  f="$(record_of tests/failing.bats)"
  [ "$(echo "$f" | jq -r '[.tests,.passed,.failed,.status] | join(",")')" = "2,1,1,failed" ]
  f="$(record_of tests/sleeps.bats)"
  [ "$(echo "$f" | jq -r '[.tests,.passed,.failed,.status] | join(",")')" = "1,1,0,passed" ]
}

@test "E77_S06_T04: the sleeping file has a plausible duration and the fast file is faster" {
  LOGF="$BASE/logs/test-timings.jsonl"
  slow_ms="$(record_of tests/sleeps.bats | jq -r '.duration_ms')"
  fast_ms="$(record_of tests/fast.bats | jq -r '.duration_ms')"
  [ "$slow_ms" -ge 1000 ]
  [ "$slow_ms" -lt 60000 ]
  [ "$fast_ms" -lt "$slow_ms" ]
}

@test "E77_S06_T04: each record carries the HEAD commit and the blob of its test file" {
  LOGF="$BASE/logs/test-timings.jsonl"
  head_sha="$(git -C "$BASE" rev-parse HEAD)"
  blob="$(git hash-object "$BASE/tests/fast.bats")"
  [ "$(record_of tests/fast.bats | jq -r '.commit')" = "$head_sha" ]
  [ "$(record_of tests/fast.bats | jq -r '.blob')" = "$blob" ]
}

@test "E77_S06_T04: the progress lines classify a file shipping or blocklisted" {
  grep -q '^\[[0-9]/3\] tests/fast.bats (shipping): timing' "$BATS_FILE_TMPDIR/base.out"
  grep -q '^\[[0-9]/3\] tests/sleeps.bats (blocklisted): timing' "$BATS_FILE_TMPDIR/base.out"
  grep -q '^timed 3 of 3, up to date 0, skipped 0' "$BATS_FILE_TMPDIR/base.out"
}

@test "E77_S06_T04: a second default run times nothing and appends nothing" {
  run timer
  [ "$status" -eq 0 ]
  case "$output" in
    *"nothing to time"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  [ "$(wc -l < "$LOGF" | tr -d ' ')" = "3" ]
}

@test "E77_S06_T04: editing a test file, or a file a test references, re-times exactly those tests" {
  # fast.bats changes itself; failing.bats is unchanged but names scripts/helper.sh, which changes
  printf '%s\n' '@test "three" { true; }' >> "$ROOT/tests/fast.bats"
  printf '# changed\n' >> "$ROOT/scripts/helper.sh"
  run timer --list-stale
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^stale')" = "2" ]
  case "$output" in
    *"stale"*"tests/failing.bats"*"subject changed: scripts/helper.sh"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  case "$output" in
    *"stale"*"tests/fast.bats"*"test file changed"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  run timer
  [ "$status" -eq 0 ]
  case "$output" in
    *"timed 2 of 3, up to date 1"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  [ "$(wc -l < "$LOGF" | tr -d ' ')" = "5" ]
  [ "$(tail -2 "$LOGF" | jq -r '.suite' | sort | tr '\n' ' ')" = "tests/failing.bats tests/fast.bats " ]
  [ "$(record_of tests/fast.bats | jq -r '.tests')" = "3" ]
}

@test "E77_S06_T04: --all re-times all three files, one at a time (never two bats processes at once)" {
  mkdir -p "$BATS_TEST_TMPDIR/stub"
  real_bats="$(command -v bats)"
  cat > "$BATS_TEST_TMPDIR/stub/bats" <<EOF
#!/usr/bin/env bash
# fails the case if a second bats starts while one is still running
if mkdir "$BATS_TEST_TMPDIR/bats.lock" 2>/dev/null; then
  "$real_bats" "\$@"; rc=\$?
  rmdir "$BATS_TEST_TMPDIR/bats.lock"
  exit \$rc
else
  echo OVERLAP >> "$BATS_TEST_TMPDIR/overlap"
  exec "$real_bats" "\$@"
fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/stub/bats"
  run env PATH="$BATS_TEST_TMPDIR/stub:$PATH" bash "$SCRIPT" --root "$ROOT" --log "$LOGF" --all
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LOGF" | tr -d ' ')" = "6" ]
  [ ! -e "$BATS_TEST_TMPDIR/overlap" ]
}

@test "E77_S06_T04: --timeout 1 on a hanging file records status timeout and leaves no orphan" {
  printf '%s\n' '#!/usr/bin/env bats' '@test "hangs" { sleep 3271; }' > "$ROOT/tests/hangs.bats"
  # an outer alarm bounds the case, so a broken watchdog fails it instead of hanging the suite
  run perl -e 'alarm 40; exec @ARGV' bash "$SCRIPT" --root "$ROOT" --log "$LOGF" --only tests/hangs.bats --timeout 1
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$LOGF" | jq -r '[.suite,.status,.duration_ms] | join(",")')" = "tests/hangs.bats,timeout,1000" ]
  tail -1 "$LOGF" | jq -e '.cpu_ms == null' > /dev/null
  case "$output" in
    *"timeout, killed after 1 s"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  run pgrep -f "sleep 3271"
  [ "$status" -ne 0 ]
}

@test "E77_S06_T04: a recorded timeout shorter than the current --timeout is listed as stale, a longer one is not" {
  printf '%s\n' '#!/usr/bin/env bats' '@test "hangs" { sleep 3272; }' > "$ROOT/tests/hangs.bats"
  bash "$REPO_ROOT/skills/j-test/scripts/record-timing.sh" --suite tests/hangs.bats --tests 1 --passed 0 --failed 0 \
    --duration-ms 1000 --caller fixture --status timeout --commit "$(git -C "$ROOT" rev-parse HEAD)" \
    --blob "$(git hash-object "$ROOT/tests/hangs.bats")" --log "$LOGF"
  run timer --only tests/hangs.bats --timeout 2 --list-stale
  [ "$status" -eq 0 ]
  case "$output" in
    *"earlier timeout"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  run timer --only tests/hangs.bats --timeout 1 --list-stale
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^stale')" = "0" ]
}

@test "E77_S06_T04: manual-only, tests/fixtures/ and --skip files are not run and are named with a reason" {
  printf '%s\n' '#!/usr/bin/env bats' '# jenga:manual-only: takes hours' '@test "huge" { false; }' > "$ROOT/tests/huge.bats"
  run timer --all --skip tests/failing.bats --only tests/huge.bats --only tests/failing.bats --list-stale
  [ "$status" -eq 0 ]
  case "$output" in
    *"skip tests/huge.bats: manual-only: takes hours"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  case "$output" in
    *"skip tests/failing.bats: named by --skip"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  run timer --list-stale --only tests/fixtures/inert.bats
  case "$output" in
    *"skip tests/fixtures/inert.bats: under tests/fixtures/"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  [ "$(wc -l < "$LOGF" | tr -d ' ')" = "3" ]
}

@test "E77_S06_T04: --list-stale runs nothing and writes nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/stub"
  printf '#!/usr/bin/env bash\necho called >> "%s/bats-called"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/stub/bats"
  chmod +x "$BATS_TEST_TMPDIR/stub/bats"
  before="$(cksum < "$LOGF")"
  status_before="$(git -C "$ROOT" status --porcelain | sort)"
  run env PATH="$BATS_TEST_TMPDIR/stub:$PATH" bash "$SCRIPT" --root "$ROOT" --log "$LOGF" --list-stale --all
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^stale')" = "3" ]
  [ ! -e "$BATS_TEST_TMPDIR/bats-called" ]
  [ "$before" = "$(cksum < "$LOGF")" ]
  [ "$status_before" = "$(git -C "$ROOT" status --porcelain | sort)" ]
}

@test "E77_S06_T04: --require-quiet exits 3 on a busy machine and runs and writes nothing" {
  stub_uptime 5.50
  before="$(cksum < "$LOGF")"
  run env PATH="$STUB_PATH" bash "$SCRIPT" --root "$ROOT" --log "$LOGF" --all --require-quiet
  [ "$status" -eq 3 ]
  [ "$before" = "$(cksum < "$LOGF")" ]
}

@test "E77_S06_T04: a busy machine only warns without --require-quiet, and the load is recorded" {
  stub_uptime 5.50
  run env PATH="$STUB_PATH" bash "$SCRIPT" --root "$ROOT" --log "$LOGF" --only tests/fast.bats --all
  [ "$status" -eq 0 ]
  case "$output" in
    *"warning: the 1-minute load average is 5.50"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  tail -1 "$LOGF" | jq -e '.load_1m == 5.5' > /dev/null
}

@test "E77_S06_T04: a quiet machine produces no load warning and the baseline records its load" {
  run grep -c 'warning' "$BATS_FILE_TMPDIR/base.out"
  [ "$output" = "0" ]
  record_of_base tests/fast.bats | jq -e '.load_1m == 0.4' > /dev/null
}

@test "E77_S06_T04: usage errors exit 2" {
  run timer --timeout 0
  [ "$status" -eq 2 ]
  run timer --timeout abc
  [ "$status" -eq 2 ]
  run timer --bogus
  [ "$status" -eq 2 ]
  run timer --only tests/not-there.bats
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$BATS_TEST_TMPDIR/no-such-dir" --log "$LOGF"
  [ "$status" -eq 2 ]
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run bash "$SCRIPT" --root "$BATS_TEST_TMPDIR/plain" --log "$BATS_TEST_TMPDIR/plain.jsonl"
  [ "$status" -eq 2 ]
  [ "$(wc -l < "$LOGF" | tr -d ' ')" = "3" ]
}

@test "E77_S06_T04: --help prints the contract and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  case "$output" in
    *"--list-stale"*"--timeout"*) ;;
    *) echo "help incomplete"; return 1 ;;
  esac
}

@test "E77_S06_T11: each completed file's record carries cpu_ms, and the sleeping file used far less CPU than wall time" {
  LOGF="$BASE/logs/test-timings.jsonl"
  for t in fast failing sleeps; do
    record_of "tests/$t.bats" | jq -e '(.cpu_ms | type) == "number" and .cpu_ms >= 0' > /dev/null
  done
  wall="$(record_of tests/sleeps.bats | jq -r '.duration_ms')"
  cpu="$(record_of tests/sleeps.bats | jq -r '.cpu_ms')"
  [ "$cpu" -lt "$wall" ]
}

@test "E77_S06_T11: the progress line shows the CPU seconds next to the wall seconds" {
  grep -Eq -- "-> (passed|failed) [0-9.]+ s, [0-9.]+ s cpu \\(" "$BATS_FILE_TMPDIR/base.out"
}
