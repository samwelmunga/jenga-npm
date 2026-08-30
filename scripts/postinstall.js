#!/usr/bin/env node
/**
 * postinstall.js — Jenga AI consumer installation hook
 *
 * Runs automatically when a consumer project installs jenga-agent via npm.
 * Copies the discovery-bound dirs — `skills/` and `agents/` — into BOTH
 * `<consumer>/.claude/` (where Claude Code looks) and `<consumer>/.agents/`
 * (where non-Claude agents like Copilot / custom look, per the framework's
 * agent-target convention). This duplication is required because each agent
 * ecosystem has its own fixed discovery path.
 *
 * Everything else (`hooks/`, `scripts/`, `templates/`, `mcp/`, `lib/`) stays
 * in the installed package and is sourced from `node_modules/jenga-agent/…`
 * at runtime — no duplication.
 *
 * The consumer's `project/` directory (if present) is left untouched.
 *
 * Safe upgrade behaviour:
 *   - First-time installs: always copy all files.
 *   - Subsequent installs: only overwrite if the new package version is strictly
 *     newer (semver) than the version recorded in <consumer-root>/.jenga-version.
 *
 * After a successful copy, writes .jenga-version with the current package version.
 *
 * The actual filesystem mirror is delegated to `lib/mirror.js`, which is the
 * single source of truth shared with the in-repo `/self-sync` skill. Consumer
 * install always uses `reconcileDeletes: false` (additive-only).
 */

import fs   from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { mirror } from '../lib/mirror.js';

// ESM equivalent of __dirname
const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

// ── helpers ──────────────────────────────────────────────────────────────────

/**
 * Very small semver comparator.
 * Returns 1 if a > b, -1 if a < b, 0 if equal.
 */
function semverCompare(a, b) {
  const clean  = (v) => String(v || '0.0.0').replace(/[^0-9.]/g, '');
  const parts  = (v) => clean(v).split('.').map(Number);
  const [aMaj, aMin, aPat] = parts(a);
  const [bMaj, bMin, bPat] = parts(b);
  if (aMaj !== bMaj) return aMaj > bMaj ? 1 : -1;
  if (aMin !== bMin) return aMin > bMin ? 1 : -1;
  if (aPat !== bPat) return aPat > bPat ? 1 : -1;
  return 0;
}

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
    console.log('  ✓ Nothing to do. Your framework files are already up to date.\n');
    return;
  }

  // Discovery-bound dirs get mirrored to both .claude/ (Claude Code) and
  // .agents/ (Copilot / custom). Everything else is sourced from
  // node_modules/jenga-agent/… at runtime — no duplication.
  const copySet    = ['skills', 'agents'];
  const targetRoots = ['.claude', '.agents'];

  // Warn about any copySet entries that are missing from the package — the
  // helper silently skips missing sources, so we surface it here for parity
  // with the previous UX.
  for (const entry of copySet) {
    if (!fs.existsSync(path.join(packageRoot, entry))) {
      console.log(`  ⚠  ${entry}/ not found in package — skipped`);
    }
  }

  let totalCopied  = 0;
  let totalSkipped = 0;

  for (const targetRoot of targetRoots) {
    const destRoot = path.join(consumerRoot, targetRoot);

    // Consumer install is additive-only: never delete files from the mirror.
    const result = mirror({
      sourceRoot:       packageRoot,
      destRoot,
      copySet,
      dryRun:           false,
      reconcileDeletes: false,
    });

    // For the per-directory line we report the aggregate write count
    // (added + overwritten) so the message matches the pre-refactor UX
    // ("N file(s) copied") even though we now distinguish the two.
    for (const entry of copySet) {
      const wrote =
        result.added.filter((p) => p.startsWith(path.join(destRoot, entry))).length +
        result.overwritten.filter((p) => p.startsWith(path.join(destRoot, entry))).length;
      console.log(`  ✓ ${targetRoot}/${entry}/ — ${wrote} file(s) copied`);
    }

    totalCopied  += result.added.length + result.overwritten.length;
    totalSkipped += result.skipped.length;
  }

  // Write .jenga-version to record the installed version at consumer root
  fs.writeFileSync(versionFile, packageVersion + '\n', 'utf8');

  console.log('\n──────────────────────────────────────────────────────');
  console.log(`  Summary: ${totalCopied} file(s) copied, ${totalSkipped} skipped`);
  console.log(`  .jenga-version written: ${packageVersion}`);
  console.log('──────────────────────────────────────────────────────\n');
}

main();
