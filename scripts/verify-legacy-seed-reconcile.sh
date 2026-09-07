#!/usr/bin/env bash
#
# verify-legacy-seed-reconcile.sh — fixture rehearsal for E26_S08_T03
#
# Rehearses the legacy-path-seeding mechanism (lib/postinstall-manifest.js's
# seedFromLegacyPaths/reconcileWithPriorPaths, wired into scripts/postinstall.js's
# no-prior-manifest branch) against THROWAWAY fixture consumer projects, as required by
# this task's `crucial_level: gated` note ("must be rehearsed against a throwaway
# fixture consumer directory before being considered done, not just unit-reasoned
# about"). Kept as a SEPARATE script from scripts/verify-postinstall-reconcile.sh
# (E26_S08_T01's already-Passed rehearsal harness) so that harness is not touched by
# this task.
#
# SAFETY: this script creates its own fixture root via `mktemp -d` and writes and
# deletes ONLY inside it. It takes no path argument and will never operate on an
# existing directory, so it cannot touch this repo or a real consumer project.
# Set KEEP_FIXTURE=1 to leave the fixture on disk for inspection.
#
# Scenarios covered
#   A. Pre-manifest orphan cleanup — THE fix this task delivers. A consumer already
#      carrying an orphan predating any manifest (e.g. a retired j-<name> twin) gets it
#      cleaned up on the VERY FIRST run of a fixed version (adopt-then-reconcile in one
#      pass), while a consumer-authored sibling file in the same directory survives
#      along with the directory itself.
#   B. Genuine first-ever install (nothing on disk to intersect with) stays purely
#      additive — no deletes, regardless of what the legacy path list contains.
#   C. A legacy-listed path that is STILL currently shipped survives (it's part of this
#      run's own copy set, so it is never "stale").
#   D. A legacy-listed path that isn't actually present on disk is never seeded (no
#      phantom delete attempt, no error).
#   E. Boundary/type safety over SEEDED paths: a traversal entry and a symlink entry in
#      the legacy list are refused exactly like a manifest-based candidate would be —
#      seeding narrows which paths are eligible, it does not relax how a candidate is
#      validated.
#   F. Regression: a consumer with a VALID prior manifest reconciles exactly as T01
#      already verifies — seeding must never fire once a real manifest exists.
#
# Usage:  bash scripts/verify-legacy-seed-reconcile.sh
# Exit:   0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/jenga-legacy-seed-fixture.XXXXXX")"

PASS=0
FAIL=0

# When RESULTS_FILE is set, every verdict is also appended in a machine-readable
# `PASS<TAB><name>` / `FAIL<TAB><name>` form, so tests/postinstall-legacy-seed.bats can
# assert on individual named checks instead of on one opaque exit status. Mirrors the
# exact convention scripts/verify-postinstall-reconcile.sh already established.
record() { if [ -n "${RESULTS_FILE:-}" ]; then printf '%s\t%s\n' "$1" "$2" >> "$RESULTS_FILE"; fi; }

pass() { PASS=$((PASS + 1)); record PASS "$1"; printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); record FAIL "$1"; printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

assert_file()      { if [ -f "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi; }
assert_absent()    { if [ ! -e "$1" ]; then pass "$2"; else fail "$2 (still present: $1)"; fi; }
assert_dir()       { if [ -d "$1" ]; then pass "$2"; else fail "$2 (missing dir: $1)"; fi; }
assert_grep()      { if grep -q "$1" "$2" 2>/dev/null; then pass "$3"; else fail "$3"; fi; }
assert_nogrep_re() { if grep -qE "$1" "$2" 2>/dev/null; then fail "$3"; else pass "$3"; fi; }

cleanup() {
  if [ "${KEEP_FIXTURE:-0}" = "1" ]; then
    printf '\n  Fixture retained at: %s\n' "$FIXTURE"
  else
    rm -rf "$FIXTURE"
  fi
}
trap cleanup EXIT

# ── build a synthetic "current package" ──────────────────────────────────────
# Real lib/ + scripts/ (the code under test), a small synthetic skills/+agents/ tree,
# and a hand-authored lib/legacy-shipped-paths.json standing in for the real generated
# artifact — this fixture's package version doesn't need to match any real published
# version; only the LOGIC under test needs to be real.
make_pkg() {
  local dir="$1"
  mkdir -p "$dir"
  cp -R "$REPO_ROOT/lib"     "$dir/lib"
  cp -R "$REPO_ROOT/scripts" "$dir/scripts"
  cat > "$dir/package.json" <<'JSON'
{ "name": "@jenga-ai/agent", "version": "3.0.0", "type": "module" }
JSON
  mkdir -p "$dir/skills/do" "$dir/agents"
  printf '# do skill (still shipped)\n' > "$dir/skills/do/SKILL.md"
  printf '# developer agent (still shipped)\n' > "$dir/agents/developer.md"
}

write_legacy_paths() {
  local dir="$1"; shift
  local paths_json
  paths_json=$(printf '"%s",' "$@")
  paths_json="[${paths_json%,}]"
  cat > "$dir/lib/legacy-shipped-paths.json" <<JSON
{
  "generated_at": "2026-01-01T00:00:00.000Z",
  "package": "@jenga-ai/agent",
  "source": "test-fixture",
  "paths": $paths_json
}
JSON
}

run_install() {
  local pkg="$1" consumer="$2" log="$3"
  ( cd "$pkg" && INIT_CWD="$consumer" node scripts/postinstall.js ) > "$log" 2>&1
}

echo
echo "══ Jenga legacy-path seeding rehearsal (E26_S08_T03) ══"
echo "  fixture: $FIXTURE"

PKG="$FIXTURE/pkg"
make_pkg "$PKG"
write_legacy_paths "$PKG" \
  "agents/developer.md" \
  "skills/do/SKILL.md" \
  "skills/j-legacy-twin/SKILL.md" \
  "../OUTSIDE-THE-FIXTURE.txt" \
  "skills/trap/LINK.md"

# ═══ Scenario A — pre-manifest orphan cleanup (THE fix) ══════════════════════
echo
echo "── Scenario A: pre-manifest orphan cleaned on the very first run ──"

CONSUMER_A="$FIXTURE/consumer-a"
mkdir -p "$CONSUMER_A/.agents/skills/j-legacy-twin" "$CONSUMER_A/.claude/skills/j-legacy-twin"
printf '# retired twin, predates any manifest\n' > "$CONSUMER_A/.agents/skills/j-legacy-twin/SKILL.md"
printf 'my own notes\n'                          > "$CONSUMER_A/.agents/skills/j-legacy-twin/my-notes.md"
printf '# retired twin, predates any manifest\n' > "$CONSUMER_A/.claude/skills/j-legacy-twin/SKILL.md"
printf 'my own notes\n'                          > "$CONSUMER_A/.claude/skills/j-legacy-twin/my-notes.md"

run_install "$PKG" "$CONSUMER_A" "$FIXTURE/a-install.log"

assert_absent "$CONSUMER_A/.agents/skills/j-legacy-twin/SKILL.md" \
  "pre-manifest orphan removed on first run (.agents)"
assert_absent "$CONSUMER_A/.claude/skills/j-legacy-twin/SKILL.md" \
  "pre-manifest orphan removed on first run (.claude)"
assert_file "$CONSUMER_A/.agents/skills/j-legacy-twin/my-notes.md" \
  "consumer-authored sibling survives (.agents)"
assert_file "$CONSUMER_A/.claude/skills/j-legacy-twin/my-notes.md" \
  "consumer-authored sibling survives (.claude)"
assert_dir "$CONSUMER_A/.agents/skills/j-legacy-twin" \
  "directory survives because it still holds a consumer file (.agents)"
assert_grep "seeded from known-shipped legacy paths" "$FIXTURE/a-install.log" \
  "install log attributes the cleanup to legacy-path seeding"
assert_file "$CONSUMER_A/.agents/skills/do/SKILL.md" \
  "currently-shipped skill untouched"
assert_file "$CONSUMER_A/.agents/agents/developer.md" \
  "currently-shipped agent file untouched"

# Manifest written this run must describe reality: current package paths only, never
# the just-deleted orphan and never the consumer's own file.
python3 - "$CONSUMER_A/.agents/.jenga-postinstall-manifest.json" <<'PYEOF'
import json, sys
paths = json.load(open(sys.argv[1]))["paths"]
assert "skills/j-legacy-twin/SKILL.md" not in paths, "deleted orphan must not be in the fresh manifest"
assert "skills/j-legacy-twin/my-notes.md" not in paths, "consumer file must never be in the manifest"
assert "skills/do/SKILL.md" in paths and "agents/developer.md" in paths, "current package paths must be present"
PYEOF
if [ $? -eq 0 ]; then pass "fresh manifest describes only what is actually on disk post-cleanup"; else fail "fresh manifest is inaccurate"; fi

# ═══ Scenario B — genuine first-ever install stays additive-only ═════════════
echo
echo "── Scenario B: genuine first-ever install (nothing to intersect with) ──"

CONSUMER_B="$FIXTURE/consumer-b"
mkdir -p "$CONSUMER_B"
run_install "$PKG" "$CONSUMER_B" "$FIXTURE/b-install.log"

assert_nogrep_re "[1-9][0-9]* stale file" "$FIXTURE/b-install.log" \
  "first-ever install deletes nothing despite a non-empty legacy path list"
assert_grep "no previous install manifest" "$FIXTURE/b-install.log" \
  "first-ever install reports plain additive-only, not a seeded outcome"
assert_file "$CONSUMER_B/.agents/skills/do/SKILL.md" \
  "first-ever install still copies current package files"

# ═══ Scenario C — a legacy path still currently shipped is never touched ═════
# (Implicitly exercised by Scenario A's "do"/"developer.md" already surviving, but
# asserted here as its own named check for clarity.)
assert_file "$CONSUMER_A/.claude/skills/do/SKILL.md" \
  "a legacy-listed path that is STILL shipped survives untouched (not stale)"

# ═══ Scenario D — a legacy path absent from disk is never phantom-seeded ═════
# The legacy list includes "skills/j-legacy-twin/SKILL.md" for consumer-b too, but
# consumer-b never had that file on disk at all. No error, no crash, nothing reported.
assert_absent "$CONSUMER_B/.agents/skills/j-legacy-twin" \
  "a legacy path never present on disk produces no phantom entries"

# ═══ Scenario E — boundary/type safety over SEEDED paths ═════════════════════
echo
echo "── Scenario E: adversarial legacy-listed paths are refused, not exploited ──"

CONSUMER_E="$FIXTURE/consumer-e"
mkdir -p "$CONSUMER_E/.agents/skills/trap"
printf 'precious\n' > "$FIXTURE/OUTSIDE-THE-FIXTURE.txt"
ln -sf "$FIXTURE/OUTSIDE-THE-FIXTURE.txt" "$CONSUMER_E/.agents/skills/trap/LINK.md"

run_install "$PKG" "$CONSUMER_E" "$FIXTURE/e-install.log"

assert_file "$FIXTURE/OUTSIDE-THE-FIXTURE.txt" \
  "traversal entry in the legacy list cannot delete outside the mirror root"
if [ -L "$CONSUMER_E/.agents/skills/trap/LINK.md" ]; then
  pass "symlink entry in the legacy list is refused, not followed or unlinked"
else
  fail "symlink entry in the legacy list was removed"
fi

# ═══ Scenario F — regression: a VALID prior manifest reconciles normally, unseeded ═══
# Uses a genuine two-version upgrade (like T01's own harness) so a REAL manifest-backed
# stale entry exists to clean up — proving the seeding branch never fires once a real
# manifest is present, not merely that nothing happened to need it.
echo
echo "── Scenario F: a consumer with a real prior manifest reconciles normally, unseeded ──"

PKG_F1="$FIXTURE/pkg-f1"
make_pkg "$PKG_F1"
mkdir -p "$PKG_F1/skills/renamed-old"
printf '# renamed-old — removed in the next version\n' > "$PKG_F1/skills/renamed-old/SKILL.md"
write_legacy_paths "$PKG_F1" "agents/developer.md" "skills/do/SKILL.md"

PKG_F2="$FIXTURE/pkg-f2"
make_pkg "$PKG_F2"
python3 -c "
import json
p = '$PKG_F2/package.json'
d = json.load(open(p)); d['version'] = '3.0.1'; json.dump(d, open(p, 'w'))
"
write_legacy_paths "$PKG_F2" "agents/developer.md" "skills/do/SKILL.md" "skills/renamed-old/SKILL.md"

CONSUMER_F="$FIXTURE/consumer-f"
mkdir -p "$CONSUMER_F"
run_install "$PKG_F1" "$CONSUMER_F" "$FIXTURE/f-install-1.log"
assert_grep "no previous install manifest" "$FIXTURE/f-install-1.log" \
  "first run for consumer-f is a normal, unseeded additive install"
assert_file "$CONSUMER_F/.agents/skills/renamed-old/SKILL.md" \
  "v1 skill mirrored before the upgrade that removes it"

run_install "$PKG_F2" "$CONSUMER_F" "$FIXTURE/f-install-2.log"
assert_absent "$CONSUMER_F/.agents/skills/renamed-old/SKILL.md" \
  "genuinely stale entry cleaned up via the REAL manifest-backed path"
assert_grep "stale file(s) removed" "$FIXTURE/f-install-2.log" \
  "the real manifest-backed delete pass ran and reported a removal"
assert_nogrep_re "seeded from known-shipped legacy paths" "$FIXTURE/f-install-2.log" \
  "seeding branch never fires when a real prior manifest is present"

echo
echo "──────────────────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
echo "──────────────────────────────────────────────────────"

[ "$FAIL" -eq 0 ]
