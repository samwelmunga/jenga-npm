#!/usr/bin/env bats
#
# Coverage for the long-running report (E77_S06_T05), written by E77_S06_T08.
#
# Fixture only. Two throwaway roots under $BATS_FILE_TMPDIR ("four", the task's
# four-file case, and "mixed", every other state) each hold a synthetic tests/ of tiny
# files that are never executed, a synthetic .publicignore and a synthetic timing log
# written through the shared record writer. setup_file runs the report over them once
# and the cases read the saved output, which keeps the file fast. The real suite, the
# real log and the real .publicignore are never read or written, and no case runs a
# single bats file.
#
# The subject is private-only tooling, so per .publicignore's rule "a test may never
# outlive its subject" each setup skips when the subject is not there.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-mirror-public/scripts/long-running-report.sh"
RECORD="$REPO_ROOT/skills/j-test/scripts/record-timing.sh"

setup_file() {
  [ -f "$SCRIPT" ] || skip "subject not shipped"
  # ---- "four": two over 50 s, one at 49 s, one unmeasured
  new_root four
  mk_test big-a 'run scripts/shipped.sh'
  mk_test big-b
  mk_test edge
  mk_test unmeasured
  rec big-a 70000 12
  rec big-b 55000 3
  rec edge 49000 4
  FOUR="$ROOT"
  export FOUR
  BEFORE="$(tree_hash)"
  report > "$BATS_FILE_TMPDIR/four.txt"
  report > "$BATS_FILE_TMPDIR/four-again.txt"
  report --format tsv > "$BATS_FILE_TMPDIR/four.tsv"
  report --threshold 30 > "$BATS_FILE_TMPDIR/four-30.txt"
  AFTER="$(tree_hash)"
  [ "$BEFORE" = "$AFTER" ] && echo same > "$BATS_FILE_TMPDIR/four-readonly" || echo changed > "$BATS_FILE_TMPDIR/four-readonly"
  # ---- "mixed": already-blocklisted, blocked subject, stale, newest wins, timeout, manual-only, load
  new_root mixed
  mk_test blocked-slow
  mk_test big-b2 'run scripts/private-only.sh'
  mk_test stale
  mk_test newest
  mk_test hangs
  mk_test huge '# jenga:manual-only: takes hours'
  mk_test a
  mk_test b
  rec blocked-slow 90000 5
  rec big-b2 55000 3
  rec stale 70000 2
  printf '# edited after it was measured\n' >> "$ROOT/tests/stale.bats"
  rec newest 200000 2
  rec newest 10000 2
  rec hangs 100000 1 timeout
  rec a 1000 1 passed 6.5
  rec b 1000 1 passed 0.2
  MIXED="$ROOT"
  report > "$BATS_FILE_TMPDIR/mixed.txt"
  report --format tsv > "$BATS_FILE_TMPDIR/mixed.tsv"
  # ---- "cpu": records with cpu_ms are measured by it (wall time was inflated by a busy machine)
  new_root cpu
  mk_test waits-a
  mk_test waits-b
  mk_test cpu-heavy
  mk_test wall-heavy
  rec waits-a 300000 5 passed 9.1 20000
  rec waits-b 400000 5 passed 9.1 30000
  rec cpu-heavy 90000 5 passed 9.1 80000
  rec wall-heavy 70000 5 passed 0.4
  report > "$BATS_FILE_TMPDIR/cpu.txt"
  report --format tsv > "$BATS_FILE_TMPDIR/cpu.tsv"
}

setup() {
  [ -f "$SCRIPT" ] || skip "subject not shipped"
  FOUR_TXT="$BATS_FILE_TMPDIR/four.txt"
}

# new_root <name>: a fresh fixture root; sets ROOT and LOGF
new_root() {
  ROOT="$BATS_FILE_TMPDIR/$1"
  LOGF="$ROOT/logs/test-timings.jsonl"
  mkdir -p "$ROOT/tests" "$ROOT/scripts" "$ROOT/logs"
  printf '#!/usr/bin/env bash\n:\n' > "$ROOT/scripts/shipped.sh"
  printf '#!/usr/bin/env bash\n:\n' > "$ROOT/scripts/private-only.sh"
  printf '%s\n' 'tests/blocked-slow.bats' 'scripts/private-only.sh' > "$ROOT/.publicignore"
}

# mk_test <name> [body]: a synthetic test file (never run)
mk_test() {
  printf '#!/usr/bin/env bats\n%s\n@test "t" { true; }\n' "${2:-}" > "$ROOT/tests/$1.bats"
}

# rec <name> <duration-ms> <tests> [status] [load] [cpu-ms]: a record whose blob matches the file as it is now
rec() {
  bash "$RECORD" --suite "tests/$1.bats" --tests "$3" --passed "$3" --failed 0 --duration-ms "$2" \
    --caller fixture --status "${4:-passed}" --commit abc1234 --blob "$(git hash-object "$ROOT/tests/$1.bats")" \
    --log "$LOGF" ${5:+--load-1m "$5"} ${6:+--cpu-ms "$6"}
}

report() { bash "$SCRIPT" --root "$ROOT" --log "$LOGF" "$@"; }

# section <file> <title-prefix>: the lines of one `== ... ==` section of a saved report, without its heading
section() {
  awk -v p="== $2" 'index($0, p) == 1 { on = 1; next } /^== / { on = 0 } on' "$1"
}

tree_hash() { (cd "$ROOT" && find . -type f | LC_ALL=C sort | xargs cksum); }

has() { grep -qF -- "$2" "$1" || { echo "missing in $1: $2"; cat "$1"; return 1; }; }
lacks() { if grep -qF -- "$2" "$1"; then echo "unexpected in $1: $2"; cat "$1"; return 1; fi; }

@test "E77_S06_T05: two files over 50 s are listed with seconds and test counts, the 49 s file and the unmeasured one are not" {
  over="$(section "$FOUR_TXT" 'Over threshold')"
  [ "$(printf '%s\n' "$over" | grep -c '^tests/')" = "2" ]
  has "$FOUR_TXT" "tests/big-a.bats  70.0 s  12 tests"
  has "$FOUR_TXT" "tests/big-b.bats  55.0 s  3 tests"
  case "$over" in
    *edge*|*unmeasured*) echo "$over"; return 1 ;;
  esac
}

@test "E77_S06_T05: the over-threshold list is longest first" {
  over="$(section "$FOUR_TXT" 'Over threshold')"
  [ "$(printf '%s\n' "$over" | grep '^tests/' | head -1 | cut -d' ' -f1)" = "tests/big-a.bats" ]
}

@test "E77_S06_T05: the unmeasured file is listed separately under never measured" {
  unmeasured="$(section "$FOUR_TXT" 'Never measured')"
  [ "$(printf '%s\n' "$unmeasured" | grep -c '^tests/')" = "1" ]
  case "$unmeasured" in
    *"tests/unmeasured.bats  no record"*) ;;
    *) echo "$unmeasured"; return 1 ;;
  esac
}

@test "E77_S06_T05: the saved total equals the sum of the over-threshold files" {
  has "$FOUR_TXT" "Gate time saved if the still-shipping over-threshold files are excluded: 125.0 s (2 files)"
  has "$FOUR_TXT" "Files over the threshold: 2"
  has "$FOUR_TXT" "Measured: 3 of 4 files, 174.0 s in total"
}

@test "E77_S06_T05: a test whose referenced path ships is flagged, naming that path, and the report calls it a heuristic" {
  has "$FOUR_TXT" "subject ships publicly: scripts/shipped.sh"
  has "$FOUR_TXT" "heuristic"
  has "$FOUR_TXT" "is your decision"
}

@test "E77_S06_T05: a test whose referenced paths are all blocked gets no publicly-ships flag" {
  has "$BATS_FILE_TMPDIR/mixed.txt" "tests/big-b2.bats  55.0 s  3 tests  ships"
  lacks "$BATS_FILE_TMPDIR/mixed.txt" "subject ships publicly:"
  # in the four-file fixture only big-a is flagged
  [ "$(grep -c 'subject ships publicly:' "$FOUR_TXT")" = "1" ]
}

@test "E77_S06_T05: a file already in .publicignore shows that state and counts as already saved, not saved-if-excluded" {
  M="$BATS_FILE_TMPDIR/mixed.txt"
  has "$M" "tests/blocked-slow.bats  90.0 s  5 tests  already in .publicignore"
  has "$M" "already saved (over threshold and already in .publicignore): 90.0 s (1 files)"
  # the 90 s of the blocklisted file is not part of the saved-if-excluded sum (55 s + the 100 s timeout)
  has "$M" "excluded: at least 155.0 s (2 files)"
}

@test "E77_S06_T05: a stale record (changed blob) lands under never measured, not in the over-threshold list" {
  M="$BATS_FILE_TMPDIR/mixed.txt"
  has "$M" "tests/stale.bats  stale: test file changed since it was measured"
  case "$(section "$M" 'Never measured')" in
    *"tests/stale.bats"*) ;;
    *) echo "stale file is not under never measured"; return 1 ;;
  esac
  case "$(section "$M" 'Over threshold')" in
    *"tests/stale.bats"*) echo "stale file listed as over threshold"; return 1 ;;
  esac
}

@test "E77_S06_T05: the newest record of a file wins over an older one" {
  M="$BATS_FILE_TMPDIR/mixed.txt"
  lacks "$M" "tests/newest.bats  200.0 s"
  case "$(section "$M" 'Over threshold')" in
    *newest*) echo "newest.bats is listed although its newest record is 10 s"; return 1 ;;
  esac
}

@test "E77_S06_T05: --threshold 30 changes the list" {
  [ "$(section "$BATS_FILE_TMPDIR/four-30.txt" 'Over threshold' | grep -c '^tests/')" = "3" ]
  has "$BATS_FILE_TMPDIR/four-30.txt" "tests/edge.bats  49.0 s"
  has "$BATS_FILE_TMPDIR/four-30.txt" "mirror-gate threshold: 30 s"
  has "$FOUR_TXT" "mirror-gate threshold: 50 s"
}

@test "E77_S06_T05: without --threshold the value comes from test-config.json through the shared reader" {
  ROOT="$FOUR"
  LOGF="$ROOT/logs/test-timings.jsonl"
  mkdir -p "$BATS_TEST_TMPDIR/cfgroot/project/configs" "$BATS_TEST_TMPDIR/cfgroot/tests"
  cp "$FOUR/tests/"*.bats "$BATS_TEST_TMPDIR/cfgroot/tests/"
  printf '%s\n' '{"mirror_gate_threshold_seconds": 60}' > "$BATS_TEST_TMPDIR/cfgroot/project/configs/test-config.json"
  run env -u JENGA_PROJECT_ROOT bash "$SCRIPT" --root "$BATS_TEST_TMPDIR/cfgroot" --log "$LOGF"
  [ "$status" -eq 0 ]
  case "$output" in
    *"mirror-gate threshold: 60 s"*) ;;
    *) echo "$output"; return 1 ;;
  esac
  case "$output" in
    *"tests/big-b.bats  55.0 s"*) echo "55 s file listed at a 60 s threshold"; return 1 ;;
  esac
}

@test "E77_S06_T05: --format tsv prints exactly 5 tab-separated fields per over-threshold line and nothing else" {
  T="$BATS_FILE_TMPDIR/four.tsv"
  [ "$(grep -c . "$T")" = "2" ]
  while IFS= read -r line; do
    [ "$(printf '%s' "$line" | awk -F'\t' '{ print NF }')" = "5" ]
  done < "$T"
  [ "$(sed -n 1p "$T")" = "$(printf 'tests/big-a.bats\t70.0\t12\tships\tscripts/shipped.sh')" ]
  [ "$(sed -n 2p "$T")" = "$(printf 'tests/big-b.bats\t55.0\t3\tships\t-')" ]
}

@test "E77_S06_T05: --format tsv carries the state, and a timeout is shown with a >= prefix" {
  T="$BATS_FILE_TMPDIR/mixed.tsv"
  [ "$(grep -c . "$T")" = "3" ]
  [ "$(awk -F'\t' '$1 == "tests/blocked-slow.bats" { print $4 }' "$T")" = "already in .publicignore" ]
  [ "$(awk -F'\t' '$1 == "tests/hangs.bats" { print $2 }' "$T")" = ">=100.0" ]
  while IFS= read -r line; do
    [ "$(printf '%s' "$line" | awk -F'\t' '{ print NF }')" = "5" ]
  done < "$T"
}

@test "E77_S06_T05: a timeout is shown as at least the cap in the text" {
  has "$BATS_FILE_TMPDIR/mixed.txt" "tests/hangs.bats  at least 100.0 s"
}

@test "E77_S06_T05: a manual-only file is outside the universe and never listed as unmeasured" {
  lacks "$BATS_FILE_TMPDIR/mixed.txt" "huge"
  has "$BATS_FILE_TMPDIR/mixed.txt" "Measured: 6 of 7 files"
}

@test "E77_S06_T05: a load warning appears when more than 10 percent of records were taken on a busy machine, and not otherwise" {
  has "$BATS_FILE_TMPDIR/mixed.txt" "WARNING: 1 of 6 measured files were timed at a 1-minute load average above 2.0"
  lacks "$FOUR_TXT" "WARNING"
}

@test "E77_S06_T05: the report is read-only: the whole fixture tree is byte-identical after the runs" {
  [ "$(cat "$BATS_FILE_TMPDIR/four-readonly")" = "same" ]
}

@test "E77_S06_T05: the text is a pure function of the log and the tree (two runs are byte-identical)" {
  cmp "$FOUR_TXT" "$BATS_FILE_TMPDIR/four-again.txt"
}

@test "E77_S06_T05: an absent log exits 6 and says to run the timing script" {
  run bash "$SCRIPT" --root "$FOUR" --log "$BATS_TEST_TMPDIR/no-such.jsonl"
  [ "$status" -eq 6 ]
  case "$output" in
    *time-shipping-tests.sh*) ;;
    *) echo "$output"; return 1 ;;
  esac
}

@test "E77_S06_T05: usage errors exit 2" {
  run bash "$SCRIPT" --root "$FOUR" --log "$FOUR/logs/test-timings.jsonl" --threshold 0
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$FOUR" --log "$FOUR/logs/test-timings.jsonl" --threshold abc
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$FOUR" --log "$FOUR/logs/test-timings.jsonl" --format csv
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$FOUR" --bogus
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$BATS_TEST_TMPDIR/no-such-dir" --log "$BATS_TEST_TMPDIR/x.jsonl"
  [ "$status" -eq 2 ]
}

@test "E77_S06_T05: --help prints the contract and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  case "$output" in
    *"--format"*"tsv"*) ;;
    *) echo "help incomplete"; return 1 ;;
  esac
}

@test "E77_S06_T11: a record with cpu_ms is measured by it, so a long wall time over a short CPU time is not over threshold" {
  has "$BATS_FILE_TMPDIR/cpu.txt" "tests/cpu-heavy.bats  80.0 s cpu  5 tests"
  has "$BATS_FILE_TMPDIR/cpu.txt" "tests/wall-heavy.bats  70.0 s  5 tests"
  over="$(section "$BATS_FILE_TMPDIR/cpu.txt" 'Over threshold')"
  case "$over" in
    *waits-a*|*waits-b*) echo "$over"; return 1 ;;
  esac
  [ "$(printf '%s\n' "$over" | grep -c '^tests/')" = "2" ]
}

@test "E77_S06_T11: the totals state the basis, and the load warning ignores CPU-measured records" {
  has "$BATS_FILE_TMPDIR/cpu.txt" "Basis: cpu time (user plus system) for 3 files, wall-clock time for 1 files"
  lacks "$BATS_FILE_TMPDIR/cpu.txt" "WARNING"
}

@test "E77_S06_T11: the tsv keeps its five fields and uses the CPU seconds" {
  [ "$(awk -F'\t' '{ print NF }' "$BATS_FILE_TMPDIR/cpu.tsv" | sort -u)" = "5" ]
  grep -q "^tests/cpu-heavy.bats	80.0	5	ships	-$" "$BATS_FILE_TMPDIR/cpu.tsv"
}

@test "E77_S06_T11: a log with no cpu_ms is reported without a Basis line (unchanged output)" {
  lacks "$FOUR_TXT" "Basis:"
  lacks "$BATS_FILE_TMPDIR/mixed.txt" "Basis:"
}
