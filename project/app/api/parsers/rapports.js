/**
 * @file project/app/api/parsers/rapports.js
 * Lists rapport markdown files and extracts summary metadata.
 */

const fs = require('fs');
const path = require('path');
const matter = require('gray-matter');

const RAPPORTS_ROOT = path.resolve(__dirname, '../../../rapports');
const DATE_PATTERN = /(\d{4}-\d{2}-\d{2})/;

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

module.exports = { readRapports };
