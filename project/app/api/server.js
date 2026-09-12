/**
 * @file project/app/api/server.js
 * Jenga AI API server entry point.
 *
 * Usage:
 *   node project/app/api/server.js
 *   JENGA_API_PORT=4000 node project/app/api/server.js
 */

'use strict';

const { resolveProjectRoot } = require('./lib/resolve-project-root');

// Pin the resolved project root as an explicit override *before* any router/parser module loads —
// each parser (board.js, git-log.js, rapports.js, architecture.js, knowledge-graph.js) computes its
// own root via resolveProjectRoot() at its own module-load time, so this must run first.
//
// Deliberately calls resolveProjectRoot() rather than setting a raw `process.cwd()` literal: the
// real launch paths in this repo (root `npm run dashboard:start`/`api:start`, both of which use
// `--prefix project/app`) run with `cwd` set to `project/app` by npm, not the repo root — and
// `project/app` itself has no `project/board` two levels below it (`project/board` is a *sibling*
// of `project/app`). A raw `cwd` override would incorrectly `throw` in that case. Calling
// resolveProjectRoot() here performs the same override-else-walk-up resolution the module already
// does (walk-up from `cwd` correctly finds `project/board` above `project/app`), then pins that
// *resolved* value into the env var — every parser's own subsequent call becomes a cheap env-var
// read instead of repeating the walk, and every parser is guaranteed to agree on the same root even
// if `process.cwd()` changes later in this process's lifetime. If a caller already set an override
// (e.g. a future `jenga dashboard start` CLI subcommand that knows the user's true invocation
// directory more reliably than this process's own `cwd`), this is a no-op — resolveProjectRoot()
// already treats an explicit override as authoritative over any walk-up.
if (!process.env.JENGA_PROJECT_ROOT) {
  process.env.JENGA_PROJECT_ROOT = resolveProjectRoot();
}

const express = require('express');
const cors    = require('cors');

const healthRouter       = require('./routes/health');
const boardRouter        = require('./routes/board');
const historyRouter      = require('./routes/history');
const architectureRouter = require('./routes/architecture');

const { API_VERSION } = require('./response');

const PORT = parseInt(process.env.JENGA_API_PORT || '3001', 10);

const app = express();

// ── Middleware ─────────────────────────────────────────────────────────────────
app.use(cors());
app.use(express.json());

// ── Routes ─────────────────────────────────────────────────────────────────────
app.use('/v1/health',       healthRouter);
app.use('/v1/board',        boardRouter);
app.use('/v1/history',      historyRouter);
app.use('/v1/architecture', architectureRouter);

// ── Fallback routes ────────────────────────────────────────────────────────────
// Registered on demand (not at require-time) so callers that mount additional
// routes on `app` after requiring this module — e.g. dashboard-start.cjs
// serving the built UI — can do so before the catch-all 404 swallows them.
const { errorResponse } = require('./response');
const { ERROR_CODES }   = require('./types');

function attachFallbackRoutes(targetApp, { rootRedirect = true } = {}) {
  if (rootRedirect) {
    targetApp.get('/', (req, res) => res.redirect('/v1/health'));
  }

  targetApp.use((req, res) => {
    res.status(404).json(errorResponse(ERROR_CODES.NOT_FOUND, `Route '${req.path}' not found`));
  });
}

// ── Start ──────────────────────────────────────────────────────────────────────
let server;

if (require.main === module) {
  attachFallbackRoutes(app);
  server = app.listen(PORT, () => {
    console.log(`[jenga-api] v${API_VERSION} listening on port ${PORT}`);
  });
  registerShutdownHandlers(server);
}

// ── Graceful Shutdown ──────────────────────────────────────────────────────────
function registerShutdownHandlers(srv) {
  const FORCE_EXIT_MS = 5000;

  function shutdown(signal) {
    console.log(`[jenga-api] Received ${signal} — shutting down gracefully…`);
    srv.close(() => {
      console.log('[jenga-api] All connections closed. Exiting cleanly.');
      process.exit(0);
    });

    setTimeout(() => {
      console.error('[jenga-api] Forced exit after 5s timeout.');
      process.exit(1);
    }, FORCE_EXIT_MS).unref();
  }

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT',  () => shutdown('SIGINT'));
}

module.exports = { app, registerShutdownHandlers, attachFallbackRoutes };
