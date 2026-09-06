#!/usr/bin/env bats
#
# Meta-test: the suite's own assertion convention (E50_S07_T08).
#
# Why this file exists
# --------------------
# bats runs each test body under errexit and installs an ERR trap, but `[[` is a
# shell KEYWORD rather than a simple command, so a failing `[[ ... ]]` never
# fires that trap. A `[[ ... ]]` that is not the body's final statement is
# therefore a no-op: it can be false on every run and its test still reports ok.
#
# That is not a hypothetical. E50_S07_T07's tester measured 37 such assertions
# across four files, including the two suites written to PROVE this story's own
# fixes -- E50_S07_T04's Copilot load gate and E50_S07_T02's router prefix
# guard. Both reported green while a share of what they appeared to check was
# never evaluated. Full measurement:
#   project/rapports/problems/E50_S07_T07-inert-bats-assertions-suite-wide.md
#
# E50_S07_T08 repaired all of them. This file is what stops the class coming
# back silently, which is the only way it ever arrives: nothing in a normal bats
# run distinguishes an assertion that passed from one that never executed.
#
# The rule
# --------
# No line under tests/ may BEGIN with `[[`. There is deliberately no exception
# for final-position `[[ ]]`, even though that form does work today (bats uses
# the body's exit status). A final-position assertion is a landmine: it silently
# disarms itself the moment someone appends a line beneath it, with no diff to
# the assertion and no signal in the output. An exception no one can see is
# worse than a rule that costs nothing to follow -- use `[ ... ]`, which is a
# builtin and does fire the trap, or one of the helpers in
# tests/helpers/assertions.bash.
#
# `[[` inside an `if`/`while`/`until` CONDITION is untouched by the rule and is
# perfectly safe: those lines begin with `if`, not `[[`, and a keyword's exit
# status in a condition context is the point rather than an error.
#
# Guarding the guard
# ------------------
# A scanner that silently matches nothing would reproduce the exact defect it is
# meant to police, so the scanner is not trusted on its own say-so. It is
# exercised against purpose-built fixtures in both directions -- it must FLAG a
# known-bad file and must NOT flag a known-good one -- and the underlying bats
# behaviour that motivates the whole rule is itself pinned by running the real
# bats binary against a fixture. If a future bats release makes a failing
# mid-body `[[` abort the test, that last test goes red and tells us this rule
# can be relaxed.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Resolved the same way package.json's `test` script gets bats.
bats_bin() {
  if command -v bats > /dev/null 2>&1; then
    echo "bats"
  else
    echo "npx --no-install bats"
  fi
}

# Prints `path:line:text` for every line that begins with `[[` under $1.
# Kept as a single grep so the rule stays greppable by hand, exactly as written
# here, by anyone auditing this later.
scan_bare_double_bracket() {
  grep -rnE '^[[:space:]]*\[\[' \
    --include='*.bats' --include='*.sh' --include='*.bash' \
    "$1" 2>/dev/null || true
}

# Writes a fixture .bats file whose body contains a line STARTING with `[[`.
#
# The brackets are assembled from variables rather than written literally,
# because a literal `[[` at the start of a line in this file would be found by
# the very scanner under test and turn the real-tree scan below red. The
# convention applies to this file too.
write_bad_fixture() {
  local path="$1" ob="[[" cb="]]"
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/usr/bin/env bats\n\n'
    printf '@test "a failing mid-body keyword assertion is silently ignored by bats" {\n'
    printf '  %s 1 -eq 2 %s\n' "$ob" "$cb"
    printf '  true\n'
    printf '}\n'
  } > "$path"
}

# The same test written the way the convention requires.
write_good_fixture() {
  local path="$1" ob="[[" cb="]]"
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/usr/bin/env bats\n\n'
    printf '@test "a builtin test command does abort the body" {\n'
    printf '  if %s 1 -eq 2 %s; then :; fi\n' "$ob" "$cb"
    printf '  [ 1 -eq 1 ]\n'
    printf '}\n'
  } > "$path"
}

# -----------------------------------------------------------------------------
# The rule itself
# -----------------------------------------------------------------------------

@test "no line under tests/ begins with a bare [[ (the inert-assertion class)" {
  local offenders
  offenders="$(scan_bare_double_bracket "$REPO_ROOT/tests")"

  if [ -n "$offenders" ]; then
    echo "A line beginning with '[[' was found under tests/." >&2
    echo "bats does NOT fail a test on a failing '[[ ... ]]' unless it is the" >&2
    echo "body's final statement -- '[[' is a keyword and never fires the ERR" >&2
    echo "trap. Use '[ ... ]' or a helper from tests/helpers/assertions.bash." >&2
    echo "$offenders" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Guarding the guard: the scanner must actually work, in both directions.
# A scan that matches nothing would pass the test above for the wrong reason.
# -----------------------------------------------------------------------------

@test "the scanner FLAGS a file that violates the convention" {
  write_bad_fixture "$BATS_TEST_TMPDIR/bad/violation.bats"

  local offenders
  offenders="$(scan_bare_double_bracket "$BATS_TEST_TMPDIR/bad")"

  if [ -z "$offenders" ]; then
    echo "The scanner found nothing in a file that definitely violates the rule." >&2
    echo "It is matching nothing, so the real-tree scan above proves nothing." >&2
    cat "$BATS_TEST_TMPDIR/bad/violation.bats" >&2
    return 1
  fi
}

@test "the scanner does NOT flag [[ used inside an if condition" {
  write_good_fixture "$BATS_TEST_TMPDIR/good/compliant.bats"

  local offenders
  offenders="$(scan_bare_double_bracket "$BATS_TEST_TMPDIR/good")"

  if [ -n "$offenders" ]; then
    echo "The scanner flagged a compliant file. '[[' in an if/while condition is" >&2
    echo "safe -- those lines begin with 'if', not '[['. Over-matching would push" >&2
    echo "authors to work around the rule rather than follow it." >&2
    echo "$offenders" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Pin the bats behaviour the rule exists because of, against the real binary.
# If bats ever changes this, this test goes red and the rule can be revisited.
# -----------------------------------------------------------------------------

@test "bats really does report ok for a failing non-final [[ ]] (the reason for the rule)" {
  write_bad_fixture "$BATS_TEST_TMPDIR/mech/inert.bats"

  run $(bats_bin) "$BATS_TEST_TMPDIR/mech/inert.bats"

  # The fixture asserts `1 -eq 2` and then keeps going. If bats were catching
  # it, this run would be non-zero and the whole convention would be
  # unnecessary. It is not: bats reports success.
  if [ "$status" -ne 0 ]; then
    echo "bats FAILED a test containing a false non-final '[[ ... ]]'." >&2
    echo "That is the opposite of the behaviour this convention compensates for." >&2
    echo "If this bats version genuinely aborts on a failing mid-body keyword," >&2
    echo "the ban in this file can be relaxed -- but verify before relaxing it." >&2
    echo "--- bats output ---" >&2
    echo "$output" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Every suite that uses the shared helpers must actually load them, or the
# helper calls resolve to nothing and the tests error out per-file.
# -----------------------------------------------------------------------------

@test "every .bats file calling a shared helper loads tests/helpers/assertions" {
  local helper_re missing="" f
  helper_re="$(sed -n 's/^\(assert_[a-z_]*\)() {$/\1/p' \
    "$REPO_ROOT/tests/helpers/assertions.bash" | paste -sd'|' -)"

  if [ -z "$helper_re" ]; then
    echo "No assert_* helpers found in tests/helpers/assertions.bash." >&2
    return 1
  fi

  for f in "$REPO_ROOT"/tests/*.bats; do
    if grep -qE "^[[:space:]]*($helper_re)[[:space:]]" "$f"; then
      if ! grep -q '^load helpers/assertions' "$f"; then
        missing="$missing $(basename "$f")"
      fi
    fi
  done

  if [ -n "$missing" ]; then
    echo "These files call a shared assertion helper without loading it:$missing" >&2
    return 1
  fi
}
