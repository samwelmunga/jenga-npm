/**
 * lib/sync-drift.js — detect a consumer that is out of step with the installed package (E26_S11_T05)
 *
 * When npm or pnpm blocks `scripts/postinstall.js` (not in `allowScripts`, `--ignore-scripts`, ...)
 * nothing tells the user. This module makes the next `jenga status` / `jenga doctor` say so. It is
 * read-only: it never writes, never runs a sync, and its result never changes an exit code.
 *
 * Two checks:
 *   1. Version drift. `<consumer>/.jenga-version` (written by `syncConsumer`) differs from the
 *      installed package's `package.json` version, or does not exist at all (framework files were
 *      never synced). Skipped when the consumer root is the package root, i.e. the dev repo.
 *   2. Skills-list drift. The skill list rendered in the Jenga block of `CLAUDE.md` / `AGENTS.md`
 *      (or of `J-CLAUDE.md` / `J-AGENTS.md` when the J- collision rule put the block there) differs
 *      from the skill directories on disk. A file with no Jenga block is not drift.
 *
 * "On disk" is whatever `generateAgentContext` itself scans, through the same exported helpers
 * (`listSkillNames`, `extractJengaBlock`, `parseSkillNamesFromBlock`), so the comparison cannot
 * disagree with what `jenga sync` would write: `.claude/skills`, else `.agents/skills`. After a sync
 * the two mirrors agree for every package skill, but a consumer's own skill that lives in only one
 * root would otherwise warn forever, however often `jenga sync` ran.
 *
 * ESM, Node built-ins only.
 */

import fs from 'node:fs';
import path from 'node:path';

import { semverCompare, readPackageInfo, samePath } from './sync.js';
import { listSkillNames, extractJengaBlock, parseSkillNamesFromBlock } from './generate-agent-context.js';

/** Agent-context files that carry a Jenga block, in the order `generateAgentContext` writes them. */
const CONTEXT_FILES = ['CLAUDE.md', 'AGENTS.md'];

const FIX = 'Run `npx jenga sync` to bring them in line.';

/** How many differing skill names a warning spells out before it says "and N more". */
const NAMES_SHOWN = 5;

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (_) {
    return null;
  }
}

function detectVersionDrift(packageRoot, consumerRoot) {
  const installed = readPackageInfo(packageRoot).version;
  const raw = readText(path.join(consumerRoot, '.jenga-version'));
  const recorded = raw === null ? null : raw.trim();
  if (recorded === null || recorded === '') return { recorded: null, installed, reason: 'missing' };
  if (semverCompare(installed, recorded) !== 0) return { recorded, installed, reason: 'differs' };
  return null;
}

function detectSkillsDrift(consumerRoot) {
  const onDisk = listSkillNames(consumerRoot);
  if (onDisk === null) return []; // no skills directory at all: nothing to compare the block with
  const expected = new Set(onDisk);

  const drifts = [];
  for (const filename of CONTEXT_FILES) {
    // Where generateAgentContext puts the block: J-<name> when a prior collision created it.
    const jFile = `J-${filename}`;
    const holder = fs.existsSync(path.join(consumerRoot, jFile)) ? jFile : filename;
    const content = readText(path.join(consumerRoot, holder));
    if (content === null) continue;
    const block = extractJengaBlock(content);
    if (block === null) continue; // no Jenga block: not drift

    const listed = new Set(parseSkillNamesFromBlock(block));
    const missing = [...expected].filter((n) => !listed.has(n)).sort();
    const extra = [...listed].filter((n) => !expected.has(n)).sort();
    if (missing.length > 0 || extra.length > 0) drifts.push({ file: holder, missing, extra });
  }
  return drifts;
}

/**
 * @param {object} opts
 * @param {string} opts.packageRoot   Installed package root.
 * @param {string} opts.consumerRoot  Consumer project root.
 * @returns {{versionDrift: boolean, skillsDrift: boolean,
 *            details: {version: null|{recorded: string|null, installed: string, reason: 'missing'|'differs'},
 *                      skills: Array<{file: string, missing: string[], extra: string[]}>}}}
 *   `details.skills[].missing` lists skills on disk but absent from the block, `extra` skills the block
 *   lists that are no longer on disk.
 */
export function detectDrift({ packageRoot, consumerRoot } = {}) {
  const none = { versionDrift: false, skillsDrift: false, details: { version: null, skills: [] } };
  if (!packageRoot || !consumerRoot) return none;
  if (samePath(packageRoot, consumerRoot)) return none; // the dev repo is not a consumer

  const version = detectVersionDrift(packageRoot, consumerRoot);
  const skills = detectSkillsDrift(consumerRoot);
  return {
    versionDrift: version !== null,
    skillsDrift: skills.length > 0,
    details: { version, skills },
  };
}

function nameList(names) {
  const shown = names.slice(0, NAMES_SHOWN).join(', ');
  return names.length > NAMES_SHOWN ? `${shown} and ${names.length - NAMES_SHOWN} more` : shown;
}

/**
 * One warning line per detected drift, each ending with the `npx jenga sync` instruction. Empty when
 * nothing drifted.
 *
 * @param {ReturnType<typeof detectDrift>} drift
 * @returns {string[]}
 */
export function driftWarnings(drift) {
  const lines = [];
  const v = drift.details.version;
  if (v) {
    lines.push(
      v.reason === 'missing'
        ? `  ⚠  .jenga-version not found: framework files were never synced for @jenga-ai/agent ${v.installed}. ${FIX}`
        : `  ⚠  .jenga-version is ${v.recorded} but @jenga-ai/agent ${v.installed} is installed: framework files may be stale. ${FIX}`
    );
  }
  for (const s of drift.details.skills) {
    const parts = [];
    if (s.missing.length > 0) parts.push(`not listed: ${nameList(s.missing)}`);
    if (s.extra.length > 0) parts.push(`listed but not installed: ${nameList(s.extra)}`);
    lines.push(`  ⚠  The skills list in ${s.file} differs from the installed skills (${parts.join('; ')}). ${FIX}`);
  }
  return lines;
}

/**
 * Detect drift and print its warnings through `log`. Read-only, never throws (a failure to check is
 * not a reason to break `jenga status` / `jenga doctor`), never touches an exit code.
 *
 * @returns {ReturnType<typeof detectDrift>}
 */
export function reportDrift({ packageRoot, consumerRoot, log = console.log } = {}) {
  let drift;
  try {
    drift = detectDrift({ packageRoot, consumerRoot });
  } catch (_) {
    return { versionDrift: false, skillsDrift: false, details: { version: null, skills: [] } };
  }
  const lines = driftWarnings(drift);
  for (const line of lines) log(line);
  if (lines.length > 0) log('');
  return drift;
}

export default { detectDrift, driftWarnings, reportDrift };
