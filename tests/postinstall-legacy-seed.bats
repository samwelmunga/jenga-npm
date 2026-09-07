#!/usr/bin/env bats
#
# Legacy-path seeding for the first manifest a consumer ever gets (E26_S08_T03).
#
# Why this file exists
# ---------------------
# E26_S08_T01's manifest-based delete reconciliation is purely forward-looking: a
# consumer already installed BEFORE any manifest existed takes the `no-prior-manifest`
# branch on their first run of a fixed version, and the manifest that run writes records
# only what THAT run mirrored. Pre-existing orphans (a retired j:-form skill, an excluded
# j-<name> twin) were never in it, so they can never become deletion candidates on any
# FUTURE upgrade either — confirmed empirically against a throwaway fixture in E26_S08's
# own story file (a planted orphan survived two upgrades, the second with an active
# delete pass, appearing 0 times in either manifest).
#
# This task closes that gap by seeding the FIRST manifest with a static list of paths
# known to have shipped in some real prior published version
# (scripts/generate-legacy-shipped-paths.js -> lib/legacy-shipped-paths.json),
# intersected with what is ACTUALLY on disk, then reconciling in that same run. Provenance
# stays the load-bearing guarantee: a path never published is never in the legacy list, so
# it can never be seeded, regardless of where it sits — a consumer's hand-authored file
# was never in any published version and stays untouchable exactly as before.
#
# What is pinned here
# --------------------
#   1. Pre-manifest orphan cleanup on the very first run (adopt-then-reconcile) — the
#      actual fix — while a consumer-authored sibling and its directory survive.
#   2. A genuine first-ever install stays purely additive regardless of what the legacy
#      list contains (nothing on disk to intersect with).
#   3. A legacy-listed path still currently shipped is never touched (not stale).
#   4. A legacy-listed path absent from disk is never phantom-seeded.
#   5. Boundary/type safety (invariants 3/4/5) holds over SEEDED candidates too —
#      traversal and symlink entries in the legacy list are refused, not exploited.
#   6. Regression: a consumer with a real prior manifest reconciles via the normal T01
#      path, unaffected by seeding.
#
# Fixture construction lives in scripts/verify-legacy-seed-reconcile.sh (kept separate
# from scripts/verify-postinstall-reconcile.sh so T01's already-Passed harness is
# untouched), run ONCE in setup_file with its per-check verdicts asserted individually
# below — same convention as tests/postinstall-delete-reconciliation.bats.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup_file() {
  export RESULTS="${BATS_FILE_TMPDIR}/results.tsv"
  export HARNESS_LOG="${BATS_FILE_TMPDIR}/harness.log"
  : > "$RESULTS"
  RESULTS_FILE="$RESULTS" bash "$REPO_ROOT/scripts/verify-legacy-seed-reconcile.sh" \
    > "$HARNESS_LOG" 2>&1 || true
}

# Asserts the harness recorded a PASS for the named check. Fails loudly if the name is
# absent entirely — a renamed check must not silently stop being tested (same fail-open
# class tests/bats-assertion-convention.bats polices).
assert_check() {
  local name="$1" line
  line="$(grep -F "	${name}" "$RESULTS" | head -1)"
  if [ -z "$line" ]; then
    echo "no such check recorded by the harness: '${name}'" >&2
    echo "--- recorded checks ---" >&2
    cut -f2 "$RESULTS" >&2
    return 1
  fi
  case "$line" in
    PASS*) return 0 ;;
    *) echo "--- harness log ---" >&2; cat "$HARNESS_LOG" >&2; return 1 ;;
  esac
}

@test "harness ran and recorded checks" {
  [ -s "$RESULTS" ]
}

@test "harness reports zero failures overall" {
  run grep -c '^FAIL' "$RESULTS"
  [ "$output" = "0" ]
}

@test "pre-manifest orphan removed on first run (.agents)" {
  assert_check "pre-manifest orphan removed on first run (.agents)"
}

@test "pre-manifest orphan removed on first run (.claude)" {
  assert_check "pre-manifest orphan removed on first run (.claude)"
}

@test "consumer-authored sibling survives the pre-manifest cleanup (.agents)" {
  assert_check "consumer-authored sibling survives (.agents)"
}

@test "consumer-authored sibling survives the pre-manifest cleanup (.claude)" {
  assert_check "consumer-authored sibling survives (.claude)"
}

@test "directory survives because it still holds a consumer file" {
  assert_check "directory survives because it still holds a consumer file (.agents)"
}

@test "install log attributes the cleanup to legacy-path seeding" {
  assert_check "install log attributes the cleanup to legacy-path seeding"
}

@test "currently-shipped skill and agent files are untouched by seeding" {
  assert_check "currently-shipped skill untouched"
  assert_check "currently-shipped agent file untouched"
}

@test "fresh manifest describes only what is actually on disk post-cleanup" {
  assert_check "fresh manifest describes only what is actually on disk post-cleanup"
}

@test "genuine first-ever install deletes nothing despite a non-empty legacy path list" {
  assert_check "first-ever install deletes nothing despite a non-empty legacy path list"
  assert_check "first-ever install reports plain additive-only, not a seeded outcome"
  assert_check "first-ever install still copies current package files"
}

@test "a legacy-listed path that is still shipped survives (not stale)" {
  assert_check "a legacy-listed path that is STILL shipped survives untouched (not stale)"
}

@test "a legacy path absent from disk is never phantom-seeded" {
  assert_check "a legacy path never present on disk produces no phantom entries"
}

@test "traversal entry in the legacy list cannot escape the mirror root" {
  assert_check "traversal entry in the legacy list cannot delete outside the mirror root"
}

@test "symlink entry in the legacy list is refused, not followed" {
  assert_check "symlink entry in the legacy list is refused, not followed or unlinked"
}

@test "regression: a real prior manifest reconciles normally, unaffected by seeding" {
  assert_check "first run for consumer-f is a normal, unseeded additive install"
  assert_check "v1 skill mirrored before the upgrade that removes it"
  assert_check "genuinely stale entry cleaned up via the REAL manifest-backed path"
  assert_check "the real manifest-backed delete pass ran and reported a removal"
  assert_check "seeding branch never fires when a real prior manifest is present"
}
