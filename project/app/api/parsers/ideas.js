/**
 * @file project/app/api/parsers/ideas.js
 * Parses project/ideas.md — a single flat file (one idea per line, written by the /idea skill)
 * with no YAML frontmatter — into entries shaped consistently with the directory-reader entries
 * from E58_S01_T01, so both can be merged into the same aggregate list.
 */

const fs = require('fs');
const path = require('path');
const { resolveProjectRoot } = require('../lib/resolve-project-root');

// Resolved relative to the invoking project's own root (E47_S02_T01/T02), not a fixed __dirname
// climb — see project/app/api/lib/resolve-project-root.js.
const IDEAS_FILE = path.join(resolveProjectRoot(), 'project', 'ideas.md');

/**
 * Determine whether a (trimmed) line should be skipped rather than treated as an idea entry.
 * Mirrors scripts/idea_manager.sh's `real_entries()` filter — blank lines, markdown headers
 * (`#`), and HTML comments (`<!--`) are structural/template scaffolding, not idea content.
 * @param {string} trimmedLine
 * @returns {boolean}
 */
function isSkippableLine(trimmedLine) {
  return trimmedLine === '' || trimmedLine.startsWith('#') || trimmedLine.startsWith('<!--');
}

/**
 * Read project/ideas.md and return one entry per non-blank idea line.
 * Returns [] if project/ideas.md does not exist (same non-throwing precedent as the other parsers).
 * @returns {Promise<Object[]>}
 */
async function readIdeas() {
  if (!fs.existsSync(IDEAS_FILE)) return [];

  let raw;
  try {
    raw = fs.readFileSync(IDEAS_FILE, 'utf8');
  } catch (err) {
    console.warn(`[ideas] Skipping unreadable file: ${IDEAS_FILE} — ${err.message}`);
    return [];
  }

  const lines = raw.split('\n');
  const results = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (isSkippableLine(trimmed)) continue;

    results.push({
      file: 'ideas.md',
      data: {},
      content: trimmed,
      category: 'idea',
      date: null,
    });
  }

  return results;
}

module.exports = { readIdeas };
