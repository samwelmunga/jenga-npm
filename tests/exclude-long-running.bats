#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for the confirmed .publicignore exclusion step (E77_S06_T06), written by
# E77_S06_T09.
#
# Fixture only. A throwaway git work tree under $BATS_FILE_TMPDIR holds a synthetic
# tests/ of tiny files that are never executed, a synthetic .publicignore, a synthetic
# timing log written through the shared record writer, and a COPY of mirror.sh with its
# assets/config.json beside it, so that the copy's --exclude branch writes the fixture's
# .publicignore and never the real one (the script refuses a mirror.sh that belongs to
# another work tree; one case drives exactly that refusal). setup_file runs the script
# once per scenario and the cases read the saved results.
#
# The subject is private-only tooling, so per .publicignore's rule "a test may never
# outlive its subject" each setup skips when the subject is not there. Blocked-skill
# names are not written literally.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL_DIR="$REPO_ROOT/skills/j-mirror-public"
SCRIPT="$SKILL_DIR/scripts/exclude-long-running.sh"
RECORD="$REPO_ROOT/skills/j-test/scripts/record-timing.sh"
HEADER='# --- Long-running tests, kept private-side (E77_S06) ---'

# new_root <dir>: a fixture work tree with the tests, the log, a .publicignore and a mirror.sh copy
new_root() {
  ROOT="$1"
  mkdir -p "$ROOT/tests" "$ROOT/scripts" "$ROOT/logs" "$ROOT/skills/j-mirror-public/scripts" "$ROOT/skills/j-mirror-public/assets"
  cp "$SKILL_DIR/scripts/mirror.sh" "$ROOT/skills/j-mirror-public/scripts/mirror.sh"
  cp "$SKILL_DIR/assets/config.json" "$ROOT/skills/j-mirror-public/assets/config.json"
  printf '#!/usr/bin/env bash\n:\n' > "$ROOT/scripts/shipped.sh"
  mk_test over-a 'run scripts/shipped.sh'
  mk_test over-b
  mk_test already
  mk_test fast
  printf '%s\n' '# existing blocklist' 'project/' 'tests/already.bats' > "$ROOT/.publicignore"
  LOGF="$ROOT/logs/test-timings.jsonl"
  rec over-a 70000 12
  rec over-b 55000 3
  rec already 90000 5
  rec fast 10000 1
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" config user.email t@example.invalid
  git -C "$ROOT" config user.name t
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -q -m fixture
}

mk_test() {
  printf '#!/usr/bin/env bats\n%s\n@test "t" { true; }\n' "${2:-}" > "$ROOT/tests/$1.bats"
}

# rec <name> <duration-ms> <tests> [status]: a record whose blob matches the file as it is now
rec() {
  bash "$RECORD" --suite "tests/$1.bats" --tests "$3" --passed "$3" --failed 0 --duration-ms "$2" \
    --caller fixture --status "${4:-passed}" --commit abc1234 --blob "$(git hash-object "$ROOT/tests/$1.bats")" \
    --log "$LOGF"
}

# fresh <name>: a copy of the base fixture, ROOT and LOGF pointing at it
fresh() {
  cp -R "$BASE" "$BATS_FILE_TMPDIR/$1"
  ROOT="$BATS_FILE_TMPDIR/$1"
  LOGF="$ROOT/logs/test-timings.jsonl"
}

# excl <extra args...>: run the script against $ROOT, stdin as given by the caller
excl() { bash "$SCRIPT" --root "$ROOT" --log "$LOGF" "$@"; }

setup_file() {
  [ -f "$SCRIPT" ] || skip "subject not shipped"
  set +e   # the scenarios below record non-zero exits on purpose
  BASE="$BATS_FILE_TMPDIR/base"
  export BASE
  new_root "$BASE"
  PI_BASE="$BASE/.publicignore"
  REAL_PI_BEFORE="$(cksum < "$REPO_ROOT/.publicignore")"

  # scenario n: the answer "n"
  fresh n
  cp "$ROOT/.publicignore" "$BATS_FILE_TMPDIR/n.before"
  printf 'n\n' | excl > "$BATS_FILE_TMPDIR/n.out" 2>&1; echo "$?" > "$BATS_FILE_TMPDIR/n.rc"

  # scenario empty: an empty line is not an answer of y
  fresh empty
  printf '\n' | excl > "$BATS_FILE_TMPDIR/empty.out" 2>&1; echo "$?" > "$BATS_FILE_TMPDIR/empty.rc"

  # scenario noans: no terminal and no data on stdin at all
  fresh noans
  excl < /dev/null > "$BATS_FILE_TMPDIR/noans.out" 2>&1; echo "$?" > "$BATS_FILE_TMPDIR/noans.rc"

  # scenario y: confirm, then run again with the same input
  fresh yes
  printf 'y\n' | excl > "$BATS_FILE_TMPDIR/y1.out" 2>&1; echo "$?" > "$BATS_FILE_TMPDIR/y1.rc"
  cp "$ROOT/.publicignore" "$BATS_FILE_TMPDIR/y1.publicignore"
  printf 'y\n' | excl > "$BATS_FILE_TMPDIR/y2.out" 2>&1; echo "$?" > "$BATS_FILE_TMPDIR/y2.rc"
  cp "$ROOT/.publicignore" "$BATS_FILE_TMPDIR/y2.publicignore"

  # scenario timeout: a file recorded as a timeout, with and without --no-timeouts
  fresh timeout
  mk_test hangs
  rec hangs 100000 1 timeout
  printf 'n\n' | excl > "$BATS_FILE_TMPDIR/to-n.out" 2>&1
  printf 'n\n' | excl --no-timeouts > "$BATS_FILE_TMPDIR/to-skip.out" 2>&1

  # scenario writer: a mirror.sh stand-in that only records its calls. The script must leave the
  # path lines to it, so with this stand-in no path line may appear.
  fresh writer
  cat > "$ROOT/skills/j-mirror-public/scripts/stand-in.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ROOT/stand-in.calls"
exit 0
EOF
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -q -m stand-in
  printf 'y\n' | excl --mirror "$ROOT/skills/j-mirror-public/scripts/stand-in.sh" > "$BATS_FILE_TMPDIR/writer.out" 2>&1

  # scenario foreign: a mirror.sh that belongs to ANOTHER work tree is refused before asking
  fresh foreign
  cp "$ROOT/.publicignore" "$BATS_FILE_TMPDIR/foreign.before"
  OTHER="$BATS_FILE_TMPDIR/other-repo"
  mkdir -p "$OTHER/skills/j-mirror-public/scripts"
  printf '#!/usr/bin/env bash\necho "should never run" >> "%s/other-ran"\nexit 0\n' "$OTHER" > "$OTHER/skills/j-mirror-public/scripts/mirror.sh"
  git -C "$OTHER" init -q -b main
  printf 'y\n' | excl --mirror "$OTHER/skills/j-mirror-public/scripts/mirror.sh" > "$BATS_FILE_TMPDIR/foreign.out" 2>&1; echo "$?" > "$BATS_FILE_TMPDIR/foreign.rc"
  export OTHER

  echo "$REAL_PI_BEFORE" > "$BATS_FILE_TMPDIR/real-pi.before"
  cksum < "$REPO_ROOT/.publicignore" > "$BATS_FILE_TMPDIR/real-pi.after"
}

setup() {
  [ -f "$SCRIPT" ] || skip "subject not shipped"
  D="$BATS_FILE_TMPDIR"
}

has() { grep -qF -- "$2" "$1" || { echo "missing in $1: $2"; cat "$1"; return 1; }; }
lacks() { if grep -qF -- "$2" "$1"; then echo "unexpected in $1: $2"; cat "$1"; return 1; fi; }

@test "E77_S06_T06: answering n leaves the fixture .publicignore byte-identical, exit 0, and says no changes" {
  [ "$(cat "$D/n.rc")" = "0" ]
  cmp "$D/n.before" "$D/n/.publicignore"
  has "$D/n.out" "no changes"
}

@test "E77_S06_T06: an empty answer line is not a yes: nothing written, exit 0" {
  [ "$(cat "$D/empty.rc")" = "0" ]
  cmp "$BASE/.publicignore" "$D/empty/.publicignore"
  has "$D/empty.out" "no changes"
}

@test "E77_S06_T06: no terminal and no answer on stdin exits 3 with the file unchanged" {
  [ "$(cat "$D/noans.rc")" = "3" ]
  cmp "$BASE/.publicignore" "$D/noans/.publicignore"
  has "$D/noans.out" "nothing was written"
}

@test "E77_S06_T06: the proposal shows each file with seconds and test count, plus the comment that will be written" {
  has "$D/n.out" "tests/over-a.bats  70.0 s  12 tests"
  has "$D/n.out" "tests/over-b.bats  55.0 s  3 tests"
  has "$D/n.out" "comment: # tests/over-a.bats: 70.0 s over the 50 s mirror-gate threshold (measured "
  has "$D/n.out" "Add these 2 files to .publicignore? [y/N]"
}

@test "E77_S06_T06: the subject-ships-publicly flag appears in the proposal for a flagged file and only for it" {
  has "$D/n.out" "subject ships publicly: scripts/shipped.sh"
  [ "$(grep -c 'subject ships publicly:' "$D/n.out")" = "1" ]
}

@test "E77_S06_T06: answering y exits 0 and adds a comment citing the measured seconds immediately above each path" {
  [ "$(cat "$D/y1.rc")" = "0" ]
  PI="$D/y1.publicignore"
  for f in over-a over-b; do
    line="$(grep -nxF "tests/$f.bats" "$PI" | cut -d: -f1)"
    [ -n "$line" ]
    above="$(sed -n "$((line - 1))p" "$PI")"
    case "$above" in
      "# tests/$f.bats: "*" s over the 50 s mirror-gate threshold (measured "*" tests; see project/logs/test-timings.jsonl)") ;;
      *) echo "line above tests/$f.bats: $above"; return 1 ;;
    esac
  done
  has "$PI" "# tests/over-a.bats: 70.0 s over the 50 s mirror-gate threshold"
  has "$PI" "# tests/over-b.bats: 55.0 s over the 50 s mirror-gate threshold"
  # what was there before is still there, in order, at the top
  [ "$(head -3 "$PI")" = "$(cat "$BASE/.publicignore")" ]
}

@test "E77_S06_T06: the path lines are written through mirror.sh --exclude" {
  # the copy of mirror.sh logs "added '<path>'" for each path line it writes
  has "$D/y1.out" "added 'tests/over-a.bats'"
  has "$D/y1.out" "added 'tests/over-b.bats'"
  has "$D/y1.out" "added: tests/over-a.bats"
  has "$D/y1.out" "Added 2 files to .publicignore through mirror.sh --exclude."
  has "$D/y1.out" "mirror.sh --dry-run"
}

@test "E77_S06_T06: with a stand-in for mirror.sh the script itself writes no path line, only the stand-in is asked to" {
  [ "$(sort "$D/writer/stand-in.calls" | tr '\n' ' ')" = "--exclude tests/over-a.bats --exclude tests/over-b.bats " ]
  # no bare path line (a comment line that cites the path is fine)
  if grep -qxF "tests/over-a.bats" "$D/writer/.publicignore"; then echo "the script wrote a path line itself"; return 1; fi
  if grep -qxF "tests/over-b.bats" "$D/writer/.publicignore"; then echo "the script wrote a path line itself"; return 1; fi
  has "$D/writer/.publicignore" "# tests/over-a.bats: 70.0 s over the 50 s"
}

@test "E77_S06_T06: the section header is written once, before the first entry" {
  PI="$D/y1.publicignore"
  [ "$(grep -cxF "$HEADER" "$PI")" = "1" ]
  header_line="$(grep -nxF "$HEADER" "$PI" | cut -d: -f1)"
  first_entry="$(grep -n '^# tests/over-' "$PI" | head -1 | cut -d: -f1)"
  [ "$header_line" -lt "$first_entry" ]
}

@test "E77_S06_T06: a second run with y leaves the file byte-identical, with no duplicate header, and says so" {
  [ "$(cat "$D/y2.rc")" = "0" ]
  cmp "$D/y1.publicignore" "$D/y2.publicignore"
  [ "$(grep -cxF "$HEADER" "$D/y2.publicignore")" = "1" ]
  has "$D/y2.out" "no changes"
  lacks "$D/y2.out" "Proposed additions"
}

@test "E77_S06_T06: a file already in .publicignore is neither proposed nor commented again" {
  lacks "$D/n.out" "tests/already.bats"
  [ "$(grep -cF 'tests/already.bats' "$D/y1.publicignore")" = "1" ]
}

@test "E77_S06_T06: a timeout record is proposed as at least the cap, and --no-timeouts leaves it out" {
  has "$D/to-n.out" "tests/hangs.bats  at least 100.0 s"
  has "$D/to-n.out" "Add these 3 files to .publicignore? [y/N]"
  lacks "$D/to-skip.out" "tests/hangs.bats  at least"
  has "$D/to-skip.out" "skipped (timeout, --no-timeouts): tests/hangs.bats"
  has "$D/to-skip.out" "Add these 2 files to .publicignore? [y/N]"
}

@test "E77_S06_T06: a mirror.sh that belongs to another work tree is refused (exit 2) before anything is asked or written" {
  [ "$(cat "$D/foreign.rc")" = "2" ]
  has "$D/foreign.out" "refusing"
  lacks "$D/foreign.out" "[y/N]"
  cmp "$D/foreign.before" "$D/foreign/.publicignore"
  [ ! -e "$OTHER/other-ran" ]
}

@test "E77_S06_T06: the real .publicignore is untouched by every scenario" {
  [ "$(cat "$D/real-pi.before")" = "$(cat "$D/real-pi.after")" ]
}

@test "E77_S06_T06: usage errors exit 2" {
  ROOT="$BASE"
  run bash "$SCRIPT" --root "$BASE" --log "$BASE/logs/test-timings.jsonl" --threshold 0 < /dev/null
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$BASE" --bogus < /dev/null
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$BATS_TEST_TMPDIR/no-such-dir" --log x < /dev/null
  [ "$status" -eq 2 ]
}

@test "E77_S06_T06: an absent timing log exits 6 and writes nothing" {
  run bash "$SCRIPT" --root "$BASE" --log "$BATS_TEST_TMPDIR/none.jsonl" < /dev/null
  [ "$status" -eq 6 ]
  cmp "$D/n.before" "$BASE/.publicignore"
}

@test "E77_S06_T06: --help prints the contract and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  case "$output" in
    *"--no-timeouts"*"--mirror"*) ;;
    *) echo "help incomplete"; return 1 ;;
  esac
}
