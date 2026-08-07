#!/usr/bin/env node
/**
 * skills/self-sync/scripts/run.js — In-repo mirror runner
 *
 * Mirrors this repo's root-level framework directories into its own
 * `.claude/` and `.agents/` sub-trees so edits to `/skills/*`, `/agents/*`,
 * `/hooks/*`, etc. take effect in the current Claude Code / non-Claude agent
 * session without a `/distribute` cycle.
 *
 * Wraps lib/mirror.js — same helper used by scripts/postinstall.js — but
 * with `reconcileDeletes: true` so orphans in the mirrors are pruned.
 *
 * Flags:
 *   --dry-run    Print the plan without writing.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { mirror } from '../../../lib/mirror.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Repo root is four levels up: run.js → scripts → self-sync → skills → repo
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

// Explicit copy set — documented in SKILL.md.
// Aligned with package.json `files`, plus `settings.json` (not shipped in
// the npm tarball but required in-repo so Claude Code picks it up locally).
const COPY_SET = [
  'bin',
  'lib',
  'scripts',
  'agents',
  'hooks',
  'mcp',
  'skills',
  'templates',
  'settings.json',
];

const DEST_ROOTS = ['.claude', '.agents'];

// Basenames to skip anywhere in the walk. These are recursive mirror
// artifacts, dev caches, or scm dirs that must never propagate into the
// agent-visible mirror. `.agents` and `.claude` in particular can appear
// nested inside `agents/` and `skills/` from legacy distribute runs.
const EXCLUDE = [
  '.agents',
  '.claude',
  '.git',
  '.tmp',
  '.training',
  'node_modules',
  '.DS_Store',
];

function parseArgs(argv) {
  const dryRun = argv.includes('--dry-run');
  return { dryRun };
}

function short(p) {
  return path.relative(REPO_ROOT, p) || '.';
}

function printSection(label, items) {
  if (items.length === 0) return;
  console.log(`  ${label} (${items.length}):`);
  for (const item of items) {
    console.log(`    - ${short(item)}`);
  }
}

function main() {
  const { dryRun } = parseArgs(process.argv.slice(2));

  console.log('');
  console.log('╔══════════════════════════════════════════════════════╗');
  console.log(`║  /self-sync — mirror root → .claude/ + .agents/      ║`);
  console.log('╚══════════════════════════════════════════════════════╝');
  console.log(`  Repo root : ${REPO_ROOT}`);
  console.log(`  Copy set  : ${COPY_SET.join(', ')}`);
  console.log(`  Dry-run   : ${dryRun ? 'YES (no writes)' : 'no'}`);
  console.log('');

  const missing = COPY_SET.filter(
    (entry) => !fs.existsSync(path.join(REPO_ROOT, entry))
  );
  if (missing.length > 0) {
    console.log(`  ⚠  Missing from repo root — skipped: ${missing.join(', ')}`);
    console.log('');
  }

  const totals = { added: 0, overwritten: 0, deleted: 0, skipped: 0 };

  for (const targetRoot of DEST_ROOTS) {
    const destRoot = path.join(REPO_ROOT, targetRoot);
    console.log(`→ ${targetRoot}/`);

    const result = mirror({
      sourceRoot: REPO_ROOT,
      destRoot,
      copySet: COPY_SET,
      dryRun,
      reconcileDeletes: true,
      exclude: EXCLUDE,
    });

    printSection('added', result.added);
    printSection('overwritten', result.overwritten);
    printSection('deleted', result.deleted);
    console.log(
      `  summary: +${result.added.length} ~${result.overwritten.length} -${result.deleted.length} =${result.skipped.length}`
    );
    console.log('');

    totals.added += result.added.length;
    totals.overwritten += result.overwritten.length;
    totals.deleted += result.deleted.length;
    totals.skipped += result.skipped.length;
  }

  console.log('──────────────────────────────────────────────────────');
  console.log(
    `  Total: +${totals.added} added  ~${totals.overwritten} overwritten  -${totals.deleted} deleted  =${totals.skipped} unchanged`
  );
  if (dryRun) {
    console.log('  (dry-run — nothing was written)');
  }
  console.log('──────────────────────────────────────────────────────');
  console.log('');
}

main();
