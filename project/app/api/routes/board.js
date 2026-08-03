/**
 * @file project/app/api/routes/board.js
 * GET /board          — full nested board
 * GET /board/:epicId  — single epic (case-insensitive)
 */

const { Router } = require('express');
const { parseBoard } = require('../parsers/board');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');

const router = Router();

router.get('/', async (req, res) => {
  try {
    const board = await parseBoard();
    res.json(successResponse(board));
  } catch (err) {
    console.error('[board] parse error:', err.message);
    res.status(500).json(errorResponse(ERROR_CODES.PARSE_ERROR, err.message));
  }
});

router.get('/:epicId', async (req, res) => {
  try {
    const board = await parseBoard();
    const id = req.params.epicId.toLowerCase();
    const epic = board.find((e) => e.id && e.id.toLowerCase() === id);
    if (!epic) {
      return res
        .status(404)
        .json(
          errorResponse(
            ERROR_CODES.EPIC_NOT_FOUND,
            `Epic '${req.params.epicId}' not found`
          )
        );
    }
    res.json(successResponse(epic));
  } catch (err) {
    console.error('[board/:epicId] parse error:', err.message);
    res.status(500).json(errorResponse(ERROR_CODES.PARSE_ERROR, err.message));
  }
});

module.exports = router;
