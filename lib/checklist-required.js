/**
 * lib/checklist-required.js — report checklist ids shipped scripts require but the effective registry lacks (E99_S04_T03)
 *
 * A thin Node wrapper around `scripts/checklist-required-check.sh`, which holds all the logic: it reads the shipped
 * declaration (`templates/checklist-required-ids.json`), asks `scripts/checklist.sh registry` which registry file is
 * in effect (project instance, else shipped default; one whole file), and prints one line per required id that file
 * lacks. This module runs it from the consumer root and turns the result into `jenga doctor` warning lines.
 *
 * Warning only: it never writes the registry, never throws and never touches an exit code. A failure to check is
 * reported as one line, not as a reason to break `jenga doctor`. Decision `E99_S04_T02` (option 3) keeps doctor
 * read-only; the write lives in the sync-time merge (`E99_S04_T05`, `scripts/checklist-required-merge.sh`).
 *
 * ESM, Node built-ins only — matches `lib/sync-drift.js`.
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

/** Path of the check script inside the package. */
export const CHECK_SCRIPT = path.join('scripts', 'checklist-required-check.sh');

/**
 * The remedy printed under the warning. One constant on purpose, so the wording lives in one place. Since
 * `E99_S04_T05` the sync-time merge (`scripts/checklist-required-merge.sh`, run by postinstall and `jenga sync`)
 * adds the missing ids to an existing instance, so `npx jenga sync` comes first; the `j.checklist` copy stays as
 * the manual alternative.
 */
export const REMEDY_LINES = [
  'Remedy: run npx jenga sync, which adds only the missing required item(s) to this registry, copied from the',
  'shipped default, and changes nothing else. Or copy them by hand from the shipped default (templates/checklists.json',
  'in @jenga-ai/agent) with j.checklist (copy), keeping their fields unchanged. Until then each script named above',
  'fails where it needs the item (foreground-preflight.sh exits 12, so /jenga, j.do and j.dooo stop before dispatching).',
];

/**
 * Run the check script from `consumerRoot`.
 *
 * @param {{packageRoot: string, consumerRoot: string, env?: object}} opts
 * @returns {{state: 'ok'|'missing'|'error', missing: {id: string, requiredBy: string, registry: string}[],
 *            exitCode: number|null, detail?: string}}
 */
export function checkRequiredChecklistIds({ packageRoot, consumerRoot, env = process.env }) {
  const script = path.join(packageRoot, CHECK_SCRIPT);
  if (!fs.existsSync(script)) {
    return { state: 'error', missing: [], exitCode: null, detail: `${script} not found` };
  }
  const run = spawnSync('bash', [script], {
    cwd: consumerRoot,
    env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (run.error) {
    return { state: 'error', missing: [], exitCode: null, detail: run.error.message };
  }
  if (run.status === 0) {
    return { state: 'ok', missing: [], exitCode: 0 };
  }
  if (run.status === 10) {
    const missing = (run.stdout || '')
      .split('\n')
      .map((line) => line.split('\t'))
      .filter((f) => f.length === 4 && f[0] === 'missing')
      .map(([, id, requiredBy, registry]) => ({ id, requiredBy, registry }));
    return { state: 'missing', missing, exitCode: 10 };
  }
  return { state: 'error', missing: [], exitCode: run.status, detail: (run.stderr || '').trim() };
}

/**
 * Warning lines for a check result. Empty when nothing is missing.
 *
 * @param {ReturnType<typeof checkRequiredChecklistIds>} result
 * @returns {string[]}
 */
export function requiredIdsWarnings(result) {
  if (result.state === 'ok') return [];
  if (result.state === 'error') {
    const first = (result.detail || '').split('\n')[0];
    return [
      `  ⚠  Could not check the checklist registry for required item ids` +
        (result.exitCode === null ? '' : ` (exit ${result.exitCode})`) +
        (first ? `: ${first}` : '.'),
    ];
  }
  const registry = result.missing.length > 0 ? result.missing[0].registry : 'none';
  const head = registry === 'none'
    ? `No checklist registry was found, so ${result.missing.length} item id(s) a shipped script requires are missing:`
    : `The checklist registry ${registry} lacks ${result.missing.length} item id(s) a shipped script requires:`;
  const lines = [`  ⚠  ${head}`];
  for (const m of result.missing) lines.push(`       ${m.id} (required by ${m.requiredBy})`);
  for (const r of REMEDY_LINES) lines.push(`     ${r}`);
  return lines;
}

/**
 * Check and print the warning through `log`. Read-only, never throws, never touches an exit code.
 *
 * @returns {ReturnType<typeof checkRequiredChecklistIds>}
 */
export function reportRequiredChecklistIds({ packageRoot, consumerRoot, log = console.log } = {}) {
  let result;
  try {
    result = checkRequiredChecklistIds({ packageRoot, consumerRoot });
  } catch (err) {
    result = { state: 'error', missing: [], exitCode: null, detail: String(err && err.message ? err.message : err) };
  }
  const lines = requiredIdsWarnings(result);
  for (const line of lines) log(line);
  if (lines.length > 0) log('');
  return result;
}

export default { checkRequiredChecklistIds, requiredIdsWarnings, reportRequiredChecklistIds };
