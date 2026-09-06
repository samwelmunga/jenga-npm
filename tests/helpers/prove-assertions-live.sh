#!/usr/bin/env bash
#
# Liveness prover for the bats assertion suite (E50_S07_T08).
#
# The problem this exists to solve
# -------------------------------
# Repairing an inert assertion and watching it go green proves nothing. The
# inert ones were green too -- that was the entire defect. "It passes" and "its
# verdict reaches the test result" are different claims, and only the second one
# is what a repair is supposed to establish.
#
# So this script proves the second claim directly, per call site. For every
# assert_* call under tests/, it re-runs the enclosing test with
#
#   JENGA_ASSERT_MUTATE="<file>:<line>"
#
# which makes tests/helpers/assertions.bash invert that one call site's verdict
# (see _jenga_assert_verdict). A live assertion MUST turn its test red under
# that inversion. One that stays green is still inert, and is reported as
# INERT with a nonzero exit.
#
# This is a real red-then-green demonstration rather than a claimed one: the red
# state is produced mechanically, per assertion, from the shipping test code --
# no hand-edited scratch copies that might not match what was committed.
#
# Usage (invoked via `bash`, matching tests/helpers/mirror-orphaned-twin-rewrite.sh,
# which the suite also runs as `bash "$HARNESS" ...` rather than relying on a
# mode bit):
#   bash tests/helpers/prove-assertions-live.sh [file.bats ...]  (default: tests/*.bats)
#
# This is a developer/verification tool, not part of `npm test`. The convention
# it backs is enforced on every run by tests/bats-assertion-convention.bats;
# this script is what proves the assertions themselves are wired, which is a
# question a green suite cannot answer.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

BATS=(npx --no-install bats)
if command -v bats > /dev/null 2>&1; then
  BATS=(bats)
fi

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  files=(tests/*.bats)
fi

live=0
inert=0
skipped=0

# Only the helpers defined in tests/helpers/assertions.bash route their verdict
# through _jenga_assert_verdict, so only those respond to JENGA_ASSERT_MUTATE.
# The suites also define their own domain wrappers -- assert_full_scaffold,
# assert_fully_staged, assert_tree_loads -- which are sound for a different
# reason: they are shell FUNCTIONS, so a `return 1` from one is a simple command
# and does abort the test. They are deliberately not mutable and are excluded
# here rather than being reported as inert, which is what a blanket `assert_*`
# match does. (Their own internal assertions are `[ ... ]` builtins and calls to
# the mutable helpers, and those internal call sites are proved on their own.)
HELPER_NAMES="$(
  sed -n 's/^\(assert_[a-z_]*\)() {$/\1/p' tests/helpers/assertions.bash | paste -sd'|' -
)"
if [ -z "$HELPER_NAMES" ]; then
  echo "prover: found no assert_* helpers in tests/helpers/assertions.bash" >&2
  exit 2
fi

# Emits "<line>\t<enclosing @test name>" for every mutable helper call site.
# Call sites in plain top-level functions are reported with an empty name and
# driven by running the whole file.
sites_in() {
  awk -v names="$HELPER_NAMES" '
    BEGIN { pattern = "^[ \t]*(" names ")[ \t]" }
    /^@test / {
      name = $0
      sub(/^@test[ \t]+"/, "", name)
      sub(/"[ \t]*\{[ \t]*$/, "", name)
      in_test = 1
      next
    }
    /^\}/ { in_test = 0; next }
    $0 ~ pattern {
      printf "%d\t%s\n", NR, (in_test ? name : "")
    }
  ' "$1"
}

# bats -f takes an extended regex; the test names carry (, ), ., ?, / and em dashes.
escape_ere() {
  printf '%s' "$1" | sed -e 's/[][\.^$*+?(){}|\\]/\\&/g'
}

for f in "${files[@]}"; do
  base="$(basename "$f")"
  case "$base" in
    bats-assertion-convention.bats)
      # The meta-test asserts over the suite's source text rather than over
      # behaviour it can mutate; it is proved by its own fixture-based cases.
      printf '\n== %s (skipped: meta-test, self-proving via fixtures)\n' "$f"
      continue
      ;;
  esac

  printf '\n== %s\n' "$f"
  while IFS=$'\t' read -r line name; do
    [ -n "$line" ] || continue

    if [ -n "$name" ]; then
      out="$(JENGA_ASSERT_MUTATE="$base:$line" "${BATS[@]}" -f "^$(escape_ere "$name")$" "$f" 2>&1)"
    else
      out="$(JENGA_ASSERT_MUTATE="$base:$line" "${BATS[@]}" "$f" 2>&1)"
    fi

    if printf '%s' "$out" | grep -q '^ok .* # skip'; then
      printf '  SKIP  %s:%-4s (test skipped in this environment)\n' "$base" "$line"
      skipped=$((skipped + 1))
      continue
    fi

    if printf '%s' "$out" | grep -q '^not ok'; then
      printf '  LIVE  %s:%-4s\n' "$base" "$line"
      live=$((live + 1))
    else
      printf '  INERT %s:%-4s <-- verdict does not reach the test result\n' "$base" "$line"
      printf '%s\n' "$out" | sed 's/^/          /'
      inert=$((inert + 1))
    fi
  done < <(sites_in "$f")
done

printf '\n----------------------------------------\n'
printf 'live: %d   inert: %d   skipped: %d\n' "$live" "$inert" "$skipped"

if [ "$inert" -gt 0 ]; then
  printf 'FAIL: %d assertion(s) do not affect their test result.\n' "$inert"
  exit 1
fi
printf 'OK: every proved assertion turns its test red when its verdict is inverted.\n'
exit 0
