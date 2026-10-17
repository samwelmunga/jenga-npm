/**
 * @file project/app/api/routes/ideas.js
 * GET / — structured idea items parsed from project/ideas.md (text, state, boardId, rapport).
 * Read-only: GET only, no write path to ideas.md. Sibling of /v1/board so existing board
 * consumers cannot regress. Returns [] when ideas.md is absent.
 */

const { Router } = require('express');
const { readIdeaItems } = require('../parsers/ideas');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');

const router = Router();

router.get('/', async (req, res) => {
  try {
    const items = await readIdeaItems();
    res.json(successResponse(items));
  } catch (err) {
    console.error('[ideas] parse error:', err.message);
    res.status(500).json(errorResponse(ERROR_CODES.PARSE_ERROR, err.message));
  }
});

module.exports = router;
