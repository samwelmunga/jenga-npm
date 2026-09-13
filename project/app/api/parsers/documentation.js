/**
 * @file project/app/api/parsers/documentation.js
 * Aggregates the project's curated reference documentation into one flat, categorized list of
 * full-content entries — the "Documentation" tab's backend source (`E58_S01_T04`, consumed by
 * `E58_S01_T05`'s `GET /v1/documentation` route).
 *
 * Four sources, none of which any existing parser touches today:
 *   - `project/PROJECT_SUMMARY.md`                    -> category `summary`
 *   - `README.md` (repo root)                         -> category `readme`
 *   - `docs/STRATEGY.md`                               -> category `strategy`
 *   - every `.md` file under `project/documentation/examples/` -> category `example`
 *
 * The first three are single named files, read directly and parsed with `gray-matter` for
 * consistency with the directory-based path even though they rarely carry frontmatter. The fourth
 * reuses `E58_S01_T01`'s shared `readMarkdownDirRecursive()` directory reader.
 *
 * Every returned entry shares the same field shape used by `E58_S01_T03`'s rapports aggregate:
 *   { file, data, content, category, date }
 * `readMarkdownDirRecursive()`'s own return contract does not include `date` (see its JSDoc), so
 * it is added here per entry — same pattern already used by `parsers/ideas.js` (E58_S01_T02) and
 * `parsers/rapports.js`: prefer frontmatter's `date` field, stringified, else `null`.
 *
 * A missing single-file source (e.g. no `docs/STRATEGY.md` yet in some projects) is skipped, not
 * thrown — the same non-throwing precedent used throughout `api/parsers/`.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const matter = require('gray-matter');
const { resolveProjectRoot } = require('../lib/resolve-project-root');
const { readMarkdownDirRecursive } = require('./lib/markdown-dir-reader');

/**
 * Derive the `date` field for an entry from its parsed frontmatter, matching the
 * `rapports.js`/`ideas.js` convention: prefer frontmatter's `date`, stringified; else `null`.
 *
 * Unquoted `YYYY-MM-DD` frontmatter values are parsed by gray-matter/js-yaml into a native `Date`
 * object rather than a plain string (the same gotcha `E06_S05_T03` hit and fixed for
 * `isStaleDeployedProd()` — see `project/rapports/problems/E06_S05_T03-stale-filter-fails-on-real-gray-matter-date-objects.md`).
 * A bare `String(date)` on a `Date` produces a full JS date-with-timezone string, not the
 * `YYYY-MM-DD` form callers expect, so `Date` inputs are explicitly reduced to their ISO calendar
 * date (`toISOString().slice(0, 10)`) instead.
 * @param {Object} data - gray-matter-parsed frontmatter object.
 * @returns {string|null}
 */
function deriveDate(data) {
  if (!data || !data.date) return null;
  if (data.date instanceof Date) return data.date.toISOString().slice(0, 10);
  return String(data.date);
}

/**
 * Read and parse a single markdown file into an aggregate entry, or `null` if the file does not
 * exist or fails to read/parse (skipped with a `console.warn`, never thrown).
 * @param {string} absPath - absolute path to the file.
 * @param {string} fileLabel - value for the returned entry's `file` field (e.g. "README.md").
 * @param {string} category - value for the returned entry's `category` field.
 * @returns {{ file: string, data: Object, content: string, category: string, date: string|null }|null}
 */
function readSingleMarkdownFile(absPath, fileLabel, category) {
  if (!fs.existsSync(absPath)) return null;

  try {
    const raw = fs.readFileSync(absPath, 'utf8');
    const parsed = matter(raw);
    return {
      file: fileLabel,
      data: parsed.data,
      content: parsed.content.trim(),
      category,
      date: deriveDate(parsed.data),
    };
  } catch (err) {
    console.warn(`[documentation] Skipping malformed file: ${absPath} — ${err.message}`);
    return null;
  }
}

/**
 * Aggregate all documentation sources into one flat list of full-content, categorized entries.
 * Returns [] entries for any source that does not exist rather than throwing.
 * @returns {Promise<Object[]>}
 */
async function readDocumentation() {
  const root = resolveProjectRoot();
  const results = [];

  const singleFileSources = [
    {
      absPath: path.join(root, 'project', 'PROJECT_SUMMARY.md'),
      fileLabel: 'PROJECT_SUMMARY.md',
      category: 'summary',
    },
    {
      absPath: path.join(root, 'README.md'),
      fileLabel: 'README.md',
      category: 'readme',
    },
    {
      absPath: path.join(root, 'docs', 'STRATEGY.md'),
      fileLabel: 'STRATEGY.md',
      category: 'strategy',
    },
  ];

  for (const source of singleFileSources) {
    const entry = readSingleMarkdownFile(source.absPath, source.fileLabel, source.category);
    if (entry) results.push(entry);
  }

  const examplesRoot = path.join(root, 'project', 'documentation', 'examples');
  // Fixed category for every file under this root, regardless of subdirectory — passed as a
  // function per readMarkdownDirRecursive()'s categorize contract (a bare string is not one of
  // its two supported forms and would silently fall back to 'uncategorized').
  const exampleEntries = readMarkdownDirRecursive(examplesRoot, () => 'example');
  for (const entry of exampleEntries) {
    results.push({ ...entry, date: deriveDate(entry.data) });
  }

  return results;
}

module.exports = { readDocumentation };
