/**
 * @file project/app/api/routes/architecture.js
 * GET /architecture — tech stack and dependency metadata
 */

const { Router } = require('express');
const { parseArchitecture } = require('../parsers/architecture');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');

const router = Router();

router.get('/', async (req, res) => {
  try {
    const arch = await parseArchitecture();
    res.json(successResponse(arch));
  } catch (err) {
    console.error('[architecture] error:', err.message);
    res.status(500).json(errorResponse(ERROR_CODES.INTERNAL_ERROR, err.message));
  }
});

module.exports = router;
