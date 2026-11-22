/**
 * lib/sync.js — shared consumer sync (E26_S11_T02)
 *
 * The one implementation that brings a consumer project's framework files in line with the
 * installed `@jenga-ai/agent` package. Two callers share it so neither can drift from the other:
 *
 *   - `scripts/postinstall.js`   npm lifecycle hook, version-gated (runs on first install / upgrade)
 *   - `lib/commands/sync.js`     `jenga sync [--dry-run]`, unconditional, for the case where npm or
 *                                pnpm blocked the hook, or the user wants to preview the changes
 *
 * `syncConsumer` runs these steps in order and returns a structured result:
 *
 *   1. Mirror `skills/` and `agents/` into `<consumer>/.claude/` and `<consumer>/.agents/`
 *      (`lib/mirror.js`, additive: `reconcileDeletes: false`) plus the manifest-based delete
 *      reconciliation and legacy-path seeding described below.
 *   2. Regenerate `lib/skill-allow-list.json` inside the installed package (before any generator
 *      that reads it).
 *   3. `.github/copilot-instructions.md` and `.github/hooks/jenga.json`.
 *   4. The Jenga block in `CLAUDE.md` and `AGENTS.md` (`generateAgentContext`; the J- collision
 *      rule applies). Runs after step 2 because the block renders the allow-list.
 *   5. Repair a legacy array-shaped `project/logs/events.json` (`lib/events-log-repair.js`).
 *   6. Merge the shipped settings fragments into `<consumer>/.claude/settings.json` and
 *      `.agents/settings.json` (`scripts/merge-settings.sh`, E100_S03): hooks, per-key `env`, and `permissions.allow` rules, additive and
 *      idempotent, never touching a client entry. The allow rules are opt-in: the script asks only when
 *      `interactive` is set (`jenga sync` on a terminal), never from postinstall, CI or a dry run, and
 *      otherwise reports them inactive. Exit 6 ("completed with conflicts or inactive allow rules") is a
 *      warning in the summary, not a failure; any other non-zero exit fails the step.
 *   7. Add the required checklist ids an EXISTING project instance (`<configs>/checklists.json`) lacks
 *      (`scripts/checklist-required-merge.sh`, E99_S04_T05; decision E99_S04_T02, option 3): only the ids
 *      declared in `templates/checklist-required-ids.json`, each copied from `templates/checklists.json`,
 *      appended after the instance's last item with every other byte unchanged, validated and moved into
 *      place atomically under a lock. Never creates an instance; a second run writes nothing. A non-zero
 *      exit fails the step and leaves the instance untouched.
 *   8. Write `.jenga-version`.
 *
 * It never modifies `jenga.cli.json`, never writes outside `.claude/` (the mirrors and `settings.json`), `.agents/`, `.github/`,
 * `CLAUDE.md`, `AGENTS.md`, `J-*.md`, `project/logs/events.json`, an existing `<configs>/checklists.json`
 * (step 7, required ids only) and `.jenga-version` (the allow-list
 * artifact lives in the installed package's own `lib/`), and never deletes a consumer-owned file.
 *
 * `dryRun: true` computes the same plan, writes nothing and creates no directory in the consumer
 * tree. Steps that depend on an earlier step's output (the allow-list and the skill list, which a
 * real run reads from the freshly mirrored `skills/`) are computed from an in-memory-equivalent
 * simulation of that mirror kept in a throwaway directory under the OS temp dir, so the dry run
 * reports what the real run would produce rather than what the stale tree holds today.
 *
 * Mirror and generator output is reported through the injected `log` function only; this module
 * never calls `console.*` itself. Each step after the mirror keeps the best-effort contract of the
 * old postinstall: a failure is reported (and recorded in `result.failures`) and never aborts the
 * others. A `mirror()` failure propagates, as it always did.
 *
 * ── Upgrade cleanup — manifest-based delete reconciliation (E26_S08_T01) ─────────────────────
 * Additive-only mirroring means a release that renames, removes, or excludes a skill leaves the
 * previously installed copies in the consumer's mirror roots forever, so old and new forms both
 * keep loading. To clean those up *without* risking consumer-authored files, each run records
 * what it wrote and the next run removes only what it itself wrote last time and did not write
 * again. `reconcileDeletes` on `mirror()` stays off: it diffs the destination against the source
 * tree with no notion of who wrote a file, so enabling it would delete a consumer's own skills.
 *
 *   Location : one manifest per destination root, inside that root —
 *                <consumer>/.agents/.jenga-postinstall-manifest.json
 *                <consumer>/.claude/.jenga-postinstall-manifest.json
 *   Rule     : a path is deleted only if a manifest previously written by THIS package lists it AND
 *              the current run did not write it. No prior manifest means no inferred deletions;
 *              every parse/IO failure degrades to additive-only.
 *   Skipped  : if any `copySet` entry is missing from the package (a packaging regression), BOTH
 *              the delete pass and the manifest write are skipped for that run. The previous
 *              manifest is left in place because it still describes what is on disk.
 *   Idempotent: the manifest is rewritten only when its package, version or path list differ, so
 *              a second run leaves every file byte-identical.
 *
 * ── Legacy-path seeding — first-manifest orphan cleanup (E26_S08_T03) ────────────────────────
 * On the `no-prior-manifest` branch the run seeds a SYNTHETIC prior path list from
 * `lib/legacy-shipped-paths.json` (paths known to have shipped in some real prior published
 * version), intersected with what is ACTUALLY a regular file on disk in that mirror root, and
 * reconciles it against this run's copy set at once (adopt-then-reconcile). A path absent from
 * every published version is never seeded, so a consumer's hand-authored file stays untouchable.
 * A genuine first-ever install has nothing on disk to intersect with, so the seed is empty and
 * this falls through to additive-only.
 *
 * The reconciliation engine and its safety invariants live in `lib/postinstall-manifest.js`; the
 * legacy list generation in `scripts/generate-legacy-shipped-paths.js`; consumer-facing docs in
 * `project/documentation/distribution.md`.
 *
 * ESM, Node built-ins only.
 */

import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';

import { mirror } from './mirror.js';
import {
  toRelativePaths,
  readManifest,
  reconcileFromManifest,
  reconcileWithPriorPaths,
  seedFromLegacyPaths,
  writeManifest,
} from './postinstall-manifest.js';
import { readLegacyShippedPaths } from '../scripts/generate-legacy-shipped-paths.js';
import { generateCopilotInstructions } from './generate-copilot-instructions.js';
import { generateCopilotHooks } from './generate-copilot-hooks.js';
import { generateAgentContext } from './generate-agent-context.js';
import { generateSkillAllowList, getSkillAllowListIdentifiers } from './generate-skill-allow-list.js';
import { classifyEventsLog, repairEventsLog } from './events-log-repair.js';

/** Discovery-bound dirs mirrored to both `.claude/` (Claude Code) and `.agents/` (Copilot / custom). */
const COPY_SET = ['skills', 'agents'];
const TARGET_ROOTS = ['.claude', '.agents'];

// ── helpers ──────────────────────────────────────────────────────────────────

/**
 * Very small semver comparator.
 * Returns 1 if a > b, -1 if a < b, 0 if equal.
 */
export function semverCompare(a, b) {
  const clean = (v) => String(v || '0.0.0').replace(/[^0-9.]/g, '');
  const parts = (v) => clean(v).split('.').map(Number);
  const [aMaj, aMin, aPat] = parts(a);
  const [bMaj, bMin, bPat] = parts(b);
  if (aMaj !== bMaj) return aMaj > bMaj ? 1 : -1;
  if (aMin !== bMin) return aMin > bMin ? 1 : -1;
  if (aPat !== bPat) return aPat > bPat ? 1 : -1;
  return 0;
}

/** True when both paths resolve to the same directory, by lexical path and by real path. */
export function samePath(a, b) {
  if (path.resolve(a) === path.resolve(b)) return true;
  try {
    return fs.realpathSync(a) === fs.realpathSync(b);
  } catch (_) {
    return false;
  }
}

const posix = (p) => p.split(path.sep).join('/');

/** Recursively list regular files under `dir`, relative to `root` and POSIX-separated. */
function listFiles(root, dir, out = []) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return out;
  }
  for (const entry of entries) {
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) listFiles(root, abs, out);
    else if (entry.isFile()) out.push(posix(path.relative(root, abs)));
  }
  return out;
}

/**
 * Build, in a throwaway directory, the `skills/` tree a real run would leave in `destRoot`:
 * every skill directory already there plus every skill directory the package ships, minus those
 * the reconciliation would empty. Only each skill's `SKILL.md` is copied, which is all the
 * allow-list and the skill-list generators read. Used for `dryRun` only.
 *
 * @returns {string} absolute path of the simulated `skills/` directory
 */
function simulateSkillsDir({ tmpBase, label, destRoot, packageRoot, deletedRel }) {
  const simSkills = path.join(tmpBase, label, 'skills');
  fs.mkdirSync(simSkills, { recursive: true });
  const deleted = new Set(deletedRel);

  const existingDir = path.join(destRoot, 'skills');
  if (fs.existsSync(existingDir)) {
    for (const entry of fs.readdirSync(existingDir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const files = listFiles(destRoot, path.join(existingDir, entry.name));
      // A directory survives unless every file in it is one the reconciliation removes.
      if (files.length > 0 && files.every((f) => deleted.has(f))) continue;
      const dest = path.join(simSkills, entry.name);
      fs.mkdirSync(dest, { recursive: true });
      const skillMd = path.join(existingDir, entry.name, 'SKILL.md');
      if (fs.existsSync(skillMd) && !deleted.has(`skills/${entry.name}/SKILL.md`)) {
        fs.copyFileSync(skillMd, path.join(dest, 'SKILL.md'));
      }
    }
  }

  const pkgSkills = path.join(packageRoot, 'skills');
  if (fs.existsSync(pkgSkills)) {
    for (const entry of fs.readdirSync(pkgSkills, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const dest = path.join(simSkills, entry.name);
      fs.mkdirSync(dest, { recursive: true });
      const skillMd = path.join(pkgSkills, entry.name, 'SKILL.md');
      if (fs.existsSync(skillMd)) fs.copyFileSync(skillMd, path.join(dest, 'SKILL.md'));
    }
  }
  return simSkills;
}

/** `{ version, name }` of the package at `packageRoot`; defaults when package.json is unreadable. */
export function readPackageInfo(packageRoot) {
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));
    return { version: pkg.version || '0.0.0', name: pkg.name || '' };
  } catch (_) {
    return { version: '0.0.0', name: '' }; // non-fatal — proceed with default
  }
}

/**
 * Consumer-relative POSIX path of the project checklist instance, for the change list (step 7). Resolved the
 * way the merge script resolves it: scripts/resolve-root.sh from the consumer root (JENGA_PROJECT_ROOT unset),
 * then the physical path as the operating system resolves it (fs.realpathSync.native, realpath(3)), following
 * ".." and symlinked directories component by component, compared with the physical consumer root. The configs
 * path is joined as text and never normalised first: path.resolve and the JS fs.realpathSync both normalise
 * lexically, which turns "missing/../link" into "link" although the OS cannot resolve it. A path with a missing
 * component throws here, matching the script, which writes nothing for it.
 * Returns null when that cannot be determined or the result lies outside the consumer root (the script refuses
 * that layout, exit 1), so the summary never names a file other than the one the script wrote.
 */
function checklistInstanceRel(consumerRoot, packageRoot) {
  try {
    const env = { ...process.env };
    delete env.JENGA_PROJECT_ROOT;
    const r = spawnSync('bash', [path.join(packageRoot, 'scripts', 'resolve-root.sh'), 'get', 'configs'],
      { cwd: consumerRoot, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    const configs = (r.stdout || '').trim();
    if (r.status !== 0 || !configs) return null;
    const root = fs.realpathSync.native(consumerRoot);
    // Joined as text, like the script's "$CONSUMER/$p": no path.resolve / path.join, which would drop "x/..".
    const raw = path.isAbsolute(configs) ? configs : `${root}${path.sep}${configs}`;
    const rel = path.relative(root, path.join(fs.realpathSync.native(raw), 'checklists.json'));
    const outside = !rel || rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel);
    return outside ? null : posix(rel);
  } catch (_) {
    return null;
  }
}

// ── main ─────────────────────────────────────────────────────────────────────

/**
 * @param {object}   opts
 * @param {string}   opts.packageRoot   Installed package root (source of skills/, agents/, templates/).
 * @param {string}   opts.consumerRoot  Consumer project root to bring in line.
 * @param {boolean} [opts.dryRun=false] Compute and report; write nothing in the consumer tree.
 * @param {boolean} [opts.interactive=false] Let step 6 ask on the terminal whether to write the opt-in
 *   `permissions.allow` rules. Only `jenga sync` on a terminal sets it; ignored under `dryRun`.
 * @param {function} [opts.log]         Receives every output line. Default `console.log`.
 * @returns {{
 *   skipped?: 'inside-package',
 *   ok: boolean, dryRun: boolean,
 *   packageVersion: string, packageName: string,
 *   copied: number, skippedFiles: number, deleted: number, changed: number,
 *   changes: Array<{path: string, action: string}>,
 *   roots: Object<string, {added: string[], overwritten: string[], removed: string[], skipped: number}>,
 *   agentContext: {written: object[], changed: boolean, skipped?: boolean}|null,
 *   steps: Array<{step: string, status: string, detail?: string}>,
 *   warnings: string[],
 *   failures: Array<{step: string, message: string}>
 * }}
 *   `changes` lists every file that was (or, under `dryRun`, would be) added, overwritten, removed
 *   or regenerated, as consumer-relative POSIX paths; `changed` is its length, so a second real run
 *   over an unchanged tree reports `changed: 0`. `skippedFiles` counts byte-identical mirror files.
 */
export function syncConsumer({ packageRoot, consumerRoot, dryRun = false, interactive = false, log = console.log } = {}) {
  if (!packageRoot || !consumerRoot) {
    throw new TypeError('syncConsumer: `packageRoot` and `consumerRoot` are required');
  }

  const { version: packageVersion, name: packageName } = readPackageInfo(packageRoot);
  const result = {
    ok: true,
    dryRun,
    packageVersion,
    packageName,
    copied: 0,
    skippedFiles: 0,
    deleted: 0,
    changed: 0,
    changes: [],
    roots: {},
    agentContext: null,
    steps: [],
    warnings: [],
    failures: [],
  };

  // Mirroring a package into itself would overwrite the repo with its own files.
  if (samePath(consumerRoot, packageRoot)) {
    result.skipped = 'inside-package';
    return result;
  }

  const would = dryRun ? ' would be' : '';
  const note = (step, status, detail) => result.steps.push({ step, status, ...(detail ? { detail } : {}) });
  const fail = (step, message) => {
    result.failures.push({ step, message });
    result.ok = false;
    note(step, 'failed', message);
  };
  const change = (rel, action) => result.changes.push({ path: rel, action });

  // ── 1. mirror + manifest reconciliation ────────────────────────────────────
  // A copySet entry missing from the package is a PACKAGING regression, not a signal that the
  // consumer should lose those files. mirror() silently skips a missing source, so `currentPaths`
  // would under-report everything under that entry and the delete pass would read the whole
  // mirrored subtree as stale and wipe it — turning a bad publish into mass deletion on every
  // consumer that installs it. So when anything is missing BOTH the delete pass and the manifest
  // write are skipped; the previous manifest still describes what is on disk.
  const missingEntries = [];
  for (const entry of COPY_SET) {
    if (!fs.existsSync(path.join(packageRoot, entry))) {
      log(`  ⚠  ${entry}/ not found in package — skipped`);
      missingEntries.push(entry);
    }
  }
  const reconcileSafe = missingEntries.length === 0;
  if (!reconcileSafe) {
    log(
      `  ⚠  Upgrade cleanup skipped — ${missingEntries.join(', ')} missing from the package. ` +
      'Existing mirrored files are left untouched.'
    );
    note('upgrade-cleanup', 'skipped', `${missingEntries.join(', ')} missing from the package`);
  }

  const deletedByRoot = {};
  for (const targetRoot of TARGET_ROOTS) {
    const destRoot = path.join(consumerRoot, targetRoot);
    const rel = (abs) => posix(path.relative(consumerRoot, abs));

    // Consumer install is additive-only: never delete files from the mirror.
    const mirrored = mirror({
      sourceRoot: packageRoot,
      destRoot,
      copySet: COPY_SET,
      dryRun,
      reconcileDeletes: false,
    });

    // The per-directory line reports added + overwritten ("N file(s) copied").
    for (const entry of COPY_SET) {
      const prefix = path.join(destRoot, entry);
      const wrote =
        mirrored.added.filter((p) => p.startsWith(prefix)).length +
        mirrored.overwritten.filter((p) => p.startsWith(prefix)).length;
      log(`  ✓ ${targetRoot}/${entry}/ — ${wrote} file(s)${would} copied`);
    }

    const rootDetail = {
      added: mirrored.added.map(rel),
      overwritten: mirrored.overwritten.map(rel),
      removed: [],
      skipped: mirrored.skipped.length,
    };
    result.roots[targetRoot] = rootDetail;
    for (const p of rootDetail.added) change(p, 'added');
    for (const p of rootDetail.overwritten) change(p, 'overwritten');

    // The copy set for manifest purposes is added + overwritten + SKIPPED. Including `skipped` is
    // essential: a byte-identical file mirror() skipped is still package-owned, and leaving it out
    // would make the very next run classify it as stale and delete it.
    const currentPaths = toRelativePaths(destRoot, [
      ...mirrored.added,
      ...mirrored.overwritten,
      ...mirrored.skipped,
    ]);

    deletedByRoot[targetRoot] = [];
    try {
      let recon = reconcileSafe
        ? reconcileFromManifest({ destRoot, currentPaths, dryRun })
        : { deleted: [], prunedDirs: [], refused: [], reason: 'skipped-incomplete-package' };

      // Legacy-path seeding (E26_S08_T03): `no-prior-manifest` is either a genuine first install or
      // a consumer installed before the manifest mechanism existed; seed from known-shipped legacy
      // paths that really are on disk, and reconcile in the same run.
      if (reconcileSafe && recon.reason === 'no-prior-manifest') {
        const legacyPathsFile = path.join(packageRoot, 'lib', 'legacy-shipped-paths.json');
        const legacyPaths = readLegacyShippedPaths(legacyPathsFile);
        const seeded = seedFromLegacyPaths({ destRoot, legacyPaths });
        if (seeded.length > 0) {
          const seedRecon = reconcileWithPriorPaths({ destRoot, priorPaths: seeded, currentPaths, dryRun });
          // Only a distinct outcome when the seed produced something to report; a seeded path this
          // release still ships is neither stale nor refused.
          if (seedRecon.deleted.length > 0 || seedRecon.prunedDirs.length > 0 || seedRecon.refused.length > 0) {
            recon = { ...seedRecon, reason: 'seeded-reconciled' };
          }
        }
      }

      if (recon.reason === 'skipped-incomplete-package') {
        // already reported once above, per-run rather than per-root
      } else if (recon.reason === 'no-prior-manifest') {
        log(`  ℹ  ${targetRoot}/ — no previous install manifest; additive copy only (no deletes)`);
      } else if (recon.deleted.length > 0 || recon.prunedDirs.length > 0) {
        const suffix = recon.reason === 'seeded-reconciled' ? ' (seeded from known-shipped legacy paths)' : '';
        log(
          `  ✓ ${targetRoot}/ — ${recon.deleted.length} stale file(s)${would} removed${suffix}` +
          (recon.prunedDirs.length ? `, ${recon.prunedDirs.length} empty dir(s) pruned` : '')
        );
      }
      for (const r of recon.refused) {
        log(`  ⚠  ${targetRoot}/${r.path} — left in place (${r.reason})`);
      }
      deletedByRoot[targetRoot] = recon.deleted;
      rootDetail.removed = recon.deleted.map((p) => `${targetRoot}/${p}`);
      for (const p of rootDetail.removed) change(p, 'removed');
      result.deleted += recon.deleted.length;
    } catch (e) {
      // Cleanup is best-effort: a reconciliation failure must never fail the install.
      log(`  ⚠  ${targetRoot}/ — upgrade cleanup skipped (${e.message})`);
      fail(`upgrade-cleanup:${targetRoot}`, e.message);
    }

    try {
      if (reconcileSafe) {
        // Rewrite the manifest only when it would say something different: its `generated_at`
        // changes on every write, and a no-op run must leave every file byte-identical.
        const prior = readManifest(destRoot);
        const same =
          prior !== null &&
          prior.package === packageName &&
          prior.package_version === packageVersion &&
          prior.paths.length === currentPaths.length &&
          prior.paths.every((p, i) => p === currentPaths[i]);
        if (!same) {
          writeManifest({ destRoot, currentPaths, packageName, packageVersion, dryRun });
          change(`${targetRoot}/.jenga-postinstall-manifest.json`, prior === null ? 'added' : 'overwritten');
        }
      }
    } catch (e) {
      log(`  ⚠  ${targetRoot}/ — could not write install manifest (${e.message})`);
      fail(`manifest:${targetRoot}`, e.message);
    }

    result.copied += mirrored.added.length + mirrored.overwritten.length;
    result.skippedFiles += mirrored.skipped.length;
  }
  note('mirror', 'ok');

  // A dry run has not mirrored anything, so the steps below read a simulation of what the mirror
  // would leave behind instead of the stale tree (see the module header).
  let tmpBase = null;
  let simAgentsSkills;
  let simClaudeSkills;
  let simIds;
  if (dryRun) {
    try {
      tmpBase = fs.mkdtempSync(path.join(os.tmpdir(), 'jenga-sync-dryrun-'));
      simAgentsSkills = simulateSkillsDir({
        tmpBase, label: 'agents', destRoot: path.join(consumerRoot, '.agents'), packageRoot,
        deletedRel: deletedByRoot['.agents'],
      });
      simClaudeSkills = simulateSkillsDir({
        tmpBase, label: 'claude', destRoot: path.join(consumerRoot, '.claude'), packageRoot,
        deletedRel: deletedByRoot['.claude'],
      });
      simIds = getSkillAllowListIdentifiers(simAgentsSkills);
    } catch (e) {
      fail('dry-run-simulation', e.message);
    }
  }

  try {
    // ── 2. skill allow-list (E50_S02) ──────────────────────────────────────────
    // Regenerated from the freshly mirrored `.agents/skills` BEFORE the generators below, which
    // render it. The output goes into this installed package's own `lib/` (never the consumer
    // root), the path the MCP router and native routing enforcement read at runtime.
    try {
      const allow = generateSkillAllowList(
        dryRun && simAgentsSkills ? simAgentsSkills : path.join(consumerRoot, '.agents', 'skills'),
        path.join(packageRoot, 'lib', 'skill-allow-list.json'),
        { dryRun }
      );
      log(`  ✓ lib/skill-allow-list.json ${dryRun ? 'would be regenerated' : 'regenerated'} (${allow.skill_count} skills)`);
      if (allow.changed) change('lib/skill-allow-list.json (installed package)', 'regenerated');
      note('allow-list', 'ok');
    } catch (e) {
      log(`  ⚠  Could not regenerate lib/skill-allow-list.json — ${e.message}`);
      fail('allow-list', e.message);
    }

    // ── 3. Copilot files ───────────────────────────────────────────────────────
    // Unconditional and non-interactive. `.agents/skills` is the skills directory the mirror just
    // populated, whatever agentTarget the user eventually picks in `jenga init`; the generator's
    // idempotent marker-replace lets a later `jenga init` refine the file without duplicating it.
    try {
      const ci = generateCopilotInstructions(
        consumerRoot, packageRoot,
        dryRun && simAgentsSkills ? simAgentsSkills : '.agents/skills',
        { dryRun, ...(dryRun && simIds ? { allowedSkillIds: simIds } : {}) }
      );
      if (ci.skipped) {
        log('  ⚠  templates/copilot-instructions.md.tpl not found — skipped .github/copilot-instructions.md bootstrap');
        note('copilot-instructions', 'skipped', 'template not found');
      } else {
        log(`  ✓ .github/copilot-instructions.md ${dryRun ? 'would be bootstrapped' : 'bootstrapped'}`);
        if (ci.changed) change('.github/copilot-instructions.md', 'regenerated');
        note('copilot-instructions', 'ok');
      }
    } catch (e) {
      log(`  ⚠  Could not bootstrap .github/copilot-instructions.md — ${e.message}`);
      fail('copilot-instructions', e.message);
    }

    // `.github/hooks/jenga.json` wires Copilot CLI's native sessionEnd/userPromptSubmitted hooks to
    // this package's hooks, using absolute node_modules/@jenga-ai/agent paths. Entirely Jenga-owned,
    // so a plain idempotent overwrite.
    try {
      const ch = generateCopilotHooks(consumerRoot, packageRoot, { dryRun });
      log(`  ✓ .github/hooks/jenga.json ${dryRun ? 'would be bootstrapped' : 'bootstrapped'} (${ch.path})`);
      if (ch.changed) change('.github/hooks/jenga.json', 'regenerated');
      note('copilot-hooks', 'ok');
    } catch (e) {
      log(`  ⚠  Could not bootstrap .github/hooks/jenga.json — ${e.message}`);
      fail('copilot-hooks', e.message);
    }

    // ── 4. Jenga block in CLAUDE.md / AGENTS.md ────────────────────────────────
    // Only the text between <!-- JENGA:START --> and <!-- JENGA:END --> is rewritten; the J-
    // collision rule applies. Must run after the allow-list step, which the block renders.
    try {
      const ac = generateAgentContext(consumerRoot, packageRoot, {
        dryRun,
        ...(dryRun && simClaudeSkills ? { skillsDir: simClaudeSkills } : {}),
        ...(dryRun && simIds ? { allowedSkillIds: simIds } : {}),
      });
      result.agentContext = ac;
      if (ac.skipped) {
        log('  ⚠  templates/agent-context.md.tpl not found — skipped CLAUDE.md/AGENTS.md generation');
        note('agent-context', 'skipped', 'template not found');
      } else {
        for (const w of ac.written) {
          const where = w.file && w.file !== w.filename ? `${w.file} (for ${w.filename})` : w.filename;
          const state = w.changed ? (dryRun ? 'would be updated' : 'updated') : 'unchanged';
          log(`  ✓ ${where} — Jenga block ${state} (${w.mode})`);
          if (w.changed) change(w.file || w.filename, w.mode === 'direct-write' || w.mode === 'collision-created-j-file' ? 'created' : 'regenerated');
        }
        note('agent-context', 'ok');
      }
    } catch (e) {
      log(`  ⚠  Could not generate CLAUDE.md/AGENTS.md — ${e.message}`);
      fail('agent-context', e.message);
    }

    // ── 5. legacy array-shaped event log (E75_S02_T01) ─────────────────────────
    // The shared log has been JSONL since E75_S01_T02 and scripts/events-append.sh refuses the old
    // array, so convert it once with scripts/events-log-migrate.sh (verified before writing,
    // atomic, locked). A missing, empty or JSONL log is not touched, and any failure is reported
    // and then ignored: the script leaves the original file untouched in every case.
    try {
      const repair = dryRun
        ? { ...classifyEventsLog(consumerRoot), attempted: false, migrated: false }
        : repairEventsLog(consumerRoot, { packageRoot });
      if (dryRun && repair.state === 'array') {
        log(`  ✓ project/logs/events.json — array-shaped event log would be migrated to JSONL (${repair.count} entries)`);
        change('project/logs/events.json', 'migrated');
      } else if (repair.migrated) {
        log(`  ✓ project/logs/events.json — array-shaped event log migrated to JSONL (${repair.count} entries)`);
        change('project/logs/events.json', 'migrated');
      } else if (repair.state === 'other') {
        log(`  ⚠  ${repair.path} — not migrated: ${repair.reason}; file left unchanged`);
      } else if (repair.attempted) {
        const detail = (repair.stderr || repair.stdout || '').trim();
        log(`  ⚠  ${repair.path} — event log migration failed (exit ${repair.exitCode}); file left unchanged`);
        if (detail) log(`     ${detail.split('\n').join('\n     ')}`);
        fail('events-log', `migration failed (exit ${repair.exitCode})`);
      }
      note('events-log', 'ok');
    } catch (e) {
      log(`  ⚠  Could not check project/logs/events.json — ${e.message}`);
      fail('events-log', e.message);
    }

    // ── 6. settings merge in .claude/settings.json and .agents/settings.json (E100_S03_T07) ──
    // Nothing else in the install path writes hooks, env or allow rules into a consumer's settings, so a
    // project updated from a release that predates one never got it. Best-effort like the event-log
    // repair: a failure is reported and never aborts the sync. Exit 6 is a warning, not a failure.
    try {
      const script = path.join(packageRoot, 'scripts', 'merge-settings.sh');
      if (!fs.existsSync(script)) {
        note('hooks', 'skipped', 'scripts/merge-settings.sh not found');
      } else {
        const ask = interactive && !dryRun;
        const r = spawnSync('bash', [script, '--consumer-root', consumerRoot, '--package-root', packageRoot,
          ...(dryRun ? ['--dry-run'] : []), ...(ask ? ['--interactive'] : [])],
        { encoding: 'utf8', ...(ask ? { stdio: ['inherit', 'pipe', 'pipe'] } : {}) });
        if (r.status !== 0 && r.status !== 6) {
          const detail = (r.stderr || r.stdout || '').trim();
          log(`  ⚠  Could not merge settings into .claude/settings.json (exit ${r.status})${detail ? ` — ${detail}` : ''}; file left unchanged`);
          fail('hooks', `merge failed (exit ${r.status})`);
        } else {
          const lines = r.stdout.split('\n');
          const events = lines.map((l) => l.match(/^(?:would add|added) (\S+)$/)).filter(Boolean).map((m) => m[1]);
          const other = lines.filter((l) => /^(?:would add|added) (?:env|allow) |^(?:would remove|removed) /.test(l)).length;
          if (events.length > 0) {
            log(`  ✓ .claude/settings.json — hooks ${dryRun ? 'would be registered' : 'registered'}: ${events.join(', ')}`);
            change('.claude/settings.json', 'hooks-registered');
          }
          if (other > 0) {
            log(`  ✓ .claude/settings.json, .agents/settings.json — ${other} env/allow/removal entr${other === 1 ? 'y' : 'ies'} ${dryRun ? 'would be updated' : 'updated'}`);
            if (events.length === 0) change('.claude/settings.json', 'settings-updated');
          }
          if (r.status === 6) {
            const conflicts = lines.filter((l) => /^conflict /.test(l)).length;
            const inactive = lines.filter((l) => /^inactive allow /.test(l)).length;
            const msg = (conflicts + inactive) > 0
              ? `settings: ${conflicts} conflict(s), ${inactive} allow rule(s) inactive`
              : 'settings: completed with conflicts or inactive entries (exit 6)';
            log(`  ⚠  ${msg}; those requirements are inactive${inactive > 0 && !ask ? ' (allow rules are only written after a yes at the terminal: run jenga sync)' : ''}`);
            result.warnings.push(msg);
            note('hooks', 'warning', msg);
          } else {
            note('hooks', 'ok');
          }
        }
      }
    } catch (e) {
      log(`  ⚠  Could not merge settings into .claude/settings.json — ${e.message}`);
      fail('hooks', e.message);
    }

    // ── 7. required checklist ids in an existing project instance (E99_S04_T05) ──────────────
    // scripts/checklist.sh reads the project instance whole when it exists, so an instance that predates a
    // required id (templates/checklist-required-ids.json) keeps failing the script that needs it. The merge
    // script adds only those ids, never creates an instance, and leaves the file untouched on any failure.
    // Best-effort like the settings merge: a failure is reported and never aborts the sync.
    try {
      const script = path.join(packageRoot, 'scripts', 'checklist-required-merge.sh');
      if (!fs.existsSync(script)) {
        note('checklist-required', 'skipped', 'scripts/checklist-required-merge.sh not found');
      } else {
        const r = spawnSync('bash', [script, '--consumer-root', consumerRoot, '--package-root', packageRoot,
          ...(dryRun ? ['--dry-run'] : [])], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
        if (r.error || r.status !== 0) {
          const detail = (r.stderr || (r.error && r.error.message) || '').trim();
          const code = r.error ? 'not run' : `exit ${r.status}`;
          log(`  ⚠  Could not add the required checklist ids to the project checklist registry (${code})${detail ? ` — ${detail}` : ''}; file left unchanged`);
          fail('checklist-required', `merge failed (${code})`);
        } else {
          const ids = (r.stdout || '').split('\n').map((l) => l.match(/^(?:would add|added) (\S+)$/)).filter(Boolean).map((m) => m[1]);
          if (ids.length > 0) {
            log(`  ✓ project checklist registry — required item(s) ${dryRun ? 'would be added' : 'added'}: ${ids.join(', ')}`);
            // The script wrote (or would write) the instance at its physical path inside the consumer root; when
            // that path cannot be named here, the entry says so rather than naming a guessed file.
            const rel = checklistInstanceRel(consumerRoot, packageRoot);
            change(rel || '<configs>/checklists.json (path not determined)', 'checklist-ids-added');
          }
          note('checklist-required', 'ok', ids.length > 0 ? ids.join(', ') : undefined);
        }
      }
    } catch (e) {
      log(`  ⚠  Could not add the required checklist ids — ${e.message}`);
      fail('checklist-required', e.message);
    }

    // ── 8. .jenga-version ──────────────────────────────────────────────────────
    try {
      const versionFile = path.join(consumerRoot, '.jenga-version');
      const next = packageVersion + '\n';
      let current = null;
      try { current = fs.readFileSync(versionFile, 'utf8'); } catch (_) { /* first install */ }
      if (current !== next) {
        if (!dryRun) fs.writeFileSync(versionFile, next, 'utf8');
        change('.jenga-version', current === null ? 'added' : 'overwritten');
      }
      note('version-file', 'ok');
    } catch (e) {
      log(`  ⚠  Could not write .jenga-version — ${e.message}`);
      fail('version-file', e.message);
    }
  } finally {
    if (tmpBase) {
      try { fs.rmSync(tmpBase, { recursive: true, force: true }); } catch (_) { /* best effort */ }
    }
  }

  result.changed = result.changes.length;
  return result;
}

export default { syncConsumer, semverCompare, readPackageInfo, samePath };
