/**
 * @file project/app/api/routes/rapports.js
 * GET / — full rapports aggregate (analysis/problems/tests/summaries/plans/idea), untruncated,
 * no query params or pagination — matches GET /v1/board's bulk-fetch precedent.
 */

const { Router } = require('express');
const { readRapportsFull } = require('../parsers/rapports');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');

const router = Router();

router.get('/', async (req, res) => {
  try {
    const rapports = await readRapportsFull();
    res.json(successResponse(rapports));
  } catch (err) {
    console.error('[rapports] parse error:', err.message);
    res.status(500).json(errorResponse(ERROR_CODES.PARSE_ERROR, err.message));
  }
});

module.exports = router;
