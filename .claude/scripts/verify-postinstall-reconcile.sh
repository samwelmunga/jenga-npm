#!/usr/bin/env bash
#
# verify-postinstall-reconcile.sh — fixture rehearsal for E26_S08_T01
#
# Rehearses the manifest-based delete reconciliation in scripts/postinstall.js
# against a THROWAWAY fixture consumer project, as required by E26_S08's
# `crucial_level: gated` note ("must be rehearsed against a throwaway fixture
# consumer directory before being considered done, not just unit-reasoned about").
#
# SAFETY: this script creates its own fixture root via `mktemp -d` and writes and
# deletes ONLY inside it. It takes no path argument and will never operate on an
# existing directory, so it cannot touch this repo or a real consumer project.
# Set KEEP_FIXTURE=1 to leave the fixture on disk for inspection.
#
# Scenarios covered
#   A. First install with no prior manifest  -> additive only, pre-existing consumer
#      files survive, NO delete pass runs.
#   B. Upgrade across a release that renames / removes / excludes skills -> stale
#      package files removed from both mirror roots, consumer-authored files survive
#      (including one planted INSIDE a package directory that is otherwise emptied),
#      and files common to both versions are left byte- and mtime-identical.
#
# Usage:  bash scripts/verify-postinstall-reconcile.sh
# Exit:   0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/jenga-postinstall-fixture.XXXXXX")"

PASS=0
FAIL=0

# When RESULTS_FILE is set, every verdict is also appended in a machine-readable
# `PASS<TAB><name>` / `FAIL<TAB><name>` form, so tests/postinstall-delete-reconciliation.bats
# can assert on individual named checks instead of on one opaque exit status.
record() { if [ -n "${RESULTS_FILE:-}" ]; then printf '%s\t%s\n' "$1" "$2" >> "$RESULTS_FILE"; fi; }

pass() { PASS=$((PASS + 1)); record PASS "$1"; printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); record FAIL "$1"; printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

exists()     { [ -e "$1" ]; }
assert_file()    { if [ -f "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi; }
assert_absent()  { if [ ! -e "$1" ]; then pass "$2"; else fail "$2 (still present: $1)"; fi; }
assert_grep()    { if grep -q "$1" "$2" 2>/dev/null; then pass "$3"; else fail "$3"; fi; }
assert_nogrep()  { if grep -q "$1" "$2" 2>/dev/null; then fail "$3"; else pass "$3"; fi; }
# ERE variant — needed where the pattern is a real regex rather than a literal.
assert_nogrep_re() { if grep -qE "$1" "$2" 2>/dev/null; then fail "$3"; else pass "$3"; fi; }

cleanup() {
  if [ "${KEEP_FIXTURE:-0}" = "1" ]; then
    printf '\n  Fixture retained at: %s\n' "$FIXTURE"
  else
    # Confined to the mktemp -d created by this script itself.
    rm -rf "$FIXTURE"
  fi
}
trap cleanup EXIT

# ── build a fake package version ─────────────────────────────────────────────
# Copies the real lib/, scripts/ and templates/ from this repo (so the code under
# test is the real code), then lays down a small synthetic skills/ + agents/ tree.
make_pkg() {
  local dir="$1" version="$2"
  mkdir -p "$dir"
  cp -R "$REPO_ROOT/lib"       "$dir/lib"
  cp -R "$REPO_ROOT/scripts"   "$dir/scripts"
  cp -R "$REPO_ROOT/templates" "$dir/templates" 2>/dev/null || true
  cat > "$dir/package.json" <<JSON
{ "name": "@jenga-ai/agent", "version": "$version", "type": "module" }
JSON
  mkdir -p "$dir/skills" "$dir/agents"
}

add_skill() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir/skills/$name"
  printf '%s\n' "$body" > "$dir/skills/$name/SKILL.md"
}

run_install() {
  local pkg="$1" consumer="$2" log="$3"
  ( cd "$pkg" && INIT_CWD="$consumer" node scripts/postinstall.js ) > "$log" 2>&1
}

echo
echo "══ Jenga postinstall delete-reconciliation rehearsal ══"
echo "  fixture: $FIXTURE"

# ── package v1.0.0 ───────────────────────────────────────────────────────────
PKG1="$FIXTURE/pkg-v1"
make_pkg "$PKG1" "1.0.0"
add_skill "$PKG1" "do"           "# do — stable across both versions"
add_skill "$PKG1" "renamed-old"  "# renamed-old — becomes renamed-new in v2"
add_skill "$PKG1" "j-legacy-twin" "# j-legacy-twin — excluded in v2 (E50_S06 style)"
printf '# developer agent v1\n' > "$PKG1/agents/developer.md"

# ── package v2.0.0 ───────────────────────────────────────────────────────────
PKG2="$FIXTURE/pkg-v2"
make_pkg "$PKG2" "2.0.0"
add_skill "$PKG2" "do"           "# do — stable across both versions"   # byte-identical
add_skill "$PKG2" "renamed-new"  "# renamed-new — replaces renamed-old"
# j-legacy-twin intentionally absent (excluded), renamed-old intentionally absent
printf '# developer agent v2 (changed)\n' > "$PKG2/agents/developer.md"

CONSUMER="$FIXTURE/consumer"
mkdir -p "$CONSUMER"

# ═══ Scenario A — first install, no prior manifest ═══════════════════════════
echo
echo "── Scenario A: first install (no prior manifest) ──"

# Plant a consumer file BEFORE the very first install. A first install must never
# delete it, because there is no manifest telling us what we wrote before.
mkdir -p "$CONSUMER/.agents/skills/preexisting" "$CONSUMER/.claude/skills/preexisting"
printf '# consumer file that predates any jenga install\n' > "$CONSUMER/.agents/skills/preexisting/JUNK.md"
printf '# consumer file that predates any jenga install\n' > "$CONSUMER/.claude/skills/preexisting/JUNK.md"

run_install "$PKG1" "$CONSUMER" "$FIXTURE/install-v1.log"

assert_grep "no previous install manifest" "$FIXTURE/install-v1.log" \
  "first install reports no delete pass"
assert_nogrep_re "[1-9][0-9]* stale file" "$FIXTURE/install-v1.log" \
  "first install deletes nothing (zero stale files reported)"
assert_file "$CONSUMER/.agents/skills/preexisting/JUNK.md" \
  "pre-existing consumer file survives first install (.agents)"
assert_file "$CONSUMER/.claude/skills/preexisting/JUNK.md" \
  "pre-existing consumer file survives first install (.claude)"
assert_file "$CONSUMER/.agents/skills/renamed-old/SKILL.md" \
  "v1 skill mirrored to .agents"
assert_file "$CONSUMER/.claude/skills/renamed-old/SKILL.md" \
  "v1 skill mirrored to .claude"
assert_file "$CONSUMER/.agents/.jenga-postinstall-manifest.json" \
  "manifest written to .agents on first install"
assert_file "$CONSUMER/.claude/.jenga-postinstall-manifest.json" \
  "manifest written to .claude on first install"
assert_nogrep "preexisting/JUNK.md" "$CONSUMER/.agents/.jenga-postinstall-manifest.json" \
  "consumer file is NOT recorded in the manifest"
assert_grep "skills/do/SKILL.md" "$CONSUMER/.agents/.jenga-postinstall-manifest.json" \
  "manifest records mirrored package paths"

# ═══ Scenario B — upgrade with renames / removals / exclusions ════════════════
echo
echo "── Scenario B: upgrade 1.0.0 -> 2.0.0 ──"

# Consumer authors their own custom skill alongside package-owned ones.
for root in .agents .claude; do
  mkdir -p "$CONSUMER/$root/skills/my-custom-skill"
  printf '# my hand-authored skill\n' > "$CONSUMER/$root/skills/my-custom-skill/SKILL.md"
  # ...and drops a note INSIDE a package directory that v2 removes entirely.
  printf '# my notes inside a package-owned dir\n' > "$CONSUMER/$root/skills/j-legacy-twin/MY-NOTES.md"
done

# Record identity of a file common to both versions, to prove it is not needlessly
# deleted and recopied (mirror() should classify it as `skipped`).
DO_BEFORE="$(ls -li "$CONSUMER/.agents/skills/do/SKILL.md" | awk '{print $1, $6, $7, $8}')"

run_install "$PKG2" "$CONSUMER" "$FIXTURE/install-v2.log"

echo
echo "  [upgrade cleanup lines]"
grep -E "stale file|left in place|no previous" "$FIXTURE/install-v2.log" | sed 's/^/    /'
echo

# 1. Stale, fully-removed package skill is gone from BOTH roots, dir pruned.
assert_absent "$CONSUMER/.agents/skills/renamed-old" \
  "renamed-away skill dir removed from .agents"
assert_absent "$CONSUMER/.claude/skills/renamed-old" \
  "renamed-away skill dir removed from .claude"

# 2. Excluded twin's package file is gone, but the consumer's note in the same dir
#    survives — so the directory itself must NOT be pruned.
assert_absent "$CONSUMER/.agents/skills/j-legacy-twin/SKILL.md" \
  "excluded twin's package file removed (.agents)"
assert_absent "$CONSUMER/.claude/skills/j-legacy-twin/SKILL.md" \
  "excluded twin's package file removed (.claude)"
assert_file "$CONSUMER/.agents/skills/j-legacy-twin/MY-NOTES.md" \
  "consumer note INSIDE the emptied package dir survives (.agents)"
assert_file "$CONSUMER/.claude/skills/j-legacy-twin/MY-NOTES.md" \
  "consumer note INSIDE the emptied package dir survives (.claude)"

# 3. Consumer's own custom skill is untouched.
assert_file "$CONSUMER/.agents/skills/my-custom-skill/SKILL.md" \
  "consumer custom skill survives upgrade (.agents)"
assert_file "$CONSUMER/.claude/skills/my-custom-skill/SKILL.md" \
  "consumer custom skill survives upgrade (.claude)"
assert_file "$CONSUMER/.agents/skills/preexisting/JUNK.md" \
  "pre-manifest consumer file still survives upgrade (.agents)"
assert_file "$CONSUMER/.claude/skills/preexisting/JUNK.md" \
  "pre-manifest consumer file still survives upgrade (.claude)"

# 4. New skill arrived.
assert_file "$CONSUMER/.agents/skills/renamed-new/SKILL.md" \
  "renamed-to skill installed (.agents)"
assert_file "$CONSUMER/.claude/skills/renamed-new/SKILL.md" \
  "renamed-to skill installed (.claude)"

# 5. Unchanged common file was neither deleted nor recopied.
DO_AFTER="$(ls -li "$CONSUMER/.agents/skills/do/SKILL.md" | awk '{print $1, $6, $7, $8}')"
if [ "$DO_BEFORE" = "$DO_AFTER" ]; then
  pass "file common to both versions untouched (same inode+mtime)"
else
  fail "file common to both versions was rewritten ($DO_BEFORE -> $DO_AFTER)"
fi

# 6. Changed common file was overwritten.
assert_grep "v2 (changed)" "$CONSUMER/.agents/agents/developer.md" \
  "changed package file overwritten with v2 content"

# 7. Manifest refreshed.
assert_nogrep "renamed-old" "$CONSUMER/.agents/.jenga-postinstall-manifest.json" \
  "refreshed manifest no longer lists the removed skill"
assert_grep "renamed-new" "$CONSUMER/.agents/.jenga-postinstall-manifest.json" \
  "refreshed manifest lists the new skill"
assert_nogrep "my-custom-skill" "$CONSUMER/.agents/.jenga-postinstall-manifest.json" \
  "refreshed manifest never records consumer-authored files"

# ═══ Scenario C — idempotent re-run of the same version ══════════════════════
echo
echo "── Scenario C: re-run same version (version gate) ──"
run_install "$PKG2" "$CONSUMER" "$FIXTURE/install-v2-again.log"
assert_grep "Nothing to do" "$FIXTURE/install-v2-again.log" \
  "same-version re-run short-circuits before any delete pass"
assert_file "$CONSUMER/.agents/skills/my-custom-skill/SKILL.md" \
  "consumer custom skill still present after re-run"
assert_file "$CONSUMER/.agents/skills/renamed-new/SKILL.md" \
  "package skill still present after re-run"

# ═══ Scenario D — adversarial / corrupt manifests ════════════════════════════
# Exercises the guards directly: a manifest is data on the consumer's disk, so a
# tampered or corrupted one must never turn into an out-of-bounds or wrong-type
# delete. Uses a fresh consumer so it cannot disturb the scenarios above.
echo
echo "── Scenario D: adversarial + corrupt manifests ──"

CONSUMER_D="$FIXTURE/consumer-d"
mkdir -p "$CONSUMER_D"
run_install "$PKG1" "$CONSUMER_D" "$FIXTURE/d-install-v1.log"

# A file OUTSIDE the mirror roots that a traversal entry would try to reach.
printf 'precious\n' > "$CONSUMER_D/OUTSIDE-THE-MIRROR.txt"
# A symlink planted at a path the manifest will claim as ours.
mkdir -p "$CONSUMER_D/.agents/skills/trap"
ln -sf "$CONSUMER_D/OUTSIDE-THE-MIRROR.txt" "$CONSUMER_D/.agents/skills/trap/LINK.md"
# A directory planted where the manifest claims a file.
mkdir -p "$CONSUMER_D/.agents/skills/trap/DIR.md"

# Hand-craft a hostile manifest: traversal escape, symlink, directory, plus a real
# stale file that SHOULD still be cleaned up (proves the guards are selective, not
# a blanket bail-out).
python3 - "$CONSUMER_D" <<'PYEOF'
import json, sys, os
root = sys.argv[1]
m = os.path.join(root, ".agents", ".jenga-postinstall-manifest.json")
d = json.load(open(m))
d["paths"] = [
    "../OUTSIDE-THE-MIRROR.txt",   # traversal escape  -> must be refused
    "skills/trap/LINK.md",          # symlink           -> must be refused
    "skills/trap/DIR.md",           # directory         -> must be refused
    "skills/renamed-old/SKILL.md",  # genuinely stale   -> must be deleted
]
json.dump(d, open(m, "w"), indent=2)
PYEOF

run_install "$PKG2" "$CONSUMER_D" "$FIXTURE/d-install-v2.log"

echo
echo "  [guard lines]"
grep -E "left in place|stale file" "$FIXTURE/d-install-v2.log" | sed 's/^/    /'
echo

assert_file "$CONSUMER_D/OUTSIDE-THE-MIRROR.txt" \
  "traversal entry cannot delete a file outside the mirror root"
assert_grep "outside-dest-root" "$FIXTURE/d-install-v2.log" \
  "traversal entry explicitly refused"
if [ -L "$CONSUMER_D/.agents/skills/trap/LINK.md" ]; then
  pass "symlink entry refused, not followed or unlinked"
else
  fail "symlink entry was removed"
fi
assert_grep "not-a-regular-file" "$FIXTURE/d-install-v2.log" \
  "non-regular-file entries explicitly refused"
if [ -d "$CONSUMER_D/.agents/skills/trap/DIR.md" ]; then
  pass "directory entry refused (manifests record files only)"
else
  fail "directory entry was removed"
fi
assert_absent "$CONSUMER_D/.agents/skills/renamed-old/SKILL.md" \
  "genuinely stale entry still cleaned up alongside refusals"

# Corrupt manifest must disable the delete pass entirely, not guess.
CONSUMER_E="$FIXTURE/consumer-e"
mkdir -p "$CONSUMER_E"
run_install "$PKG1" "$CONSUMER_E" "$FIXTURE/e-install-v1.log"
printf '{ this is not valid json' > "$CONSUMER_E/.agents/.jenga-postinstall-manifest.json"
printf '{"manifest_version": 99, "paths": ["skills/renamed-old/SKILL.md"]}' \
  > "$CONSUMER_E/.claude/.jenga-postinstall-manifest.json"
run_install "$PKG2" "$CONSUMER_E" "$FIXTURE/e-install-v2.log"

assert_file "$CONSUMER_E/.agents/skills/renamed-old/SKILL.md" \
  "corrupt manifest disables the delete pass (.agents)"
assert_file "$CONSUMER_E/.claude/skills/renamed-old/SKILL.md" \
  "unknown manifest_version disables the delete pass (.claude)"
assert_grep "no previous install manifest" "$FIXTURE/e-install-v2.log" \
  "unreadable manifest degrades to additive-only"
assert_grep "manifest_version" "$CONSUMER_E/.agents/.jenga-postinstall-manifest.json" \
  "a fresh valid manifest is rewritten over the corrupt one"

# ═══ Scenario E — case-only rename on a case-insensitive filesystem ══════════
# Regression cover for tester finding 1 (E26_S08_T01 rapport). Staleness is decided
# by a case-SENSITIVE string set, but unlinks happen on a filesystem that may be
# case-INSENSITIVE (macOS APFS, Windows NTFS). After skill.md -> SKILL.md the old
# manifest string looks stale, yet it resolves to the file this run just wrote --
# so a string-only diff deletes the new file and the skill vanishes entirely.
echo
echo "── Scenario E: case-only rename (finding 1) ──"

PKG1C="$FIXTURE/pkg-v1-case"
PKG2C="$FIXTURE/pkg-v2-case"
make_pkg "$PKG1C" "1.0.0"
make_pkg "$PKG2C" "2.0.0"
mkdir -p "$PKG1C/skills/alpha" "$PKG2C/skills/alpha"
printf '# alpha\n' > "$PKG1C/skills/alpha/skill.md"   # lowercase in v1
printf '# alpha\n' > "$PKG2C/skills/alpha/SKILL.md"   # UPPERCASE in v2

CONSUMER_C="$FIXTURE/consumer-case"
mkdir -p "$CONSUMER_C"
run_install "$PKG1C" "$CONSUMER_C" "$FIXTURE/case-v1.log"
run_install "$PKG2C" "$CONSUMER_C" "$FIXTURE/case-v2.log"

# Detect whether this filesystem is even case-insensitive; on a case-SENSITIVE fs
# both names legitimately coexist and the old one is genuinely stale.
if [ -f "$CONSUMER_C/.agents/skills/alpha/skill.md" ] && \
   [ -f "$CONSUMER_C/.agents/skills/alpha/SKILL.md" ] && \
   [ "$(cat "$CONSUMER_C/.agents/skills/alpha/skill.md" 2>/dev/null)" != "$(cat "$CONSUMER_C/.agents/skills/alpha/SKILL.md" 2>/dev/null)" ]; then
  CASE_INSENSITIVE=0
else
  CASE_INSENSITIVE=1
fi

if [ "$CASE_INSENSITIVE" -eq 1 ]; then
  # The whole point: the skill must still exist under SOME name after the upgrade.
  if [ -f "$CONSUMER_C/.agents/skills/alpha/SKILL.md" ] || [ -f "$CONSUMER_C/.agents/skills/alpha/skill.md" ]; then
    pass "case-only rename does not delete the just-written file (.agents)"
  else
    fail "case-only rename deleted the skill entirely (.agents)"
  fi
  if [ -f "$CONSUMER_C/.claude/skills/alpha/SKILL.md" ] || [ -f "$CONSUMER_C/.claude/skills/alpha/skill.md" ]; then
    pass "case-only rename does not delete the just-written file (.claude)"
  else
    fail "case-only rename deleted the skill entirely (.claude)"
  fi
  assert_grep "written-this-run" "$FIXTURE/case-v2.log" \
    "identity guard reports the spared entry as written-this-run"
else
  pass "case-only rename (skipped: filesystem is case-sensitive)"
  pass "case-only rename (skipped: filesystem is case-sensitive) (.claude)"
  pass "identity guard reports the spared entry as written-this-run (n/a on case-sensitive fs)"
fi

# ═══ Scenario F — copySet entry missing from the package ═════════════════════
# Regression cover for tester finding 2. mirror() silently skips a missing source,
# so currentPaths under-reports and the delete pass would read the whole mirrored
# subtree as stale -- converting a bad publish into mass deletion on every consumer.
echo
echo "── Scenario F: packaging regression (finding 2) ──"

PKG2M="$FIXTURE/pkg-v2-missing"
make_pkg "$PKG2M" "2.0.0"
printf '# developer agent v2\n' > "$PKG2M/agents/developer.md"
rm -rf "$PKG2M/skills"          # simulate skills/ omitted from the published package

CONSUMER_M="$FIXTURE/consumer-missing"
mkdir -p "$CONSUMER_M"
run_install "$PKG1" "$CONSUMER_M" "$FIXTURE/missing-v1.log"
run_install "$PKG2M" "$CONSUMER_M" "$FIXTURE/missing-v2.log"

assert_file "$CONSUMER_M/.agents/skills/do/SKILL.md" \
  "missing copySet entry does not wipe the mirrored subtree (.agents)"
assert_file "$CONSUMER_M/.claude/skills/do/SKILL.md" \
  "missing copySet entry does not wipe the mirrored subtree (.claude)"
assert_grep "Upgrade cleanup skipped" "$FIXTURE/missing-v2.log" \
  "packaging regression reported, cleanup skipped"
assert_grep "skills/renamed-old/SKILL.md" "$CONSUMER_M/.agents/.jenga-postinstall-manifest.json" \
  "previous manifest left intact (still describes what is on disk)"

echo
echo "══════════════════════════════════════════════════════"
printf '  Result: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "══════════════════════════════════════════════════════"
echo
[ "$FAIL" -eq 0 ]
