/**
 * @file project/app/api/routes/pipeline.js
 * GET /v1/pipeline - which stages of the Jenga pipeline currently have work (epic E92, E92_S04_T02).
 *
 * Nothing is derived here: scripts/pipeline-stage.sh owns the stage rule and its counts. This route locates it
 * (locateAgentScript, the same three install layouts as /v1/progress), runs it with `--root <project root>` and
 * returns its JSON untouched as `data` (schema_version, stages, active, idle, skipped).
 */

'use strict';

const path = require('path');
const { Router } = require('express');
const { execFile } = require('child_process');
const { successResponse, errorResponse } = require('../response');
const { ERROR_CODES } = require('../types');
const { resolveProjectRoot } = require('../lib/resolve-project-root');
const { locateAgentScript } = require('../lib/run-board-progress');

const SCRIPT_NAME = 'pipeline-stage.sh';
const DEFAULT_TIMEOUT_MS = 30000;
const MAX_BUFFER = 8 * 1024 * 1024;

/** Run the script for one project root and resolve with its parsed JSON; rejects with an explanatory Error. */
function runPipelineStage({ projectRoot, fallbackDir, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const root = projectRoot || resolveProjectRoot();
  const script = locateAgentScript(SCRIPT_NAME, { projectRoot: root, fallbackDir });
  if (!script) {
    return Promise.reject(new Error(
      `${SCRIPT_NAME} not found; looked in ${path.join(root, 'scripts')}, ` +
      `${path.join(root, 'node_modules', '@jenga-ai', 'agent', 'scripts')} and the monorepo scripts directory`
    ));
  }
  return new Promise((resolve, reject) => {
    execFile(
      'bash',
      [script, '--root', root],
      { env: { ...process.env, JENGA_PROJECT_ROOT: root }, timeout: timeoutMs, maxBuffer: MAX_BUFFER, encoding: 'utf8' },
      (err, stdout, stderr) => {
        const detail = String(stderr || '').trim();
        if (err) {
          const how = err.killed ? `timed out after ${timeoutMs} ms` : `failed (${err.code})`;
          return reject(new Error(`${SCRIPT_NAME} ${how}${detail ? `: ${detail}` : ''}`));
        }
        try {
          return resolve(JSON.parse(stdout));
        } catch (parseErr) {
          return reject(new Error(`${SCRIPT_NAME} printed output that is not JSON: ${parseErr.message}`));
        }
      }
    );
  });
}

/**
 * @param {Object} [runOptions] projectRoot, fallbackDir, timeoutMs; tests only
 * @returns {import('express').Router}
 */
function createPipelineRouter(runOptions = {}) {
  const router = Router();

  router.get('/', async (req, res) => {
    try {
      res.json(successResponse(await runPipelineStage(runOptions)));
    } catch (err) {
      console.error('[pipeline] error:', err.message);
      res.status(500).json(errorResponse(ERROR_CODES.INTERNAL_ERROR, err.message));
    }
  });

  return router;
}

const router = createPipelineRouter();
router.createPipelineRouter = createPipelineRouter;
router.runPipelineStage = runPipelineStage;

module.exports = router;
