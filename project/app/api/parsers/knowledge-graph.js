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

// E20_S10_T01: nodes whose provenance is genuinely architectural — a human-confirmed elicitation
// (`source: 'human'`) or a mechanical AST-derived extraction (`source: 'ast'`), per
// STUB_SCHEMA.md's Provenance Field section.
const VERIFIED_SOURCES = new Set(['human', 'ast']);

function isVerifiedSource(node) {
  return Boolean(node) && VERIFIED_SOURCES.has(node.source);
}

/**
 * Read and transform `project/knowledge-graph/graph.json` into the UI-facing SAD map shape.
 *
 * E20_S10_T01 provenance-gating contract (the single authoritative filtering point for any
 * architecture-view consumer — see the story's Acceptance Criteria): only `source: 'human'` or
 * `source: 'ast'` nodes are ever rendered as full architecture nodes. `source: 'board'` nodes
 * (mechanical Epic/Story restatements — see STUB_SCHEMA.md's "Where `board` Fits") are excluded
 * from `nodes` here, but this is a READ-TIME filter only: `graph.json` itself is never modified by
 * this reader, so `board` nodes remain available on disk for any other consumer that still wants
 * board/PM traceability. Filtering lives here (rather than being duplicated in `architecture.js`,
 * which just forwards this function's return value, or in `SADMap.jsx`) because this is already
 * the single place that transforms the raw on-disk graph shape into the UI-facing shape — any
 * future architecture-view consumer should call `readSADMap()` rather than reimplementing its own
 * provenance filter.
 *
 * `status: superseded` nodes are also excluded, regardless of provenance (pre-existing behavior,
 * unchanged by E20_S10_T01). Never throws — returns `{ nodes: [], edges: [], coverage: {shown: 0,
 * hidden: 0, total: 0, needsRevalidation: 0} }` for a missing, empty, or malformed graph.json.
 *
 * E20_S10_T05 staleness/revalidation: a verified node MAY carry `needs_revalidation: true` (set by
 * `scripts/populate-knowledge-graph.js`'s staleness check comparing a node's stored `content_hash`
 * against its current source — see that script's `checkStaleness()`). This is surfaced two ways:
 * per-node (`needsRevalidation` on the rendered node, for a UI badge) and aggregated into
 * `coverage.needsRevalidation`, through the SAME pass as `shown`/`hidden`/`total`, per this
 * function's existing never-drift contract. The flag is additive — it never removes a node from
 * `nodes`, only marks it for a "needs re-verification" badge.
 *
 * E20_S10_T03 mixed-provenance edge handling: an unverified (`board`) node that is nonetheless an
 * edge endpoint paired with a verified (`human`/`ast`) node is NOT dropped from `nodes` — it is
 * still included, tagged `verified: false`, so `SADMap.jsx` can render it as a dimmed/"ghost" stub
 * (label + provenance badge, no full detail) rather than silently dropping the edge or promoting
 * the unverified node to full status. Every other `board` node (not an edge endpoint of a verified
 * node) stays excluded per `E20_S10_T01`. Ghost-stub nodes are still counted as `hidden`, never
 * `shown`, in `coverage` — they were never confirmed as architecture, only surfaced for edge
 * continuity.
 *
 * @returns {{
 *   nodes: Array<{id: string, label: string, type: string, verified: boolean, source: string, needsRevalidation: boolean}>,
 *   edges: Array<{from: string, to: string, label: string}>,
 *   coverage: {shown: number, hidden: number, total: number, needsRevalidation: number}
 * }}
 */
function readSADMap() {
  try {
    const graph = readJsonSafe(GRAPH_JSON_PATH);

    const rawNodes = graph && Array.isArray(graph.nodes) ? graph.nodes : [];
    const rawEdges = graph && Array.isArray(graph.edges) ? graph.edges : [];

    const activeNodes = rawNodes.filter((node) => node && node.status !== 'superseded');
    const activeNodeById = new Map(activeNodes.map((node) => [node.id, node]));

    const verifiedNodes = activeNodes.filter(isVerifiedSource);
    const verifiedIds = new Set(verifiedNodes.map((node) => node.id));

    // E20_S10_T03: an unverified node earns a ghost-stub slot only when it is a genuine edge
    // endpoint whose *other* endpoint is verified — never merely for being present in the graph.
    // This keeps the bulk of unverified nodes hidden while preserving the traceability link a full
    // drop would sever.
    const ghostIds = new Set();
    for (const edge of rawEdges) {
      if (!edge) continue;
      considerGhostEndpoint(edge.to, edge.from);
      considerGhostEndpoint(edge.from, edge.to);
    }
    function considerGhostEndpoint(candidateId, otherId) {
      if (!verifiedIds.has(otherId)) return; // other endpoint must be verified
      if (verifiedIds.has(candidateId)) return; // candidate already fully rendered
      const candidate = activeNodeById.get(candidateId);
      if (candidate && !isVerifiedSource(candidate)) ghostIds.add(candidateId);
    }

    const nodes = [
      ...verifiedNodes.map((node) => ({
        id: node.id,
        label: node.label,
        type: node.type,
        verified: true,
        source: node.source,
        needsRevalidation: node.needs_revalidation === true,
      })),
      ...[...ghostIds].map((id) => {
        const node = activeNodeById.get(id);
        return {
          id: node.id,
          label: node.label,
          type: node.type,
          verified: false,
          source: node.source,
          needsRevalidation: false, // staleness only applies to verified (non-board) nodes
        };
      }),
    ];

    const edges = rawEdges.map((edge) => ({
      from: edge.from,
      to: edge.to,
      label: edge.description || edge.type,
    }));

    // E20_S10_T02: coverage counts are derived from this same pass (activeNodes / verifiedNodes),
    // never a separately cached computation, so they can never drift from what's actually
    // rendered. `shown` counts only fully-verified nodes — ghost stubs never count as shown.
    const shown = verifiedNodes.length;
    const total = activeNodes.length;
    const hidden = total - shown;
    // E20_S10_T05: counted from the same verifiedNodes pass — never separately cached.
    const needsRevalidation = verifiedNodes.filter((node) => node.needs_revalidation === true).length;

    return { nodes, edges, coverage: { shown, hidden, total, needsRevalidation } };
  } catch {
    return { nodes: [], edges: [], coverage: { shown: 0, hidden: 0, total: 0, needsRevalidation: 0 } };
  }
}

module.exports = { readSADMap };
