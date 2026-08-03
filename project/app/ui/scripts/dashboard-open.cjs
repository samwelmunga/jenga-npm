#!/usr/bin/env node
/**
 * jenga dashboard open
 *
 * Usage:
 *   node scripts/dashboard-open.js [--port <number>]
 *
 * Performs a health check against the API server, then opens the dashboard
 * URL in the system's default browser. Always exits with code 0.
 *
 *   --port <number>   Port to check / open (default: 3001).
 *                     Also respects JENGA_API_PORT env var.
 */

'use strict';

const http     = require('http');
const { execFile } = require('child_process');

// ── Parse CLI flags ───────────────────────────────────────────────────────────
const args = process.argv.slice(2);

let port = parseInt(process.env.JENGA_API_PORT || '3001', 10);

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    const p = parseInt(args[++i], 10);
    if (!isNaN(p) && p >= 1 && p <= 65535) {
      port = p;
    } else {
      console.error(`Error: --port must be a valid port number (1-65535), got: ${args[i]}`);
      process.exit(0); // still exit 0 per spec
    }
  }
}

const url = `http://localhost:${port}`;

// ── Health check ─────────────────────────────────────────────────────────────
function healthCheck(timeoutMs = 2000) {
  return new Promise(resolve => {
    const req = http.get(`${url}/v1/health`, res => {
      resolve(res.statusCode >= 200 && res.statusCode < 300);
      res.resume();
    });
    req.setTimeout(timeoutMs, () => {
      req.destroy();
      resolve(false);
    });
    req.on('error', () => resolve(false));
  });
}

// ── Open browser ──────────────────────────────────────────────────────────────
function openBrowser(targetUrl) {
  return new Promise(resolve => {
    let cmd, args;
    switch (process.platform) {
      case 'darwin':  cmd = 'open';      args = [targetUrl]; break;
      case 'win32':   cmd = 'cmd';       args = ['/c', 'start', '', targetUrl]; break;
      default:        cmd = 'xdg-open';  args = [targetUrl]; break;
    }

    execFile(cmd, args, err => {
      if (err && err.code === 'ENOENT') {
        console.log(`Open your browser at: ${targetUrl}`);
      } else if (err) {
        console.log(`Open your browser at: ${targetUrl}`);
      }
      resolve();
    });
  });
}

// ── Main ──────────────────────────────────────────────────────────────────────
(async () => {
  const healthy = await healthCheck();

  if (!healthy) {
    console.warn(`⚠ Warning: Dashboard server does not appear to be running at ${url}`);
    console.warn('  Start it with: node project/app/ui/scripts/dashboard-start.cjs');
    console.log(`\nOpen your browser at: ${url}`);
    process.exit(0);
  }

  await openBrowser(url);
  process.exit(0);
})();
