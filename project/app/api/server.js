/**
 * @file project/app/api/server.js
 * Jenga AI API server entry point.
 *
 * Usage:
 *   node project/app/api/server.js
 *   JENGA_API_PORT=4000 node project/app/api/server.js
 */

'use strict';

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

// Convenience root redirect
app.get('/', (req, res) => res.redirect('/v1/health'));

// ── 404 fallback ───────────────────────────────────────────────────────────────
const { errorResponse } = require('./response');
const { ERROR_CODES }   = require('./types');

app.use((req, res) => {
  res.status(404).json(errorResponse(ERROR_CODES.NOT_FOUND, `Route '${req.path}' not found`));
});

// ── Start ──────────────────────────────────────────────────────────────────────
let server;

if (require.main === module) {
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

module.exports = { app, registerShutdownHandlers };
