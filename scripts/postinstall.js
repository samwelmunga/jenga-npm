#!/usr/bin/env node
/**
 * postinstall.js — JengaAgent consumer installation hook
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
 */

import fs   from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

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

/**
 * Recursively copy `src` directory into `dest`.
 * Returns an object with `copied` and `skipped` arrays (absolute paths).
 */
function copyDirSync(src, dest, { overwrite = true } = {}) {
  const result = { copied: [], skipped: [] };

  if (!fs.existsSync(src)) {
    return result;
  }

  fs.mkdirSync(dest, { recursive: true });

  const entries = fs.readdirSync(src, { withFileTypes: true });

  for (const entry of entries) {
    const srcPath  = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);

    if (entry.isDirectory()) {
      const sub = copyDirSync(srcPath, destPath, { overwrite });
      result.copied.push(...sub.copied);
      result.skipped.push(...sub.skipped);
    } else {
      if (!overwrite && fs.existsSync(destPath)) {
        result.skipped.push(destPath);
      } else {
        fs.copyFileSync(srcPath, destPath);
        result.copied.push(destPath);
      }
    }
  }

  return result;
}

// ── main ─────────────────────────────────────────────────────────────────────

function main() {
  // __dirname is scripts/ inside the package; package root is one level up
  const packageRoot = path.resolve(__dirname, '..');

  // npm sets INIT_CWD to the directory where the user ran `npm install`
  const consumerRoot = process.env.INIT_CWD || process.cwd();

  // Avoid running during development (when INIT_CWD === packageRoot itself)
  if (path.resolve(consumerRoot) === path.resolve(packageRoot)) {
    console.log('\n  ℹ  JengaAgent postinstall: running inside the package itself — skipping copy.\n');
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
  console.log('║            JengaAgent — postinstall hook             ║');
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
  const dirs        = ['skills', 'agents'];
  const targetRoots = ['.claude', '.agents'];

  let totalCopied  = 0;
  let totalSkipped = 0;

  for (const dir of dirs) {
    const src = path.join(packageRoot, dir);

    if (!fs.existsSync(src)) {
      console.log(`  ⚠  ${dir}/ not found in package — skipped`);
      continue;
    }

    for (const targetRoot of targetRoots) {
      const dest = path.join(consumerRoot, targetRoot, dir);
      const { copied, skipped } = copyDirSync(src, dest, { overwrite: true });
      totalCopied  += copied.length;
      totalSkipped += skipped.length;

      console.log(`  ✓ ${targetRoot}/${dir}/ — ${copied.length} file(s) copied`);
    }
  }

  // Write .jenga-version to record the installed version at consumer root
  fs.writeFileSync(versionFile, packageVersion + '\n', 'utf8');

  console.log('\n──────────────────────────────────────────────────────');
  console.log(`  Summary: ${totalCopied} file(s) copied, ${totalSkipped} skipped`);
  console.log(`  .jenga-version written: ${packageVersion}`);
  console.log('──────────────────────────────────────────────────────\n');
}

main();
