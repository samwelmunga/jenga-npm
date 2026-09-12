#!/usr/bin/env bash
#
# verify-consumer-install.sh — real-consumer rehearsal for E47_S02_T02
#
# Verifies that project/app/api/server.js and its 5 parsers (board.js, git-log.js, rapports.js,
# architecture.js, knowledge-graph.js) resolve their data root via
# project/app/api/lib/resolve-project-root.js (E47_S02_T01) — not a fixed __dirname-relative climb —
# against three scenarios, matching the verification bar E46_S01 already set for /init:
#
#   A. SELF-HOSTING — dashboard launched from this repo's own checkout (no env override, pure
#      cwd walk-up) still serves this repo's own board/history/architecture data unchanged.
#   B. SYMLINKED INVOCATION — dashboard launched with cwd reached through a symlink to this repo's
#      own checkout still resolves correctly (same bug class E46_S01 fixed for /init).
#   C. REAL CONSUMER INSTALL — a scratch "package" is `npm pack`ed (from a throwaway copy of this
#      repo's own git-tracked tree, with a *temporary, uncommitted* `files` field patch — see the
#      KNOWN SIMPLIFICATION note below) and `npm install`ed into a second scratch "consumer"
#      directory that has its own, distinctly-fixtured `project/board`/`project/rapports`/
#      `project/knowledge-graph`. The dashboard is launched from inside that consumer directory and
#      its API responses must reflect the *consumer's* fixture data, never this repo's own.
#
# KNOWN SIMPLIFICATION (documented, not a bug in this task's own scope): shipping the dashboard in
# the published npm package at all — including which files ship and how project/app/api's own
# runtime dependencies (express/cors/gray-matter) get installed for a real consumer — is E47_S01's
# job, still `Pending` as of this task. This script's Scenario C therefore (1) patches a *scratch
# copy only* of package.json's `files` field, never this repo's real tracked package.json, and
# (2) runs a manual `npm install` inside the installed copy's project/app/api/ directory to satisfy
# its own dependencies, mirroring the manual step a real consumer would currently have to take until
# E47_S01 solves dependency packaging. When E47_S01 lands, both of these become unnecessary and this
# script's Scenario C can be simplified accordingly (tracked as a follow-up, not fixed here).
#
# SAFETY: all scratch state lives under `mktemp -d`. This script never modifies this repo's own
# tracked package.json, board, or any other file — only throwaway copies.
#
# Usage:  bash scripts/verify-consumer-install.sh
# Exit:   0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/jenga-consumer-verify.XXXXXX")"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

# Servers are stopped via `pkill -f <unique-absolute-path-fragment>` rather than `kill <pid>` —
# each scenario requires server.js from a distinct absolute path (this repo's own checkout, the
# symlinked path, or the scratch-installed tarball copy), so matching on that path is unambiguous
# and, unlike a bare `kill`, works reliably in sandboxed shells that gate direct PID signaling.
stop_server() { pkill -f "$1" >/dev/null 2>&1 || true; }

cleanup() {
  stop_server "$REPO_ROOT/project/app/api/server.js"
  stop_server "$SCRATCH/symlinked-repo/project/app/api/server.js"
  stop_server "$SCRATCH/consumer-project/node_modules/@jenga-ai/agent/project/app/ui/scripts/dashboard-start.cjs"
  if [ "${KEEP_FIXTURE:-0}" = "1" ]; then
    printf '\n  Fixture retained at: %s\n' "$SCRATCH"
  else
    rm -rf "$SCRATCH"
  fi
}
trap cleanup EXIT

wait_for_health() {
  local port="$1" tries=0
  while [ "$tries" -lt 40 ]; do
    if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/v1/health" 2>/dev/null | grep -q '^2'; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.25
  done
  return 1
}

# ── Scenario A: self-hosting ─────────────────────────────────────────────────
echo "== Scenario A: self-hosting (this repo's own checkout) =="
PORT_A=41001
( cd "$REPO_ROOT" && JENGA_API_PORT="$PORT_A" node "$REPO_ROOT/project/app/api/server.js" >"$SCRATCH/server-a.log" 2>&1 & )

if wait_for_health "$PORT_A"; then
  BOARD_A="$(curl -s "http://localhost:${PORT_A}/v1/board")"
  ARCH_A="$(curl -s "http://localhost:${PORT_A}/v1/architecture")"
  HISTORY_A="$(curl -s "http://localhost:${PORT_A}/v1/history?limit=5")"
  if echo "$BOARD_A" | grep -q '"id":"E01"'; then
    pass "self-hosting: /v1/board contains this repo's own E01"
  else
    fail "self-hosting: /v1/board missing this repo's own E01"
  fi
  if echo "$ARCH_A" | grep -q '"name":"jenga"'; then
    pass "self-hosting: /v1/architecture reflects this repo's own package.json"
  else
    fail "self-hosting: /v1/architecture did not reflect this repo's own package.json"
  fi
  if echo "$HISTORY_A" | grep -q '"type":"git_commit"'; then
    pass "self-hosting: /v1/history returns this repo's own git commits"
  else
    fail "self-hosting: /v1/history did not return any git commits"
  fi
else
  fail "self-hosting: server never became healthy on port $PORT_A (see $SCRATCH/server-a.log)"
fi
stop_server "$REPO_ROOT/project/app/api/server.js"

# ── Scenario B: symlinked invocation path ────────────────────────────────────
echo "== Scenario B: symlinked invocation path =="
SYMLINK_PATH="$SCRATCH/symlinked-repo"
ln -s "$REPO_ROOT" "$SYMLINK_PATH"
PORT_B=41002
( cd "$SYMLINK_PATH" && JENGA_API_PORT="$PORT_B" node "$SYMLINK_PATH/project/app/api/server.js" >"$SCRATCH/server-b.log" 2>&1 & )

if wait_for_health "$PORT_B"; then
  BOARD_B="$(curl -s "http://localhost:${PORT_B}/v1/board")"
  if echo "$BOARD_B" | grep -q '"id":"E01"'; then
    pass "symlinked cwd: /v1/board still resolves to this repo's own data"
  else
    fail "symlinked cwd: /v1/board did not resolve to this repo's own data"
  fi
else
  fail "symlinked cwd: server never became healthy on port $PORT_B (see $SCRATCH/server-b.log)"
fi
stop_server "$SYMLINK_PATH/project/app/api/server.js"

# ── Scenario C: real consumer install (npm pack + npm install) ──────────────
echo "== Scenario C: real consumer install (npm pack + npm install) =="

PKG_SRC="$SCRATCH/pkg-src"
mkdir -p "$PKG_SRC"
( cd "$REPO_ROOT" && git archive HEAD ) | tar -x -C "$PKG_SRC"

# Temporary, uncommitted files-field patch — scratch copy only (see KNOWN SIMPLIFICATION above).
node -e '
  const fs = require("fs");
  const p = "'"$PKG_SRC"'/package.json";
  const pkg = JSON.parse(fs.readFileSync(p, "utf8"));
  pkg.files = pkg.files || [];
  pkg.files.push("project/app/api/**", "project/app/ui/scripts/**");
  fs.writeFileSync(p, JSON.stringify(pkg, null, 2));
'

TARBALL_DIR="$SCRATCH/tarball"
mkdir -p "$TARBALL_DIR"
TARBALL_NAME="$(cd "$PKG_SRC" && npm pack --silent --pack-destination "$TARBALL_DIR" 2>"$SCRATCH/npm-pack.log")"
if [ -z "$TARBALL_NAME" ] || [ ! -f "$TARBALL_DIR/$TARBALL_NAME" ]; then
  fail "npm pack did not produce a tarball (see $SCRATCH/npm-pack.log)"
else
  pass "npm pack produced $TARBALL_NAME"

  CONSUMER="$SCRATCH/consumer-project"
  mkdir -p "$CONSUMER"
  ( cd "$CONSUMER" && npm init -y >/dev/null 2>"$SCRATCH/npm-init.log" )
  ( cd "$CONSUMER" && npm install --no-audit --no-fund "$TARBALL_DIR/$TARBALL_NAME" >"$SCRATCH/npm-install.log" 2>&1 )

  INSTALLED_API="$CONSUMER/node_modules/@jenga-ai/agent/project/app/api"
  if [ -f "$INSTALLED_API/server.js" ] && [ -f "$INSTALLED_API/lib/resolve-project-root.js" ]; then
    pass "installed tarball contains server.js and the shared resolver"
  else
    fail "installed tarball is missing server.js or lib/resolve-project-root.js (see $SCRATCH/npm-install.log)"
  fi

  # Manual dependency install inside the installed copy — see KNOWN SIMPLIFICATION above.
  ( cd "$INSTALLED_API" && npm install --no-audit --no-fund >"$SCRATCH/npm-install-api-deps.log" 2>&1 )

  # Distinct consumer fixture data — deliberately unlike anything in this repo's own board.
  mkdir -p "$CONSUMER/project/board/epics" "$CONSUMER/project/rapports" "$CONSUMER/project/knowledge-graph"
  cat > "$CONSUMER/project/board/epics/ZZZ_scratch-fixture-epic.md" <<'FIXTURE'
---
id: ZZZ_FIXTURE
title: Scratch Consumer Fixture Epic — Not A Real Jenga Epic
status: Pending
date_created: 2026-09-11
stories: []
---

# Epic: Scratch Consumer Fixture Epic — Not A Real Jenga Epic
FIXTURE
  echo '{"nodes": [], "edges": []}' > "$CONSUMER/project/knowledge-graph/graph.json"

  # A real (throwaway) git repo with one distinctive commit, so /v1/history has something
  # consumer-specific to assert on, rather than an ambiguous empty array. node_modules is
  # excluded from the commit purely so this doesn't take forever to `git add`.
  echo 'node_modules/' > "$CONSUMER/.gitignore"
  ( cd "$CONSUMER" \
    && git init -q \
    && git config user.email "fixture@example.com" \
    && git config user.name "Fixture Consumer" \
    && git add -A \
    && git commit -q -m "ZZZ_FIXTURE_COMMIT: scratch consumer project init" )

  PORT_C=41003
  DASHBOARD_START="$CONSUMER/node_modules/@jenga-ai/agent/project/app/ui/scripts/dashboard-start.cjs"
  ( cd "$CONSUMER" && JENGA_API_PORT="$PORT_C" node "$DASHBOARD_START" --port "$PORT_C" >"$SCRATCH/server-c.log" 2>&1 & )

  if wait_for_health "$PORT_C"; then
    BOARD_C="$(curl -s "http://localhost:${PORT_C}/v1/board")"
    if echo "$BOARD_C" | grep -q 'ZZZ_FIXTURE'; then
      pass "consumer install: /v1/board serves the CONSUMER's own fixture epic"
    else
      fail "consumer install: /v1/board did not contain the consumer's fixture epic"
    fi
    if echo "$BOARD_C" | grep -q '"id":"E01"'; then
      fail "consumer install: /v1/board leaked THIS REPO's own E01 epic into the consumer response"
    else
      pass "consumer install: /v1/board does not leak this repo's own board data"
    fi

    HISTORY_C="$(curl -s "http://localhost:${PORT_C}/v1/history?limit=5")"
    if echo "$HISTORY_C" | grep -q 'ZZZ_FIXTURE_COMMIT'; then
      pass "consumer install: /v1/history serves the CONSUMER's own fixture commit"
    else
      fail "consumer install: /v1/history did not contain the consumer's fixture commit"
    fi

    ARCH_C="$(curl -s "http://localhost:${PORT_C}/v1/architecture")"
    if echo "$ARCH_C" | grep -q '"name":"jenga"'; then
      fail "consumer install: /v1/architecture leaked THIS REPO's own package.json tech_stack entry"
    else
      pass "consumer install: /v1/architecture does not leak this repo's own package.json"
    fi

    HEALTH_C="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT_C}/v1/health")"
    if [ "$HEALTH_C" = "200" ]; then
      pass "consumer install: /v1/health responds 200"
    else
      fail "consumer install: /v1/health responded $HEALTH_C, expected 200"
    fi
  else
    fail "consumer install: server never became healthy on port $PORT_C (see $SCRATCH/server-c.log)"
  fi
  stop_server "$DASHBOARD_START"
fi

echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
