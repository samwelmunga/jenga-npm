#!/usr/bin/env node
/**
 * scripts/generate-legacy-shipped-paths.js — legacy shipped-path list generator (E26_S08_T03)
 *
 * Why this exists
 * ────────────────
 * `lib/postinstall-manifest.js`'s delete reconciliation (E26_S08_T01) is purely forward-looking:
 * a consumer already installed before any manifest existed can never have their pre-existing
 * orphans cleaned up, because the first manifest a fixed version ever writes for them records
 * only what THAT run mirrored. This script produces the static list this package ships so the
 * FIRST manifest a consumer ever gets can instead be *seeded* with paths known to have shipped in
 * some real prior published version — see `seedFromLegacyPaths` in `lib/postinstall-manifest.js`
 * and `scripts/postinstall.js`'s `no-prior-manifest` branch for how the seed is consumed.
 *
 * Why not git tags
 * ─────────────────
 * The task's design note allows deriving the list "from git tags" as an alternative to
 * publish-time derivation. Checked and rejected for this repo specifically: this repo's local
 * tags (`v0.0.1`, `v55.0.1`, `last-self-sync`) do not correspond to the real npm publish history
 * at all — `npm view @jenga-ai/agent versions --json` shows the real, disconnected sequence
 * (1.0.0 through 3.0.0 as of this writing). Reconstructing shipped paths from local git tags in
 * this repo would silently produce a list bearing no relation to what was actually published.
 *
 * Two modes
 * ─────────
 *   --bootstrap   Fetches EVERY version `npm view <package> versions --json` currently lists from
 *                 the real registry, `npm pack`s each one into a throwaway temp dir, and unions
 *                 the `skills/`+`agents/` entries inside every tarball. Network-dependent. This is
 *                 how the real historical shipped-path set is captured — including versions whose
 *                 git history is not reliably reconstructable locally (verified true here). Meant
 *                 to be run manually / rarely — a one-off backfill, or an occasional resync — NOT
 *                 wired into the automatic per-publish flow (see incremental mode below for that).
 *
 *   (default)     Incremental, no network: reads whatever is already at the output path (if any)
 *                 and unions it with the paths CURRENTLY on disk under this repo's own `skills/`
 *                 and `agents/` directories — i.e. "what this release is about to ship" folds into
 *                 the running cumulative record. This is the mode wired into the publish pipeline
 *                 (`skills/publish/scripts/npm_pipeline.sh` / `npm_ci_pipeline.sh`, via the
 *                 `generate:legacy-paths` npm script) so every future publish keeps the list
 *                 current with zero network dependency and zero publish-time registry flakiness.
 *
 *                 IMPORTANT — this mode's first-ever run is NOT a substitute for --bootstrap: if
 *                 the output file doesn't exist yet, incremental mode unions an EMPTY existing set
 *                 with whatever's on disk in THIS repo's tree right now. That happens to currently
 *                 equal the real historical union (this repo's working tree is a superset of every
 *                 published version's file list, as of the 2026-09-07 verification below) — but
 *                 that is a coincidence of this repo's current state, not a guarantee the mode
 *                 itself provides. The very first generation of the shipped artifact MUST use
 *                 --bootstrap so the baseline is verified against the real registry, not assumed.
 *
 * Output
 * ──────
 * `lib/legacy-shipped-paths.json` (ships automatically — `lib/` is already in package.json's
 * `files` allow-list, no change needed there):
 *
 *   {
 *     "generated_at": "<ISO 8601>",
 *     "package": "@jenga-ai/agent",
 *     "source": "bootstrap-from-registry+incremental" | "incremental",
 *     "paths": ["agents/developer.md", "skills/do/SKILL.md", ...]
 *   }
 *
 * `paths` are relative to a mirror root, POSIX-separated, deduped and sorted — matching the same
 * shape convention `lib/postinstall-manifest.js`'s own manifest uses, for consistency.
 *
 * The generation step is regenerated automatically as part of the publish flow (incremental mode),
 * per this task's AC — it is NOT hand-maintained, so it cannot silently go stale across releases.
 *
 * ESM, Node built-ins only — matches lib/postinstall-manifest.js and lib/mirror.js. `npm` itself is
 * shelled out to (via `execFileSync`) only in `--bootstrap` mode.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.join(__dirname, '..');

export const DEFAULT_OUTPUT_PATH = path.join(REPO_ROOT, 'lib', 'legacy-shipped-paths.json');
export const DEFAULT_PACKAGE_NAME = '@jenga-ai/agent';

/** Discovery-bound directories mirrored into a consumer's .agents/ and .claude/ (see docs/distribution.md §1). */
const COPY_SET = ['skills', 'agents'];

// ── walk a real directory tree ──────────────────────────────────────────────

function walkDir(base, dir, out) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return;
  }
  for (const entry of entries) {
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkDir(base, abs, out);
    } else if (entry.isFile()) {
      out.push(path.relative(base, abs).split(path.sep).join('/'));
    }
    // symlinks intentionally ignored — matches lib/mirror.js's own walk behavior.
  }
}

/**
 * Relative POSIX paths this repo's CURRENT `skills/` + `agents/` trees would ship, i.e. exactly
 * what a fresh install of the version about to be published would mirror.
 *
 * @param {string} repoRoot
 * @returns {string[]} sorted, deduped
 */
export function currentShippedPaths(repoRoot = REPO_ROOT) {
  const out = [];
  for (const entry of COPY_SET) {
    const dir = path.join(repoRoot, entry);
    if (fs.existsSync(dir)) walkDir(repoRoot, dir, out);
  }
  return [...new Set(out)].sort();
}

// ── read existing output (if any) ───────────────────────────────────────────

function readExistingPaths(outputPath) {
  try {
    const parsed = JSON.parse(fs.readFileSync(outputPath, 'utf8'));
    return Array.isArray(parsed.paths) ? parsed.paths.filter((p) => typeof p === 'string') : [];
  } catch (_) {
    return []; // absent, unreadable, or corrupt — start from an empty cumulative set
  }
}

// ── bootstrap from the real npm registry ────────────────────────────────────

/**
 * Fetch every currently-listed published version of `packageName`, `npm pack` each into a
 * throwaway temp dir, and union the `skills/`+`agents/` entries found inside every tarball.
 * Network-dependent — intended for manual/rare use (a one-off backfill or occasional resync),
 * never called by the automatic per-publish (incremental) path.
 *
 * @param {string} packageName
 * @returns {string[]} sorted, deduped relative POSIX paths
 */
export function bootstrapFromRegistry(packageName = DEFAULT_PACKAGE_NAME) {
  const versionsRaw = execFileSync('npm', ['view', packageName, 'versions', '--json'], {
    encoding: 'utf8',
  });
  const versions = JSON.parse(versionsRaw);
  const all = new Set();

  for (const version of versions) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'jenga-legacy-bootstrap-'));
    try {
      execFileSync('npm', ['pack', `${packageName}@${version}`, '--silent'], { cwd: tmp, stdio: 'ignore' });
      const tarball = fs.readdirSync(tmp).find((f) => f.endsWith('.tgz'));
      if (!tarball) continue;
      const listing = execFileSync('tar', ['-tzf', path.join(tmp, tarball)], { encoding: 'utf8' });
      for (const line of listing.split('\n')) {
        const m = line.match(/^package\/(skills|agents)\/(.+)$/);
        if (m && !line.endsWith('/')) all.add(`${m[1]}/${m[2]}`);
      }
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  }

  return [...all].sort();
}

// ── generate ─────────────────────────────────────────────────────────────────

/**
 * @param {object}  [opts]
 * @param {string}  [opts.outputPath]   Default: lib/legacy-shipped-paths.json
 * @param {string}  [opts.packageName]  Default: @jenga-ai/agent
 * @param {boolean} [opts.bootstrap]    Default: false (incremental, no network)
 * @param {string}  [opts.repoRoot]     Default: this repo's own root
 * @returns {{written: boolean, path: string, count: number, source: string}}
 */
export function generate({
  outputPath = DEFAULT_OUTPUT_PATH,
  packageName = DEFAULT_PACKAGE_NAME,
  bootstrap = false,
  repoRoot = REPO_ROOT,
} = {}) {
  const existing = readExistingPaths(outputPath);
  let paths;
  let source;

  if (bootstrap) {
    const registryPaths = bootstrapFromRegistry(packageName);
    paths = [...new Set([...registryPaths, ...existing])].sort();
    source = 'bootstrap-from-registry+incremental';
  } else {
    const current = currentShippedPaths(repoRoot);
    paths = [...new Set([...existing, ...current])].sort();
    source = 'incremental';
  }

  const artifact = {
    generated_at: new Date().toISOString(),
    package: packageName,
    source,
    paths,
  };

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(artifact, null, 2) + '\n', 'utf8');

  return { written: true, path: outputPath, count: paths.length, source };
}

/**
 * Read the shipped legacy-paths artifact's `paths` array. Fail-toward-doing-nothing: any read or
 * parse failure returns `[]` rather than throwing — a missing/corrupt legacy-paths file must
 * never abort or degrade an unattended `npm install`, mirroring `readManifest`'s own posture in
 * `lib/postinstall-manifest.js`.
 *
 * @param {string} artifactPath
 * @returns {string[]}
 */
export function readLegacyShippedPaths(artifactPath = DEFAULT_OUTPUT_PATH) {
  try {
    const parsed = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
    if (!Array.isArray(parsed.paths)) return [];
    return parsed.paths.filter((p) => typeof p === 'string' && p.length > 0);
  } catch (_) {
    return [];
  }
}

// ── CLI guard ────────────────────────────────────────────────────────────────
// node scripts/generate-legacy-shipped-paths.js [--bootstrap] [--package <name>] [outputPath]

const invokedPath = process.argv[1] ? fs.realpathSync(process.argv[1]) : null;
if (invokedPath === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const bootstrap = argv.includes('--bootstrap');
  const pkgFlagIndex = argv.indexOf('--package');
  const packageName = pkgFlagIndex !== -1 ? argv[pkgFlagIndex + 1] : DEFAULT_PACKAGE_NAME;
  const positional = argv.filter((a, i) => a !== '--bootstrap' && i !== pkgFlagIndex && i !== pkgFlagIndex + 1 && !a.startsWith('--'));
  const outputPath = positional[0] || DEFAULT_OUTPUT_PATH;

  const result = generate({ outputPath, packageName, bootstrap });
  console.log(`✓ ${result.path} (${result.count} paths, ${result.source})`);
}
