/**
 * lib/commands/sync.js — `jenga sync [--dry-run]` (E26_S11_T03)
 *
 * The non-interactive post-upgrade command. It brings `.claude/`, `.agents/`, the Copilot files and the
 * Jenga block in `CLAUDE.md` / `AGENTS.md` in line with the installed `@jenga-ai/agent`, by calling the
 * same `syncConsumer` that `scripts/postinstall.js` calls. This file contains no mirror or generator
 * logic of its own: argument parsing, the refuse-inside-the-package guard, output and the exit code.
 *
 * Unlike postinstall it is unconditional (no `.jenga-version` gate), so it is also the recovery path when
 * npm or pnpm blocked the lifecycle script. It never runs the interactive `jenga init` wizard, never
 * modifies `jenga.cli.json`, and never touches text outside the JENGA markers or consumer-owned skills.
 *
 * `--dry-run` prints what would change and writes nothing in the consumer tree.
 *
 * Exit code: 0 on success (including a no-op), 1 when a step failed, when run inside the package itself,
 * or on an unknown argument. The code is set through `process.exitCode` (never `process.exit`) so piped
 * output is not truncated; the returned object carries it too.
 *
 * ESM, Node built-ins only.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { syncConsumer, readPackageInfo } from '../sync.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Default package root: this file lives at <package>/lib/commands/sync.js. */
const DEFAULT_PACKAGE_ROOT = path.join(__dirname, '..', '..');

export const SYNC_USAGE = [
  'Usage: jenga sync [--dry-run]',
  '',
  'Bring this project in line with the installed @jenga-ai/agent: mirror skills/ and agents/ into',
  '.claude/ and .agents/, regenerate the skill allow-list, write the Copilot files and regenerate the',
  'Jenga block in CLAUDE.md and AGENTS.md. Non-interactive and idempotent.',
  '',
  'Options:',
  '  --dry-run   Print what would change and write nothing',
  '  --help, -h  Print this help message',
].join('\n');

const ACTION_VERB = {
  added: 'add',
  overwritten: 'overwrite',
  removed: 'remove',
  regenerated: 'regenerate',
  created: 'create',
  migrated: 'migrate',
  'hooks-registered': 'register hooks in',
  'settings-updated': 'update settings in',
  'checklist-ids-added': 'add required checklist ids to',
};

function readRecordedVersion(consumerRoot) {
  try {
    return fs.readFileSync(path.join(consumerRoot, '.jenga-version'), 'utf8').trim() || null;
  } catch (_) {
    return null;
  }
}

/**
 * @param {string[]} args
 * @param {object}   [opts]
 * @param {string}   [opts.packageRoot] Installed package root (default: this file's own package).
 * @param {string}   [opts.targetRoot]  Consumer project root (default: process.cwd()).
 * @param {function} [opts.log]         Output sink (default: console.log). Test seam.
 * @returns {Promise<{exitCode: number, result?: object}>}
 */
export async function runSync(args = [], opts = {}) {
  const packageRoot = opts.packageRoot || DEFAULT_PACKAGE_ROOT;
  const consumerRoot = opts.targetRoot || process.cwd();
  const log = typeof opts.log === 'function' ? opts.log : console.log;

  const finish = (exitCode, result) => {
    if (exitCode) process.exitCode = exitCode;
    return { exitCode, ...(result ? { result } : {}) };
  };

  if (args.includes('--help') || args.includes('-h')) {
    log(SYNC_USAGE);
    return finish(0);
  }
  const unknown = args.filter((a) => a !== '--dry-run');
  if (unknown.length > 0) {
    log(`Unknown argument${unknown.length > 1 ? 's' : ''} for jenga sync: ${unknown.join(' ')}\n`);
    log(SYNC_USAGE);
    return finish(1);
  }
  const dryRun = args.includes('--dry-run');

  const recorded = readRecordedVersion(consumerRoot);
  log(`\njenga sync${dryRun ? ' --dry-run — nothing will be written' : ''}`);
  log(`  Package version  : ${readPackageInfo(packageRoot).version}`);
  log(`  Recorded version : ${recorded ?? '(none — .jenga-version not found)'}`);
  log(`  Consumer root    : ${consumerRoot}\n`);

  let result;
  try {
    // Ask about the opt-in allow rules only with a person at a terminal, never in CI or a pipe (E100_S03_T07).
    const interactive = !dryRun && Boolean(process.stdin.isTTY && process.stdout.isTTY) && !process.env.CI;
    result = syncConsumer({ packageRoot, consumerRoot, dryRun, interactive, log });
  } catch (e) {
    log(`\n  ✗ jenga sync failed: ${e.message}`);
    return finish(1);
  }

  if (result.skipped === 'inside-package') {
    log('\n  ✗ jenga sync refused: the working directory is the @jenga-ai/agent package itself.');
    log('    Run it from a project that has installed the package. Nothing was written.\n');
    return finish(1, result);
  }

  if (dryRun) {
    if (result.changes.length === 0) {
      log('\n  ✓ Nothing to do. Already in line with the installed version.');
    } else {
      log(`\n  Pending changes (${result.changes.length}):`);
      for (const c of result.changes) {
        log(`    would ${ACTION_VERB[c.action] || c.action}  ${c.path}`);
      }
    }
    log('\n──────────────────────────────────────────────────────');
    log(`  Dry run: ${result.changes.length} change(s) pending, nothing written`);
    log('──────────────────────────────────────────────────────\n');
  } else {
    log('\n──────────────────────────────────────────────────────');
    log(`  Summary: ${result.copied} file(s) copied, ${result.skippedFiles} skipped, ${result.deleted} stale file(s) removed`);
    log(result.changed === 0
      ? `  ✓ Nothing changed — already in line with ${result.packageVersion}`
      : `  ✓ ${result.changed} file(s) changed; .jenga-version is ${result.packageVersion}`);
    log('──────────────────────────────────────────────────────\n');
  }

  for (const w of result.warnings || []) log(`  ⚠  ${w}`);
  if (!result.ok) {
    for (const f of result.failures) log(`  ✗ ${f.step}: ${f.message}`);
    log('');
    return finish(1, result);
  }
  return finish(0, result);
}

export default { runSync, SYNC_USAGE };
