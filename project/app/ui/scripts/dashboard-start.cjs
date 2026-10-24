#!/usr/bin/env node
/**
 * jenga dashboard start
 *
 * Usage:
 *   node scripts/dashboard-start.js [--port <number>] [--api-only] [--open]
 *
 * Starts the Jenga AI API server and serves the built UI from dashboard/dist/. Accepts:
 *   --port <number>   Port to listen on (default: 3001). Also respects
 *                     JENGA_API_PORT env var. CLI flag takes precedence.
 *   --api-only        Serve the API without the UI.
 *   --open            Open the dashboard in the default browser once listening.
 *                     Implies serving the UI.
 */

'use strict';

const path = require('path');
const fs   = require('fs');
const { execFile } = require('child_process');

// ── Parse CLI flags ───────────────────────────────────────────────────────────
const args = process.argv.slice(2);

let port = parseInt(process.env.JENGA_API_PORT || '3001', 10);
let apiOnly = false;
let openInBrowser = false;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    const p = parseInt(args[++i], 10);
    if (isNaN(p) || p < 1 || p > 65535) {
      console.error(`Error: --port must be a valid port number (1-65535), got: ${args[i]}`);
      process.exit(1);
    }
    port = p;
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

// Pass port to the server via env var before requiring it
process.env.JENGA_API_PORT = String(port);

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

const server = app.listen(port, () => {
  const url = `http://localhost:${port}`;
  console.log(`Dashboard API running at ${url}`);
  if (serveApp) {
    console.log(`Dashboard app  running at ${url}`);
  }
  if (openInBrowser) {
    launchBrowser(url);
  }
});

registerShutdownHandlers(server);
