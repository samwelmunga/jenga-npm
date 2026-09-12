/**
 * @file project/app/api/lib/resolve-project-root.js
 *
 * Resolves the invoking (consumer) project's root directory for the dashboard API, so that
 * `project/app/api/parsers/*.js` never has to compute its data root via a fixed
 * `path.resolve(__dirname, '../../../...')` climb — the same defect pattern `E46_S01` already fixed
 * for `/init` (see `skills/init/scripts/init.sh`'s `PKG_ROOT` idiom and
 * `lib/generate-agent-context.js`'s `realpathSync` symlink-safe comparison). A `__dirname` climb only
 * ever resolves correctly when this module runs from this monorepo's own checkout; once mirrored into
 * a real consumer's `node_modules/@jenga-ai/agent/`, climbing a fixed number of levels lands inside or
 * above `node_modules`, never at the consuming project's own root.
 *
 * Resolution order:
 *   1. Explicit override — the `JENGA_PROJECT_ROOT` env var. This is the primary mechanism for the
 *      real npm-consumer case: the dashboard's own launch path (`dashboard-start.cjs` /
 *      `dashboard-open.cjs` / `server.js`) already knows the invoking `cwd` and can set this before
 *      the parsers ever load.
 *   2. Walk up from `cwd` (default `process.cwd()`) looking for a `project/board` directory — the
 *      marker every Jenga-initialized project has (see `/init`'s scaffold) — bounded to a generous
 *      but finite number of parent levels.
 *   3. Fail loudly. Never silently fall back to `__dirname`, `cwd` itself, or `null` — an unresolved
 *      project root is always a thrown `Error` with a descriptive message naming both the override
 *      var and the path that was walked.
 *
 * Both the override path and every step of the walk-up are resolved through `fs.realpathSync`, so a
 * symlinked invocation path (macOS `/tmp`/`$TMPDIR`, `npm link`, a symlinked home directory — the same
 * bug class `E46_S01` fixed) does not break resolution.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const OVERRIDE_ENV_VAR = 'JENGA_PROJECT_ROOT';
const PROJECT_MARKER = path.join('project', 'board');
const MAX_WALK_LEVELS = 20;

/**
 * @param {string} dir absolute, already-realpath'd directory
 * @returns {boolean} true if `dir/project/board` exists and is a directory
 */
function hasProjectMarker(dir) {
  try {
    return fs.statSync(path.join(dir, PROJECT_MARKER)).isDirectory();
  } catch {
    return false;
  }
}

/**
 * Resolve an absolute, symlink-free directory path, throwing a descriptive error (not a raw ENOENT)
 * if it doesn't exist.
 * @param {string} label human-readable label used in the error message
 * @param {string} rawPath the path as provided (env var value or cwd)
 * @returns {string}
 */
function realpathOrThrow(label, rawPath) {
  const resolved = path.resolve(rawPath);
  try {
    return fs.realpathSync(resolved);
  } catch (err) {
    throw new Error(
      `[resolve-project-root] ${label} "${rawPath}" (resolved to "${resolved}") does not exist: ${err.message}`
    );
  }
}

/**
 * Determine the invoking consumer project's root directory.
 *
 * @param {Object} [options]
 * @param {string} [options.cwd] working directory to resolve/walk from (defaults to `process.cwd()`)
 * @param {NodeJS.ProcessEnv} [options.env] environment to read the override from (defaults to `process.env`)
 * @returns {string} absolute, symlink-resolved path to the project root
 * @throws {Error} if no project root can be determined (fail loudly — never returns a wrong/empty path)
 */
function resolveProjectRoot({ cwd = process.cwd(), env = process.env } = {}) {
  // 1. Explicit override.
  const override = env && env[OVERRIDE_ENV_VAR];
  if (override) {
    const resolvedOverride = realpathOrThrow(`${OVERRIDE_ENV_VAR}`, override);
    if (!fs.statSync(resolvedOverride).isDirectory()) {
      throw new Error(
        `[resolve-project-root] ${OVERRIDE_ENV_VAR} "${override}" (resolved to "${resolvedOverride}") is not a directory.`
      );
    }
    return resolvedOverride;
  }

  // 2. Walk up from cwd looking for a project/board marker. realpath the starting point once so
  // every subsequent path.dirname() step stays symlink-free.
  let startDir;
  try {
    startDir = fs.realpathSync(path.resolve(cwd));
  } catch (err) {
    throw new Error(
      `[resolve-project-root] cwd "${cwd}" does not exist: ${err.message}. ` +
        `Set ${OVERRIDE_ENV_VAR} to your project's root directory instead.`
    );
  }

  let dir = startDir;
  for (let i = 0; i < MAX_WALK_LEVELS; i++) {
    if (hasProjectMarker(dir)) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) break; // reached filesystem root
    dir = parent;
  }

  // 3. Fail loudly.
  throw new Error(
    `[resolve-project-root] Could not locate a project root (looked for a "${PROJECT_MARKER}" ` +
      `directory) walking up from "${startDir}" (${MAX_WALK_LEVELS} levels). ` +
      `Set the ${OVERRIDE_ENV_VAR} environment variable to your project's root directory, or run ` +
      `the dashboard from inside a Jenga-initialized project.`
  );
}

module.exports = { resolveProjectRoot, OVERRIDE_ENV_VAR, PROJECT_MARKER, MAX_WALK_LEVELS };
