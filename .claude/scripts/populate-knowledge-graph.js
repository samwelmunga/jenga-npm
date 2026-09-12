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

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.join(__dirname, '..');

const EPIC_ID_RE = /^E\d+$/;
const STORY_ID_RE = /^E\d+_S\d+$/;

const NODE_KEY_ORDER = ['id', 'type', 'label', 'description', 'source', 'status', 'superseded_by'];
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
  for (const [id, computedNode] of computed.nodes) {
    const merged = { ...(nodeMap.get(id) ?? {}), ...computedNode };
    nodeMap.set(id, canonicalizeKeys(merged, NODE_KEY_ORDER));
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
  return { nodes, edges };
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
  const merged = mergeGraph(existing, computed);
  const nextContent = `${JSON.stringify(merged, null, 2)}\n`;

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
  run,
};
