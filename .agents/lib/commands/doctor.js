/**
 * lib/commands/doctor.js — `jenga doctor` / `jenga clean` interactive orphan cleanup (E26_S08_T02)
 *
 * Why this exists
 * ────────────────
 * `scripts/postinstall.js`'s manifest-based delete reconciliation (E26_S08_T01) only ever cleans
 * up a path that a manifest THIS package's postinstall previously wrote lists. That is safe, but
 * purely forward-looking: a consumer already installed before any manifest existed can never have
 * their pre-existing orphans (retired `j:`-form skill files, excluded `j-<name>` twins, or any
 * other drift) reconciled by postinstall alone — see `E26_S08`'s "Scope gap discovered after T01"
 * section. `E26_S08_T03` closes that gap automatically for the pre-manifest-migration case
 * specifically, going forward. This command is the manual stopgap that works right now, for any
 * cause of drift (not only the one migration that surfaced the bug): a human runs it, reviews a
 * candidate list, and confirms before anything is deleted.
 *
 * Heuristic — "looks package-owned"
 * ──────────────────────────────────
 * There is no manifest guarantee to lean on here (that is exactly the gap this command exists to
 * cover), so eligibility is decided by a heuristic instead of provenance:
 *
 *   - A top-level directory under `<root>/skills/` is a candidate ONLY if it is not one of the
 *     currently-installed package's own skill directories AND its `SKILL.md` (if present) carries
 *     frontmatter whose `name:` matches `/^j[.:]/i` — the same anti-masquerading prefix regex
 *     `lib/generate-skill-allow-list.js` already uses as the canonical "this looks like a genuine
 *     Jenga skill identifier" signal. Every regular file recursively inside a confirmed candidate
 *     directory becomes a delete candidate, grouped under that directory.
 *   - A top-level `.md` file directly under `<root>/agents/` is a candidate if its name does not
 *     match one of the currently-installed package's own agent files.
 *   - Any path already recorded in that root's `.jenga-postinstall-manifest.json` is excluded —
 *     manifest-listed paths already self-heal via the normal postinstall path (or will, once
 *     E26_S08_T03 lands), so surfacing them here too would be redundant.
 *
 * False-positive posture (documented, not hidden): a consumer's own `SKILL.md` that happens to
 * declare `name: j.<something>` frontmatter, or a consumer's own hand-dropped `.md` file placed
 * directly under `agents/`, would be misclassified as package-owned. This is an accepted risk —
 * the confirmation step below is the compensating control, not a convenience, per this task's
 * `crucial_level: gated` note. A directory the package currently ships is NEVER inspected
 * file-by-file, which is what lets a consumer's own extra file living inside an otherwise-current
 * package skill directory survive untouched without a separate special case.
 *
 * Safety
 * ──────
 * Deletion re-uses the exact boundary/type checks `lib/postinstall-manifest.js`'s delete pass
 * uses: `isInside` (must resolve strictly inside the mirror root), `lstatSync` regular-file check
 * (symlinks refused, never followed), and directories are only ever pruned via the shared
 * `pruneEmptyDirs` helper once genuinely empty — never deleted directly. Nothing is ever deleted
 * without an explicit interactive "yes", and a non-TTY stdin never falls through to deleting.
 *
 * ESM, Node built-ins only — matches `lib/postinstall-manifest.js` and `lib/mirror.js`.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

import { readManifest, isInside, pruneEmptyDirs } from '../postinstall-manifest.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/** Default package root: this file lives at <package>/lib/commands/doctor.js. */
const DEFAULT_PACKAGE_ROOT = path.join(__dirname, '..', '..');

/** Mirror roots a consumer install writes into (see docs/distribution.md). */
const MIRROR_ROOTS = ['.agents', '.claude'];

/** Jenga skill-name prefix regex — matches lib/generate-skill-allow-list.js's guard exactly. */
const JENGA_NAME_PREFIX = /^j[.:]/i;

// ── frontmatter helpers ─────────────────────────────────────────────────────

/** Extract the frontmatter `name:` field from SKILL.md content, or null. */
function extractSkillName(content) {
  const fmMatch = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!fmMatch) return null;
  const nameMatch = fmMatch[1].match(/^name:\s*(.+)$/m);
  if (!nameMatch) return null;
  return nameMatch[1].trim().replace(/^["']|["']$/g, '');
}

/** True iff `<dir>/SKILL.md` exists and its frontmatter name looks like a genuine Jenga skill. */
function looksLikeJengaSkillDir(dir) {
  const skillMd = path.join(dir, 'SKILL.md');
  let content;
  try {
    content = fs.readFileSync(skillMd, 'utf8');
  } catch (_) {
    return false; // no SKILL.md — not enough signal to call this package-owned
  }
  const name = extractSkillName(content);
  return typeof name === 'string' && JENGA_NAME_PREFIX.test(name);
}

// ── package's own current shape ─────────────────────────────────────────────

/** Top-level skill directory names the installed package currently ships. */
function currentPackageSkillDirs(packageRoot) {
  const dir = path.join(packageRoot, 'skills');
  if (!fs.existsSync(dir)) return new Set();
  return new Set(
    fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => e.name)
  );
}

/** Top-level agent `.md` file names the installed package currently ships. */
function currentPackageAgentFiles(packageRoot) {
  const dir = path.join(packageRoot, 'agents');
  if (!fs.existsSync(dir)) return new Set();
  return new Set(
    fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isFile() && e.name.endsWith('.md'))
      .map((e) => e.name)
  );
}

// ── scan ─────────────────────────────────────────────────────────────────────

/** Recursively collect relative POSIX paths of every regular file under `dir`. */
function collectFiles(root, dir, out) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return;
  }
  for (const entry of entries) {
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      collectFiles(root, abs, out);
    } else {
      let stat;
      try {
        stat = fs.lstatSync(abs);
      } catch (_) {
        continue;
      }
      if (!stat.isFile()) continue; // symlinks and other node types refused, not followed
      out.push(path.relative(root, abs).split(path.sep).join('/'));
    }
  }
}

/**
 * Scan one mirror root for orphan candidates.
 *
 * @param {object} opts
 * @param {string} opts.destRoot     Absolute path to the mirror root (e.g. <consumer>/.agents).
 * @param {string} opts.packageRoot  Absolute path to the currently-installed package root.
 * @returns {{groups: Array<{label: string, files: string[]}>, total: number}}
 */
export function scanRoot({ destRoot, packageRoot }) {
  const groups = [];
  if (!fs.existsSync(destRoot)) return { groups, total: 0 };

  const manifest = readManifest(destRoot);
  const manifestPaths = new Set(manifest ? manifest.paths : []);

  const currentSkillDirs = currentPackageSkillDirs(packageRoot);
  const currentAgentFiles = currentPackageAgentFiles(packageRoot);

  // skills/<name>/ — directory-level candidacy, then sweep every file inside.
  const skillsDir = path.join(destRoot, 'skills');
  if (fs.existsSync(skillsDir)) {
    for (const entry of fs.readdirSync(skillsDir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      if (currentSkillDirs.has(entry.name)) continue; // currently shipped — never inspected
      const abs = path.join(skillsDir, entry.name);
      if (!looksLikeJengaSkillDir(abs)) continue; // no Jenga-shaped SKILL.md — not enough signal

      const files = [];
      collectFiles(destRoot, abs, files);
      const candidateFiles = files.filter((rel) => !manifestPaths.has(rel));
      if (candidateFiles.length > 0) {
        groups.push({ label: `skills/${entry.name}/`, files: candidateFiles });
      }
    }
  }

  // agents/<name>.md — flat file-level candidacy.
  const agentsDir = path.join(destRoot, 'agents');
  if (fs.existsSync(agentsDir)) {
    for (const entry of fs.readdirSync(agentsDir, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.endsWith('.md')) continue;
      if (currentAgentFiles.has(entry.name)) continue; // currently shipped
      const rel = `agents/${entry.name}`;
      if (manifestPaths.has(rel)) continue;
      let stat;
      try {
        stat = fs.lstatSync(path.join(agentsDir, entry.name));
      } catch (_) {
        continue;
      }
      if (!stat.isFile()) continue; // symlink refused
      groups.push({ label: rel, files: [rel] });
    }
  }

  const total = groups.reduce((n, g) => n + g.files.length, 0);
  return { groups, total };
}

// ── delete ───────────────────────────────────────────────────────────────────

/**
 * Delete every file across `groups` (relative to `destRoot`), applying the same boundary/type
 * checks the postinstall delete pass uses, then prune directories left empty.
 *
 * @returns {{deleted: string[], refused: Array<{path: string, reason: string}>}}
 */
function deleteGroups({ destRoot, groups }) {
  const root = path.resolve(destRoot);
  const deleted = [];
  const refused = [];
  const dirsToConsider = new Set();

  for (const group of groups) {
    for (const rel of group.files) {
      const abs = path.resolve(root, rel);
      if (!isInside(root, abs)) {
        refused.push({ path: rel, reason: 'outside-dest-root' });
        continue;
      }
      let stat;
      try {
        stat = fs.lstatSync(abs);
      } catch (_) {
        continue; // already gone
      }
      if (!stat.isFile()) {
        refused.push({ path: rel, reason: 'not-a-regular-file' });
        continue;
      }
      try {
        fs.rmSync(abs);
        deleted.push(rel);
        dirsToConsider.add(path.dirname(abs));
      } catch (e) {
        refused.push({ path: rel, reason: `unlink-failed: ${e.code || e.message}` });
      }
    }
  }

  const prunedDirs = [];
  for (const dir of dirsToConsider) {
    pruneEmptyDirs(root, dir, prunedDirs);
  }

  return { deleted, refused, prunedDirs: prunedDirs.sort() };
}

// ── prompt ───────────────────────────────────────────────────────────────────

function askYesNo(question) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`${question} [y/N] `, (answer) => {
      rl.close();
      resolve(/^y(es)?$/i.test(answer.trim()));
    });
  });
}

// ── main ─────────────────────────────────────────────────────────────────────

/**
 * @param {string[]} args
 * @param {object}   [opts]
 * @param {string}   [opts.packageRoot]   Installed package root (default: this file's own package).
 * @param {string}   [opts.targetRoot]    Consumer project root to scan (default: process.cwd()).
 * @param {boolean}  [opts.isInteractive] Test seam ONLY — overrides the real `process.stdin.isTTY`
 *                                        check. Never set by `bin/jenga.js`'s CLI dispatch, which
 *                                        always leaves this undefined so the real TTY check applies;
 *                                        exists so `tests/postinstall-doctor-cleanup.bats` can drive
 *                                        the actual confirm/decline delete code path deterministically
 *                                        without needing a real pty, matching the same non-TTY
 *                                        readline limitation already documented in tests/init.bats.
 * @param {function} [opts.confirmFn]     Test seam ONLY — overrides the real interactive `askYesNo`
 *                                        prompt with a function returning (or resolving to) a
 *                                        boolean. Never set by `bin/jenga.js`.
 */
export async function runDoctor(args = [], opts = {}) {
  const packageRoot = opts.packageRoot || DEFAULT_PACKAGE_ROOT;
  const targetRoot = opts.targetRoot || process.cwd();
  const dryRun = args.includes('--dry-run');
  const isInteractive = typeof opts.isInteractive === 'boolean' ? opts.isInteractive : Boolean(process.stdin.isTTY);
  const confirmFn = typeof opts.confirmFn === 'function' ? opts.confirmFn : askYesNo;

  console.log('\n╔══════════════════════════════════════════════════════╗');
  console.log('║              jenga doctor — orphan scan             ║');
  console.log('╚══════════════════════════════════════════════════════╝\n');

  const scans = MIRROR_ROOTS
    .map((root) => ({ root, destRoot: path.join(targetRoot, root) }))
    .filter(({ destRoot }) => fs.existsSync(destRoot))
    .map(({ root, destRoot }) => ({ root, destRoot, ...scanRoot({ destRoot, packageRoot }) }));

  const grandTotal = scans.reduce((n, s) => n + s.total, 0);

  if (grandTotal === 0) {
    console.log('  ✓ No orphan candidates found. Nothing to clean up.\n');
    return { deleted: [], total: 0 };
  }

  for (const s of scans) {
    if (s.total === 0) continue;
    console.log(`  ${s.root}/ — ${s.total} candidate file(s):`);
    for (const group of s.groups) {
      console.log(`    ${group.label} (${group.files.length} file(s))`);
    }
  }
  console.log(`\n  Total: ${grandTotal} candidate file(s) across ${scans.length} mirror root(s).\n`);

  if (dryRun) {
    console.log('  --dry-run: no files were deleted.\n');
    return { deleted: [], total: grandTotal, dryRun: true };
  }

  if (!isInteractive) {
    console.log('  Non-interactive session detected — nothing deleted.');
    console.log('  Re-run `jenga doctor` interactively to confirm deletion.\n');
    return { deleted: [], total: grandTotal, nonInteractive: true };
  }

  const confirmed = await confirmFn(`Delete all ${grandTotal} candidate file(s) listed above?`);
  if (!confirmed) {
    console.log('\n  Declined — nothing was deleted.\n');
    return { deleted: [], total: grandTotal, confirmed: false };
  }

  let totalDeleted = 0;
  for (const s of scans) {
    if (s.total === 0) continue;
    const { deleted, refused, prunedDirs } = deleteGroups({ destRoot: s.destRoot, groups: s.groups });
    totalDeleted += deleted.length;
    if (deleted.length > 0) {
      console.log(`  ✓ ${s.root}/ — ${deleted.length} file(s) removed` +
        (prunedDirs.length ? `, ${prunedDirs.length} empty dir(s) pruned` : ''));
    }
    for (const r of refused) {
      console.log(`  ⚠  ${s.root}/${r.path} — left in place (${r.reason})`);
    }
  }

  console.log(`\n  Done. ${totalDeleted} file(s) removed.\n`);
  return { deleted: totalDeleted, total: grandTotal, confirmed: true };
}

export default { runDoctor, scanRoot };
