#!/usr/bin/env bash
#
# verify-consumer-install.sh — real-consumer rehearsal for E47_S02_T02 / E47_S01
#
# Verifies that project/app/api/server.js and its 5 parsers (board.js, git-log.js, rapports.js,
# architecture.js, knowledge-graph.js) resolve their data root via
# project/app/api/lib/resolve-project-root.js (E47_S02_T01) — not a fixed __dirname-relative climb —
# and that the dashboard's API + built UI actually ship and run for a real npm consumer (E47_S01),
# against five scenarios, matching the verification bar E46_S01 already set for /init:
#
#   A. SELF-HOSTING — dashboard launched from this repo's own checkout (no env override, pure
#      cwd walk-up) still serves this repo's own board/history/architecture data unchanged.
#   B. SYMLINKED INVOCATION — dashboard launched with cwd reached through a symlink to this repo's
#      own checkout still resolves correctly (same bug class E46_S01 fixed for /init).
#   C. REAL CONSUMER INSTALL — a scratch "package" is `npm pack`ed directly from a throwaway copy
#      of this repo's own git-tracked tree (`git archive HEAD`, unmodified — no scratch patch of
#      any kind) and `npm install`ed into a second scratch "consumer" directory that has its own,
#      distinctly-fixtured `project/board`/`project/rapports`/`project/knowledge-graph`. The
#      dashboard is launched from inside that consumer directory and its API responses must
#      reflect the *consumer's* fixture data, never this repo's own. No manual dependency install
#      step is run inside the installed copy — the consumer's own top-level `npm install` (E47_S01_T03's
#      root `dependencies`) must be sufficient on its own for express/cors/gray-matter to resolve.
#   D. SERVED UI (installed tarball) — `--serve-app` launched against the SAME already-installed
#      consumer copy from Scenario C, with no build step run inside the consumer directory at any
#      point, confirms the UI ships pre-built (E47_S01_T02's `prepack` step) and is servable as-is.
#   E. `jenga dashboard start`/`jenga dashboard open` CLI VERBS (installed tarball, E47_S03) — the
#      SAME already-installed consumer copy from Scenario C is driven through its own installed
#      `bin/jenga.js dashboard start`/`open` CLI entry point (not a direct `node
#      .../dashboard-start.cjs` invocation like Scenarios C/D use) and asserted against the same
#      consumer-fixture-not-leaked checks Scenario C already performs, plus the unknown/missing
#      sub-verb usage-error path. This proves the CLI wiring E47_S03_T01 added inside this
#      monorepo also works end-to-end from a real `npm pack`/`npm install`, serving the actual
#      packaged tarball contents rather than a scratch/dev-mode copy.
#   F. THIS REPO'S OWN SCRIPTS (regression) — `npm run dashboard:start`, `npm run dashboard:open`,
#      and `npm run ui:build` all still exist and run without error from this repo's own checkout
#      (story E47_S01's AC4 — no regression to this monorepo's own internal use).
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
  # Fallback for Scenario E's regression server, which is launched via nested `npm run --prefix`
  # layers rather than a direct absolute `node <path>` call, so its argv may not carry the
  # REPO_ROOT-prefixed absolute path the pattern above expects.
  stop_server "dashboard-start.cjs"
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

# Install project/app's own dev dependencies inside the scratch source copy — this is what a
# maintainer's real checkout already has in place before running `npm publish`/`npm pack`
# themselves (the prepack script below needs project/app/ui's own vite install to actually build
# dist/). This is NOT a package.json patch and NOT a workaround for missing packaging — packing
# itself, and everything below, now runs against the real tracked package.json exactly as a real
# `npm publish` would see it (E47_S01_T01/T02/T03 landed — no scratch `files` patch anymore).
( cd "$PKG_SRC/project/app" && npm install --no-audit --no-fund >"$SCRATCH/npm-install-pkgsrc-app.log" 2>&1 )

TARBALL_DIR="$SCRATCH/tarball"
mkdir -p "$TARBALL_DIR"
# `| tail -1`: the prepack step (E47_S01_T02) now runs a real `vite build` before packing, and
# vite's own progress output goes to stdout alongside npm's own tarball-filename line — even
# under `--silent`, which only suppresses npm's own notices, not a lifecycle script's output.
# `npm pack`'s own stdout contract still ends with exactly the tarball filename on its own final
# line, so taking the last line isolates it from the build noise printed before it.
TARBALL_NAME="$(cd "$PKG_SRC" && npm pack --silent --pack-destination "$TARBALL_DIR" 2>"$SCRATCH/npm-pack.log" | tail -1)"
if [ -z "$TARBALL_NAME" ] || [ ! -f "$TARBALL_DIR/$TARBALL_NAME" ]; then
  fail "npm pack did not produce a tarball (see $SCRATCH/npm-pack.log)"
else
  pass "npm pack produced $TARBALL_NAME"

  CONSUMER="$SCRATCH/consumer-project"
  mkdir -p "$CONSUMER"
  ( cd "$CONSUMER" && npm init -y >/dev/null 2>"$SCRATCH/npm-init.log" )
  ( cd "$CONSUMER" && npm install --no-audit --no-fund "$TARBALL_DIR/$TARBALL_NAME" >"$SCRATCH/npm-install.log" 2>&1 )

  INSTALLED_APP="$CONSUMER/node_modules/@jenga-ai/agent/project/app"
  INSTALLED_API="$INSTALLED_APP/api"
  if [ -f "$INSTALLED_API/server.js" ] && [ -f "$INSTALLED_API/lib/resolve-project-root.js" ]; then
    pass "installed tarball contains server.js and the shared resolver"
  else
    fail "installed tarball is missing server.js or lib/resolve-project-root.js (see $SCRATCH/npm-install.log)"
  fi

  # E47_S01_T02: the prepack build step must have shipped a real, non-empty built dist/ — no
  # build step is ever run inside the consumer directory itself, only at pack time in PKG_SRC.
  INSTALLED_DIST="$INSTALLED_APP/ui/dist"
  if [ -d "$INSTALLED_DIST" ] && [ -f "$INSTALLED_DIST/index.html" ] && [ -n "$(ls -A "$INSTALLED_DIST" 2>/dev/null)" ]; then
    pass "installed tarball contains a non-empty project/app/ui/dist/ (prepack build shipped)"
  else
    fail "installed tarball is missing a built project/app/ui/dist/ (see $SCRATCH/npm-pack.log)"
  fi

  # E47_S01_T03: express/cors/gray-matter must resolve from the consumer's own top-level
  # node_modules (root package.json dependencies) — no manual install inside the installed copy.
  DEPS_RESOLVE_LOG="$SCRATCH/deps-resolve.log"
  if node -e '
      const path = require("path");
      const serverPath = path.join(process.argv[1], "server.js");
      for (const dep of ["express", "cors", "gray-matter"]) {
        require.resolve(dep, { paths: [path.dirname(serverPath)] });
      }
    ' "$INSTALLED_API" >"$DEPS_RESOLVE_LOG" 2>&1; then
    pass "consumer install: express/cors/gray-matter all resolve with no manual dependency install"
  else
    fail "consumer install: express/cors/gray-matter failed to resolve (see $DEPS_RESOLVE_LOG)"
  fi

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

  # ── Scenario D: served UI, against the SAME already-installed consumer copy ────────────
  echo "== Scenario D: served UI (installed tarball, --serve-app, no build step in consumer) =="
  if [ -d "$INSTALLED_DIST" ]; then
    PORT_D=41004
    ( cd "$CONSUMER" && JENGA_API_PORT="$PORT_D" node "$DASHBOARD_START" --port "$PORT_D" --serve-app >"$SCRATCH/server-d.log" 2>&1 & )

    if wait_for_health "$PORT_D"; then
      ROOT_STATUS_D="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT_D}/")"
      if [ "$ROOT_STATUS_D" = "200" ]; then
        pass "served UI: GET / responds 200 from the installed tarball's dist/"
      else
        fail "served UI: GET / responded $ROOT_STATUS_D, expected 200"
      fi

      INDEX_BODY_D="$(curl -s "http://localhost:${PORT_D}/")"
      if echo "$INDEX_BODY_D" | grep -qi '<div id="root"'; then
        pass "served UI: response body looks like the built index.html (has #root mount div)"
      else
        fail "served UI: response body did not look like the built index.html"
      fi

      # /v1/* API routes must still work alongside the static SPA fallback.
      HEALTH_D="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT_D}/v1/health")"
      if [ "$HEALTH_D" = "200" ]; then
        pass "served UI: /v1/health still responds 200 alongside the static SPA fallback"
      else
        fail "served UI: /v1/health responded $HEALTH_D, expected 200"
      fi
    else
      fail "served UI: server never became healthy on port $PORT_D (see $SCRATCH/server-d.log)"
    fi
    stop_server "$DASHBOARD_START"
  else
    fail "served UI: skipped — no installed project/app/ui/dist/ to serve (see Scenario C above)"
  fi
fi

# ── Scenario E: `jenga dashboard start`/`open` CLI verbs (installed tarball, E47_S03) ────────
echo "== Scenario E: 'jenga dashboard start'/'open' via installed CLI (npm pack + npm install) =="

INSTALLED_BIN="$CONSUMER/node_modules/@jenga-ai/agent/bin/jenga.js"
if [ -f "$INSTALLED_BIN" ]; then
  # Missing/unknown sub-verb: must print usage and exit non-zero, never crash or silently no-op.
  if ( cd "$CONSUMER" && node "$INSTALLED_BIN" dashboard >"$SCRATCH/cli-missing-subverb.log" 2>&1 ); then
    fail "installed CLI: 'jenga dashboard' (no sub-verb) exited 0, expected non-zero"
  else
    if grep -qi "usage" "$SCRATCH/cli-missing-subverb.log"; then
      pass "installed CLI: 'jenga dashboard' (no sub-verb) exits non-zero with a usage message"
    else
      fail "installed CLI: 'jenga dashboard' (no sub-verb) exited non-zero but printed no usage message"
    fi
  fi

  if ( cd "$CONSUMER" && node "$INSTALLED_BIN" dashboard bogus-verb >/dev/null 2>"$SCRATCH/cli-unknown-subverb.log" ); then
    fail "installed CLI: 'jenga dashboard bogus-verb' exited 0, expected non-zero"
  else
    pass "installed CLI: 'jenga dashboard bogus-verb' exits non-zero (unknown sub-verb rejected)"
  fi

  # `jenga dashboard start` — same consumer fixture data Scenario C seeded, driven through the
  # installed CLI entry point rather than a direct node <path>/dashboard-start.cjs invocation.
  PORT_E=41007
  ( cd "$CONSUMER" && node "$INSTALLED_BIN" dashboard start --port "$PORT_E" >"$SCRATCH/server-e.log" 2>&1 & )

  if wait_for_health "$PORT_E"; then
    BOARD_E="$(curl -s "http://localhost:${PORT_E}/v1/board")"
    if echo "$BOARD_E" | grep -q 'ZZZ_FIXTURE'; then
      pass "installed CLI: 'jenga dashboard start' serves the CONSUMER's own fixture epic"
    else
      fail "installed CLI: 'jenga dashboard start' did not serve the consumer's fixture epic"
    fi
    if echo "$BOARD_E" | grep -q '"id":"E01"'; then
      fail "installed CLI: 'jenga dashboard start' leaked THIS REPO's own E01 epic into the response"
    else
      pass "installed CLI: 'jenga dashboard start' does not leak this repo's own board data"
    fi
  else
    fail "installed CLI: 'jenga dashboard start' never became healthy on port $PORT_E (see $SCRATCH/server-e.log)"
  fi
  stop_server "$CONSUMER/node_modules/@jenga-ai/agent/project/app/ui/scripts/dashboard-start.cjs"

  # `jenga dashboard start --serve-app` — confirms the served UI is the installed tarball's own
  # pre-built dist/ (E47_S01_T02's prepack step), reached through the CLI wrapper.
  if [ -d "$INSTALLED_DIST" ]; then
    PORT_E2=41008
    ( cd "$CONSUMER" && node "$INSTALLED_BIN" dashboard start --port "$PORT_E2" --serve-app >"$SCRATCH/server-e2.log" 2>&1 & )
    if wait_for_health "$PORT_E2"; then
      ROOT_STATUS_E2="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT_E2}/")"
      if [ "$ROOT_STATUS_E2" = "200" ]; then
        pass "installed CLI: 'jenga dashboard start --serve-app' serves the installed tarball's dist/"
      else
        fail "installed CLI: 'jenga dashboard start --serve-app' GET / responded $ROOT_STATUS_E2, expected 200"
      fi
    else
      fail "installed CLI: 'jenga dashboard start --serve-app' never became healthy on port $PORT_E2 (see $SCRATCH/server-e2.log)"
    fi
    stop_server "$CONSUMER/node_modules/@jenga-ai/agent/project/app/ui/scripts/dashboard-start.cjs"
  else
    fail "installed CLI: 'jenga dashboard start --serve-app' skipped — no installed dist/ (see Scenario C above)"
  fi

  # `jenga dashboard open` always exits 0 by design — run it against nothing listening so it
  # takes the "not healthy" branch and never actually invokes the OS 'open'/'xdg-open' command,
  # which would pop a real browser window in this harness.
  if ( cd "$CONSUMER" && node "$INSTALLED_BIN" dashboard open --port 41009 >"$SCRATCH/open-e.log" 2>&1 ); then
    pass "installed CLI: 'jenga dashboard open' runs without error"
  else
    fail "installed CLI: 'jenga dashboard open' exited non-zero (see $SCRATCH/open-e.log)"
  fi
else
  fail "installed CLI: bin/jenga.js not found in installed tarball at $INSTALLED_BIN (see Scenario C above)"
fi

# ── Scenario F: this repo's own scripts still work (regression, story AC4) ──────────────────
echo "== Scenario F: this repo's own dashboard:start / dashboard:open / ui:build (regression) =="

PORT_F=41005
( cd "$REPO_ROOT" && JENGA_API_PORT="$PORT_F" npm run dashboard:start >"$SCRATCH/server-f.log" 2>&1 & )
if wait_for_health "$PORT_F"; then
  pass "this repo: 'npm run dashboard:start' launches a healthy server"
else
  fail "this repo: 'npm run dashboard:start' never became healthy on port $PORT_F (see $SCRATCH/server-f.log)"
fi
# Invoked via nested `npm run --prefix` layers rather than a direct absolute `node <path>` call
# (unlike Scenarios A/B/C/D), so the underlying process's argv may carry the script's path in
# relative form. Match on the filename alone — by this point in the script, every earlier
# dashboard-start.cjs instance (Scenarios C, D, and E) has already been explicitly stopped, so
# this is unambiguous in practice.
stop_server "dashboard-start.cjs"

# dashboard:open always exits 0 by design (see project/app/ui/scripts/dashboard-open.cjs) — run
# it with nothing listening on its default port so it takes the "not healthy" branch and never
# actually invokes the OS 'open'/'xdg-open' command, which would pop a real browser window.
if ( cd "$REPO_ROOT" && JENGA_API_PORT=41006 npm run dashboard:open >"$SCRATCH/open-f.log" 2>&1 ); then
  pass "this repo: 'npm run dashboard:open' runs without error"
else
  fail "this repo: 'npm run dashboard:open' exited non-zero (see $SCRATCH/open-f.log)"
fi

if ( cd "$REPO_ROOT" && npm run ui:build >"$SCRATCH/ui-build-f.log" 2>&1 ); then
  pass "this repo: 'npm run ui:build' runs without error"
else
  fail "this repo: 'npm run ui:build' exited non-zero (see $SCRATCH/ui-build-f.log)"
fi

echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
