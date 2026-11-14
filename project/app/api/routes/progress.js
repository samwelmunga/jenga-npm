/**
 * @file project/app/api/routes/progress.js
 * GET /v1/progress - status distribution of tasks, stories, epics and the backlog (epic E92, E92_S03_T01).
 *
 * Nothing is counted here: scripts/board-progress.sh does all of it (lib/run-board-progress.js runs it) and each
 * block below is the script's own `counts` / `totals` object, passed through untouched.
 *
 *   data: { schema_version, charts: { tasks, stories, epics, backlog } }
 *     tasks / stories / epics   the matching levels.<level> block of `--all`, or { empty: true } when absent
 *     backlog                   the `levels` of `--backlog` (only the levels that have items), or { empty: true }
 *                               for an empty or missing project/todo.md
 */

'use strict';

const { Router } = require('express');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');
const { runBoardProgress } = require('../lib/run-board-progress');

const EMPTY = Object.freeze({ empty: true });

/** The block for one level of a `--all` result, or the empty marker. */
function levelBlock(result, level) {
  return (result && result.levels && result.levels[level]) || EMPTY;
}

/**
 * @param {Object} [runOptions] passed to runBoardProgress (projectRoot, fallbackDir, timeoutMs); tests only
 * @returns {import('express').Router}
 */
function createProgressRouter(runOptions = {}) {
  const router = Router();

  router.get('/', async (req, res) => {
    try {
      const [all, backlog] = await Promise.all([
        runBoardProgress(['--all'], runOptions),
        runBoardProgress(['--backlog'], runOptions),
      ]);
      res.json(successResponse({
        schema_version: all.schema_version === undefined ? backlog.schema_version : all.schema_version,
        charts: {
          tasks:   levelBlock(all, 'tasks'),
          stories: levelBlock(all, 'stories'),
          epics:   levelBlock(all, 'epics'),
          backlog: backlog.levels || EMPTY,
        },
      }));
    } catch (err) {
      console.error('[progress] error:', err.message);
      res.status(err.status || 500).json(errorResponse(ERROR_CODES.INTERNAL_ERROR, err.message));
    }
  });

  return router;
}

const router = createProgressRouter();
router.createProgressRouter = createProgressRouter;

module.exports = router;
