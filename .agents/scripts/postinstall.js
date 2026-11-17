#!/usr/bin/env node
/**
 * postinstall.js — Jenga AI consumer installation hook
 *
 * Runs automatically when a consumer project installs jenga-agent via npm.
 * Mirrors the discovery-bound dirs — `skills/` and `agents/` — into BOTH
 * `<consumer>/.claude/` (where Claude Code looks) and `<consumer>/.agents/`
 * (where non-Claude agents like Copilot / custom look), regenerates the skill
 * allow-list, the Copilot files and the Jenga block in `CLAUDE.md` / `AGENTS.md`,
 * repairs a legacy event log and records the version in `.jenga-version`.
 *
 * Everything else (`hooks/`, `scripts/`, `templates/`, `mcp/`, `lib/`) stays
 * in the installed package and is sourced from `node_modules/jenga-agent/…`
 * at runtime — no duplication. The consumer's `project/` directory is left
 * untouched, apart from the one-time event-log repair.
 *
 * What lives here, and what does not
 * ──────────────────────────────────
 * Everything that changes files lives in `lib/sync.js` (`syncConsumer`), shared
 * with `jenga sync` (`lib/commands/sync.js`) so the two can never diverge: the
 * mirror, the manifest-based delete reconciliation (E26_S08_T01), the legacy-path
 * seeding (E26_S08_T03) and their safety invariants are documented in that file's
 * header, and in `lib/postinstall-manifest.js`. This file keeps only what is specific
 * to being an npm lifecycle hook:
 *   - resolving the consumer root (`INIT_CWD`) and refusing to run inside the package;
 *   - the version gate: copy on a first install or a strictly newer version recorded
 *     in <consumer-root>/.jenga-version, skip otherwise. `jenga sync` has no gate;
 *   - the banner and the closing summary, which points at `npx jenga sync` for the
 *     case where this hook did not run (npm `allowScripts`, pnpm, `--ignore-scripts`)
 *     or anything looks stale.
 */

import fs   from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { syncConsumer, semverCompare } from '../lib/sync.js';

// ESM equivalent of __dirname
const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

/** Closing hint printed on every path that reaches the summary (E26_S11_T04). */
const SYNC_HINT = 'If anything looks stale, or this hook did not run, run: npx jenga sync';

// ── main ─────────────────────────────────────────────────────────────────────

function main() {
  // __dirname is scripts/ inside the package; package root is one level up
  const packageRoot = path.resolve(__dirname, '..');

  // npm sets INIT_CWD to the directory where the user ran `npm install`
  const consumerRoot = process.env.INIT_CWD || process.cwd();

  // Avoid running during development (when INIT_CWD === packageRoot itself)
  if (path.resolve(consumerRoot) === path.resolve(packageRoot)) {
    console.log('\n  ℹ  Jenga AI postinstall: running inside the package itself — skipping copy.\n');
    return;
  }

  // Read this package's version
  let packageVersion = '0.0.0';
  try {
    const pkgPath = path.join(packageRoot, 'package.json');
    const pkg     = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
    packageVersion = pkg.version || '0.0.0';
  } catch (_) {
    // non-fatal — proceed with default
  }

  // Read the installed version at the consumer root (if any)
  const versionFile    = path.join(consumerRoot, '.jenga-version');
  let installedVersion = null;
  try {
    installedVersion = fs.readFileSync(versionFile, 'utf8').trim();
  } catch (_) {
    // file doesn't exist yet — first-time install
  }

  const isFirstInstall = installedVersion === null;
  const isUpgrade      = !isFirstInstall && semverCompare(packageVersion, installedVersion) > 0;
  const shouldCopy     = isFirstInstall || isUpgrade;

  console.log('\n╔══════════════════════════════════════════════════════╗');
  console.log('║            Jenga AI — postinstall hook             ║');
  console.log('╚══════════════════════════════════════════════════════╝\n');
  console.log(`  Package version  : ${packageVersion}`);
  console.log(`  Installed version: ${installedVersion ?? '(none — first install)'}`);
  console.log(`  Consumer root    : ${consumerRoot}`);
  console.log(`  Action           : ${
    isFirstInstall ? 'First install — copying all framework files' :
    isUpgrade      ? `Upgrade ${installedVersion} → ${packageVersion} — copying all framework files` :
                     'Same or newer version already installed — skipping overwrite'
  }\n`);

  if (!shouldCopy) {
    console.log('  ✓ Nothing to do. Your framework files are already up to date.');
    console.log(`  ${SYNC_HINT}`);
    return;
  }

  // One implementation shared with `jenga sync` (lib/sync.js): mirror, manifest reconciliation, allow-list,
  // Copilot files, the Jenga block in CLAUDE.md / AGENTS.md, event-log repair and .jenga-version. It prints
  // every step through `log`; a failed step is reported there and never fails the install.
  const result = syncConsumer({ packageRoot, consumerRoot, dryRun: false, log: console.log });

  console.log('\n──────────────────────────────────────────────────────');
  console.log(`  Summary: ${result.copied} file(s) copied, ${result.skippedFiles} skipped, ${result.deleted} stale file(s) removed`);
  console.log(`  .jenga-version written: ${packageVersion}`);
  console.log('──────────────────────────────────────────────────────');
  console.log(`  ${SYNC_HINT}`);
}

main();
