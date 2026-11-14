/**
 * @file project/app/api/routes/progress-graph.js
 * GET /v1/progress-graph[?within=<id>] - tasks, states and dependency edges for the progress overlay (epic E92, E92_S06_T05).
 *
 * Sibling of routes/progress-cards.js, but the full `--graph` output (with `tasks[]`, `state`, `blocked_by`,
 * `unlocked_by`, `ready`, `external`) is passed through untouched, plus `labels` and `lang` from
 * scripts/progress-labels-json.sh. Large, so only the overlay requests it; the card never does.
 *
 *   ?within=E01 | E01_S02   restrict to that epic or story (forwarded as `--within <id>`)
 *
 * `within` is validated against the id grammar here, before it reaches the script, and the script is run with
 * execFile (lib/run-board-progress.js), never through a shell. A malformed value is a 400 INVALID_QUERY_PARAM; the
 * script's own exit 2 (an unknown id) is mapped to the same 400.
 *
 *   data: { ...board-progress.sh --graph [--within <id>], labels, lang }
 *   data: { empty: true, labels, lang }                                  for an empty board (script exit 3)
 */

'use strict';

const { Router } = require('express');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');
const { runBoardProgress, runProgressLabels } = require('../lib/run-board-progress');

// Epic (E01) or story (E01_S02) id; task ids and anything else are rejected before the script is run.
const WITHIN_RE = /^E\d+(_S\d+)?$/;
const SCRIPT_USAGE_EXIT = 2;

/**
 * @param {Object} [runOptions] passed to runBoardProgress / runProgressLabels (projectRoot, fallbackDir, timeoutMs); tests only
 * @returns {import('express').Router}
 */
function createProgressGraphRouter(runOptions = {}) {
  const router = Router();

  router.get('/', async (req, res) => {
    const within = req.query.within;
    if (within !== undefined && (typeof within !== 'string' || !WITHIN_RE.test(within))) {
      return res.status(400).json(errorResponse(
        ERROR_CODES.INVALID_QUERY_PARAM,
        'within must be an epic id (E01) or a story id (E01_S02)'
      ));
    }
    try {
      const args = ['--graph'];
      if (within !== undefined) args.push('--within', within);
      const [graph, meta] = await Promise.all([
        runBoardProgress(args, runOptions),
        runProgressLabels(runOptions),
      ]);
      return res.json(successResponse({ ...graph, labels: meta.labels, lang: meta.lang }));
    } catch (err) {
      console.error('[progress-graph] error:', err.message);
      if (err.exitCode === SCRIPT_USAGE_EXIT) {
        return res.status(400).json(errorResponse(ERROR_CODES.INVALID_QUERY_PARAM, err.message));
      }
      return res.status(err.status || 500).json(errorResponse(ERROR_CODES.INTERNAL_ERROR, err.message));
    }
  });

  return router;
}

const router = createProgressGraphRouter();
router.createProgressGraphRouter = createProgressGraphRouter;

module.exports = router;
