#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E99_S01_T06: the ratchet on the number of skill scripts the smoke test cannot verify.
#
# Every script under skills/<skill>/scripts/ must either handle --help/-h in its code (comments do not count) or declare
# its safe invocation in its first 40 lines with `# smoke-invoke: <args>` (or `# smoke-invoke: none <reason>`), unless it
# is exempt: a skill that never ships (read from .publicignore), a tests/ or test/ directory, or a sourced lib/ file.
# A script with neither is `undeclared`, and this file fails on it.
#
# The classification is the smoke test's own: `smoke-test-skills.sh --classify-only` runs the same function the execution
# phase runs (classify_script), prints one line per script and executes none. This file never runs the execution phase over
# the real catalog (about 74 s); the whole file is bounded to a few seconds. It tests the private smoke test, so it follows
# its subject (.publicignore, E99_S01_T18 block).
#
# THE PIN. DECLARED_NONE_PIN is the number of scripts declared `# smoke-invoke: none <reason>` in the real tree, read from a
# fresh `--classify-only` run. Declaring a script `none` is a way to skip verification, so the number may not grow without
# someone noticing; and when it drops (a script gets a real invocation) the pin must be lowered in the same change.

# shellcheck disable=SC2016
# SC2016: the fixture scripts are written with single quotes on purpose; they hold literal $ and backticks.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HARNESS="$REPO_ROOT/skills/j-smoke-test/scripts/smoke-test-skills.sh"
BASH_BIN="$(command -v bash)"

# Pinned from a fresh `bash skills/j-smoke-test/scripts/smoke-test-skills.sh --classify-only` run (2026-11-22, E99_S01_T06).
DECLARED_NONE_PIN=22

# fixture_script <root> <skill> <relative path under scripts/> : the body is read from stdin.
# The directory must exist (fixture_dirs); the body is written with builtins only, since a process start is the slow part here.
fixture_script() {
  local body
  IFS= read -r -d '' body || true
  printf '%s' "$body" > "$1/skills/$2/scripts/$3"
}

# fixture_root <dir>: an empty synthetic package that can run the harness.
fixture_root() {
  mkdir -p "$1/skills" "$1/scripts"
  cp "$REPO_ROOT/scripts/never-public-refs.sh" "$1/scripts/never-public-refs.sh"
}

# The classification is computed ONCE per package in setup_file (a process start costs tens of milliseconds on a loaded
# machine, and every run pays the harness's own start-up), and the cases below read the saved output.
setup_file() {
  local late i f="$BATS_FILE_TMPDIR/fix" n="$BATS_FILE_TMPDIR/fixnone" marker="$BATS_FILE_TMPDIR/marker"
  fixture_root "$f"
  fixture_root "$n"
  mkdir -p "$f/skills/"{j-undecl,j-help,j-helph,j-decl,j-declbare,j-none,j-late,j-comment,j-fixblocked,j-mark}/scripts \
    "$f/skills/j-lib/scripts/lib" "$f/skills/j-lib/scripts/tests" "$n/skills/j-fixblocked/scripts"
  printf '%s\n' '# a comment' 'skills/j-fixblocked/' > "$f/.publicignore"   # the "no .publicignore" package has none

  fixture_script "$f" j-undecl run.sh <<'EOF'
#!/usr/bin/env bash
echo "does something"
EOF
  fixture_script "$f" j-help run.sh <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --help|-h) echo usage; exit 0 ;; esac
EOF
  fixture_script "$f" j-helph run.sh <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-h" ] && { echo usage; exit 0; }
EOF
  fixture_script "$f" j-decl run.sh <<'EOF'
#!/usr/bin/env bash
# smoke-invoke: show --quiet
echo "does something"
EOF
  fixture_script "$f" j-declbare run.sh <<'EOF'
#!/usr/bin/env bash
# smoke-invoke:
echo "does something"
EOF
  fixture_script "$f" j-none run.sh <<'EOF'
#!/usr/bin/env bash
# smoke-invoke: none writes into the working directory
echo "does something"
EOF
  late='#!/usr/bin/env bash
'
  for ((i = 0; i < 45; i++)); do late="$late# filler
"; done
  late="$late# smoke-invoke: none too late
"
  fixture_script "$f" j-late run.sh <<<"${late%$'\n'}"
  fixture_script "$f" j-comment run.sh <<'EOF'
#!/usr/bin/env bash
# Usage: run.sh [--help | -h]   (this comment is documentation, not a handler)
  # also --help here
echo "does something"
EOF
  fixture_script "$f" j-fixblocked run.sh <<'EOF'
#!/usr/bin/env bash
echo "no handler, but never shipped"
EOF
  fixture_script "$f" j-lib lib/helper.sh <<'EOF'
#!/usr/bin/env bash
echo "sourced, no handler"
EOF
  fixture_script "$f" j-lib tests/check.sh <<'EOF'
#!/usr/bin/env bash
echo "test support, no handler"
EOF
  # Scripts that write a marker file when they are EXECUTED, one of each class the harness might be tempted to run.
  fixture_script "$f" j-mark handler.sh <<EOF
#!/usr/bin/env bash
case "\${1:-}" in --help) ;; esac
touch "$marker"
EOF
  fixture_script "$f" j-mark declared.sh <<EOF
#!/usr/bin/env bash
# smoke-invoke: run
touch "$marker"
EOF
  fixture_script "$f" j-mark bare.sh <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
  # No .publicignore: nothing is exempt as never shipped.
  fixture_script "$n" j-fixblocked run.sh <<'EOF'
#!/usr/bin/env bash
echo "no handler"
EOF

  # --no-exec and --critical-only are passed on purpose: --classify-only wins over both. No fixture skill has a SKILL.md,
  # which would be a critical structural finding for each, so an empty stdout besides the class lines shows nothing else ran.
  "$BASH_BIN" "$HARNESS" --root "$f" --no-exec --critical-only --classify-only > "$f.out" 2> "$f.err"; echo "$?" > "$f.rc"
  "$BASH_BIN" "$HARNESS" --root "$n" --classify-only > "$n.out" 2> "$n.err"; echo "$?" > "$n.rc"
  # One real-tree classification for every real-tree case below.
  "$BASH_BIN" "$HARNESS" --classify-only > "$BATS_FILE_TMPDIR/real.out" 2> "$BATS_FILE_TMPDIR/real.err"
  echo "$?" > "$BATS_FILE_TMPDIR/real.rc"
}

# class_of <file> <skills/path>: the class column of that script's line, empty when it is not listed.
class_of() {
  awk -F'\t' -v p="$2" '$2 == p { print $1 }' "$1"
}

# count_of <class> <file>: how many lines of the file have that class.
count_of() {
  awk -F'\t' -v c="$1" '$1 == c { n++ } END { print n + 0 }' "$2"
}

# ratchet <file> [<skills/path>]: the assertion the real tree must meet. Fails, printing the offenders, when any script
# (or just the named one) is `undeclared`.
ratchet() {
  local n
  n="$(awk -F'\t' -v p="${2:-}" '$1 == "undeclared" && (p == "" || $2 == p) { n++ } END { print n + 0 }' "$1")"
  if [ "$n" -ne 0 ]; then
    echo "ratchet: $n skill script(s) have neither a --help/-h handler nor a '# smoke-invoke:' header:" >&2
    awk -F'\t' -v p="${2:-}" '$1 == "undeclared" && (p == "" || $2 == p) { print "  " $2 }' "$1" >&2
    return 1
  fi
}

# --- fixture cases (a) to (g) -------------------------------------------------------------------------------------

@test "ratchet (a, d2, e): a script with neither a --help handler nor a smoke-invoke header is undeclared and fails the ratchet" {
  F="$BATS_FILE_TMPDIR/fix.out"
  [ "$(cat "$BATS_FILE_TMPDIR/fix.rc")" -eq 0 ]
  # (a) nothing at all
  [ "$(class_of "$F" skills/j-undecl/scripts/run.sh)" = "undeclared" ]
  run ratchet "$F" skills/j-undecl/scripts/run.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/j-undecl/scripts/run.sh"* ]]
  # (d2) a smoke-invoke header after line 40 does not count
  [ "$(class_of "$F" skills/j-late/scripts/run.sh)" = "undeclared" ]
  # (e) a --help mentioned only in a comment is not a handler
  [ "$(class_of "$F" skills/j-comment/scripts/run.sh)" = "undeclared" ]
  run ratchet "$F" skills/j-comment/scripts/run.sh
  [ "$status" -eq 1 ]
}

@test "ratchet (b, c, d): a --help or -h handler, a smoke-invoke header (with or without arguments) and 'none <reason>' all pass" {
  F="$BATS_FILE_TMPDIR/fix.out"
  # (b) --help, and -h alone
  [ "$(class_of "$F" skills/j-help/scripts/run.sh)" = "handles-help" ]
  [ "$(class_of "$F" skills/j-helph/scripts/run.sh)" = "handles-help" ]
  # (c) declared, with the arguments shown, and a bare header
  [ "$(class_of "$F" skills/j-decl/scripts/run.sh)" = "declared" ]
  [ "$(class_of "$F" skills/j-declbare/scripts/run.sh)" = "declared" ]
  grep -qF "$(printf 'skills/j-decl/scripts/run.sh\tshow --quiet')" "$F"
  # (d) none <reason> is declared-none, never undeclared
  [ "$(class_of "$F" skills/j-none/scripts/run.sh)" = "declared-none" ]
  grep -qF "writes into the working directory" "$F"
  for s in j-help j-helph j-decl j-declbare j-none; do ratchet "$F" "skills/$s/scripts/run.sh"; done
}

@test "ratchet (f, f2): never-shipped (fixture .publicignore), lib/ and tests/ scripts are exempt; with no .publicignore nothing is never shipped" {
  F="$BATS_FILE_TMPDIR/fix.out"; N="$BATS_FILE_TMPDIR/fixnone.out"
  [ "$(class_of "$F" skills/j-fixblocked/scripts/run.sh)" = "exempt" ]
  [ "$(class_of "$F" skills/j-lib/scripts/lib/helper.sh)" = "exempt" ]
  [ "$(class_of "$F" skills/j-lib/scripts/tests/check.sh)" = "exempt" ]
  grep -qF "never shipped (blocked by .publicignore)" "$F"
  grep -qF "sourced library, not an entry point" "$F"
  grep -qF "test support, not an entry point" "$F"
  [ "$(cat "$BATS_FILE_TMPDIR/fixnone.rc")" -eq 0 ]
  [ "$(class_of "$N" skills/j-fixblocked/scripts/run.sh)" = "undeclared" ]
  [ "$(count_of exempt "$N")" -eq 0 ]
  ! grep -qF "never shipped" "$N" "$BATS_FILE_TMPDIR/fixnone.err"
}

@test "ratchet (g): --classify-only runs no script, skips the structural checks, and wins over --no-exec and --critical-only" {
  F="$BATS_FILE_TMPDIR/fix"
  [ "$(class_of "$F.out" skills/j-mark/scripts/handler.sh)" = "handles-help" ]
  [ "$(class_of "$F.out" skills/j-mark/scripts/declared.sh)" = "declared" ]
  [ "$(class_of "$F.out" skills/j-mark/scripts/bare.sh)" = "undeclared" ]
  [ ! -e "$BATS_FILE_TMPDIR/marker" ]
  # No fixture skill has a SKILL.md, which the structural checks would report as a critical finding each (--critical-only was
  # passed, so they would be on stdout). stdout holds only <class> TAB <path> TAB <detail> lines.
  ! grep -q '^{' "$F.out"
  [ "$(awk -F'\t' 'NF != 3 { n++ } END { print n + 0 }' "$F.out")" -eq 0 ]
  # The counts, and no sign of the execution phase or of the structural summary.
  grep -qE "^classify-only: 14 scripts: exempt=3 handles-help=3 declared=3 declared-none=1 undeclared=4$" "$F.err"
  ! grep -q "Execution check\|Skill Smoke Test" "$F.err"
}

@test "ratchet (g): --help documents --classify-only" {
  run --separate-stderr "$BASH_BIN" "$HARNESS" --help
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"--classify-only"* ]]
}

# --- the real tree (h) --------------------------------------------------------------------------------------------

@test "ratchet (h): --classify-only over the real tree exits 0, lists every script, and reports ZERO undeclared (the ratchet)" {
  [ "$(cat "$BATS_FILE_TMPDIR/real.rc")" -eq 0 ]
  total="$(find "$REPO_ROOT/skills" -type f -name '*.sh' -path '*/scripts/*' | wc -l)"
  [ "$(wc -l < "$BATS_FILE_TMPDIR/real.out")" -eq "$total" ]
  [ "$total" -gt 100 ]
  run ratchet "$BATS_FILE_TMPDIR/real.out"
  if [ "$status" -ne 0 ]; then
    echo "A new skill script needs a --help/-h handler, or '# smoke-invoke: <args>' / '# smoke-invoke: none <reason>' in its first 40 lines (project/documentation/skill-authoring.md)." >&2
    printf '%s\n' "$output" >&2
  fi
  [ "$status" -eq 0 ]
  # The summary on stderr agrees with the class lines.
  want="$(awk -F'\t' '{ c[$1]++ } END { printf "exempt=%d handles-help=%d declared=%d declared-none=%d undeclared=%d", c["exempt"], c["handles-help"], c["declared"], c["declared-none"], c["undeclared"] }' "$BATS_FILE_TMPDIR/real.out")"
  [[ "$(cat "$BATS_FILE_TMPDIR/real.err")" == *"$want" ]]
}

@test "ratchet (h): the number of declared-none scripts equals the pin, and neither grows nor silently drops" {
  n="$(count_of declared-none "$BATS_FILE_TMPDIR/real.out")"
  if [ "$n" -gt "$DECLARED_NONE_PIN" ]; then
    echo "declared-none rose from $DECLARED_NONE_PIN to $n: a script was newly declared '# smoke-invoke: none <reason>'. Give it a --help handler or a real read-only invocation instead; raise DECLARED_NONE_PIN in tests/smoke-test-ratchet.bats only for a reason a reviewer accepts." >&2
    awk -F'\t' '$1 == "declared-none" { print "  " $2 "  " $3 }' "$BATS_FILE_TMPDIR/real.out" >&2
  fi
  if [ "$n" -lt "$DECLARED_NONE_PIN" ]; then
    echo "declared-none dropped from $DECLARED_NONE_PIN to $n: lower DECLARED_NONE_PIN to $n in tests/smoke-test-ratchet.bats in the same change." >&2
  fi
  [ "$n" -eq "$DECLARED_NONE_PIN" ]
}

@test "ratchet (h): the exempt classes come from the derivation (.publicignore, tests/, lib/), not from a list in this test" {
  # Every exempt line carries one of the three reasons the smoke test itself produces; the never-shipped set is whatever the
  # root .publicignore blocks, so it is checked against that file rather than against names written here. And the converse:
  # no script of a blocked skill is classified as anything but exempt.
  run awk -F'\t' '
    FNR == NR { if ($0 ~ /^skills\/j-[^\/]+\/$/) blocked[$0] = 1; next }
    { skill = $2; sub(/^skills\//, "", skill); sub(/\/.*$/, "", skill); dir = "skills/" skill "/" }
    $1 == "exempt" {
      n++
      if ($3 == "never shipped (blocked by .publicignore)") { if (!(dir in blocked)) print $2 ": exempt as never shipped, but " dir " is not blocked in .publicignore" }
      else if ($3 == "test support, not an entry point") { if ($2 !~ /\/tests?\//) print $2 ": not a test directory" }
      else if ($3 == "sourced library, not an entry point") { if ($2 !~ /\/lib\//) print $2 ": not a lib/ file" }
      else print $2 ": unexpected exempt reason: " $3
      next
    }
    dir in blocked { print $2 ": belongs to a blocked skill but is classified " $1 }
    END { if (n == 0) print "no exempt script at all: the exempt classes were not derived" }
  ' "$REPO_ROOT/.publicignore" "$BATS_FILE_TMPDIR/real.out"
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}
