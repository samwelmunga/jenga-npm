/**
 * @file project/app/api/routes/health.js
 * GET /health — server liveness check
 */

const { Router } = require('express');
const { successResponse } = require('../response');
const { API_VERSION } = require('../response');
const { resolveProjectTitle } = require('../lib/resolve-project-title');

const router = Router();

const startTime = Date.now();

/**
 * The consuming project's name, via the shared resolver (E47_S09_T01): strategy doc, then README
 * H1, then git repo name, then package.json `name`, then a safe default - always a non-empty
 * string, never "undefined". Resolved once at module load (it does not change for the lifetime of
 * a running server process); the resolver never throws.
 */
const projectName = resolveProjectTitle();

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
