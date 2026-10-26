/**
 * @file project/app/api/routes/security.js
 * GET / — security aggregate (findings, events, config) from the security parser,
 * no query params — matches GET /v1/rapports' bulk-fetch precedent.
 */

const { Router } = require('express');
const { readSecurity } = require('../parsers/security');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');

const router = Router();

router.get('/', async (req, res) => {
  try {
    const security = await readSecurity();
    res.json(successResponse(security));
  } catch (err) {
    console.error('[security] parse error:', err.message);
    res.status(500).json(errorResponse(ERROR_CODES.PARSE_ERROR, err.message));
  }
});

module.exports = router;
