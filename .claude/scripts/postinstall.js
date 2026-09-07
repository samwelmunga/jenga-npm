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
 * install always uses `reconcileDeletes: false` (additive-only) — that flag diffs
 * the destination's current contents against the source tree with no notion of who
 * wrote a given file, so enabling it here would delete a consumer's own custom
 * skills. It is deliberately left off; see the manifest mechanism below.
 *
 * Upgrade cleanup — manifest-based delete reconciliation (E26_S08_T01)
 * ────────────────────────────────────────────────────────────────────
 * Additive-only mirroring means a release that renames, removes, or excludes a
 * skill leaves the previously installed copies in the consumer's mirror roots
 * forever, so old and new forms both keep loading. To clean those up *without*
 * risking consumer-authored files, each run records what it wrote and the next run
 * removes only what it itself wrote last time and did not write again.
 *
 *   Location : one manifest per destination root, inside that root —
 *                <consumer>/.agents/.jenga-postinstall-manifest.json
 *                <consumer>/.claude/.jenga-postinstall-manifest.json
 *              Keeping it inside the root it describes means it travels with that
 *              mirror; moving or renaming the consumer project cannot desync it.
 *
 *   Format   : {
 *                "manifest_version": 1,
 *                "package":          "@jenga-ai/agent",
 *                "package_version":  "3.0.1",
 *                "generated_at":     "<ISO 8601>",
 *                "dest_root":        ".agents",
 *                "paths":            ["agents/developer.md", "skills/do/SKILL.md"]
 *              }
 *              `paths` are relative to the destination root, POSIX-separated,
 *              deduped and sorted, and record REGULAR FILES ONLY — never
 *              directories. Directory removal is derived by pruning parents that
 *              become empty, which is precisely why a directory still holding a
 *              consumer file is never removed.
 *
 *   Rule     : a path is deleted only if a manifest previously written by THIS
 *              package's postinstall lists it AND the current run did not write it.
 *              If no prior manifest exists, see the legacy-path seeding note below —
 *              "we don't know what we wrote before" is never treated as "delete
 *              everything we didn't just write". Every parse/IO failure likewise
 *              degrades to additive-only.
 *
 *   Skipped   : if any `copySet` entry is missing from the package (a packaging
 *              regression), BOTH the delete pass and the manifest write are skipped
 *              for that run — otherwise the run would under-report what it wrote and
 *              read an entire mirrored subtree as stale. The previous manifest is
 *              left in place because it still describes what is on disk.
 *
 * Legacy-path seeding — first-manifest orphan cleanup (E26_S08_T03)
 * ────────────────────────────────────────────────────────────────────
 * T01's rule above is purely forward-looking: a consumer already installed BEFORE any
 * manifest existed takes the `no-prior-manifest` branch on their first run of a fixed
 * version, and the manifest that run writes records only what that one run mirrored —
 * pre-existing orphans (e.g. a retired `j:`-form skill, an excluded `j-<name>` twin)
 * were never in it, so they could never become deletion candidates on any FUTURE
 * upgrade either. Confirmed empirically against a throwaway fixture, not merely
 * reasoned about: such a file survived two upgrades, the second with an active delete
 * pass, appearing 0 times in either manifest.
 *
 * On the `no-prior-manifest` branch, this run now additionally seeds a SYNTHETIC prior
 * path list from `lib/legacy-shipped-paths.json` — a static, package-shipped list of
 * paths known to have shipped in some real prior published version (see
 * `scripts/generate-legacy-shipped-paths.js`) — intersected with what is ACTUALLY a
 * regular file on disk in that mirror root right now
 * (`seedFromLegacyPaths` in `lib/postinstall-manifest.js`). If anything seeds, it is
 * reconciled against THIS run's copy set immediately (adopt-then-reconcile), so the
 * cleanup lands on the very upgrade that introduces this feature rather than one cycle
 * later. Provenance stays the entire compensating control: a path absent from every
 * published version's file list is never in `lib/legacy-shipped-paths.json`, so it can
 * never be seeded, regardless of where it sits in the mirror root — a consumer's own
 * hand-authored file was never in any published version and stays untouchable exactly
 * as before. A genuine first-ever install has nothing on disk to intersect with, so the
 * seed set is naturally empty and this falls straight through to the additive-only
 * behaviour — no separate "is this a first install" branch is needed for that to hold.
 * The seeded reconciliation reuses the EXACT SAME boundary/type-checked delete engine
 * as the manifest-backed path (`reconcileWithPriorPaths` shares its core with
 * `reconcileFromManifest`), so invariants 3, 4, and 5 apply unchanged over seeded
 * candidates too.
 *
 * Implementation lives in `lib/postinstall-manifest.js` (full rationale + safety
 * invariants documented there) and `scripts/generate-legacy-shipped-paths.js` (legacy
 * path list generation); consumer-facing docs in `docs/distribution.md`.
 */

import fs   from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { mirror } from '../lib/mirror.js';
import {
  toRelativePaths,
  reconcileFromManifest,
  reconcileWithPriorPaths,
  seedFromLegacyPaths,
  writeManifest,
} from '../lib/postinstall-manifest.js';
import { readLegacyShippedPaths } from './generate-legacy-shipped-paths.js';
import { generateCopilotInstructions } from '../lib/generate-copilot-instructions.js';
import { generateSkillAllowList } from '../lib/generate-skill-allow-list.js';

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
  let packageName    = '';
  try {
    const pkgPath = path.join(packageRoot, 'package.json');
    const pkg     = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
    packageVersion = pkg.version || '0.0.0';
    packageName    = pkg.name || '';
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
  const missingEntries = [];
  for (const entry of copySet) {
    if (!fs.existsSync(path.join(packageRoot, entry))) {
      console.log(`  ⚠  ${entry}/ not found in package — skipped`);
      missingEntries.push(entry);
    }
  }

  // A copySet entry missing from the package is a PACKAGING regression, not a signal
  // that the consumer should lose those files. mirror() silently skips a missing
  // source, so `currentPaths` would under-report everything under that entry and the
  // delete pass would read the whole mirrored subtree as stale and wipe it — turning
  // a bad publish into mass deletion on every consumer that installs it.
  //
  // So when anything is missing we skip BOTH the delete pass and the manifest write.
  // Leaving the previous manifest untouched is deliberate: it still accurately
  // describes what is on disk (those files are still there, just not refreshed), so a
  // later healthy release reconciles correctly against it. Writing an under-reporting
  // manifest here would merely defer the same mass delete to the next run.
  const reconcileSafe = missingEntries.length === 0;
  if (!reconcileSafe) {
    console.log(
      `  ⚠  Upgrade cleanup skipped — ${missingEntries.join(', ')} missing from the package. ` +
      'Existing mirrored files are left untouched.'
    );
  }

  let totalCopied  = 0;
  let totalSkipped = 0;
  let totalDeleted = 0;

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

    // ── Manifest-based delete reconciliation (E26_S08_T01) ───────────────────
    // The copy set for manifest purposes is added + overwritten + SKIPPED. Including
    // `skipped` is essential, not incidental: a file that was byte-identical and
    // therefore skipped by mirror() is still a package-owned path, and leaving it out
    // would make the very next run classify it as stale and delete it.
    const currentPaths = toRelativePaths(destRoot, [
      ...result.added,
      ...result.overwritten,
      ...result.skipped,
    ]);

    // Deletes only ever touch paths a manifest we ourselves wrote lists and this run
    // did not rewrite. No prior manifest => see the E26_S08_T03 seeding branch below.
    try {
      let recon = reconcileSafe
        ? reconcileFromManifest({ destRoot, currentPaths })
        : { deleted: [], prunedDirs: [], refused: [], reason: 'skipped-incomplete-package' };

      // ── Legacy-path seeding (E26_S08_T03) ───────────────────────────────────
      // reconcileFromManifest returned 'no-prior-manifest' — this is either a genuine
      // first-ever install, OR a consumer already installed before this manifest
      // mechanism (E26_S08_T01) existed. The two are indistinguishable from a manifest
      // alone, which is exactly the gap T03 closes: seed a SYNTHETIC prior-path list from
      // this package's known-shipped legacy paths, intersected with what is ACTUALLY a
      // regular file on disk right now (seedFromLegacyPaths never seeds a path that isn't
      // really there), then reconcile against that seed in THIS SAME run
      // (adopt-then-reconcile) rather than waiting one more upgrade cycle. A genuine
      // first-ever install has nothing on disk to intersect with, so the seed set is
      // naturally empty and this falls straight through to the additive-only branch below
      // — no separate first-install check is needed for that to hold.
      if (reconcileSafe && recon.reason === 'no-prior-manifest') {
        const legacyPathsFile = path.join(packageRoot, 'lib', 'legacy-shipped-paths.json');
        const legacyPaths = readLegacyShippedPaths(legacyPathsFile);
        const seeded = seedFromLegacyPaths({ destRoot, legacyPaths });
        if (seeded.length > 0) {
          const seedRecon = reconcileWithPriorPaths({ destRoot, priorPaths: seeded, currentPaths });
          // Only surface this as a distinct outcome if the seed actually produced
          // something to report. A seeded path that is STILL part of this run's own
          // currentPaths (e.g. a legacy path this release still ships) is neither
          // stale nor refused — nothing happened, so the plain "no previous install
          // manifest" additive-only message stays accurate and must not be hidden by
          // an outcome-less 'seeded-reconciled' relabel.
          if (seedRecon.deleted.length > 0 || seedRecon.prunedDirs.length > 0 || seedRecon.refused.length > 0) {
            recon = { ...seedRecon, reason: 'seeded-reconciled' };
          }
        }
      }

      if (recon.reason === 'skipped-incomplete-package') {
        // already reported once above, per-run rather than per-root
      } else if (recon.reason === 'no-prior-manifest') {
        console.log(`  ℹ  ${targetRoot}/ — no previous install manifest; additive copy only (no deletes)`);
      } else if (recon.deleted.length > 0 || recon.prunedDirs.length > 0) {
        const suffix = recon.reason === 'seeded-reconciled' ? ' (seeded from known-shipped legacy paths)' : '';
        console.log(
          `  ✓ ${targetRoot}/ — ${recon.deleted.length} stale file(s) removed${suffix}` +
          (recon.prunedDirs.length ? `, ${recon.prunedDirs.length} empty dir(s) pruned` : '')
        );
        totalDeleted += recon.deleted.length;
      }
      for (const r of recon.refused) {
        console.log(`  ⚠  ${targetRoot}/${r.path} — left in place (${r.reason})`);
      }
    } catch (e) {
      // Cleanup is best-effort: a reconciliation failure must never fail the install.
      console.log(`  ⚠  ${targetRoot}/ — upgrade cleanup skipped (${e.message})`);
    }

    try {
      if (reconcileSafe) {
        writeManifest({ destRoot, currentPaths, packageName, packageVersion });
      }
    } catch (e) {
      console.log(`  ⚠  ${targetRoot}/ — could not write install manifest (${e.message})`);
    }

    totalCopied  += result.added.length + result.overwritten.length;
    totalSkipped += result.skipped.length;
  }

  // Regenerate the canonical skill allow-list (E50_S02) from the freshly mirrored
  // `.agents/skills` BEFORE bootstrapping .github/copilot-instructions.md below — so a consumer
  // install ships a correct, current allow-list from the very first `npm install`, not
  // only after a later `/self-sync`. The output is written into this installed package's own
  // `lib/` (not the consumer root — `lib/` is never duplicated into the consumer per this file's
  // header comment), matching generateSkillAllowList's own default output location and the path
  // the MCP router / native routing enforcement (E50_S02_T03/T04) read from at runtime.
  //
  // Ordering matters (E50_S02_T04): generateCopilotInstructions() below now renders an
  // {{ALLOWED_SKILL_IDS}} block by reading this same lib/skill-allow-list.json path. Running
  // this regeneration first means that render reflects the freshly-mirrored `.agents/skills`
  // scan from this very postinstall run, not the stale artifact committed at publish time.
  // Wrapped in a try/catch-and-warn pattern so a generation failure degrades gracefully
  // (console warning) rather than failing the whole postinstall.
  try {
    const result = generateSkillAllowList(
      path.join(consumerRoot, '.agents', 'skills'),
      path.join(packageRoot, 'lib', 'skill-allow-list.json')
    );
    console.log(`  ✓ lib/skill-allow-list.json regenerated (${result.skill_count} skills)`);
  } catch (e) {
    console.log(`  ⚠  Could not regenerate lib/skill-allow-list.json — ${e.message}`);
  }

  // Bootstrap .github/copilot-instructions.md unconditionally, right after the mirror step —
  // no interactive prompts, since postinstall runs unattended during `npm install`. Without
  // this, a consumer whose very first action is a Copilot slash command (before ever running
  // the separate `jenga init` CLI wizard) gets no `/skill-name` routing instructions at all
  // (E46_S03_T01). `.agents/skills` is passed as the skills directory because that's the
  // directory the mirror step above just populated, regardless of which agentTarget the user
  // eventually picks in `jenga init`. The shared generator's idempotent marker-replace logic
  // (lib/generate-copilot-instructions.js) means a later `jenga init` run — using the user's
  // actual chosen skillsPath — safely refines this file without duplicating the JENGA block.
  try {
    const result = generateCopilotInstructions(consumerRoot, packageRoot, '.agents/skills');
    if (result.skipped) {
      console.log('  ⚠  templates/copilot-instructions.md.tpl not found — skipped .github/copilot-instructions.md bootstrap');
    } else {
      console.log('  ✓ .github/copilot-instructions.md bootstrapped');
    }
  } catch (e) {
    console.log(`  ⚠  Could not bootstrap .github/copilot-instructions.md — ${e.message}`);
  }

  // Write .jenga-version to record the installed version at consumer root
  fs.writeFileSync(versionFile, packageVersion + '\n', 'utf8');

  console.log('\n──────────────────────────────────────────────────────');
  console.log(`  Summary: ${totalCopied} file(s) copied, ${totalSkipped} skipped, ${totalDeleted} stale file(s) removed`);
  console.log(`  .jenga-version written: ${packageVersion}`);
  console.log('──────────────────────────────────────────────────────\n');
}

main();
