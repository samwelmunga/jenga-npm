/**
 * lib/postinstall-manifest.js — Provenance manifest for consumer postinstall mirrors
 *
 * Why this exists (E26_S08_T01)
 * ─────────────────────────────
 * `scripts/postinstall.js` mirrors `skills/` and `agents/` into a consumer's
 * `.claude/` and `.agents/` discovery roots additively — it never deletes
 * (`reconcileDeletes: false`, an intentional E27_S01_T01 decision). That means a
 * release which renames, removes, or excludes a skill leaves the previously
 * installed copies in the consumer's mirror roots forever, and both the old and
 * new forms keep loading.
 *
 * The blanket fix — flipping `lib/mirror.js`'s `reconcileDeletes` to `true` — is
 * unsafe here: that flag's delete logic diffs the destination's *current directory
 * contents* against the source tree, with no notion of who wrote a given file. On a
 * consumer's machine it would happily delete their own hand-authored custom skills
 * sitting alongside package-owned ones.
 *
 * This module is the narrower alternative. It records, per destination root, the
 * exact set of relative paths this package's own postinstall wrote on its last run.
 * A path is eligible for deletion *only* if a manifest previously written by this
 * package lists it and the current run did not write it. Anything a consumer
 * authored themselves was never in a manifest, so it can never be deleted —
 * regardless of where it sits.
 *
 * Manifest location
 * ─────────────────
 * One manifest per destination root, stored inside that root:
 *
 *   <consumer>/.agents/.jenga-postinstall-manifest.json
 *   <consumer>/.claude/.jenga-postinstall-manifest.json
 *
 * Keeping it inside the root it describes means it travels with that mirror: moving
 * or renaming the consumer project cannot desynchronise it, and deleting one mirror
 * root without the other cannot leave a stale record of the deleted one behind.
 *
 * Manifest format
 * ───────────────
 *   {
 *     "manifest_version": 1,
 *     "package":          "@jenga-ai/agent",
 *     "package_version":  "3.0.1",
 *     "generated_at":     "2026-09-07T00:00:00.000Z",
 *     "dest_root":        ".agents",
 *     "paths":            ["agents/developer.md", "skills/do/SKILL.md"]
 *   }
 *
 *   - `paths` are relative to the destination root, POSIX-separated, deduped and
 *     sorted — portable across platforms and independent of the consumer's absolute
 *     project path.
 *   - `paths` records **regular files only**, never directories. Directory removal is
 *     derived by pruning parent directories that become empty after the file deletes.
 *     This is the core safety property: a directory that still holds any consumer file
 *     is not empty, so it is never pruned.
 *   - `manifest_version` lets a future format change be detected; an unrecognised
 *     version is treated as "no manifest", which disables the delete pass.
 *
 * Safety invariants (all four hold independently)
 * ───────────────────────────────────────────────
 *   1. No prior manifest ⇒ no delete pass at all. First installs, and upgrades from
 *      any version predating this feature, are additive-only. "We don't know what we
 *      wrote before" is never treated as "delete everything we didn't just write".
 *   2. A path is deletable only if it appears in a prior manifest written by this
 *      package's postinstall AND is absent from the current run's copy set.
 *   3. Every candidate is boundary-checked to resolve strictly inside its destination
 *      root, and must be a regular file (`lstat`, so symlinks are refused, not
 *      followed). Directories are never deleted directly, only pruned when empty.
 *   4. Every read/parse/IO failure degrades toward doing nothing: a corrupt or
 *      unreadable manifest disables the delete pass rather than guessing.
 *   5. A candidate whose inode identity matches a file THIS run wrote is never
 *      deleted, even if its recorded path string differs. Path-string comparison
 *      alone is not sufficient on a case-insensitive filesystem (macOS APFS,
 *      Windows NTFS) or under Unicode normalisation differences: a case-only
 *      rename makes the old and new manifest strings differ while both resolve to
 *      the SAME file on disk, so a string-only diff would delete the very file the
 *      current run just wrote. Comparing dev+ino closes that whole collision
 *      class rather than special-casing letter case.
 *
 * ESM, Node built-ins only — matching `lib/mirror.js` and `scripts/postinstall.js`.
 */

import fs from 'node:fs';
import path from 'node:path';

/** Filename written into each destination root. */
export const MANIFEST_FILENAME = '.jenga-postinstall-manifest.json';

/** Format version of the manifest this module writes and accepts. */
export const MANIFEST_VERSION = 1;

// ── path helpers ─────────────────────────────────────────────────────────────

/**
 * Boundary predicate: does `child` resolve to a path strictly inside `parent`?
 *
 * Deliberately a *predicate* rather than lib/mirror.js's throwing `assertInside`:
 * a single suspicious manifest entry must be skipped, not allowed to abort an
 * unattended `npm install`.
 *
 * @returns {boolean} true iff child is inside parent (parent itself → false).
 */
export function isInside(parent, child) {
  const rel = path.relative(path.resolve(parent), path.resolve(child));
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}

/**
 * Convert absolute destination paths into manifest-shaped relative paths:
 * POSIX-separated, deduped, sorted. Entries outside `destRoot` are dropped.
 *
 * @param {string}   destRoot Absolute destination root.
 * @param {string[]} absPaths Absolute paths beneath it.
 * @returns {string[]}
 */
export function toRelativePaths(destRoot, absPaths = []) {
  const root = path.resolve(destRoot);
  const out = new Set();
  for (const abs of absPaths) {
    if (typeof abs !== 'string' || abs.length === 0) continue;
    if (!isInside(root, abs)) continue;
    out.add(path.relative(root, path.resolve(abs)).split(path.sep).join('/'));
  }
  return [...out].sort();
}

/** Absolute path of the manifest for a given destination root. */
export function manifestPath(destRoot) {
  return path.join(path.resolve(destRoot), MANIFEST_FILENAME);
}

// ── read / write ─────────────────────────────────────────────────────────────

/**
 * Read the manifest previously written into `destRoot`.
 *
 * Returns `null` for every failure mode — absent, unreadable, unparseable, wrong
 * shape, or an unrecognised `manifest_version`. Callers treat `null` as "no prior
 * manifest", which suppresses the delete pass entirely (invariant 1).
 *
 * @returns {{manifest_version: number, paths: string[]}|null}
 */
export function readManifest(destRoot) {
  let raw;
  try {
    raw = fs.readFileSync(manifestPath(destRoot), 'utf8');
  } catch (_) {
    return null; // absent or unreadable — first install, or pre-feature version
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_) {
    return null; // corrupt — refuse to infer anything from it
  }

  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
  if (parsed.manifest_version !== MANIFEST_VERSION) return null;
  if (!Array.isArray(parsed.paths)) return null;
  if (!parsed.paths.every((p) => typeof p === 'string' && p.length > 0)) return null;

  return parsed;
}

/**
 * Write the manifest for `destRoot`, recording `currentPaths` as the set this run
 * mirrored. Atomic: written to a temp file and renamed, so an interrupted run leaves
 * either the old manifest or the new one — never a truncated one.
 *
 * @param {object}   opts
 * @param {string}   opts.destRoot        Absolute destination root.
 * @param {string[]} opts.currentPaths    Relative POSIX paths written this run.
 * @param {string}  [opts.packageName]
 * @param {string}  [opts.packageVersion]
 * @param {boolean} [opts.dryRun=false]
 * @returns {{path: string, count: number, written: boolean}}
 */
export function writeManifest({
  destRoot,
  currentPaths = [],
  packageName = '',
  packageVersion = '',
  dryRun = false,
} = {}) {
  const target = manifestPath(destRoot);
  const body = {
    manifest_version: MANIFEST_VERSION,
    package: packageName,
    package_version: packageVersion,
    generated_at: new Date().toISOString(),
    dest_root: path.basename(path.resolve(destRoot)),
    paths: [...new Set(currentPaths)].sort(),
  };

  if (dryRun) return { path: target, count: body.paths.length, written: false };

  const tmp = `${target}.tmp-${process.pid}`;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify(body, null, 2) + '\n', 'utf8');
  fs.renameSync(tmp, target);

  return { path: target, count: body.paths.length, written: true };
}

// ── delete reconciliation ────────────────────────────────────────────────────

/**
 * Filesystem identity of a path: `dev:ino`. Returns null if it cannot be stat'd.
 * Two paths with the same identity are the same file, regardless of how their path
 * strings compare — which is exactly the case-insensitive / normalisation situation
 * a string diff gets wrong.
 */
function identityOf(abs) {
  try {
    const st = fs.lstatSync(abs);
    return `${st.dev}:${st.ino}`;
  } catch (_) {
    return null;
  }
}

/**
 * Core diff/delete engine shared by `reconcileFromManifest` (E26_S08_T01) and the
 * legacy-path seeding branch (E26_S08_T03): given a "prior" path list — whether read
 * from a real manifest or seeded from `seedFromLegacyPaths` — delete whatever is in
 * `priorPaths` but absent from `currentPaths`, applying every safety invariant, then
 * prune directories left empty.
 *
 * Extracted as its own function (E26_S08_T03) so seeding can share the EXACT same
 * validated diff/delete logic rather than re-implementing the invariant checks a
 * second time — seeding only ever changes *which paths are eligible for
 * consideration* (via `seedFromLegacyPaths`), never *how a candidate is checked*
 * once it is under consideration. `reconcileFromManifest`'s own behavior and return
 * shape are unchanged by this extraction.
 *
 * @param {object}   opts
 * @param {string}   opts.root          Absolute, already-resolved destination root.
 * @param {string[]} opts.priorPaths    Relative POSIX paths considered previously written.
 * @param {string[]} opts.currentPaths  Relative POSIX paths mirrored by THIS run. Must
 *                                      include paths that were byte-identical and
 *                                      therefore skipped by `mirror()` — a skipped file
 *                                      is still package-owned, and omitting it would make
 *                                      the next run consider it stale.
 * @param {boolean} [opts.dryRun=false] Compute the plan without touching the filesystem.
 * @returns {{deleted: string[], prunedDirs: string[], refused: Array<{path: string, reason: string}>}}
 *          Entries in `refused` carry why they were spared ('outside-dest-root',
 *          'not-a-regular-file', 'written-this-run', ...). Paths in all three arrays are
 *          relative + POSIX.
 */
function reconcilePriorPaths({ root, priorPaths = [], currentPaths = [], dryRun = false }) {
  const result = { deleted: [], prunedDirs: [], refused: [] };

  const current = new Set(currentPaths);
  const stale = priorPaths.filter((p) => !current.has(p));
  const dirsToConsider = new Set();

  // INVARIANT 5 — identity backstop for the path-string diff above.
  // `current` is a case-SENSITIVE string set, but it is used to decide unlinks on a
  // filesystem that may be case-INSENSITIVE. After a case-only rename
  // (skills/x/skill.md -> skills/x/SKILL.md) the two strings differ, so the old name
  // looks stale — yet on macOS/Windows it resolves to the file this run just wrote,
  // and deleting it removes the new file. Built lazily: costs nothing on the
  // overwhelmingly common run where nothing is stale.
  let currentIdentities = null;
  const identitiesWrittenThisRun = () => {
    if (currentIdentities === null) {
      currentIdentities = new Set();
      for (const rel of current) {
        const id = identityOf(path.resolve(root, rel));
        if (id !== null) currentIdentities.add(id);
      }
    }
    return currentIdentities;
  };

  for (const rel of stale) {
    const abs = path.resolve(root, rel);

    // INVARIANT 3a — must resolve strictly inside the destination root.
    if (!isInside(root, abs)) {
      result.refused.push({ path: rel, reason: 'outside-dest-root' });
      continue;
    }
    // Never delete our own bookkeeping file.
    if (path.basename(abs) === MANIFEST_FILENAME) {
      result.refused.push({ path: rel, reason: 'manifest-file' });
      continue;
    }

    let stat;
    try {
      // lstat, not stat: a symlink must be refused, not followed.
      stat = fs.lstatSync(abs);
    } catch (_) {
      continue; // already gone — nothing to do, and not an error
    }

    // INVARIANT 3b — manifests only ever record regular files. Anything else at this
    // path is not what we wrote, so it is not ours to remove.
    if (!stat.isFile()) {
      result.refused.push({ path: rel, reason: 'not-a-regular-file' });
      continue;
    }

    // INVARIANT 5 — refuse anything that IS a file this run wrote, under any name.
    if (identitiesWrittenThisRun().has(`${stat.dev}:${stat.ino}`)) {
      result.refused.push({ path: rel, reason: 'written-this-run' });
      continue;
    }

    try {
      if (!dryRun) fs.rmSync(abs);
      result.deleted.push(rel);
      dirsToConsider.add(path.dirname(abs));
    } catch (e) {
      // INVARIANT 4 — a single EPERM must not abort an unattended npm install.
      result.refused.push({ path: rel, reason: `unlink-failed: ${e.code || e.message}` });
    }
  }

  if (!dryRun) {
    for (const dir of dirsToConsider) {
      pruneEmptyDirs(root, dir, result.prunedDirs);
    }
    result.prunedDirs.sort();
  }

  return result;
}

/**
 * Delete files this package's postinstall wrote on a previous run but did NOT write
 * on this one, then prune any directories left empty by those deletions.
 *
 * @param {object}   opts
 * @param {string}   opts.destRoot      Absolute destination root (e.g. <consumer>/.agents).
 * @param {string[]} opts.currentPaths  Relative POSIX paths mirrored by THIS run. Must
 *                                      include paths that were byte-identical and
 *                                      therefore skipped by `mirror()` — a skipped file
 *                                      is still package-owned, and omitting it would make
 *                                      the next run consider it stale.
 * @param {boolean} [opts.dryRun=false] Compute the plan without touching the filesystem.
 * @returns {{deleted: string[], prunedDirs: string[], refused: Array<{path: string, reason: string}>, reason: string}}
 *          `reason` is 'no-prior-manifest' when the delete pass was skipped outright,
 *          otherwise 'reconciled'. Entries in `refused` carry why they were spared
 *          ('outside-dest-root', 'not-a-regular-file', 'written-this-run', ...). Paths in all three arrays are relative + POSIX.
 */
export function reconcileFromManifest({ destRoot, currentPaths = [], dryRun = false } = {}) {
  const root = path.resolve(destRoot);

  const prior = readManifest(root);
  if (prior === null) {
    // INVARIANT 1 — never infer deletions without a manifest we ourselves wrote.
    return { deleted: [], prunedDirs: [], refused: [], reason: 'no-prior-manifest' };
  }

  const core = reconcilePriorPaths({ root, priorPaths: prior.paths, currentPaths, dryRun });
  return { ...core, reason: 'reconciled' };
}

/**
 * Seed a synthetic "prior manifest" path list (E26_S08_T03) from a static list of paths
 * known to have shipped in some prior published version, intersected with what is
 * ACTUALLY a regular file on disk in `destRoot` right now. Never seeds a path that is
 * not really there, and applies the identical boundary (`isInside`) and type (`lstat`
 * regular-file, symlinks refused) checks the delete pass itself uses — seeding only
 * narrows *which* paths are eligible for consideration, it does not relax how a
 * candidate is validated once under consideration.
 *
 * The returned list is meant to be passed as `priorPaths` to `reconcileWithPriorPaths`
 * so the very same run that first sees `legacyPaths` can adopt-then-reconcile in one
 * pass, rather than requiring the consumer to upgrade twice.
 *
 * @param {object}   opts
 * @param {string}   opts.destRoot     Absolute destination root.
 * @param {string[]} opts.legacyPaths  Relative POSIX paths known to have shipped in some
 *                                     prior published version (see
 *                                     lib/legacy-shipped-paths.json /
 *                                     scripts/generate-legacy-shipped-paths.js).
 * @returns {string[]} Relative POSIX paths — the subset of `legacyPaths` that both
 *                      resolve inside `destRoot` and are a real regular file there now.
 */
export function seedFromLegacyPaths({ destRoot, legacyPaths = [] } = {}) {
  const root = path.resolve(destRoot);
  const seeded = [];

  for (const rel of legacyPaths) {
    if (typeof rel !== 'string' || rel.length === 0) continue;
    const abs = path.resolve(root, rel);

    // Same boundary check the delete pass itself applies to every candidate.
    if (!isInside(root, abs)) continue;

    let stat;
    try {
      // lstat, not stat: a symlink must never be seeded, let alone followed.
      stat = fs.lstatSync(abs);
    } catch (_) {
      continue; // not on disk — never seed a path that isn't really there
    }
    if (!stat.isFile()) continue; // regular files only, exactly like manifest `paths`

    seeded.push(rel);
  }

  return [...new Set(seeded)].sort();
}

/**
 * Public entry point (E26_S08_T03) for reconciling an explicit prior path list — used by
 * `scripts/postinstall.js`'s `no-prior-manifest` branch to adopt-then-reconcile a seeded
 * list (`seedFromLegacyPaths`) within the same run, rather than waiting for a manifest to
 * exist first. `reconcileFromManifest` (T01) remains the entry point for the normal,
 * manifest-backed case and is unchanged by this addition.
 *
 * @param {object}   opts
 * @param {string}   opts.destRoot      Absolute destination root.
 * @param {string[]} opts.priorPaths    Relative POSIX paths to treat as previously written
 *                                      (typically the output of `seedFromLegacyPaths`).
 * @param {string[]} opts.currentPaths  Relative POSIX paths mirrored by THIS run.
 * @param {boolean} [opts.dryRun=false]
 * @returns {{deleted: string[], prunedDirs: string[], refused: Array<{path: string, reason: string}>}}
 */
export function reconcileWithPriorPaths({ destRoot, priorPaths = [], currentPaths = [], dryRun = false } = {}) {
  const root = path.resolve(destRoot);
  return reconcilePriorPaths({ root, priorPaths, currentPaths, dryRun });
}

/**
 * Walk upward from `startDir`, removing directories that are empty, stopping before
 * `root` (which is never removed). Only ever removes directories `readdirSync`
 * reports as empty — so a directory still holding a consumer-authored file survives,
 * which is how a consumer's custom skill folder inside an otherwise-removed package
 * directory is preserved.
 *
 * Exported (E26_S08_T02) so `lib/commands/doctor.js`'s heuristic-based cleanup can prune
 * directories the exact same way this module's own manifest-based delete pass does, rather
 * than re-implementing the same walk-upward-while-empty logic a second time.
 */
export function pruneEmptyDirs(root, startDir, pruned) {
  let dir = path.resolve(startDir);
  while (isInside(root, dir)) {
    let entries;
    try {
      entries = fs.readdirSync(dir);
    } catch (_) {
      return; // already gone or unreadable
    }
    if (entries.length > 0) return; // not empty — stop, and never recurse further up
    try {
      fs.rmdirSync(dir);
    } catch (_) {
      return;
    }
    pruned.push(path.relative(root, dir).split(path.sep).join('/'));
    dir = path.dirname(dir);
  }
}

export default {
  readManifest,
  writeManifest,
  reconcileFromManifest,
  toRelativePaths,
  isInside,
  pruneEmptyDirs,
  seedFromLegacyPaths,
  reconcileWithPriorPaths,
};
