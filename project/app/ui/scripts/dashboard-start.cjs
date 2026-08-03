#!/usr/bin/env node
/**
 * jenga dashboard start
 *
 * Usage:
 *   node scripts/dashboard-start.js [--port <number>] [--serve-app]
 *
 * Starts the JengaAgent API server. Accepts:
 *   --port <number>   Port to listen on (default: 3001). Also respects
 *                     JENGA_API_PORT env var. CLI flag takes precedence.
 *   --serve-app       Also serve the dashboard/dist/ static files from Express.
 */

'use strict';

const path = require('path');
const fs   = require('fs');

// ── Parse CLI flags ───────────────────────────────────────────────────────────
const args = process.argv.slice(2);

let port = parseInt(process.env.JENGA_API_PORT || '3001', 10);
let serveApp = false;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    const p = parseInt(args[++i], 10);
    if (isNaN(p) || p < 1 || p > 65535) {
      console.error(`Error: --port must be a valid port number (1-65535), got: ${args[i]}`);
      process.exit(1);
    }
    port = p;
  } else if (args[i] === '--serve-app') {
    serveApp = true;
  }
}

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
const { app, registerShutdownHandlers } = require(SERVER_PATH);

if (serveApp) {
  const express = require('express');
  if (!fs.existsSync(DIST_DIR)) {
    console.warn(`Warning: dashboard/dist/ not found at ${DIST_DIR}`);
    console.warn('Run "npm run build" inside the dashboard/ directory first.');
  }
  app.use(express.static(DIST_DIR));
  // Fallback to index.html for SPA routing
  app.get('*', (_req, res) => {
    const indexPath = path.join(DIST_DIR, 'index.html');
    if (fs.existsSync(indexPath)) {
      res.sendFile(indexPath);
    } else {
      res.status(404).send('Dashboard not built. Run "npm run build" in dashboard/.');
    }
  });
}

// ── Start listening ───────────────────────────────────────────────────────────
const server = app.listen(port, () => {
  console.log(`Dashboard API running at http://localhost:${port}`);
  if (serveApp) {
    console.log(`Dashboard app  running at http://localhost:${port}`);
  }
});

registerShutdownHandlers(server);
