#!/usr/bin/env bash
#
# validate_npm_metadata.sh — deterministic check that package.json carries
# the metadata npm/GitHub discovery depends on (E41_S01_T02).
#
# Rationale: per the repo's "Scripts Over Inline Logic" principle
# (CLAUDE.md), this is a script rather than an agent instruction so that
# future drift in package.json's publish-facing fields (e.g. keywords
# accidentally cleared, or repository.url silently re-pointed at the
# private samwelmunga/Jenga AI repo instead of the public jenga-npm
# mirror) is caught deterministically instead of relying on an agent
# noticing during review.
#
# IMPORTANT — no pinned version check:
#   This script intentionally does NOT compare package.json's `version`
#   field against any hardcoded literal. E41_S01_T01 established that the
#   locally committed version and the version actually published to npm
#   drift independently over time, so pinning a literal here would go
#   stale on the very next release. If a version check is wanted at all,
#   it is structural only (present + semver-shaped), never a pinned value.
#
# Usage:
#   bash scripts/validate_npm_metadata.sh
#   npm run validate:npm-metadata
#
# Exit codes:
#   0  All checks passed.
#   1  One or more checks failed (each failure is printed with a
#      descriptive message; a summary count follows).
#
# Dependencies: node only (already a required runtime for this project —
# see package.json's "engines" field). No new dependency is introduced.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_JSON="${1:-$REPO_ROOT/package.json}"

if [[ ! -f "$PACKAGE_JSON" ]]; then
  echo "FAIL: package.json not found at $PACKAGE_JSON" >&2
  exit 1
fi

# All validation logic lives in one embedded Node script to avoid the
# quoting/escaping pitfalls of parsing JSON arrays and nested objects from
# bash. Node prints one "PASS: ..." or "FAIL: ..." line per check to
# stdout, plus a final "SUMMARY: <n> failed" line. Bash only interprets
# the final summary line to decide the exit code and print the banner.
NODE_OUTPUT="$(node -e '
const fs = require("fs");

const pkgPath = process.argv[1];
const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));

const failures = [];
const pass = (msg) => console.log("PASS: " + msg);
const fail = (msg) => { failures.push(msg); console.log("FAIL: " + msg); };

// keywords: must exist, be a non-empty array
if (!Array.isArray(pkg.keywords) || pkg.keywords.length === 0) {
  fail("keywords is empty or missing — package.json must declare a non-empty keywords array for npm/GitHub discoverability.");
} else {
  pass("keywords is present with " + pkg.keywords.length + " entries.");
}

// author: must exist and be non-empty (string or object form)
const authorEmpty = (() => {
  if (pkg.author == null) return true;
  if (typeof pkg.author === "string") return pkg.author.trim().length === 0;
  if (typeof pkg.author === "object") {
    return !pkg.author.name || String(pkg.author.name).trim().length === 0;
  }
  return true;
})();
if (authorEmpty) {
  fail("author is empty or missing — package.json must declare an author (string or {name, ...} object).");
} else {
  pass("author is present.");
}

// repository / homepage / bugs: must all be present
if (pkg.repository == null || (typeof pkg.repository === "object" && Object.keys(pkg.repository).length === 0)) {
  fail("repository is missing from package.json.");
} else {
  pass("repository is present.");
}

if (!pkg.homepage || String(pkg.homepage).trim().length === 0) {
  fail("homepage is missing from package.json.");
} else {
  pass("homepage is present.");
}

if (pkg.bugs == null || (typeof pkg.bugs === "object" && Object.keys(pkg.bugs).length === 0)) {
  fail("bugs is missing from package.json.");
} else {
  pass("bugs is present.");
}

// repository.url (object form) or repository (string form) must point at
// the PUBLIC mirror (samwelmunga/jenga-npm), never the private repo.
const PUBLIC_REPO_MARKER = "samwelmunga/jenga-npm";
if (pkg.repository != null) {
  const repoUrl = typeof pkg.repository === "string"
    ? pkg.repository
    : (pkg.repository.url || "");

  if (!repoUrl || repoUrl.trim().length === 0) {
    fail("repository is present but has no resolvable url.");
  } else if (!repoUrl.includes(PUBLIC_REPO_MARKER)) {
    fail("repository.url (\"" + repoUrl + "\") does not point at the public " + PUBLIC_REPO_MARKER + " repo — it must not reference a private repo (e.g. samwelmunga/Jenga AI) or any other location.");
  } else {
    pass("repository.url points at the public " + PUBLIC_REPO_MARKER + " repo.");
  }
}

// version: structural semver check only — NEVER a pinned literal value.
// See header comment for why a pinned check would go stale immediately.
const SEMVER_RE = /^\d+\.\d+\.\d+/;
if (!pkg.version || !SEMVER_RE.test(String(pkg.version))) {
  fail("version (\"" + pkg.version + "\") is missing or not a valid semver-shaped string.");
} else {
  pass("version (\"" + pkg.version + "\") is a valid semver-shaped string (no pinned-value check performed, by design).");
}

console.log("SUMMARY: " + failures.length + " failed");
process.exit(failures.length > 0 ? 1 : 0);
' "$PACKAGE_JSON")" && NODE_EXIT=0 || NODE_EXIT=$?

echo "$NODE_OUTPUT"
echo

FAILED_COUNT="$(echo "$NODE_OUTPUT" | grep -c '^FAIL:' || true)"

if [[ "$NODE_EXIT" -ne 0 || "$FAILED_COUNT" -gt 0 ]]; then
  echo "npm publish metadata validation FAILED ($FAILED_COUNT check(s) failed). See FAIL lines above." >&2
  exit 1
fi

echo "All npm publish metadata checks passed."
exit 0
