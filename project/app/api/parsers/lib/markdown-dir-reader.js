/**
 * @file project/app/api/parsers/lib/markdown-dir-reader.js
 * Shared recursive markdown-directory reader with frontmatter parsing and caller-derived
 * categorization.
 *
 * Generalizes two pre-existing, independently-written directory readers in this codebase:
 *   - `board.js`'s `readMarkdownDir()` — non-recursive, parses frontmatter + content via
 *     `gray-matter`, but only reads a single flat directory (epics/stories/tasks are each read
 *     separately).
 *   - `rapports.js`'s `listMdFiles()` — recursively walks a directory tree, but only collects file
 *     paths; frontmatter/content extraction happens separately in `readRapports()`.
 *
 * This module merges both: a single recursive walk that also parses frontmatter/content per file,
 * plus a category derived from a mapping supplied by the caller (this module never hardcodes any
 * category name — different consumers need different taxonomies from the same walk/parse logic).
 *
 * ---------------------------------------------------------------------------------------------
 * RETURN SHAPE CONTRACT (depended on by E58_S01_T03 [rapports.js] and E58_S01_T04
 * [documentation.js] — do not change without updating both):
 *
 *   readMarkdownDirRecursive(rootDir, categorize) -> Array<{
 *     file: string,     // path relative to rootDir, POSIX-style separators (e.g. "problems/foo.md"
 *                        // or "foo.md" for a file directly under rootDir). Never an absolute path.
 *     data: Object,      // gray-matter-parsed frontmatter object (`{}` if the file has none).
 *     content: string,   // full markdown body, `gray-matter`'s `content` field with leading/
 *                        // trailing whitespace trimmed (`.trim()`). Never truncated.
 *     category: string,  // derived via the caller-supplied `categorize` argument — see below.
 *   }>
 *
 * `categorize` contract:
 *   - May be a function: `(topLevelSegment, relativeFilePath) => string`
 *       `topLevelSegment` is the first path segment of the file's path relative to `rootDir`
 *       (e.g. "problems" for "problems/foo.md"), or `null` when the file sits directly under
 *       `rootDir` with no subdirectory (e.g. "foo.md").
 *       `relativeFilePath` is the same POSIX-style relative path that ends up in the returned
 *       entry's `file` field, in case a consumer needs finer-grained categorization than the
 *       top-level segment alone.
 *       The function's return value is used verbatim as `category`.
 *   - May be a plain lookup object: `{ [topLevelSegment]: categoryString }`. Looked up by the
 *     file's top-level segment; if the segment is `null` (file directly under rootDir) or has no
 *     matching key, falls back to the object's own `_default` key if present, else `'uncategorized'`.
 *   - May be omitted entirely, in which case every entry gets `category: 'uncategorized'`.
 *
 * Malformed files (parse errors) are skipped with a `console.warn` — matching the existing
 * `board.js`/`rapports.js` pattern — rather than aborting the whole walk. A root directory that
 * does not exist returns `[]` rather than throwing (matches the existing `fs.existsSync` guard
 * used by both `board.js` and `rapports.js`).
 * ---------------------------------------------------------------------------------------------
 */

'use strict';

const fs = require('fs');
const path = require('path');
const matter = require('gray-matter');

const DEFAULT_CATEGORY = 'uncategorized';

/**
 * Recursively collect absolute paths of every `.md` file under `dir`.
 * Mirrors rapports.js's listMdFiles(), kept private to this module.
 * @param {string} dir
 * @returns {string[]} absolute file paths
 */
function listMdFilesRecursive(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...listMdFilesRecursive(full));
    } else if (entry.isFile() && entry.name.endsWith('.md')) {
      files.push(full);
    }
  }
  return files;
}

/**
 * Normalize a relative path to POSIX-style separators so API payloads never leak `\` on Windows
 * dev environments.
 * @param {string} relPath
 * @returns {string}
 */
function toPosixPath(relPath) {
  return relPath.split(path.sep).join('/');
}

/**
 * Derive the top-level subdirectory segment of a POSIX-style relative path, or `null` if the file
 * sits directly under the root with no subdirectory.
 * @param {string} posixRelPath
 * @returns {string|null}
 */
function topLevelSegmentOf(posixRelPath) {
  const idx = posixRelPath.indexOf('/');
  return idx === -1 ? null : posixRelPath.slice(0, idx);
}

/**
 * Resolve a category string for a file given the caller-supplied `categorize` mapping.
 * @param {Function|Object|undefined} categorize
 * @param {string|null} topLevelSegment
 * @param {string} posixRelPath
 * @returns {string}
 */
function resolveCategory(categorize, topLevelSegment, posixRelPath) {
  if (typeof categorize === 'function') {
    const result = categorize(topLevelSegment, posixRelPath);
    return typeof result === 'string' && result.length > 0 ? result : DEFAULT_CATEGORY;
  }
  if (categorize && typeof categorize === 'object') {
    if (topLevelSegment !== null && Object.prototype.hasOwnProperty.call(categorize, topLevelSegment)) {
      return categorize[topLevelSegment];
    }
    if (Object.prototype.hasOwnProperty.call(categorize, '_default')) {
      return categorize._default;
    }
    return DEFAULT_CATEGORY;
  }
  return DEFAULT_CATEGORY;
}

/**
 * Recursively read all `.md` files under `rootDir`, parsing frontmatter + content via
 * `gray-matter` and deriving a `category` per file via the caller-supplied `categorize` mapping.
 *
 * Returns `[]` if `rootDir` does not exist. Skips (with `console.warn`) any file that fails to
 * read or parse, rather than aborting the whole walk.
 *
 * @param {string} rootDir - absolute path to the directory to walk.
 * @param {Function|Object} [categorize] - see module-level JSDoc for the full contract.
 * @returns {{ file: string, data: Object, content: string, category: string }[]}
 */
function readMarkdownDirRecursive(rootDir, categorize) {
  if (!fs.existsSync(rootDir)) return [];

  const absolutePaths = listMdFilesRecursive(rootDir);
  const results = [];

  for (const absPath of absolutePaths) {
    try {
      const raw = fs.readFileSync(absPath, 'utf8');
      const parsed = matter(raw);
      const posixRelPath = toPosixPath(path.relative(rootDir, absPath));
      const topLevelSegment = topLevelSegmentOf(posixRelPath);
      const category = resolveCategory(categorize, topLevelSegment, posixRelPath);

      results.push({
        file: posixRelPath,
        data: parsed.data,
        content: parsed.content.trim(),
        category,
      });
    } catch (err) {
      console.warn(`[markdown-dir-reader] Skipping malformed file: ${absPath} — ${err.message}`);
    }
  }

  return results;
}

module.exports = { readMarkdownDirRecursive };
