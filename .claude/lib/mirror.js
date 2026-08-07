/**
 * lib/mirror.js — Shared directory-mirroring helper
 *
 * Single source of truth for copying an explicit set of top-level entries
 * (files or directories) from a source root into a destination root. Used
 * by:
 *   - scripts/postinstall.js  (consumer install; reconcileDeletes = false)
 *   - skills/self-sync/...    (in-repo dev mirror; reconcileDeletes = true)   [wired in T02]
 *
 * Design constraints:
 *   - ESM, Node built-ins only (node:fs / node:fs/promises / node:path).
 *   - Never writes outside `destRoot` — every destination path is boundary-
 *     checked with a resolved-path comparison.
 *   - Additive by default. Delete reconciliation only fires when the caller
 *     explicitly passes `reconcileDeletes: true`.
 *   - `dryRun` computes the plan (added / overwritten / deleted / skipped)
 *     without touching the filesystem.
 */

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';

// ── boundary check ────────────────────────────────────────────────────────────

/**
 * Assert that `child` resolves to a path inside `parent`.
 * Rejects `..` traversal, symlink escapes, and absolute overrides.
 * Throws if the invariant is violated.
 */
function assertInside(parent, child, label) {
  const resolvedParent = path.resolve(parent);
  const resolvedChild = path.resolve(child);
  const rel = path.relative(resolvedParent, resolvedChild);
  if (rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel))) {
    return; // inside (rel === '' means child === parent, which is fine)
  }
  throw new Error(
    `mirror: refusing to write outside destRoot (${label}): ${resolvedChild} is outside ${resolvedParent}`
  );
}

// ── content comparison ────────────────────────────────────────────────────────

/**
 * Byte-compare two files. Returns true iff both exist and have identical
 * contents. Any read error → false (treated as "differs, needs copy").
 */
function filesEqual(a, b) {
  try {
    const statA = fs.statSync(a);
    const statB = fs.statSync(b);
    if (statA.size !== statB.size) return false;
    const bufA = fs.readFileSync(a);
    const bufB = fs.readFileSync(b);
    return bufA.equals(bufB);
  } catch (_) {
    return false;
  }
}

// ── walk source, classify + copy ──────────────────────────────────────────────

/**
 * Recursively walk `src` and mirror into `dst`, classifying each file.
 * Mutates `result` in place. Honors `destRoot` boundary via assertInside.
 */
function mirrorEntry(src, dst, destRoot, dryRun, excludeNames, result) {
  if (!fs.existsSync(src)) return;

  const srcStat = fs.statSync(src);

  if (srcStat.isFile()) {
    assertInside(destRoot, dst, 'file target');
    const exists = fs.existsSync(dst);
    if (!exists) {
      result.added.push(dst);
      if (!dryRun) {
        fs.mkdirSync(path.dirname(dst), { recursive: true });
        fs.copyFileSync(src, dst);
      }
    } else if (!filesEqual(src, dst)) {
      result.overwritten.push(dst);
      if (!dryRun) {
        fs.copyFileSync(src, dst);
      }
    } else {
      result.skipped.push(dst);
    }
    return;
  }

  if (srcStat.isDirectory()) {
    assertInside(destRoot, dst, 'dir target');
    if (!dryRun) fs.mkdirSync(dst, { recursive: true });
    const entries = fs.readdirSync(src, { withFileTypes: true });
    for (const entry of entries) {
      if (excludeNames.has(entry.name)) continue;
      mirrorEntry(
        path.join(src, entry.name),
        path.join(dst, entry.name),
        destRoot,
        dryRun,
        excludeNames,
        result
      );
    }
  }
  // symlinks and other node types are intentionally ignored (parity with
  // the old bash + node behavior, both of which used plain copy).
}

// ── delete reconciliation ─────────────────────────────────────────────────────

/**
 * For each top-level entry in `copySet`, walk the destination subtree and
 * delete any file/dir that is not present in the source subtree. Records
 * the deletions in `result.deleted`. Boundary-checked. No-op unless
 * `reconcileDeletes` was requested by the caller.
 */
function reconcileEntry(src, dst, destRoot, dryRun, excludeNames, result) {
  if (!fs.existsSync(dst)) return;

  const dstStat = fs.statSync(dst);

  // If the source is entirely absent, the whole destination entry is orphaned.
  if (!fs.existsSync(src)) {
    assertInside(destRoot, dst, 'orphan delete');
    result.deleted.push(dst);
    if (!dryRun) fs.rmSync(dst, { recursive: true, force: true });
    return;
  }

  if (!dstStat.isDirectory()) {
    // File-vs-file mismatches are handled by mirrorEntry; nothing to reconcile.
    return;
  }

  const srcExists = fs.existsSync(src) && fs.statSync(src).isDirectory();
  if (!srcExists) {
    // src changed type (was a dir, now a file). Delete the whole mirror dir.
    assertInside(destRoot, dst, 'type-change delete');
    result.deleted.push(dst);
    if (!dryRun) fs.rmSync(dst, { recursive: true, force: true });
    return;
  }

  const dstEntries = fs.readdirSync(dst, { withFileTypes: true });
  for (const entry of dstEntries) {
    // Excluded names in the destination are treated as orphans and pruned —
    // this is how the mirror recovers from prior copies made before the
    // exclusion list existed (e.g. legacy `.agents/` nested inside `agents/`).
    const childDst = path.join(dst, entry.name);
    const childSrc = path.join(src, entry.name);
    if (excludeNames.has(entry.name) || !fs.existsSync(childSrc)) {
      assertInside(destRoot, childDst, 'orphan child delete');
      result.deleted.push(childDst);
      if (!dryRun) fs.rmSync(childDst, { recursive: true, force: true });
    } else if (entry.isDirectory()) {
      reconcileEntry(childSrc, childDst, destRoot, dryRun, excludeNames, result);
    }
  }
}

// ── public API ────────────────────────────────────────────────────────────────

/**
 * Mirror an explicit set of top-level entries from `sourceRoot` into `destRoot`.
 *
 * @param {object}   opts
 * @param {string}   opts.sourceRoot        Absolute path to source root.
 * @param {string}   opts.destRoot          Absolute path to destination root.
 * @param {string[]} opts.copySet           Relative paths (files or dirs).
 * @param {boolean} [opts.dryRun=false]     If true, compute plan without writing.
 * @param {boolean} [opts.reconcileDeletes=false] If true, remove dest files/dirs
 *                                           not present in source (within copySet).
 * @param {string[]} [opts.exclude=[]]      Basenames to skip anywhere in the walk
 *                                           (e.g. ['.agents', '.claude', 'node_modules']).
 *                                           When reconcileDeletes is on, excluded
 *                                           basenames present in the destination
 *                                           are pruned as orphans.
 * @returns {{added: string[], overwritten: string[], deleted: string[], skipped: string[]}}
 *          Absolute destination paths grouped by outcome.
 */
export function mirror({
  sourceRoot,
  destRoot,
  copySet,
  dryRun = false,
  reconcileDeletes = false,
  exclude = [],
} = {}) {
  if (!sourceRoot || typeof sourceRoot !== 'string') {
    throw new TypeError('mirror: `sourceRoot` must be a non-empty string');
  }
  if (!destRoot || typeof destRoot !== 'string') {
    throw new TypeError('mirror: `destRoot` must be a non-empty string');
  }
  if (!Array.isArray(copySet)) {
    throw new TypeError('mirror: `copySet` must be an array of relative paths');
  }
  if (!Array.isArray(exclude)) {
    throw new TypeError('mirror: `exclude` must be an array of basenames');
  }

  const resolvedSource = path.resolve(sourceRoot);
  const resolvedDest = path.resolve(destRoot);
  const excludeNames = new Set(exclude);

  const result = {
    added: [],
    overwritten: [],
    deleted: [],
    skipped: [],
  };

  if (!dryRun) {
    fs.mkdirSync(resolvedDest, { recursive: true });
  }

  for (const entry of copySet) {
    if (typeof entry !== 'string' || entry.length === 0) {
      throw new TypeError(`mirror: copySet entries must be non-empty strings (got ${JSON.stringify(entry)})`);
    }
    // Reject entries that would escape either root.
    const src = path.join(resolvedSource, entry);
    const dst = path.join(resolvedDest, entry);
    assertInside(resolvedSource, src, `copySet source entry "${entry}"`);
    assertInside(resolvedDest, dst, `copySet dest entry "${entry}"`);

    mirrorEntry(src, dst, resolvedDest, dryRun, excludeNames, result);

    if (reconcileDeletes) {
      reconcileEntry(src, dst, resolvedDest, dryRun, excludeNames, result);
    }
  }

  return result;
}

// Also export helpers for advanced callers / tests. Not part of the stable API.
export const __internal = { assertInside, filesEqual };

export default mirror;
