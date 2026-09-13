/**
 * @file project/app/api/routes/documentation.js
 * GET / — full documentation aggregate (summary/readme/strategy/example), untruncated, no query
 * params or pagination — matches GET /v1/board's bulk-fetch precedent.
 */

const { Router } = require('express');
const { readDocumentation } = require('../parsers/documentation');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');

const router = Router();

router.get('/', async (req, res) => {
  try {
    const documentation = await readDocumentation();
    res.json(successResponse(documentation));
  } catch (err) {
    console.error('[documentation] parse error:', err.message);
    res.status(500).json(errorResponse(ERROR_CODES.PARSE_ERROR, err.message));
  }
});

module.exports = router;
