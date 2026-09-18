#!/usr/bin/env node
/**
 * scripts/populate-knowledge-graph.js — Mechanical Board-to-Graph Populator (E20_S09_T02)
 *
 * Reads `project/board/epics/*.md` and `project/board/stories/*.md` frontmatter (read-only) and
 * writes/updates nodes and edges into `project/knowledge-graph/graph.json`, per
 * `project/knowledge-graph/STUB_SCHEMA.md`'s node/edge shape, using `source: "board"` (defined in
 * E20_S09_T01 — see STUB_SCHEMA.md's "Where `board` Fits" section for its exact semantics: lowest
 * precedence, one-way superseded-by relationship, never supersedes human/ast nodes).
 *
 * Scope, by design (see STUB_SCHEMA.md and E20_S09's story):
 *   - One node per Epic, one node per Story. Tasks are never nodes via this populator.
 *   - Containment edges (Epic -> Story) and `depends_on`-derived dependency edges only — nothing
 *     fabricated beyond what board frontmatter actually states.
 *   - Idempotent on `id`: re-running merges into the existing graph rather than duplicating or
 *     blindly overwriting unrelated content.
 *   - Strictly read-only against `project/board/` — this script never creates, modifies, or
 *     deletes anything under it.
 *   - No network calls, no external dependencies. The repo root `package.json` has no runtime
 *     `dependencies` (verified) — every other script under `scripts/`/`lib/` is dependency-free
 *     Node ESM using only `node:*` builtins (e.g. `postinstall.js`, `generate-legacy-shipped-paths.js`),
 *     so this script follows the same convention with its own small hand-rolled frontmatter parser
 *     rather than adding `gray-matter` (only present in the separate `project/app/` workspace) as a
 *     new root-level dependency for a single script.
 *
 * Note: `scripts/e25_s01_extract_board_graph.py` is an existing throwaway spike with its own
 * hand-rolled frontmatter parser, explicitly marked "Do not import" in its own header comment. It
 * was consulted only as prior art on the shape of the problem — nothing from it is imported or
 * reused here.
 *
 * CLI:
 *   node scripts/populate-knowledge-graph.js [--project-root <path>] [--dry-run]
 *
 *   --project-root  Path to a directory containing board/ and knowledge-graph/ (default: the
 *                    repo's own `project/` directory, resolved relative to this script). Lets
 *                    E20_S09_T03's test coverage point the populator at fixture board directories
 *                    without touching the real board.
 *   --dry-run        Compute the merged graph and report whether it would change, but never write
 *                    to disk.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.join(__dirname, '..');

const EPIC_ID_RE = /^E\d+$/;
const STORY_ID_RE = /^E\d+_S\d+$/;

// E20_S10_T05: extracted_at/content_hash/needs_revalidation are appended after the pre-existing
// fields — never inserted in the middle — so a graph.json written before E20_S10_T05 diffs
// cleanly against one written after it for every node that doesn't carry the new fields.
const NODE_KEY_ORDER = [
  'id',
  'type',
  'label',
  'description',
  'source',
  'status',
  'superseded_by',
  'extracted_at',
  'content_hash',
  'needs_revalidation',
];
const EDGE_KEY_ORDER = ['id', 'from', 'to', 'type', 'description'];

// ── CLI args ────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = { projectRoot: path.join(REPO_ROOT, 'project'), dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--project-root') {
      args.projectRoot = path.resolve(argv[++i] ?? '');
    } else if (arg.startsWith('--project-root=')) {
      args.projectRoot = path.resolve(arg.slice('--project-root='.length));
    } else if (arg === '--dry-run') {
      args.dryRun = true;
    }
  }
  return args;
}

// ── Minimal frontmatter parsing ────────────────────────────────────────────
// Tailored to this project's actual board schema: flat `key: value` scalar pairs, plus one
// multi-line list shape (`  - item` continuation lines under a bare `key:`). Verified against
// every epic/story file in this repo before writing — no general YAML support is attempted.

function unquote(value) {
  const text = value.trim();
  if (
    (text.startsWith('"') && text.endsWith('"') && text.length >= 2) ||
    (text.startsWith("'") && text.endsWith("'") && text.length >= 2)
  ) {
    return text.slice(1, -1);
  }
  return text;
}

function parseFrontmatter(raw) {
  if (!raw.startsWith('---\n') && raw !== '---') {
    return { frontmatter: {}, body: raw };
  }
  const closeIdx = raw.indexOf('\n---', 4);
  if (closeIdx === -1) {
    return { frontmatter: {}, body: raw };
  }
  const rawFrontmatter = raw.slice(4, closeIdx);
  // Body starts after the closing `---` line.
  const afterClose = raw.indexOf('\n', closeIdx + 1);
  const body = afterClose === -1 ? '' : raw.slice(afterClose + 1);

  const frontmatter = {};
  let currentListKey = null;
  for (const line of rawFrontmatter.split('\n')) {
    if (line.trim() === '') continue;
    if (/^\s+-\s?/.test(line) && currentListKey) {
      const item = unquote(line.replace(/^\s+-\s?/, ''));
      frontmatter[currentListKey].push(item);
      continue;
    }
    const colonIdx = line.indexOf(':');
    if (colonIdx === -1) {
      currentListKey = null;
      continue;
    }
    const key = line.slice(0, colonIdx).trim();
    const rawValue = line.slice(colonIdx + 1).trim();
    if (rawValue === '') {
      // Could be the start of a list (`stories:` followed by `  - E20_S01`) or a genuinely
      // empty scalar field (e.g. `date_completed:`). Assume list; if no `- item` lines follow,
      // it naturally stays an empty array, which is falsy-equivalent for our purposes.
      frontmatter[key] = [];
      currentListKey = key;
    } else {
      frontmatter[key] = unquote(rawValue);
      currentListKey = null;
    }
  }
  return { frontmatter, body };
}

// ── Description derivation ─────────────────────────────────────────────────

function firstParagraphAfterHeading(body) {
  const lines = body.split('\n');
  let idx = 0;
  while (idx < lines.length && !lines[idx].trim().startsWith('# ')) idx++;
  if (idx < lines.length) idx++; // past the heading line itself
  while (idx < lines.length && lines[idx].trim() === '') idx++;
  const paragraph = [];
  while (idx < lines.length && lines[idx].trim() !== '' && !lines[idx].trim().startsWith('#')) {
    paragraph.push(lines[idx].trim());
    idx++;
  }
  return paragraph.join(' ').trim();
}

function purposeSection(body) {
  const headingMatch = body.match(/^##\s*Purpose\s*$/m);
  if (!headingMatch) return null;
  const rest = body.slice(headingMatch.index + headingMatch[0].length);
  const nextHeadingMatch = rest.match(/\n##\s/);
  const section = nextHeadingMatch ? rest.slice(0, nextHeadingMatch.index) : rest;
  return section.trim();
}

function epicDescription(body) {
  const purpose = purposeSection(body);
  if (purpose) return purpose;
  // Fallback for board files that predate the `## Purpose` convention (e.g. E24).
  return firstParagraphAfterHeading(body);
}

function storyDescription(body) {
  return firstParagraphAfterHeading(body);
}

// ── Board scan ──────────────────────────────────────────────────────────────

function listMarkdownFiles(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    if (err.code === 'ENOENT') return [];
    throw err;
  }
  return entries
    .filter((entry) => entry.isFile() && entry.name.endsWith('.md'))
    .map((entry) => path.join(dir, entry.name))
    .sort();
}

function scanEpics(boardDir) {
  const files = listMarkdownFiles(path.join(boardDir, 'epics'));
  const epics = [];
  for (const file of files) {
    const raw = fs.readFileSync(file, 'utf8');
    const { frontmatter, body } = parseFrontmatter(raw);
    if (!frontmatter.id || !EPIC_ID_RE.test(frontmatter.id)) continue;
    epics.push({
      id: frontmatter.id,
      title: frontmatter.title ?? '',
      description: epicDescription(body),
    });
  }
  return epics;
}

function scanStories(boardDir) {
  const files = listMarkdownFiles(path.join(boardDir, 'stories'));
  const stories = [];
  for (const file of files) {
    const raw = fs.readFileSync(file, 'utf8');
    const { frontmatter, body } = parseFrontmatter(raw);
    if (!frontmatter.id || !STORY_ID_RE.test(frontmatter.id)) continue;
    stories.push({
      id: frontmatter.id,
      title: frontmatter.title ?? '',
      description: storyDescription(body),
      epicId: typeof frontmatter.epic_id === 'string' ? frontmatter.epic_id : '',
      dependsOn: typeof frontmatter.depends_on === 'string' ? frontmatter.depends_on : '',
    });
  }
  return stories;
}

function parseDependsOn(raw) {
  if (!raw) return [];
  return raw
    .split(',')
    .map((token) => token.trim())
    .filter((token) => token !== '' && token.toLowerCase() !== 'none');
}

// ── Node/edge derivation ────────────────────────────────────────────────────

function deriveNodesAndEdges(epics, stories) {
  const nodes = new Map();
  const edges = new Map();

  for (const epic of epics) {
    nodes.set(epic.id, {
      id: epic.id,
      type: 'epic',
      label: epic.title,
      description: epic.description,
      source: 'board',
    });
  }
  for (const story of stories) {
    nodes.set(story.id, {
      id: story.id,
      type: 'story',
      label: story.title,
      description: story.description,
      source: 'board',
    });
  }

  const epicIds = new Set(epics.map((e) => e.id));
  const storyIds = new Set(stories.map((s) => s.id));
  const knownIds = new Set([...epicIds, ...storyIds]);

  // Containment: derived from each story's own `epic_id` field (not the epic's `stories:` list),
  // so a stale/out-of-sync list on the epic side can never produce a dangling edge.
  for (const story of stories) {
    if (story.epicId && epicIds.has(story.epicId)) {
      const edgeId = `board:contains:${story.epicId}:${story.id}`;
      edges.set(edgeId, {
        id: edgeId,
        from: story.epicId,
        to: story.id,
        type: 'contains',
        description: `${story.epicId} contains ${story.id}.`,
      });
    }
  }

  // Dependency edges: only for targets that resolve to a real, known Epic or Story node — a
  // `depends_on` referencing a Task (or any unrecognised id) is skipped rather than fabricated.
  for (const story of stories) {
    for (const targetId of parseDependsOn(story.dependsOn)) {
      if (!knownIds.has(targetId)) continue;
      const edgeId = `board:depends-on:${story.id}:${targetId}`;
      edges.set(edgeId, {
        id: edgeId,
        from: story.id,
        to: targetId,
        type: 'depends-on',
        description: `${story.id} depends on ${targetId} (per board depends_on frontmatter).`,
      });
    }
  }

  return { nodes, edges };
}

// ── Merge into existing graph.json ─────────────────────────────────────────

function canonicalizeKeys(obj, order) {
  const result = {};
  for (const key of order) {
    if (key in obj) result[key] = obj[key];
  }
  for (const key of Object.keys(obj)) {
    if (!(key in result)) result[key] = obj[key];
  }
  return result;
}

function loadExistingGraph(graphPath) {
  let raw;
  try {
    raw = fs.readFileSync(graphPath, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return { nodes: [], edges: [] };
    throw err;
  }
  try {
    const parsed = JSON.parse(raw);
    return {
      nodes: Array.isArray(parsed.nodes) ? parsed.nodes : [],
      edges: Array.isArray(parsed.edges) ? parsed.edges : [],
    };
  } catch {
    // Unparsable existing file: treat as empty rather than crash. This is a graceful-degradation
    // choice, not silent data loss — the populator only ever writes back a superset (merge), and a
    // corrupt file was already not a valid graph to begin with.
    return { nodes: [], edges: [] };
  }
}

const BOARD_EDGE_ID_PREFIXES = ['board:contains:', 'board:depends-on:'];

function isBoardOwnedEdgeId(id) {
  return BOARD_EDGE_ID_PREFIXES.some((prefix) => id.startsWith(prefix));
}

// ── Entity resolution (E20_S10_T04) ────────────────────────────────────────
//
// This governs *whether two nodes are the same node at all* — distinct from, and does not
// replace, STUB_SCHEMA.md's Evidence-Wins Conflict Rule (which governs *which description wins*
// once two nodes are already known to be the same entity). A node's literal `id` is already this
// populator's own stable identity for its own `board`-sourced writes (an Epic/Story's own board
// id never changes shape between runs), so key-based merging is infrastructure ahead of its real
// caller: a future `human`/`ast` writer describing the same real-world entity under a different
// literal `id` than an existing node. Deliberately conservative (under-merging on purpose, per the
// task's own instruction to start narrow and expand only on observed false negatives) — a node
// with no usable key returns `null` and is matched by `id` only, never over-merged.

const SOURCE_PRECEDENCE = { human: 2, ast: 2, board: 1 };

function sourcePrecedence(source) {
  return SOURCE_PRECEDENCE[source] ?? 0;
}

function normalizeKeyPart(value) {
  return String(value ?? '').trim().toLowerCase().replace(/\s+/g, ' ');
}

/**
 * Compute a node's canonical identity key, or `null` if this node type has no reliable key yet.
 * `epic`/`story` key on their own (already-stable) board id, matching this populator's existing
 * identity scheme. Any other type (e.g. a future `service`/`module`/`function` from an `ast`/
 * `human` writer) keys on its normalized `label` — exact-normalized, not fuzzy, per the
 * conservative-by-design instruction above.
 * @param {{id: string, type: string, label?: string}} node
 * @returns {string|null}
 */
function canonicalKey(node) {
  if (!node || !node.type) return null;
  if (node.type === 'epic' || node.type === 'story') {
    return node.id ? `${node.type}:${normalizeKeyPart(node.id)}` : null;
  }
  return node.label ? `${node.type}:${normalizeKeyPart(node.label)}` : null;
}

/**
 * Resolve a computed node against an existing node map using canonical-key identity resolution,
 * merging in place (and logging the merge) when a genuine match is found under a *different*
 * literal id. Falls back to plain `id`-keyed merge/create — completely unchanged from the
 * pre-E20_S10_T04 behavior — whenever no key-based match applies.
 * @param {Map<string, object>} nodeMap mutated in place
 * @param {string} computedId
 * @param {object} computedNode
 * @param {Map<string, string>} keyIndex canonical key -> existing node id, built before this run's
 *   computed nodes are applied (so a computed node is only ever matched against pre-existing data,
 *   never against another computed node from the same run)
 * @param {Array<object>} mergeLog appended to in place with a record of every key-based merge
 */
function resolveNodeIdentity(nodeMap, computedId, computedNode, keyIndex, mergeLog) {
  const key = canonicalKey(computedNode);
  const matchedExistingId = key ? keyIndex.get(key) : undefined;

  if (matchedExistingId && matchedExistingId !== computedId) {
    // Genuine key-based merge: same canonical identity, different literal id. Merge into the
    // EXISTING node's id (stable target) rather than creating a second node for the same entity.
    const existingNode = nodeMap.get(matchedExistingId) ?? {};
    const resolvedSource =
      sourcePrecedence(computedNode.source) >= sourcePrecedence(existingNode.source)
        ? computedNode.source
        : existingNode.source; // never downgrade an existing node's provenance via a lower-precedence write

    const changedFields = [];
    for (const field of ['label', 'description', 'type']) {
      if (computedNode[field] !== undefined && computedNode[field] !== existingNode[field]) {
        changedFields.push(field);
      }
    }
    if (existingNode.source !== resolvedSource) changedFields.push('source');

    const merged = {
      ...existingNode,
      ...computedNode,
      id: existingNode.id, // keep the existing (target) id stable — never renamed by a merge
      source: resolvedSource,
    };
    nodeMap.set(matchedExistingId, canonicalizeKeys(ensureProvenanceMetadata(merged), NODE_KEY_ORDER));

    mergeLog.push({
      key,
      targetId: matchedExistingId,
      mergedFromId: computedId,
      changedFields,
      existingSource: existingNode.source,
      incomingSource: computedNode.source,
    });
    return;
  }

  // No key-based match (or the match IS this same id, i.e. the pre-existing idempotent-on-id
  // case) — fall back to plain id-keyed merge/create, unchanged from pre-E20_S10_T04 behavior.
  const merged = { ...(nodeMap.get(computedId) ?? {}), ...computedNode };
  nodeMap.set(computedId, canonicalizeKeys(ensureProvenanceMetadata(merged), NODE_KEY_ORDER));
}

// ── Staleness / revalidation (E20_S10_T05) ─────────────────────────────────
//
// Gating on `source` alone (E20_S10_T01) relocates, rather than solves, the original "board goes
// stale" defect: a non-`board` node can itself drift from the source it was extracted from with no
// signal to the user. `hashSource`/`checkStaleness` are the general-purpose, directly-testable
// utilities this closes with — deliberately NOT new scheduling infrastructure, per the task's own
// instruction to hook into an existing lifecycle trigger point instead. This populator has no live
// `ast`/`human` writer yet (same caveat as E20_S10_T04's entity resolution), so it applies these
// utilities to its own passthrough of any non-`board` node it merges, using that node's own
// descriptive text as a content proxy — a future dedicated writer with real source-file text
// should call `hashSource()` directly with its own normalized content instead of relying on this
// proxy.

/**
 * Hash arbitrary content (already normalized by the caller, if normalization is available) into a
 * short, stable fingerprint. Prefer passing normalized/parsed structure rather than raw bytes when
 * the caller has one available — e.g. a future AST writer hashing a normalized AST dump rather than
 * raw file text — so purely cosmetic/formatting-only source changes don't flip staleness.
 * @param {string} content
 * @returns {string} hex-encoded sha256 digest
 */
function hashSource(content) {
  return createHash('sha256').update(String(content ?? '')).digest('hex');
}

/**
 * Best-effort "source content" proxy for a node with no separately-tracked raw source file: its
 * own label + description. Used only by this populator's own write path below, which has nothing
 * else to hash against; a dedicated ast/human writer with real source-file text should hash that
 * directly via hashSource() instead of going through this proxy.
 */
function contentFingerprint(node) {
  return `${node.label ?? ''} ${node.description ?? ''}`;
}

/**
 * Compare a node's stored `content_hash` against a freshly computed hash of its current source
 * content. A node with no stored `content_hash` yet has nothing to compare against — reported as
 * not stale (never a false "needs re-verification" for a node that was never hash-stamped at all).
 * @param {{content_hash?: string}} node
 * @param {string} currentContent
 * @returns {{stale: boolean}}
 */
function checkStaleness(node, currentContent) {
  if (!node || !node.content_hash) return { stale: false };
  return { stale: hashSource(currentContent) !== node.content_hash };
}

/**
 * Stamp `extracted_at`/`content_hash` on any non-`board` node being written, refreshing
 * `extracted_at` only when the computed content hash actually changes (so re-running against
 * unchanged content never bumps the timestamp). `board` nodes are left untouched — this metadata
 * is scoped to non-`board` provenance per the task's own Acceptance Criteria.
 * @param {object} node
 * @param {string} [now] ISO 8601 UTC timestamp; overridable for tests
 * @returns {object} a new node object (or the same reference, if source is 'board')
 */
function ensureProvenanceMetadata(node, now = new Date().toISOString()) {
  if (!node || node.source === 'board') return node;
  const hash = hashSource(contentFingerprint(node));
  if (node.content_hash === hash) return node; // unchanged — keep the existing extracted_at as-is
  return { ...node, content_hash: hash, extracted_at: now };
}

function mergeGraph(existing, computed) {
  const nodeMap = new Map(existing.nodes.map((node) => [node.id, node]));
  // Prune stale populator-owned nodes no longer produced this run (e.g. an Epic or Story board
  // file was deleted or renamed, so its id no longer appears in the current board scan). Only
  // nodes this populator itself owns — `source: "board"` — are ever eligible for pruning; a
  // `human`- or `ast`-sourced node is never touched here, mirroring the edge-pruning namespace
  // guard below (E20_S09_T02 rapport: a stale board node was previously left behind forever while
  // its containment edge was correctly pruned on the same re-run — this closes that gap).
  for (const [id, node] of [...nodeMap.entries()]) {
    if (node.source === 'board' && !computed.nodes.has(id)) {
      nodeMap.delete(id);
    }
  }

  // Built BEFORE this run's computed nodes are applied, so key-based resolution only ever matches
  // against pre-existing graph state — never against a sibling computed node from the same pass.
  const keyIndex = new Map();
  for (const node of nodeMap.values()) {
    const key = canonicalKey(node);
    if (key && !keyIndex.has(key)) keyIndex.set(key, node.id);
  }

  const mergeLog = [];
  for (const [id, computedNode] of computed.nodes) {
    resolveNodeIdentity(nodeMap, id, computedNode, keyIndex, mergeLog);
  }

  const edgeMap = new Map(existing.edges.map((edge) => [edge.id, edge]));
  // Prune stale populator-owned edges no longer produced this run (e.g. a `depends_on` was
  // removed from a story). Only ids in this populator's own `board:contains:`/`board:depends-on:`
  // namespace are ever touched — never a node, and never an edge belonging to another source.
  for (const id of [...edgeMap.keys()]) {
    if (isBoardOwnedEdgeId(id) && !computed.edges.has(id)) {
      edgeMap.delete(id);
    }
  }
  for (const [id, computedEdge] of computed.edges) {
    const merged = { ...(edgeMap.get(id) ?? {}), ...computedEdge };
    edgeMap.set(id, canonicalizeKeys(merged, EDGE_KEY_ORDER));
  }

  const nodes = [...nodeMap.values()].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const edges = [...edgeMap.values()].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return { nodes, edges, mergeLog };
}

// ── Main ─────────────────────────────────────────────────────────────────

function run(argv) {
  const args = parseArgs(argv);
  const boardDir = path.join(args.projectRoot, 'board');
  const graphPath = path.join(args.projectRoot, 'knowledge-graph', 'graph.json');

  const epics = scanEpics(boardDir);
  const stories = scanStories(boardDir);
  const computed = deriveNodesAndEdges(epics, stories);

  const existing = loadExistingGraph(graphPath);
  const { nodes, edges, mergeLog } = mergeGraph(existing, computed);
  // graph.json's on-disk shape is strictly {nodes, edges} per STUB_SCHEMA.md — mergeLog is
  // reporting-only and must never be serialized into it.
  const merged = { nodes, edges };
  const nextContent = `${JSON.stringify(merged, null, 2)}\n`;

  // E20_S10_T04: every key-based merge is logged (what changed, which sources were involved) so a
  // silent merge never hides a legitimate content difference between sources — printed regardless
  // of --dry-run, since a merge decision is worth surfacing even on a preview run.
  for (const entry of mergeLog) {
    process.stdout.write(
      `[merge] ${entry.mergedFromId} -> ${entry.targetId} (key: ${entry.key}) — ` +
        `source ${entry.existingSource ?? 'none'} + ${entry.incomingSource ?? 'none'} -> ${
          entry.changedFields.includes('source')
            ? 'upgraded'
            : entry.existingSource ?? entry.incomingSource
        }; changed fields: ${entry.changedFields.length ? entry.changedFields.join(', ') : 'none'}\n`,
    );
  }

  let currentContent = null;
  try {
    currentContent = fs.readFileSync(graphPath, 'utf8');
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }

  const changed = currentContent !== nextContent;

  if (args.dryRun) {
    process.stdout.write(
      changed
        ? `[dry-run] graph.json would change (${merged.nodes.length} nodes, ${merged.edges.length} edges).\n`
        : `[dry-run] graph.json is already up to date (${merged.nodes.length} nodes, ${merged.edges.length} edges).\n`,
    );
    return 0;
  }

  if (changed) {
    fs.mkdirSync(path.dirname(graphPath), { recursive: true });
    fs.writeFileSync(graphPath, nextContent);
    process.stdout.write(
      `Wrote ${graphPath} (${merged.nodes.length} nodes, ${merged.edges.length} edges).\n`,
    );
  } else {
    process.stdout.write(
      `${graphPath} already up to date (${merged.nodes.length} nodes, ${merged.edges.length} edges) — no write.\n`,
    );
  }
  return 0;
}

const invokedPath = process.argv[1] ? fs.realpathSync(process.argv[1]) : null;
if (invokedPath === fileURLToPath(import.meta.url)) {
  process.exitCode = run(process.argv.slice(2));
}

export {
  parseFrontmatter,
  epicDescription,
  storyDescription,
  scanEpics,
  scanStories,
  parseDependsOn,
  deriveNodesAndEdges,
  loadExistingGraph,
  mergeGraph,
  canonicalKey,
  resolveNodeIdentity,
  hashSource,
  checkStaleness,
  ensureProvenanceMetadata,
  run,
};
