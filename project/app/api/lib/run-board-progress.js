/**
 * @file project/app/api/lib/run-board-progress.js
 * E92_S03_T01 - runs scripts/board-progress.sh for the dashboard API and hands its JSON back untouched.
 *
 * The API never counts anything itself: the script owns the status-to-bucket mapping and the counting, this
 * module only locates it, runs it (execFile, no shell string, with a timeout) and parses what it printed.
 *
 *   locateAgentScript(name, opts)      absolute path of a Jenga script, or null when no layout holds it
 *   runBoardProgress(args, opts)       Promise of the parsed JSON, or { empty: true } on the script's exit 3
 *   BoardProgressError                 thrown for a missing script, exit 1/2, a timeout or unparseable output
 *
 * `locateAgentScript` is exported on its own because E92_S04_T02 reuses it for another script.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const { resolveProjectRoot } = require('./resolve-project-root');

const SCRIPT_NAME = 'board-progress.sh';
const LABELS_SCRIPT_NAME = 'progress-labels-json.sh';
const DEFAULT_TIMEOUT_MS = 30000;
const EMPTY_SCOPE_EXIT = 3;
// board-progress.sh prints the whole board as JSON; a large board stays far below this.
const MAX_BUFFER = 64 * 1024 * 1024;

/** The monorepo checkout's own scripts/ directory, relative to this file (project/app/api/lib -> repo root). */
const MONOREPO_SCRIPTS_DIR = path.resolve(__dirname, '..', '..', '..', '..', 'scripts');

/** Raised when the script cannot be found or does not produce a usable answer; `status` is the HTTP status to send. */
class BoardProgressError extends Error {
  constructor(message, { status = 500, exitCode = null, stderr = '' } = {}) {
    super(message);
    this.name = 'BoardProgressError';
    this.status = status;
    this.exitCode = exitCode;
    this.stderr = stderr;
  }
}

/**
 * The directories searched for an agent script, in order: the project's own scripts/, the installed package's
 * scripts/ (node_modules/@jenga-ai/agent), then the monorepo checkout relative to this file.
 * @param {string} projectRoot
 * @param {string} [fallbackDir] replaces the file-relative monorepo directory (tests only)
 * @returns {string[]}
 */
function scriptDirs(projectRoot, fallbackDir = MONOREPO_SCRIPTS_DIR) {
  return [
    path.join(projectRoot, 'scripts'),
    path.join(projectRoot, 'node_modules', '@jenga-ai', 'agent', 'scripts'),
    fallbackDir,
  ];
}

/**
 * Find a Jenga script by file name across the three install layouts.
 * @param {string} name script file name, e.g. 'board-progress.sh'
 * @param {Object} [options]
 * @param {string} [options.projectRoot] defaults to resolveProjectRoot()
 * @param {string} [options.fallbackDir] replaces the file-relative monorepo scripts directory (tests only)
 * @returns {string|null} absolute path of the first match, or null when none of the layouts holds the script
 */
function locateAgentScript(name, { projectRoot, fallbackDir } = {}) {
  if (typeof name !== 'string' || name === '' || name !== path.basename(name)) {
    throw new Error(`[run-board-progress] script name must be a plain file name, got: ${JSON.stringify(name)}`);
  }
  const root = projectRoot || resolveProjectRoot();
  for (const dir of scriptDirs(root, fallbackDir)) {
    const candidate = path.join(dir, name);
    try {
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch { /* not in this layout */ }
  }
  return null;
}

/**
 * Run board-progress.sh with the given scope arguments and return its parsed JSON.
 * @param {string[]} args scope arguments, e.g. ['--all'] or ['--backlog']
 * @param {Object} [options]
 * @param {string} [options.projectRoot] defaults to resolveProjectRoot()
 * @param {string} [options.fallbackDir] see locateAgentScript
 * @param {number} [options.timeoutMs]
 * @returns {Promise<Object>} the script's JSON, or { empty: true } when the scope is empty (exit 3)
 * @throws {BoardProgressError} missing script, exit 1 or 2, timeout, or output that is not JSON
 */
function runBoardProgress(args, { projectRoot, fallbackDir, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const root = projectRoot || resolveProjectRoot();
  const script = locateAgentScript(SCRIPT_NAME, { projectRoot: root, fallbackDir });
  if (!script) {
    return Promise.reject(new BoardProgressError(
      `${SCRIPT_NAME} not found; looked in ${scriptDirs(root, fallbackDir).join(', ')}`
    ));
  }

  const env = {
    ...process.env,
    JENGA_PROJECT_ROOT: root,
    // The backlog is the todo file of THIS project, never the todo.md of the API process's working directory.
    JENGA_TODO_FILE: path.join(root, 'project', 'todo.md'),
  };

  return new Promise((resolve, reject) => {
    execFile(
      'bash',
      [script, ...args, '--root', root],
      { env, timeout: timeoutMs, maxBuffer: MAX_BUFFER, encoding: 'utf8' },
      (err, stdout, stderr) => {
        const detail = String(stderr || '').trim();
        if (err) {
          if (err.code === EMPTY_SCOPE_EXIT) return resolve({ empty: true });
          const how = err.killed ? `timed out after ${timeoutMs} ms` : `failed (${err.code})`;
          return reject(new BoardProgressError(
            `${SCRIPT_NAME} ${args.join(' ')} ${how}${detail ? `: ${detail}` : ''}`,
            { exitCode: typeof err.code === 'number' ? err.code : null, stderr: detail }
          ));
        }
        try {
          return resolve(JSON.parse(stdout));
        } catch (parseErr) {
          return reject(new BoardProgressError(
            `${SCRIPT_NAME} ${args.join(' ')} printed output that is not JSON: ${parseErr.message}`,
            { stderr: detail }
          ));
        }
      }
    );
  });
}

/**
 * Run scripts/progress-labels-json.sh and return its parsed `{ lang, labels }`. Same location search, timeout and
 * execFile call as runBoardProgress, but never rejects: a missing or failing script, a timeout or output that is
 * not JSON yields `{ lang: <JENGA_PROGRESS_LANG or 'en'>, labels: {} }` so a label problem cannot fail a route.
 * @param {Object} [options] projectRoot, fallbackDir, timeoutMs (as runBoardProgress)
 * @returns {Promise<{lang: string, labels: Object}>}
 */
function runProgressLabels({ projectRoot, fallbackDir, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const root = projectRoot || resolveProjectRoot();
  const lang = process.env.JENGA_PROGRESS_LANG === 'sv' ? 'sv' : 'en';
  const fallback = { lang, labels: {} };
  const script = locateAgentScript(LABELS_SCRIPT_NAME, { projectRoot: root, fallbackDir });
  if (!script) return Promise.resolve(fallback);
  return new Promise(resolve => {
    execFile(
      'bash',
      [script],
      { env: { ...process.env, JENGA_PROJECT_ROOT: root }, timeout: timeoutMs, maxBuffer: MAX_BUFFER, encoding: 'utf8' },
      (err, stdout) => {
        if (err) return resolve(fallback);
        try {
          const parsed = JSON.parse(stdout);
          if (!parsed || typeof parsed.labels !== 'object' || parsed.labels === null) return resolve(fallback);
          return resolve({ lang: typeof parsed.lang === 'string' ? parsed.lang : lang, labels: parsed.labels });
        } catch {
          return resolve(fallback);
        }
      }
    );
  });
}

module.exports = { locateAgentScript, runBoardProgress, runProgressLabels, BoardProgressError, SCRIPT_NAME, LABELS_SCRIPT_NAME, DEFAULT_TIMEOUT_MS };
