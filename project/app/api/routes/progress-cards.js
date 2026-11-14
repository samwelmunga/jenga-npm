/**
 * @file project/app/api/routes/progress-cards.js
 * GET /v1/progress-cards - per-epic and per-story progress counts for the Board tab cards (epic E92, E92_S06_T04).
 *
 * Sibling of routes/progress.js: nothing is counted here. scripts/board-progress.sh --graph --counts-only does it
 * (lib/run-board-progress.js runs it) and its JSON is passed through untouched, with one addition, `labels`,
 * from scripts/progress-labels-json.sh (a failing labels script gives `labels: {}`, never a failed route).
 *
 *   data: { schema_version, epics, stories, labels, lang }     (the --counts-only shape: no `tasks`)
 *   data: { empty: true, labels, lang }                         for an empty board (script exit 3)
 */

'use strict';

const { Router } = require('express');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');
const { runBoardProgress, runProgressLabels } = require('../lib/run-board-progress');

/**
 * @param {Object} [runOptions] passed to runBoardProgress / runProgressLabels (projectRoot, fallbackDir, timeoutMs); tests only
 * @returns {import('express').Router}
 */
function createProgressCardsRouter(runOptions = {}) {
  const router = Router();

  router.get('/', async (req, res) => {
    try {
      const [graph, meta] = await Promise.all([
        runBoardProgress(['--graph', '--counts-only'], runOptions),
        runProgressLabels(runOptions),
      ]);
      res.json(successResponse({ ...graph, labels: meta.labels, lang: meta.lang }));
    } catch (err) {
      console.error('[progress-cards] error:', err.message);
      res.status(err.status || 500).json(errorResponse(ERROR_CODES.INTERNAL_ERROR, err.message));
    }
  });

  return router;
}

const router = createProgressCardsRouter();
router.createProgressCardsRouter = createProgressCardsRouter;

module.exports = router;
