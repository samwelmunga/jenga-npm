#!/usr/bin/env node
/**
 * jenga dashboard start
 *
 * Usage:
 *   node scripts/dashboard-start.js [--port <number>] [--api-only] [--open]
 *
 * Starts the Jenga AI API server and serves the built UI from dashboard/dist/. Accepts:
 *   --port <number>   Port to listen on. Also respects JENGA_API_PORT env var; the CLI flag takes
 *                     precedence. An explicit port that is busy is an error (exit 1), never replaced.
 *                     Without either, the first verified-free port from 3001 is bound and its URL printed
 *                     (E47_S08_T03); it is recorded in project/queue/dashboard-port.json for
 *                     `dashboard open`.
 *   --api-only        Serve the API without the UI.
 *   --open            Open the dashboard in the default browser once listening.
 *                     Implies serving the UI. If this project's dashboard is already running, that one
 *                     is opened instead of starting a second.
 */

'use strict';

const path = require('path');
const fs   = require('fs');
const http = require('http');
const { execFile } = require('child_process');

// Shared, dependency-free helpers (root scripts/ ships in the package; same relative depth in the monorepo
// and in node_modules/@jenga-ai/agent/).
const PKG_SCRIPTS = path.resolve(__dirname, '../../../../scripts');
const { listenOnFreePort } = require(path.join(PKG_SCRIPTS, 'find-free-port.cjs'));
const portState = require(path.join(PKG_SCRIPTS, 'dashboard-port-state.cjs'));

// ── Parse CLI flags ───────────────────────────────────────────────────────────
const args = process.argv.slice(2);

// `explicitPort` stays null unless the user asked for a port (--port or JENGA_API_PORT).
function parsePort(raw, label) {
  const p = Number(raw);
  if (!Number.isInteger(p) || p < 1 || p > 65535) {
    console.error(`Error: ${label} must be a valid port number (1-65535), got: ${raw}`);
    process.exit(1);
  }
  return p;
}
let explicitPort = process.env.JENGA_API_PORT ? parsePort(process.env.JENGA_API_PORT, 'JENGA_API_PORT') : null;
let apiOnly = false;
let openInBrowser = false;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    explicitPort = parsePort(args[++i], '--port');
  } else if (args[i] === '--api-only') {
    apiOnly = true;
  } else if (args[i] === '--open') {
    openInBrowser = true;
  }
}

if (apiOnly && openInBrowser) {
  console.error('Error: --api-only cannot be combined with --open');
  process.exit(1);
}

const serveApp = !apiOnly;

// The invoking project's root, where the running dashboard's port is recorded. Null outside a Jenga
// project: the dashboard still starts, it just cannot be found again without a flag.
let projectRoot = null;
try {
  projectRoot = require(path.resolve(__dirname, '../../api/lib/resolve-project-root.js')).resolveProjectRoot();
} catch { /* not inside a Jenga project */ }

function healthy(port, timeoutMs = 2000) {
  return new Promise(resolve => {
    const req = http.get(`http://localhost:${port}/v1/health`, res => {
      res.resume();
      resolve(res.statusCode >= 200 && res.statusCode < 300);
    });
    req.setTimeout(timeoutMs, () => { req.destroy(); resolve(false); });
    req.on('error', () => resolve(false));
  });
}

// ── Optionally patch the app to serve static files ────────────────────────────
const APP_ROOT    = path.resolve(__dirname, '../..');
const DIST_DIR    = path.join(APP_ROOT, 'ui', 'dist');
const SERVER_PATH = path.join(APP_ROOT, 'api', 'server.js');

if (!fs.existsSync(SERVER_PATH)) {
  console.error(`Error: API server not found at ${SERVER_PATH}`);
  console.error('Make sure you are running this script from the repository root.');
  process.exit(1);
}

// ── Load the API server ───────────────────────────────────────────────────────
const { app, registerShutdownHandlers, attachFallbackRoutes } = require(SERVER_PATH);

if (serveApp) {
  const express = require('express');
  if (!fs.existsSync(DIST_DIR)) {
    console.warn(`Warning: dashboard/dist/ not found at ${DIST_DIR}`);
    console.warn('Run "npm run build" inside the dashboard/ directory first.');
  }
  app.use(express.static(DIST_DIR));
  // Fallback to index.html for SPA routing, but leave /v1/* API routes alone
  // so unmatched API paths still get a JSON 404 instead of the SPA shell.
  app.get(/^(?!\/v1\/).*/, (_req, res) => {
    const indexPath = path.join(DIST_DIR, 'index.html');
    if (fs.existsSync(indexPath)) {
      res.sendFile(indexPath);
    } else {
      res.status(404).send('Dashboard not built. Run "npm run build" in dashboard/.');
    }
  });
  // rootRedirect: false — the static middleware above already serves
  // index.html at '/'; the unconditional /v1/health redirect would shadow it.
  attachFallbackRoutes(app, { rootRedirect: false });
} else {
  attachFallbackRoutes(app);
}

// ── Start listening ───────────────────────────────────────────────────────────
function launchBrowser(url) {
  let cmd, cmdArgs;
  switch (process.platform) {
    case 'darwin': cmd = 'open';     cmdArgs = [url]; break;
    case 'win32':  cmd = 'cmd';      cmdArgs = ['/c', 'start', '', url]; break;
    default:       cmd = 'xdg-open'; cmdArgs = [url]; break;
  }
  execFile(cmd, cmdArgs, err => {
    if (err) console.log(`Open your browser at: ${url}`);
  });
}

(async () => {
  // --open on a project whose dashboard is already up: open that one rather than starting a second.
  if (openInBrowser && projectRoot) {
    const running = portState.readState(projectRoot);
    if (running && await healthy(running.port)) {
      console.log(`Dashboard already running at ${running.url}`);
      launchBrowser(running.url);
      return;
    }
  }

  let server, port;
  try {
    ({ server, port } = await listenOnFreePort(app, { explicit: explicitPort, start: portState.DEFAULT_PORT }));
  } catch (err) {
    if (err.code === 'EADDRINUSE') {
      console.error(`Error: port ${explicitPort} is already in use. Stop whatever is using it, or choose another with --port (or omit --port to pick a free one).`);
    } else {
      console.error(`Error: could not start the dashboard: ${err.message}`);
    }
    process.exit(1);
  }

  process.env.JENGA_API_PORT = String(port); // for anything this process spawns
  const url = `http://localhost:${port}`;
  console.log(`Dashboard API running at ${url}`);
  if (serveApp) {
    console.log(`Dashboard app  running at ${url}`);
  }
  if (explicitPort === null && port !== portState.DEFAULT_PORT) {
    console.log(`(port ${portState.DEFAULT_PORT} was busy; using ${port})`);
  }
  if (projectRoot) {
    portState.writeState(projectRoot, { port });
    process.on('exit', () => portState.clearState(projectRoot));
  }
  if (openInBrowser) {
    launchBrowser(url);
  }

  registerShutdownHandlers(server);
})();
