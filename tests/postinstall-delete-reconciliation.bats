#!/usr/bin/env bats
#
# Consumer postinstall delete reconciliation (E26_S08_T01).
#
# Why this file exists
# --------------------
# scripts/postinstall.js mirrors skills/ and agents/ into a consumer's .claude/
# and .agents/ additively only, so a release that renames, removes, or excludes
# a skill left the old copies in place forever and both forms kept loading.
# Confirmed live upgrading to @jenga-ai/agent@3.0.0 after E50_S06's twin
# exclusions and E50_S07's j: -> j. rename.
#
# The obvious fix -- flipping lib/mirror.js's reconcileDeletes to true on the
# consumer call site -- is the one thing this must NOT do. That flag diffs the
# destination's current contents against the source tree with no notion of who
# wrote a file, so on a consumer's machine it deletes their own hand-authored
# skills. E27_S01_T01 made additive-only the default for exactly that reason.
# lib/postinstall-manifest.js is the provenance-scoped alternative: only paths a
# manifest THIS package wrote lists, and this run did not rewrite, are eligible.
#
# What is pinned here
# -------------------
# The safety properties, not the happy path. Each of the four invariants has a
# test that goes red if that invariant alone is removed:
#   1. no prior manifest => no delete pass at all
#   2. provenance required => consumer files are never candidates
#   3. bounded + regular-file-only => traversal and symlink entries refused
#   4. fail toward doing nothing => corrupt manifest disables the pass
#
# Fixture construction lives in scripts/verify-postinstall-reconcile.sh rather
# than here, because E26_S08 is crucial_level: gated and its crucial_note
# requires a rehearsal harness runnable on its own, outside the suite. That
# script creates its own mktemp -d and writes/deletes only inside it. It is run
# ONCE in setup_file and its per-check verdicts are asserted individually below,
# so a single regression names the property it broke instead of collapsing the
# whole rehearsal into one opaque failure.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup_file() {
  export RESULTS="${BATS_FILE_TMPDIR}/results.tsv"
  export HARNESS_LOG="${BATS_FILE_TMPDIR}/harness.log"
  : > "$RESULTS"
  RESULTS_FILE="$RESULTS" bash "$REPO_ROOT/scripts/verify-postinstall-reconcile.sh" \
    > "$HARNESS_LOG" 2>&1 || true
}

# Asserts the harness recorded a PASS for the named check. Fails loudly if the
# name is absent entirely -- a renamed check must not silently stop being tested,
# which is the same fail-open class tests/bats-assertion-convention.bats polices.
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
    *) echo "check FAILED in harness: ${name}" >&2; return 1 ;;
  esac
}

@test "harness ran and recorded checks" {
  [ -s "$RESULTS" ]
  run wc -l < "$RESULTS"
  [ "$status" -eq 0 ]
}

@test "harness reports zero failures overall" {
  run grep -c '^FAIL' "$RESULTS"
  [ "$output" = "0" ]
}

# -----------------------------------------------------------------------------
# Invariant 1 -- no prior manifest means no delete pass. This is what stops "we
# don't know what we wrote before" becoming "delete everything we didn't just
# write", which is the exact custom-skill-deletion failure mode the story exists
# to prevent.
# -----------------------------------------------------------------------------

@test "first install runs no delete pass" {
  assert_check "first install reports no delete pass"
  assert_check "first install deletes nothing (zero stale files reported)"
}

@test "files predating any install survive the first install" {
  assert_check "pre-existing consumer file survives first install (.agents)"
  assert_check "pre-existing consumer file survives first install (.claude)"
}

# -----------------------------------------------------------------------------
# Invariant 2 -- provenance. A consumer file was never in a manifest, so it is
# never a deletion candidate regardless of where it sits.
# -----------------------------------------------------------------------------

@test "consumer-authored skills survive an upgrade that deletes" {
  assert_check "consumer custom skill survives upgrade (.agents)"
  assert_check "consumer custom skill survives upgrade (.claude)"
  assert_check "pre-manifest consumer file still survives upgrade (.agents)"
  assert_check "pre-manifest consumer file still survives upgrade (.claude)"
}

# The sharpest case for the files-only manifest + prune-when-empty design: the
# package's file goes, the consumer's file in the SAME directory stays, and the
# directory therefore must not be pruned.
@test "consumer file inside an emptied package directory survives with its directory" {
  assert_check "excluded twin's package file removed (.agents)"
  assert_check "excluded twin's package file removed (.claude)"
  assert_check "consumer note INSIDE the emptied package dir survives (.agents)"
  assert_check "consumer note INSIDE the emptied package dir survives (.claude)"
}

@test "manifest records package paths only, never consumer files" {
  assert_check "consumer file is NOT recorded in the manifest"
  assert_check "manifest records mirrored package paths"
  assert_check "refreshed manifest never records consumer-authored files"
}

# -----------------------------------------------------------------------------
# The actual bug being fixed: stale package files must go, from BOTH roots.
# -----------------------------------------------------------------------------

@test "renamed-away skill is removed from both mirror roots" {
  assert_check "renamed-away skill dir removed from .agents"
  assert_check "renamed-away skill dir removed from .claude"
  assert_check "renamed-to skill installed (.agents)"
  assert_check "renamed-to skill installed (.claude)"
}

@test "manifest is refreshed to the current copy set" {
  assert_check "refreshed manifest no longer lists the removed skill"
  assert_check "refreshed manifest lists the new skill"
}

# Guards against a regression where the manifest omits mirror()'s `skipped`
# paths: a byte-identical file is still package-owned, and dropping it would make
# the next run treat it as stale and delete it.
@test "unchanged common files are neither deleted nor recopied" {
  assert_check "file common to both versions untouched (same inode+mtime)"
  assert_check "changed package file overwritten with v2 content"
}

@test "same-version reinstall short-circuits before any delete pass" {
  assert_check "same-version re-run short-circuits before any delete pass"
  assert_check "consumer custom skill still present after re-run"
  assert_check "package skill still present after re-run"
}

# -----------------------------------------------------------------------------
# Invariant 3 -- a manifest is data on the consumer's disk, so a tampered one
# must not become an out-of-bounds or wrong-type delete. Refusals are selective:
# a hostile entry does not stop legitimate cleanup in the same manifest.
# -----------------------------------------------------------------------------

@test "traversal entry cannot delete outside the mirror root" {
  assert_check "traversal entry cannot delete a file outside the mirror root"
  assert_check "traversal entry explicitly refused"
}

@test "symlink and directory entries are refused, not followed" {
  assert_check "symlink entry refused, not followed or unlinked"
  assert_check "directory entry refused (manifests record files only)"
  assert_check "non-regular-file entries explicitly refused"
}

@test "refusals do not block legitimate cleanup in the same manifest" {
  assert_check "genuinely stale entry still cleaned up alongside refusals"
}

# -----------------------------------------------------------------------------
# Invariant 4 -- every parse/IO failure degrades to additive-only rather than
# guessing at what was previously written.
# -----------------------------------------------------------------------------

@test "corrupt or unknown-version manifest disables the delete pass" {
  assert_check "corrupt manifest disables the delete pass (.agents)"
  assert_check "unknown manifest_version disables the delete pass (.claude)"
  assert_check "unreadable manifest degrades to additive-only"
  assert_check "a fresh valid manifest is rewritten over the corrupt one"
}

# -----------------------------------------------------------------------------
# Invariant 5 -- identity backstop. Found by the tester during E26_S08_T01
# verification, not by the original harness: staleness is decided by a
# case-SENSITIVE string set but unlinked against a possibly case-INSENSITIVE
# filesystem (macOS APFS, Windows NTFS). After skill.md -> SKILL.md the old
# manifest string looks stale while resolving to the file this run just wrote, so
# a string-only diff deleted the new file and the skill vanished outright -- and
# did not self-heal, because the manifest then recorded it as present and the
# version gate blocked a recopy. Comparing dev+ino closes the whole collision
# class (case, Unicode normalisation, hardlinks) rather than special-casing case.
# Verified red without the guard.
# -----------------------------------------------------------------------------

@test "case-only rename does not delete the file the run just wrote" {
  assert_check "case-only rename does not delete the just-written file (.agents)"
  assert_check "case-only rename does not delete the just-written file (.claude)"
}

# -----------------------------------------------------------------------------
# A copySet entry missing from the package is a packaging regression, not a
# licence to delete. mirror() silently skips a missing source, so currentPaths
# under-reports and the delete pass read the entire mirrored subtree as stale --
# converting one bad publish into mass deletion on every consumer that installs
# it. E26_S02_T05 shows postinstall-adjacent packaging regressions do happen here.
# Both the delete pass and the manifest write are now skipped for such a run.
# Verified red without the guard.
# -----------------------------------------------------------------------------

@test "missing copySet entry does not wipe the mirrored subtree" {
  assert_check "missing copySet entry does not wipe the mirrored subtree (.agents)"
  assert_check "missing copySet entry does not wipe the mirrored subtree (.claude)"
  assert_check "packaging regression reported, cleanup skipped"
  assert_check "previous manifest left intact (still describes what is on disk)"
}

# -----------------------------------------------------------------------------
# The guardrail the whole design rests on: if this flag is ever flipped true at
# the consumer call site, every provenance guard above becomes irrelevant,
# because lib/mirror.js would delete by directory diff before any of them run.
# -----------------------------------------------------------------------------

@test "consumer call site keeps reconcileDeletes false" {
  # Match the CODE line (trailing comma), not the phrase -- the file's header
  # comment discusses `reconcileDeletes: false` in prose, so a bare phrase count
  # matches twice and would make this guard assert the wrong thing.
  run grep -c 'reconcileDeletes: *false,' "$REPO_ROOT/scripts/postinstall.js"
  [ "$output" = "1" ]
  run grep -n 'reconcileDeletes: *true' "$REPO_ROOT/scripts/postinstall.js"
  [ "$status" -ne 0 ]
}
