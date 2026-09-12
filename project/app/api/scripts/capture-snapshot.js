#!/usr/bin/env node
/**
 * @file project/app/api/scripts/capture-snapshot.js
 *
 * E47_S04_T02 — capture step for `j.dashboard --snapshot`.
 *
 * Calls the dashboard API's `/v1/board`, `/v1/history`, and `/v1/architecture` routes exactly once
 * each and writes their combined JSON to a single artifact, consumable by the bundling/inlining
 * step in `E47_S04_T03` (not yet implemented — this script's job ends at "artifact written to
 * disk").
 *
 * ── Why an ad-hoc, in-process server instead of hitting an already-running one ──────────────────
 * This script always spins up its own short-lived, ephemeral (`--port 0` by default) server
 * instance bound to an explicitly resolved project root, rather than assuming or reaching for some
 * already-running dashboard server. An already-running server on a well-known port (e.g. 3001)
 * could be serving an entirely different project root's data — reusing it would silently defeat
 * the "capture the *invoking* project's data, not this repo's" requirement this task exists to
 * satisfy. A freshly spawned, request-scoped instance removes that ambiguity entirely: whatever
 * root this script resolves is unambiguously the root the three routes below will answer for.
 *
 * ── Reuses E47_S02's generalized data-source resolution — does not re-derive it ─────────────────
 * `../lib/resolve-project-root.js`'s `resolveProjectRoot()` (added by E47_S02_T01, wired into
 * `../server.js` and every parser by E47_S02_T02) is the sole path-resolution mechanism used here:
 *   - `--project-root <path>`, if given, is set as the `JENGA_PROJECT_ROOT` env var *before*
 *     calling `resolveProjectRoot()` — i.e. it drives E47_S02's own primary override mechanism
 *     (the same one `server.js`'s own doc comment names as the future `jenga dashboard start` CLI's
 *     intended integration path), rather than inventing a second override convention.
 *   - If `--project-root` is not given, `resolveProjectRoot({ cwd: process.cwd() })` is called with
 *     no override — exactly mirroring `server.js`'s own no-override behavior (walk up from cwd
 *     looking for a `project/board` marker, fail loudly if none is found within the bound).
 *   - Either way, the *resolved* (realpath'd) value is then re-pinned onto `JENGA_PROJECT_ROOT`
 *     before `../server` is required, so `server.js`'s own load-time check
 *     (`if (!process.env.JENGA_PROJECT_ROOT) { ... }`) short-circuits and never re-derives
 *     resolution — every parser downstream agrees with exactly what this script already validated.
 * If `resolveProjectRoot()` ever throws (e.g. no `project/board` marker found, or an explicit
 * `--project-root` that doesn't exist), this script fails loudly with that same descriptive error
 * and never starts a server or writes a partial artifact.
 *
 * ── Output artifact shape (the hand-off contract for E47_S04_T03) ────────────────────────────────
 * A single UTF-8 JSON file:
 * {
 *   "schema_version": 1,
 *   "captured_at": "<ISO 8601 UTC timestamp>",
 *   "project_root": "<absolute, realpath'd project root this snapshot was captured against>",
 *   "routes": {
 *     "board":        <full API envelope from GET /v1/board,        i.e. { data, meta, error }>,
 *     "history":       <full API envelope from GET /v1/history,      i.e. { data, meta, error }>,
 *     "architecture":  <full API envelope from GET /v1/architecture, i.e. { data, meta, error }>
 *   }
 * }
 * Each `routes.<name>` value is the *full* envelope exactly as the route returned it (see
 * `../response.js`'s `successResponse`/`errorResponse` shape) — deliberately not unwrapped to a
 * bare `.data` — so `E47_S04_T03`'s bundler can decide for itself how to feed this into the UI's
 * existing `client.js` request contract (which itself expects `{ data, meta, error }` and throws on
 * a truthy `error`) without this task guessing that choice on its behalf. Since capture already
 * hard-fails on any route error (see below), `error` will always be `null` in a written artifact —
 * it is kept in the shape anyway so the two representations (a live API response vs. a captured
 * one) stay structurally identical.
 *
 * ── Failure behavior ──────────────────────────────────────────────────────────────────────────
 * Any of the following is treated as a hard failure: the ad-hoc server fails to start, a route
 * request errors at the network level, a route responds with a non-2xx status, a route responds
 * with non-JSON, or a route's own JSON envelope carries a truthy `error` field. In every case: the
 * ad-hoc server is closed, a specific, actionable message is printed to stderr (naming the route
 * and the failure reason), the process exits non-zero, and **no artifact is written** — never a
 * partial or silently-empty snapshot.
 *
 * ── Node compatibility ────────────────────────────────────────────────────────────────────────
 * Uses the built-in `http` module rather than global `fetch`, to stay compatible with the root
 * `package.json`'s declared `engines.node: >=14.13.1` floor (global `fetch` only became available
 * unflagged in Node 18).
 *
 * Usage:
 *   node capture-snapshot.js [--project-root <path>] [--out <path>] [--port <n>]
 *
 *   --project-root <path>  Explicit project root override (see above). Default: resolve by
 *                          walking up from the current working directory.
 *   --out <path>           Where to write the combined snapshot JSON. Default:
 *                          "./dashboard-snapshot-data.json" (relative to cwd). Final on-disk
 *                          location for a real `--snapshot` run is E47_S04_T03's call, not this
 *                          script's — it only writes wherever `--out` points.
 *   --port <n>             Port for the ad-hoc capture server. Default: 0 (OS-assigned ephemeral
 *                          port) — deliberately not the dashboard's usual default port, so this
 *                          never collides with (or is confused for) a real already-running server.
 */

'use strict';

const path = require('path');
const http = require('http');
const fs = require('fs');

const ROUTES = ['/v1/board', '/v1/history', '/v1/architecture'];
const ROUTE_KEYS = {
  '/v1/board': 'board',
  '/v1/history': 'history',
  '/v1/architecture': 'architecture',
};

function printUsage() {
  console.log(`Usage: capture-snapshot.js [--project-root <path>] [--out <path>] [--port <n>]

  --project-root <path>  Explicit project root override, passed through to E47_S02's
                          resolveProjectRoot() as the JENGA_PROJECT_ROOT override (the same
                          mechanism server.js itself honors). Defaults to walking up from the
                          current working directory looking for a project/board marker.
  --out <path>            Where to write the combined snapshot JSON.
                          Default: ./dashboard-snapshot-data.json (relative to cwd).
  --port <n>              Port for the ad-hoc capture server instance. Default: 0
                          (OS-assigned ephemeral port).
`);
}

function die(message) {
  console.error(`Error: capture-snapshot: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = { projectRoot: null, out: null, port: 0 };
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    switch (token) {
      case '--project-root':
        args.projectRoot = argv[++i];
        if (!args.projectRoot) die('--project-root requires a value');
        break;
      case '--out':
        args.out = argv[++i];
        if (!args.out) die('--out requires a value');
        break;
      case '--port': {
        const raw = argv[++i];
        const parsed = parseInt(raw, 10);
        if (raw === undefined || isNaN(parsed) || parsed < 0 || parsed > 65535) {
          die(`--port must be a valid port number (0-65535), got: ${raw}`);
        }
        args.port = parsed;
        break;
      }
      case '-h':
      case '--help':
        printUsage();
        process.exit(0);
        break;
      default:
        printUsage();
        die(`unknown argument: ${token}`);
    }
  }
  return args;
}

/**
 * Issue a single GET request to the ad-hoc capture server and parse its JSON envelope. Rejects
 * (rather than resolving with a partial/error payload) on any network error, non-2xx status,
 * non-JSON body, or a truthy `error` field in the parsed envelope — the caller treats a rejection
 * as a hard capture failure.
 */
function fetchJson(port, routePath) {
  return new Promise((resolve, reject) => {
    const req = http.get(
      { host: '127.0.0.1', port, path: routePath, timeout: 15000 },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          body += chunk;
        });
        res.on('end', () => {
          let parsed;
          try {
            parsed = JSON.parse(body);
          } catch (err) {
            reject(
              new Error(
                `${routePath} returned a non-JSON response (status ${res.statusCode}): ${err.message}`
              )
            );
            return;
          }
          if (res.statusCode < 200 || res.statusCode >= 300 || (parsed && parsed.error)) {
            const reason =
              parsed && parsed.error
                ? `${parsed.error.code}: ${parsed.error.message}`
                : `HTTP ${res.statusCode}`;
            reject(new Error(`${routePath} returned an error response — ${reason}`));
            return;
          }
          resolve(parsed);
        });
      }
    );
    req.on('timeout', () => {
      req.destroy(new Error(`${routePath} timed out after 15s — is the capture server reachable?`));
    });
    req.on('error', (err) => {
      reject(new Error(`${routePath} request failed: ${err.message} — is the capture server reachable?`));
    });
  });
}

function startServer(app, port) {
  return new Promise((resolve, reject) => {
    const server = app.listen(port, '127.0.0.1');
    server.once('listening', () => resolve(server));
    server.once('error', (err) => {
      reject(new Error(`could not start the ad-hoc capture server on port ${port}: ${err.message}`));
    });
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  // eslint-disable-next-line global-require
  const { resolveProjectRoot } = require('../lib/resolve-project-root');

  if (args.projectRoot) {
    // Drive E47_S02's own primary override mechanism rather than inventing a second one.
    process.env.JENGA_PROJECT_ROOT = args.projectRoot;
  }

  let resolvedRoot;
  try {
    resolvedRoot = resolveProjectRoot();
  } catch (err) {
    die(err.message);
    return; // unreachable — die() exits — but keeps linters happy about resolvedRoot's usage below
  }

  // Re-pin the *resolved* (realpath'd) value so server.js's own load-time resolution becomes a
  // no-op and every downstream parser agrees with what was just validated here.
  process.env.JENGA_PROJECT_ROOT = resolvedRoot;

  const outPath = path.resolve(args.out || 'dashboard-snapshot-data.json');

  let app;
  try {
    // eslint-disable-next-line global-require
    ({ app } = require('../server'));
  } catch (err) {
    die(`failed to load the dashboard API server: ${err.message}`);
    return;
  }

  let server;
  try {
    server = await startServer(app, args.port);
  } catch (err) {
    die(err.message);
    return;
  }

  const boundPort = server.address().port;

  const routeResults = {};
  try {
    for (const routePath of ROUTES) {
      // Sequential, not parallel: on the first failure we stop immediately with a clear,
      // single-cause error rather than a pile of concurrent rejections to untangle.
      // eslint-disable-next-line no-await-in-loop
      routeResults[ROUTE_KEYS[routePath]] = await fetchJson(boundPort, routePath);
    }
  } catch (err) {
    server.close();
    die(`snapshot capture failed — ${err.message}. No artifact was written.`);
    return;
  }

  server.close();

  const snapshot = {
    schema_version: 1,
    captured_at: new Date().toISOString(),
    project_root: resolvedRoot,
    routes: routeResults,
  };

  try {
    fs.writeFileSync(outPath, `${JSON.stringify(snapshot, null, 2)}\n`);
  } catch (err) {
    die(`failed to write snapshot artifact to ${outPath}: ${err.message}`);
    return;
  }

  console.log(`Snapshot captured: ${outPath}`);
  console.log(`  project_root: ${resolvedRoot}`);
  console.log(`  routes: ${Object.keys(routeResults).join(', ')}`);
}

main().catch((err) => {
  die(err && err.stack ? err.stack : String(err));
});
