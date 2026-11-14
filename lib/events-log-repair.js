/**
 * lib/events-log-repair.js - classify and repair a legacy array-shaped event log (E75_S02_T01)
 *
 * Why this exists
 * ───────────────
 * `project/logs/events.json` is JSONL since E75_S01_T02 (one JSON value per line, so a line-based
 * `merge=union` driver can keep both sides of a concurrent append). A project installed before that
 * change still holds the old single JSON array, and `scripts/events-append.sh` refuses it
 * ("events.json is array-shaped, not JSONL", exit 4). `scripts/events-log-migrate.sh` converts such a
 * file safely (verified before writing, idempotent, locked, atomic rename) but nothing called it for
 * an existing install.
 *
 * This module is the one shared place that decides what state the log is in and, for an array,
 * runs that script. Its two callers share it so neither duplicates the classification:
 *
 *   - `scripts/postinstall.js`   migrates an array automatically, without a prompt (the script's own
 *                                verification is the safeguard) and never fails the install.
 *   - `lib/commands/doctor.js`   lists an array, asks for an explicit yes, and only then migrates.
 *
 * Decisions
 * ─────────
 *   - The conversion is NOT reimplemented here. The migration is `scripts/events-log-migrate.sh`,
 *     spawned from the installed package (`packageRoot`), never from the consumer tree.
 *   - `classifyEventsLog` reads the file once, parses it at most once, and never writes.
 *   - Only `array` is ever acted on. `missing`, `empty`, `jsonl` and `other` are left byte-for-byte
 *     untouched (a file that is neither an array nor JSONL is the migration script's exit 2 and is
 *     refused there too; this module does not even try).
 *   - Python 3 is required by the migration script. If it is missing the script exits 4 with its own
 *     message, which is returned unchanged for the caller to print.
 *
 * ESM, Node built-ins only - matches `lib/postinstall-manifest.js`.
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Default package root: this file lives at <package>/lib/events-log-repair.js. */
const DEFAULT_PACKAGE_ROOT = path.join(__dirname, '..');

/** States `classifyEventsLog` can report. */
export const STATES = Object.freeze(['missing', 'empty', 'jsonl', 'array', 'other']);

/** Absolute path of the shared event log under a project root. */
export function eventsLogPath(root) {
  return path.join(root, 'project', 'logs', 'events.json');
}

/**
 * Classify `<root>/project/logs/events.json`. Read-only.
 *
 * @param {string} root  Consumer (project) root.
 * @returns {{state: 'missing'|'empty'|'jsonl'|'array'|'other', path: string, count?: number, reason?: string}}
 *   `count` is the element count for `array` and the record count for `jsonl`.
 */
export function classifyEventsLog(root) {
  const file = eventsLogPath(root);

  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    if (e && e.code === 'ENOENT') return { state: 'missing', path: file };
    return { state: 'other', path: file, reason: `unreadable (${(e && e.code) || (e && e.message)})` };
  }

  if (!text.trim()) return { state: 'empty', path: file };

  if (text.trimStart()[0] === '[') {
    let value;
    try {
      value = JSON.parse(text);
    } catch (e) {
      return { state: 'other', path: file, reason: `not valid JSON (${e.message})` };
    }
    if (!Array.isArray(value)) return { state: 'other', path: file, reason: 'top-level value is not an array' };
    return { state: 'array', path: file, count: value.length };
  }

  let count = 0;
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i += 1) {
    if (!lines[i].trim()) continue;
    try {
      JSON.parse(lines[i]);
    } catch (e) {
      return { state: 'other', path: file, reason: `neither a JSON array nor JSONL (line ${i + 1}: ${e.message})` };
    }
    count += 1;
  }
  return { state: 'jsonl', path: file, count };
}

/**
 * Run `scripts/events-log-migrate.sh` on `file`.
 *
 * @param {string} file
 * @param {object} [opts]
 * @param {string} [opts.packageRoot]  Installed package root (default: this file's own package).
 * @param {string} [opts.scriptPath]   Override the migration script. Test seam only.
 * @returns {{exitCode: number, stdout: string, stderr: string}}
 */
export function runEventsLogMigration(file, opts = {}) {
  const packageRoot = opts.packageRoot || DEFAULT_PACKAGE_ROOT;
  const script = opts.scriptPath || path.join(packageRoot, 'scripts', 'events-log-migrate.sh');

  if (!fs.existsSync(script)) {
    return { exitCode: 4, stdout: '', stderr: `events-log-migrate: ${script} not found\n` };
  }

  const res = spawnSync('bash', [script, file], { encoding: 'utf8' });
  if (res.error) {
    return { exitCode: 4, stdout: '', stderr: `events-log-migrate: could not run ${script} (${res.error.message})\n` };
  }
  // A signal-terminated child has a null status; treat it as the script's runtime-failure code.
  const exitCode = typeof res.status === 'number' ? res.status : 4;
  return { exitCode, stdout: res.stdout || '', stderr: res.stderr || '' };
}

/**
 * Classify the log and, only when it is array-shaped, migrate it.
 *
 * @param {string} root
 * @param {object} [opts]  See `runEventsLogMigration`.
 * @returns {{state: string, path: string, count?: number, reason?: string,
 *            attempted: boolean, migrated: boolean, exitCode?: number, stdout?: string, stderr?: string}}
 *   `attempted` is true only when the migration script was run; `migrated` only when it exited 0 on
 *   an array. Anything else leaves the file as it was.
 */
export function repairEventsLog(root, opts = {}) {
  const found = classifyEventsLog(root);
  if (found.state !== 'array') return { ...found, attempted: false, migrated: false };

  const run = runEventsLogMigration(found.path, opts);
  return { ...found, attempted: true, migrated: run.exitCode === 0, ...run };
}

export default { eventsLogPath, classifyEventsLog, runEventsLogMigration, repairEventsLog };
