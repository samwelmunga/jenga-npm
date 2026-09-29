/**
 * @file project/app/api/routes/todo-warnings.js
 * GET /todo-warnings — active-looking `project/todo.md` lines that don't match the documented
 * `<mission title>: <ref>` shape (most commonly the ref written first instead of last). Such a line
 * is silently invisible to `_queued` promotion (parsers/board.js, kanbanColumns.js) even though a
 * human reader would recognize it as a queued item — this route exists so the dashboard can warn
 * about that gap instead of leaving it unnoticed indefinitely.
 */

const { Router } = require('express');
const { readTodoRefs } = require('../parsers/todo');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');

const router = Router();

router.get('/', (req, res) => {
  try {
    const { unrecognized } = readTodoRefs();
    res.json(successResponse(unrecognized));
  } catch (err) {
    console.error('[todo-warnings] read error:', err.message);
    res.status(500).json(errorResponse(ERROR_CODES.PARSE_ERROR, err.message));
  }
});

module.exports = router;
