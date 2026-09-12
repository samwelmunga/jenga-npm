/**
 * @file project/app/api/parsers/knowledge-graph.js
 * Reads `project/knowledge-graph/graph.json` (E20_S09) and transforms it into the UI-facing
 * `{nodes:[{id,label,type}], edges:[{from,to,label}]}` shape consumed by the Architecture tab's
 * SAD map — see `project/knowledge-graph/STUB_SCHEMA.md` for the on-disk node/edge shape this
 * reads from (id/type/label/description/source/status?/superseded_by? for nodes;
 * id/from/to/type/description for edges).
 *
 * Kept deliberately defensive: the stub schema is explicitly throwaway (pending E20_S01's real
 * schema), so this reader tolerates a missing file, an empty/malformed file, or unexpected field
 * shapes by degrading to an empty map rather than throwing.
 */

const fs = require('fs');
const path = require('path');
const { resolveProjectRoot } = require('../lib/resolve-project-root');

// Resolved relative to the invoking project's own root, not a fixed __dirname climb — same fix as
// the other 4 parsers (E47_S02_T01/T02). Not one of the 4 files originally named in E47_S02_T02's
// scope, but it has the identical defect and directly feeds architecture.js's sad_map field, which
// the story's own Acceptance Criteria names explicitly ("architecture" data must resolve relative
// to the invoking project) — see E47_S02_T02-plan.md's "Scope addition" section for the full
// reasoning.
const ROOT = resolveProjectRoot();
const GRAPH_JSON_PATH = path.join(ROOT, 'project/knowledge-graph/graph.json');

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
 * Read and transform `project/knowledge-graph/graph.json` into the UI-facing SAD map shape.
 * `status: superseded` nodes are excluded. Never throws — returns `{ nodes: [], edges: [] }` for
 * a missing, empty, or malformed graph.json.
 * @returns {{ nodes: Array<{id: string, label: string, type: string}>, edges: Array<{from: string, to: string, label: string}> }}
 */
function readSADMap() {
  try {
    const graph = readJsonSafe(GRAPH_JSON_PATH);

    const rawNodes = graph && Array.isArray(graph.nodes) ? graph.nodes : [];
    const rawEdges = graph && Array.isArray(graph.edges) ? graph.edges : [];

    const nodes = rawNodes
      .filter((node) => node && node.status !== 'superseded')
      .map((node) => ({
        id: node.id,
        label: node.label,
        type: node.type,
      }));

    const edges = rawEdges.map((edge) => ({
      from: edge.from,
      to: edge.to,
      label: edge.description || edge.type,
    }));

    return { nodes, edges };
  } catch {
    return { nodes: [], edges: [] };
  }
}

module.exports = { readSADMap };
