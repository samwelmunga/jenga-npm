#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# st-test-run.sh - run the staged-release consumer verification procedure (formerly the
# README's "Verifying a Staged Release Against a Consumer Project" section, removed from the
# public README because it describes internal process) against the ST-Test project, and
# print the results.
#
# Follows the former README steps 3-9 in order: download the staged tarball to a temp
# directory, check its shasum, install it in the consumer, approve and run the
# postinstall, check .jenga-version, run the skill smoke test, run the package's own
# two node tests, then run the consumer's own checks.
#
# stdout is the report (the step's `report` output, consumed by the confirm step that
# offers the release options). Progress goes to stderr.
#
# EXIT POLICY, deliberately: a failing CHECK does not fail this script. The workflow
# is meant to reach its report-and-choose step with the results in hand and let the
# user decide, so exit 0 means "the procedure ran" and the report says what passed.
# Only a failure that leaves nothing to test (no consumer directory, no tarball)
# exits non-zero.
#
# Usage: st-test-run.sh <st-test-path> <stage-id> [<package-name>]
#
# Exit: 0 the procedure ran (read the report); 1 nothing could be tested; 2 setup error.
# ---------------------------------------------------------------------------
set -uo pipefail

ST_PATH="${1:-}"
STAGE_ID="${2:-}"
PKG_OVERRIDE="${3:-}"

die() { printf 'st-test-run: %s\n' "$1" >&2; exit "${2:-2}"; }
note() { printf 'st-test-run: %s\n' "$1" >&2; }

[ -n "$ST_PATH" ] || die "usage: st-test-run.sh <st-test-path> <stage-id> [<package-name>]"
[ -n "$STAGE_ID" ] || die "usage: st-test-run.sh <st-test-path> <stage-id> [<package-name>]"
command -v npm >/dev/null 2>&1 || die "npm not installed"
command -v node >/dev/null 2>&1 || die "node not installed"
command -v shasum >/dev/null 2>&1 || die "shasum not installed"
command -v git >/dev/null 2>&1 || die "git not installed"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git work tree"
[ -f "$ROOT/package.json" ] || die "no package.json at $ROOT"
VERSION="$(node -p "require('$ROOT/package.json').version" 2>/dev/null)" || die "cannot read the version from package.json"
PKG="${PKG_OVERRIDE:-$(node -p "require('$ROOT/package.json').name" 2>/dev/null)}"
[ -n "$PKG" ] || die "cannot read the package name from package.json"

CONSUMER="$(cd "$ST_PATH" 2>/dev/null && pwd)" || die "no such consumer directory: $ST_PATH" 1
[ -f "$CONSUMER/package.json" ] || die "no package.json in the consumer directory $CONSUMER" 1

# One report line per check. STATUS is the running verdict.
REPORT=""
FAILED=0
PASSED=0
add() {
  REPORT="${REPORT}$1
"
}
check() {
  # check <PASS|FAIL|SKIP> <label> [detail]
  local verdict="$1" label="$2" detail="${3:-}"
  case "$verdict" in
    PASS) PASSED=$((PASSED + 1)) ;;
    FAIL) FAILED=$((FAILED + 1)) ;;
  esac
  if [ -n "$detail" ]; then
    add "$(printf '%-4s %s - %s' "$verdict" "$label" "$detail")"
  else
    add "$(printf '%-4s %s' "$verdict" "$label")"
  fi
  note "$verdict $label"
}

DL_DIR="${TMPDIR:-/tmp}/st-dl-${STAGE_ID}"
mkdir -p "$DL_DIR" || die "cannot create the download directory $DL_DIR"

add "stage        $STAGE_ID"
add "package      ${PKG}@${VERSION}"
add "consumer     $CONSUMER"
add "download dir $DL_DIR"
add ""

# --- README step 3: download the staged tarball, outside the consumer repo --------
note "downloading the staged tarball"
DL_OUT="$(cd "$DL_DIR" && npm stage download "$STAGE_ID" 2>&1)"
DL_RC=$?
TARBALL="$(ls -t "$DL_DIR"/*.tgz 2>/dev/null | head -n 1)"
if [ "$DL_RC" -ne 0 ] || [ -z "$TARBALL" ]; then
  check FAIL "npm stage download" "exit $DL_RC; $(printf '%s' "$DL_OUT" | tail -n 3 | tr '\n' ' ')"
  printf '%s' "$REPORT"
  printf '\nNOTHING TESTED: the staged tarball could not be downloaded, so steps 4-9 were skipped.\n'
  exit 1
fi
check PASS "npm stage download" "$(basename "$TARBALL")"

# --- README step 4: the shasum must match `npm stage view` ------------------------
VIEW_OUT="$(npm stage view "$STAGE_ID" 2>&1)" || VIEW_OUT=""
EXPECTED_SHA="$(printf '%s' "$VIEW_OUT" | grep -Eio '[0-9a-f]{40}' | head -n 1)"
ACTUAL_SHA="$(shasum -a 1 "$TARBALL" 2>/dev/null | awk '{print $1}')"
if [ -z "$EXPECTED_SHA" ]; then
  check SKIP "shasum match" "no shasum found in 'npm stage view' output; compare by hand (tarball is $ACTUAL_SHA)"
elif [ "$EXPECTED_SHA" = "$ACTUAL_SHA" ]; then
  check PASS "shasum match" "$ACTUAL_SHA"
else
  check FAIL "shasum match" "stage says $EXPECTED_SHA, tarball is $ACTUAL_SHA"
fi

# --- README step 5: install the tarball in the consumer ---------------------------
note "installing the tarball in the consumer"
INSTALL_OUT="$(cd "$CONSUMER" && npm install "$TARBALL" 2>&1)"
if [ $? -eq 0 ]; then
  check PASS "npm install <tarball>" "dependency now points at a file: path - restore the registry version after the release"
else
  check FAIL "npm install <tarball>" "$(printf '%s' "$INSTALL_OUT" | tail -n 3 | tr '\n' ' ')"
fi

# --- README step 6: approve and run the postinstall, then check .jenga-version ----
APPROVE_OUT="$(cd "$CONSUMER" && npm approve-scripts "$PKG" </dev/null 2>&1)"
if [ $? -eq 0 ]; then
  check PASS "npm approve-scripts $PKG"
else
  check FAIL "npm approve-scripts $PKG" "$(printf '%s' "$APPROVE_OUT" | tail -n 2 | tr '\n' ' ')"
fi

REBUILD_OUT="$(cd "$CONSUMER" && npm rebuild "$PKG" 2>&1)"
if [ $? -eq 0 ]; then
  check PASS "npm rebuild $PKG"
else
  check FAIL "npm rebuild $PKG" "$(printf '%s' "$REBUILD_OUT" | tail -n 2 | tr '\n' ' ')"
fi

INSTALLED_VERSION="$(cat "$CONSUMER/.jenga-version" 2>/dev/null | tr -d '[:space:]')"
if [ "$INSTALLED_VERSION" = "$VERSION" ]; then
  check PASS ".jenga-version matches" "$INSTALLED_VERSION"
else
  check FAIL ".jenga-version matches" "expected $VERSION, found '${INSTALLED_VERSION:-missing}'"
fi

# --- README step 7: the skill smoke test, against the package root ----------------
PKG_ROOT="node_modules/$PKG"
SMOKE="$PKG_ROOT/skills/j-smoke-test/scripts/smoke-test-skills.sh"
if [ -f "$CONSUMER/$SMOKE" ]; then
  SMOKE_OUT="$(cd "$CONSUMER" && bash "$SMOKE" --root "$PKG_ROOT" 2>&1)"
  SMOKE_RC=$?
  if [ "$SMOKE_RC" -eq 0 ]; then
    check PASS "skill smoke test" "no critical finding"
  else
    check FAIL "skill smoke test" "exit $SMOKE_RC; $(printf '%s' "$SMOKE_OUT" | tail -n 4 | tr '\n' ' ')"
  fi
else
  check FAIL "skill smoke test" "$SMOKE not found in the installed package"
fi

# --- README step 8: the package's own two node tests ------------------------------
for t in populate-knowledge-graph.entity-resolution.test.js populate-knowledge-graph.staleness.test.js; do
  if [ -f "$CONSUMER/$PKG_ROOT/scripts/$t" ]; then
    T_OUT="$(cd "$CONSUMER" && node "$PKG_ROOT/scripts/$t" 2>&1)"
    if [ $? -eq 0 ]; then
      check PASS "package test $t"
    else
      check FAIL "package test $t" "$(printf '%s' "$T_OUT" | tail -n 3 | tr '\n' ' ')"
    fi
  else
    check FAIL "package test $t" "not found in the installed package"
  fi
done

# --- README step 9: the consumer's own checks ------------------------------------
HAS_TEST="$(node -p "!!(require('$CONSUMER/package.json').scripts||{}).test" 2>/dev/null)"
if [ "$HAS_TEST" = "true" ]; then
  note "running the consumer's own npm test (this is the slow one)"
  CONSUMER_OUT="$(cd "$CONSUMER" && npm test 2>&1)"
  if [ $? -eq 0 ]; then
    check PASS "consumer npm test"
  else
    check FAIL "consumer npm test" "$(printf '%s' "$CONSUMER_OUT" | tail -n 6 | tr '\n' ' ')"
  fi
else
  check SKIP "consumer npm test" "the consumer declares no test script"
fi

printf '%s' "$REPORT"
printf '\n%s passed, %s failed.\n' "$PASSED" "$FAILED"
if [ "$FAILED" -eq 0 ]; then
  printf 'VERDICT: pass - stage %s behaves in %s.\n' "$STAGE_ID" "$(basename "$CONSUMER")"
else
  printf 'VERDICT: fail - %s check(s) failed; read the lines above before choosing to release.\n' "$FAILED"
fi
printf 'Reminder: %s in %s is installed from a file: path. Restore the registry version after the release.\n' "$PKG" "$CONSUMER"
exit 0
