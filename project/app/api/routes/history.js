/**
 * @file project/app/api/routes/history.js
 * GET /history — merged git commits + rapport files, sorted by date desc
 * Query params:
 *   ?limit=N          — return first N items
 *   ?type=git_commit|rapport — filter by type
 */

const { Router } = require('express');
const { readGitLog } = require('../parsers/git-log');
const { readRapports } = require('../parsers/rapports');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');

const router = Router();

router.get('/', async (req, res) => {
  const { limit, type } = req.query;

  if (limit !== undefined && (isNaN(Number(limit)) || Number(limit) < 1)) {
    return res
      .status(400)
      .json(
        errorResponse(ERROR_CODES.INVALID_QUERY_PARAM, '`limit` must be a positive integer')
      );
  }
  if (type !== undefined && !['git_commit', 'rapport'].includes(type)) {
    return res
      .status(400)
      .json(
        errorResponse(ERROR_CODES.INVALID_QUERY_PARAM, '`type` must be git_commit or rapport')
      );
  }

  try {
    const [commits, rapports] = await Promise.all([readGitLog(), readRapports()]);
    let items = [...commits, ...rapports];

    items.sort((a, b) => {
      const da = new Date(a.date || 0).getTime();
      const db = new Date(b.date || 0).getTime();
      return db - da;
    });

    if (type) items = items.filter((i) => i.type === type);
    if (limit) items = items.slice(0, Number(limit));

    res.json(successResponse(items));
  } catch (err) {
    console.error('[history] error:', err.message);
    res.status(500).json(errorResponse(ERROR_CODES.INTERNAL_ERROR, err.message));
  }
});

module.exports = router;
