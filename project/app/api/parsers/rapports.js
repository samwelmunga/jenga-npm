/**
 * @file project/app/api/parsers/rapports.js
 * Lists rapport markdown files and extracts summary metadata.
 *
 * Also exports `readRapportsFull()` (E58_S01_T03) — a full-content, 6-category aggregate built
 * on `./lib/markdown-dir-reader`'s `readMarkdownDirRecursive()` (E58_S01_T01) and `./ideas`'s
 * `readIdeas()` (E58_S01_T02), covering `project/rapports/{analysis,problems,tests}`,
 * `project/documentation/{summaries,plans}`, and `project/ideas.md`. This coexists with, and does
 * not alter, the original `readRapports()` below — that function and its truncated
 * `content_summary` shape are `GET /v1/history`'s exclusive, unchanged dependency.
 */

const fs = require('fs');
const path = require('path');
const matter = require('gray-matter');
const { resolveProjectRoot } = require('../lib/resolve-project-root');
const { readMarkdownDirRecursive } = require('./lib/markdown-dir-reader');
const { readIdeas } = require('./ideas');

// Resolved relative to the invoking project's own root (E47_S02_T01/T02), not a fixed __dirname
// climb — see project/app/api/lib/resolve-project-root.js.
const RAPPORTS_ROOT = path.join(resolveProjectRoot(), 'project', 'rapports');
const DOCUMENTATION_SUMMARIES_ROOT = path.join(
  resolveProjectRoot(),
  'project',
  'documentation',
  'summaries'
);
const DOCUMENTATION_PLANS_ROOT = path.join(
  resolveProjectRoot(),
  'project',
  'documentation',
  'plans'
);
const DATE_PATTERN = /(\d{4}-\d{2}-\d{2})/;

// Maps project/rapports/*'s top-level subdirectories onto the 6-category taxonomy named in
// E58_S01's story description ("Rapports: analysis/problems/tests/summaries/plans/ideas").
const RAPPORTS_CATEGORIZE = { analysis: 'analysis', problems: 'problems', tests: 'tests' };

/**
 * Recursively list .md files under a directory.
 * @param {string} dir
 * @returns {string[]} absolute file paths
 */
function listMdFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...listMdFiles(full));
    } else if (entry.isFile() && entry.name.endsWith('.md')) {
      files.push(full);
    }
  }
  return files;
}

/**
 * Read rapport files and return summary objects.
 * Returns [] if the rapports directory does not exist.
 * @returns {Promise<Object[]>}
 */
async function readRapports() {
  if (!fs.existsSync(RAPPORTS_ROOT)) return [];

  const files = listMdFiles(RAPPORTS_ROOT);
  const results = [];

  for (const filePath of files) {
    try {
      const raw = fs.readFileSync(filePath, 'utf8');
      const { data: frontmatter, content } = matter(raw);
      const filename = path.relative(RAPPORTS_ROOT, filePath);

      // Date: prefer frontmatter, then extract from filename
      let date = frontmatter.date || null;
      if (!date) {
        const match = DATE_PATTERN.exec(path.basename(filePath));
        if (match) date = match[1];
      }

      const content_summary = content.trim().slice(0, 300);

      results.push({
        type: 'rapport',
        filename,
        date: date ? String(date) : null,
        content_summary,
      });
    } catch (err) {
      console.warn(`[rapports] Skipping malformed file: ${filePath} — ${err.message}`);
    }
  }

  return results;
}

/**
 * Resolve a `date` field for a `readMarkdownDirRecursive()` entry, mirroring the exact
 * frontmatter-then-filename fallback rule `readRapports()` already uses above — factored out here
 * so `readRapportsFull()` can apply the identical rule across all of its directory-reader sources
 * without duplicating it per call site. Does not alter `readRapports()` itself.
 * @param {Object} data - gray-matter-parsed frontmatter object.
 * @param {string} relFile - path relative to the source root (used for filename-based fallback).
 * @returns {string|null}
 */
function extractDate(data, relFile) {
  let date = (data && data.date) || null;
  if (!date) {
    const match = DATE_PATTERN.exec(path.basename(relFile));
    if (match) date = match[1];
  }
  return date ? String(date) : null;
}

/**
 * Aggregate full (untruncated) content across the 6-category taxonomy named in E58_S01's story
 * description: `analysis`/`problems`/`tests` (from `project/rapports/*`), `summaries`/`plans`
 * (from `project/documentation/*`), and `idea` (from `project/ideas.md`).
 *
 * Each entry carries: `{ file, data, content, category, date }` — `file` is a path relative to
 * its own source root (POSIX-style, per `readMarkdownDirRecursive()`'s contract), `data` is the
 * parsed frontmatter object (`{}` if none), `content` is the full untruncated markdown body, and
 * `date` follows the same frontmatter-then-filename fallback rule as `readRapports()`. A missing
 * source directory/file contributes zero entries rather than throwing (inherited from
 * `readMarkdownDirRecursive()`'s and `readIdeas()`'s own non-throwing guards).
 *
 * Does not alter `readRapports()` or its truncated `content_summary` shape — `GET /v1/history`
 * is unaffected by this function's existence.
 * @returns {Promise<Object[]>}
 */
async function readRapportsFull() {
  const withDates = (entries) => entries.map((e) => ({ ...e, date: extractDate(e.data, e.file) }));

  const rapportEntries = withDates(readMarkdownDirRecursive(RAPPORTS_ROOT, RAPPORTS_CATEGORIZE));
  const summaryEntries = withDates(
    readMarkdownDirRecursive(DOCUMENTATION_SUMMARIES_ROOT, () => 'summaries')
  );
  const planEntries = withDates(readMarkdownDirRecursive(DOCUMENTATION_PLANS_ROOT, () => 'plans'));
  const ideaEntries = await readIdeas();

  return [...rapportEntries, ...summaryEntries, ...planEntries, ...ideaEntries];
}

module.exports = { readRapports, readRapportsFull };
