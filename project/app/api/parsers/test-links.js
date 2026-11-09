/**
 * @file project/app/api/parsers/test-links.js
 * Reads the derived assertion-test-to-architecture links file
 * (`project/knowledge-graph/test-links.json`, produced by the E83 generator; the schema validator
 * script owns its shape) and groups it by architecture node id for the Architecture tab's read-only
 * test coverage overlay.
 *
 * Kept deliberately defensive, in the style of knowledge-graph.js: a missing, empty or malformed file,
 * or one whose shape is not the schema, degrades to an empty map rather than throwing. Read-only: no
 * write and no network call.
 */

const fs = require('fs');
const path = require('path');
const { resolveProjectRoot } = require('../lib/resolve-project-root');

// Resolved relative to the invoking project's own root, same as the other parsers. The path is
// joined once at load; `fs.readFileSync` is looked up on the shared module at call time so a test
// can intercept it.
const ROOT = resolveProjectRoot();
const TEST_LINKS_JSON_PATH = path.join(ROOT, 'project/knowledge-graph/test-links.json');

/**
 * Safely read and parse a JSON file, returning null on any error (including a missing file).
 * @param {string} filePath
 * @returns {Object|null}
 */
function readJsonSafe(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Read `project/knowledge-graph/test-links.json` and group its links by node id.
 * Never throws: returns `{ byNode: {}, total: 0 }` for a missing, empty or malformed file, or one with
 * no `links` array. A link that is not an object or has no `node_id` is skipped; the rest are kept.
 *
 * @returns {{
 *   byNode: Object<string, Array<{name: string, type: string, file: string, line: number}>>,
 *   total: number
 * }}
 */
function readTestLinks() {
  const empty = () => ({ byNode: {}, total: 0 });
  try {
    const doc = readJsonSafe(TEST_LINKS_JSON_PATH);
    if (!doc || !Array.isArray(doc.links)) return empty();

    const byNode = Object.create(null);
    let total = 0;
    for (const link of doc.links) {
      if (!link || typeof link !== 'object') continue;
      if (typeof link.node_id !== 'string' || link.node_id === '') continue;
      (byNode[link.node_id] || (byNode[link.node_id] = [])).push({
        name: link.name,
        type: link.type,
        file: link.file,
        line: link.line,
      });
      total += 1;
    }
    return { byNode: { ...byNode }, total };
  } catch {
    return empty();
  }
}

module.exports = { readTestLinks };
