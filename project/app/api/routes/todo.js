/**
 * @file project/app/api/routes/todo.js
 * GET /v1/todo - the active `project/todo.md` entries that carry a story or task ref, as
 * `{ref, title, line}` (E47_S10_T01). Read-only: no other verb is exposed and nothing writes todo.md.
 * The board join (title/status) is done by the UI. A missing todo.md yields an empty list.
 */

const { Router } = require('express');
const { listActiveTodoEntries } = require('../parsers/todo');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');

const router = Router();

router.get('/', (req, res) => {
  try {
    res.json(successResponse(listActiveTodoEntries()));
  } catch (err) {
    console.error('[todo] read error:', err.message);
    res.status(500).json(errorResponse(ERROR_CODES.PARSE_ERROR, err.message));
  }
});

module.exports = router;
