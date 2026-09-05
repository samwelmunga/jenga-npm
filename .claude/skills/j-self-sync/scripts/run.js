#!/usr/bin/env node
/**
 * skills/j-self-sync/scripts/run.js — In-repo mirror runner
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
import { spawnSync } from 'node:child_process';

import { mirror } from '../../../lib/mirror.js';
import { generateSkillAllowList } from '../../../lib/generate-skill-allow-list.js';

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

// Runs E51_S02_T02's Merged-status pass after a successful non-dry-run sync.
// `mark-merged.sh` (with no --diff-file/--stdin flag) invokes E51_S02_T01's
// compute-sync-diff.sh itself as its default diff source, so this is a
// single subprocess call, not two — re-deriving that composition here would
// duplicate logic mark-merged.sh already owns.
//
// Non-fatal by design, mirroring the generateSkillAllowList regeneration
// step just above: a hiccup in the Merged-marking pipeline (a lock timeout,
// a malformed board file, etc.) must never make the underlying mirror sync
// — the thing the user actually asked for — appear to have failed.
function runMergedStatusPass() {
  const script = path.join(
    REPO_ROOT,
    'skills',
    'self-sync',
    'scripts',
    'mark-merged.sh'
  );
  try {
    const result = spawnSync(script, [], {
      cwd: REPO_ROOT,
      encoding: 'utf8',
    });
    if (result.error) {
      throw result.error;
    }
    if (typeof result.status === 'number' && result.status !== 0) {
      console.log(
        `  ⚠  Merged-status pass exited with code ${result.status} — board left as-is`
      );
      if (result.stderr) {
        console.log(
          result.stderr
            .trim()
            .split('\n')
            .map((line) => `    ${line}`)
            .join('\n')
        );
      }
      return;
    }
    console.log('  ✓ Merged-status pass complete');
    if (result.stderr) {
      console.log(
        result.stderr
          .trim()
          .split('\n')
          .filter(Boolean)
          .map((line) => `    ${line}`)
          .join('\n')
      );
    }
  } catch (e) {
    console.log(`  ⚠  Could not run Merged-status pass — ${e.message}`);
  }
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
  } else {
    // Regenerate the canonical skill allow-list (E50_S02) from this repo's own skills/ so it
    // never goes stale without hand-maintenance. Non-fatal on failure — a generation error here
    // must not fail the whole /self-sync run, mirroring the mirror step's own resilience.
    try {
      const result = generateSkillAllowList(
        path.join(REPO_ROOT, 'skills'),
        path.join(REPO_ROOT, 'lib', 'skill-allow-list.json')
      );
      console.log(`  ✓ ${short(result.path)} (${result.skill_count} skills)`);
    } catch (e) {
      console.log(`  ⚠  Could not regenerate skill-allow-list.json — ${e.message}`);
    }

    // E51_S02_T03 — Merged-status pass (skips entirely on --dry-run; see the
    // `if (dryRun)` branch above, which this code is deliberately outside of).
    runMergedStatusPass();
  }
  console.log('──────────────────────────────────────────────────────');
  console.log('');
}

main();
