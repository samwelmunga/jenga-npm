/**
 * @file project/app/api/routes/health.js
 * GET /health — server liveness check
 */

const { Router } = require('express');
const { successResponse } = require('../response');
const { API_VERSION } = require('../response');

const router = Router();

const startTime = Date.now();

router.get('/', (req, res) => {
  const uptime = (Date.now() - startTime) / 1000;
  res.json(
    successResponse({
      status: 'ok',
      version: API_VERSION,
      uptime,
    })
  );
});

module.exports = router;
