/**
 * @file project/app/api/routes/health.js
 * GET /health — server liveness check
 */

const fs = require('fs');
const path = require('path');
const { Router } = require('express');
const { successResponse } = require('../response');
const { API_VERSION } = require('../response');
const { resolveProjectRoot } = require('../lib/resolve-project-root');

const router = Router();

const startTime = Date.now();

/**
 * Resolve the consuming project's name from its own root `package.json`, via the shared
 * `resolveProjectRoot()` (see E47_S02) — never this monorepo's own `package.json` when running
 * against a consumer install.
 *
 * Resolved once at module load, mirroring `startTime` above: the consuming project's own
 * `package.json` does not change for the lifetime of a running server process.
 *
 * Graceful by design (E47_S06_T01): a missing project root, missing/unreadable `package.json`, a
 * parse failure, or a missing/non-string `name` field all resolve to `null` rather than throwing or
 * propagating "undefined" — the health check's liveness contract must never fail because project
 * metadata could not be resolved, and the UI is expected to fall back to a sensible default title
 * when this is `null`.
 *
 * @returns {string|null}
 */
function resolveProjectName() {
  try {
    const root = resolveProjectRoot();
    const pkgRaw = fs.readFileSync(path.join(root, 'package.json'), 'utf8');
    const pkg = JSON.parse(pkgRaw);
    if (typeof pkg.name === 'string' && pkg.name.trim().length > 0) {
      return pkg.name.trim();
    }
    return null;
  } catch {
    return null;
  }
}

const projectName = resolveProjectName();

router.get('/', (req, res) => {
  const uptime = (Date.now() - startTime) / 1000;
  res.json(
    successResponse({
      status: 'ok',
      version: API_VERSION,
      uptime,
      projectName,
    })
  );
});

module.exports = router;
