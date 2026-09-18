/**
 * @file project/app/api/parsers/knowledge-graph.test.js
 * Plain Node `assert`-based test script for `readSADMap()` (knowledge-graph.js) and its integration
 * into `parseArchitecture()` (architecture.js). No test-framework dependency is introduced: at the
 * time this file was added, `project/app/api/` (and `project/app/` generally) had no JS test
 * convention at all — the root `package.json`'s `test` script runs `bats tests/*.bats`, which covers
 * shell scripts only. Per E08_S05_T03's instructions, this falls back to a plain Node script using
 * only built-ins (`assert`, `fs`, `path`).
 *
 * Run directly:
 *   node project/app/api/parsers/knowledge-graph.test.js
 * or, from project/app/api/:
 *   npm test
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------------------------
// Fixture injection via fs.readFileSync interception.
//
// knowledge-graph.js resolves an absolute GRAPH_JSON_PATH from its own __dirname and calls
// fs.readFileSync(GRAPH_JSON_PATH, 'utf8') on the shared `fs` module singleton at call time (not a
// destructured copy). Patching fs.readFileSync here therefore transparently intercepts those calls
// without knowledge-graph.js needing any path-override parameter (it doesn't have one). The patch
// only redirects calls whose path ends with project/knowledge-graph/graph.json; every other
// readFileSync call (e.g. architecture.js reading package.json/project.config.json) passes through
// untouched to the real filesystem. This means the real, 346+-node
// project/knowledge-graph/graph.json is never read or mutated by this test.
// ---------------------------------------------------------------------------------------------

const GRAPH_JSON_SUFFIX = path.join('project', 'knowledge-graph', 'graph.json');

const originalReadFileSync = fs.readFileSync;

// undefined = passthrough (no mock active); null = simulate a missing file (throws ENOENT); string
// = literal mocked file content.
let mockGraphJson;

fs.readFileSync = function patchedReadFileSync(filePath, ...rest) {
  if (
    mockGraphJson !== undefined &&
    typeof filePath === 'string' &&
    filePath.endsWith(GRAPH_JSON_SUFFIX)
  ) {
    if (mockGraphJson === null) {
      const err = new Error(`ENOENT: no such file or directory, open '${filePath}'`);
      err.code = 'ENOENT';
      throw err;
    }
    return mockGraphJson;
  }
  return originalReadFileSync.call(fs, filePath, ...rest);
};

function withMockGraphJson(value, fn) {
  const previous = mockGraphJson;
  mockGraphJson = value;
  try {
    return fn();
  } finally {
    mockGraphJson = previous;
  }
}

const { readSADMap } = require('./knowledge-graph');
const { parseArchitecture } = require('./architecture');

// ---------------------------------------------------------------------------------------------
// Fixture data (isolated from the real graph.json).
// ---------------------------------------------------------------------------------------------

// E20_S10_T01: mixes `human`/`ast` (verified — must render) with `board` (unverified — must never
// render as architecture) provenance, so the provenance-gating filter has both sides of the
// conflict to exercise from day one, matching STUB_SCHEMA.md's own provenance vocabulary.
const FIXTURE_GRAPH = {
  nodes: [
    { id: 'E-fixture-01', type: 'epic', label: 'Fixture Epic', description: 'desc', source: 'human' },
    { id: 'E-fixture-02', type: 'story', label: 'Fixture Story', description: 'desc', source: 'ast' },
    {
      id: 'E-fixture-03',
      type: 'service',
      label: 'Fixture Superseded Service',
      description: 'desc',
      source: 'ast',
      status: 'superseded',
      superseded_by: 'E-fixture-02',
    },
    // Unverified board-sourced node — present in graph.json, must never appear in readSADMap()'s
    // rendered `nodes` output (E20_S10_T01), but IS counted in `coverage.hidden` (E20_S10_T02).
    { id: 'E-fixture-04', type: 'story', label: 'Fixture Board Story', description: 'desc', source: 'board' },
  ],
  edges: [
    { id: 'edge-1', from: 'E-fixture-01', to: 'E-fixture-02', type: 'contains', description: 'Epic contains story' },
    // No `description` — exercises the `description || type` label fallback. Also points at the
    // superseded node E-fixture-03: per E08_S05_T01's tester note, edges are NOT currently filtered
    // when they point at a superseded node (only nodes are). This is documented, accepted behavior,
    // not a bug under test here.
    { id: 'edge-2', from: 'E-fixture-02', to: 'E-fixture-03', type: 'depends_on' },
  ],
};

// ---------------------------------------------------------------------------------------------
// Minimal test harness (no framework).
// ---------------------------------------------------------------------------------------------

const tests = [];
function test(name, fn) {
  tests.push({ name, fn });
}

async function run() {
  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      await fn();
      console.log(`PASS - ${name}`);
    } catch (err) {
      failures += 1;
      console.error(`FAIL - ${name}`);
      console.error(err && err.stack ? err.stack : err);
    }
  }
  // Always restore the original fs.readFileSync, even on failure, so no state leaks past this
  // process/test run.
  fs.readFileSync = originalReadFileSync;

  console.log(`\n${tests.length - failures}/${tests.length} passed`);
  if (failures > 0) {
    process.exitCode = 1;
  }
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

test('transforms a fixture graph.json into the {nodes, edges} UI shape', () => {
  const result = withMockGraphJson(JSON.stringify(FIXTURE_GRAPH), () => readSADMap());

  // E20_S10_T03: every returned node now also carries `verified`/`source` (needed so SADMap.jsx
  // can distinguish a fully-rendered node from a ghost stub) — no ghost candidates in this
  // baseline fixture, so both entries here are `verified: true`.
  assert.deepStrictEqual(result.nodes, [
    { id: 'E-fixture-01', label: 'Fixture Epic', type: 'epic', verified: true, source: 'human', needsRevalidation: false },
    { id: 'E-fixture-02', label: 'Fixture Story', type: 'story', verified: true, source: 'ast', needsRevalidation: false },
  ]);

  assert.deepStrictEqual(result.edges, [
    { from: 'E-fixture-01', to: 'E-fixture-02', label: 'Epic contains story' },
    { from: 'E-fixture-02', to: 'E-fixture-03', label: 'depends_on' },
  ]);
});

test('excludes status: superseded nodes from the output', () => {
  const result = withMockGraphJson(JSON.stringify(FIXTURE_GRAPH), () => readSADMap());

  const ids = result.nodes.map((n) => n.id);
  assert.ok(!ids.includes('E-fixture-03'), 'superseded node E-fixture-03 must not appear in nodes');
});

// -------------------------------------------------------------------------------------------
// E20_S10_T01: provenance-gating filter
// -------------------------------------------------------------------------------------------

test('excludes source: board nodes from the rendered output (provenance gate)', () => {
  const result = withMockGraphJson(JSON.stringify(FIXTURE_GRAPH), () => readSADMap());

  const ids = result.nodes.map((n) => n.id);
  assert.ok(!ids.includes('E-fixture-04'), 'board-sourced node E-fixture-04 must never render as architecture');
  assert.strictEqual(result.nodes.length, 2, 'only the 2 human/ast, non-superseded fixture nodes should remain');
});

test('only source: human or source: ast nodes are ever marked verified: true', () => {
  const result = withMockGraphJson(JSON.stringify(FIXTURE_GRAPH), () => readSADMap());

  for (const node of result.nodes) {
    if (node.verified) {
      assert.ok(
        node.source === 'human' || node.source === 'ast',
        `node ${node.id} is verified: true but has source "${node.source}"`
      );
    }
  }
});

test('documents (does not fix) that edges pointing at a superseded node are not filtered', () => {
  const result = withMockGraphJson(JSON.stringify(FIXTURE_GRAPH), () => readSADMap());

  const edgeToSuperseded = result.edges.find((e) => e.to === 'E-fixture-03');
  assert.ok(
    edgeToSuperseded,
    'edge-2 (E-fixture-02 -> E-fixture-03, a superseded node) is expected to still be present — ' +
      'known, accepted behavior per E08_S05_T01\'s tester note; only nodes are filtered, not edges'
  );
});

const EMPTY_SAD_MAP = { nodes: [], edges: [], coverage: { shown: 0, hidden: 0, total: 0, needsRevalidation: 0 } };

test('a missing graph.json produces an empty {nodes, edges, coverage} shape without throwing', () => {
  assert.doesNotThrow(() => {
    const result = withMockGraphJson(null, () => readSADMap());
    assert.deepStrictEqual(result, EMPTY_SAD_MAP);
  });
});

test('an empty-string graph.json produces an empty {nodes, edges, coverage} shape without throwing', () => {
  assert.doesNotThrow(() => {
    const result = withMockGraphJson('', () => readSADMap());
    assert.deepStrictEqual(result, EMPTY_SAD_MAP);
  });
});

test('a valid-but-schemaless graph.json ("{}") produces an empty {nodes, edges, coverage} shape without throwing', () => {
  assert.doesNotThrow(() => {
    const result = withMockGraphJson('{}', () => readSADMap());
    assert.deepStrictEqual(result, EMPTY_SAD_MAP);
  });
});

// -------------------------------------------------------------------------------------------
// E20_S10_T02: coverage counts, computed from the same pass as the rendered nodes
// -------------------------------------------------------------------------------------------

test('coverage counts are computed from the same filtering pass as the rendered nodes', () => {
  const result = withMockGraphJson(JSON.stringify(FIXTURE_GRAPH), () => readSADMap());

  // Fixture: 4 nodes total, 1 superseded (excluded from both shown and hidden — it is not "active"
  // architecture data at all), leaving 3 active nodes: 2 human/ast (shown) + 1 board (hidden).
  assert.deepStrictEqual(result.coverage, { shown: 2, hidden: 1, total: 3, needsRevalidation: 0 });
});

test('coverage.shown equals the count of verified: true nodes (not the raw nodes array length)', () => {
  // Since E20_S10_T03, `nodes` may also contain ghost stubs (verified: false), so `shown` is
  // compared against the verified subset specifically, not the array's raw length.
  const result = withMockGraphJson(JSON.stringify(FIXTURE_GRAPH), () => readSADMap());
  const verifiedCount = result.nodes.filter((n) => n.verified).length;
  assert.strictEqual(result.coverage.shown, verifiedCount);
});

test('a fixture with zero human/ast nodes produces coverage.shown === 0 (empty-state trigger)', () => {
  const allBoardFixture = {
    nodes: [
      { id: 'B-01', type: 'epic', label: 'Board Epic', description: 'desc', source: 'board' },
      { id: 'B-02', type: 'story', label: 'Board Story', description: 'desc', source: 'board' },
    ],
    edges: [],
  };
  const result = withMockGraphJson(JSON.stringify(allBoardFixture), () => readSADMap());

  assert.strictEqual(result.nodes.length, 0);
  assert.deepStrictEqual(result.coverage, { shown: 0, hidden: 2, total: 2, needsRevalidation: 0 });
});

// -------------------------------------------------------------------------------------------
// E20_S10_T03: ghost/dimmed endpoint stubs for mixed-provenance edges
// -------------------------------------------------------------------------------------------

// A genuine mixed-provenance edge: M-01 (human, verified) -> M-02 (board, unverified). M-03 is a
// board node with NO edge to a verified node — the negative case, confirming a ghost slot is only
// earned by genuine edge participation, not mere presence in the graph.
const MIXED_PROVENANCE_FIXTURE = {
  nodes: [
    { id: 'M-01', type: 'service', label: 'Verified Service', description: 'desc', source: 'human' },
    { id: 'M-02', type: 'story', label: 'Unverified Board Endpoint', description: 'desc', source: 'board' },
    { id: 'M-03', type: 'story', label: 'Unconnected Board Node', description: 'desc', source: 'board' },
  ],
  edges: [
    { id: 'mixed-edge-1', from: 'M-01', to: 'M-02', type: 'depends-on', description: 'Verified depends on board-sourced item' },
  ],
};

test('a board endpoint of an edge to a verified node renders as a ghost stub (verified: false), not dropped', () => {
  const result = withMockGraphJson(JSON.stringify(MIXED_PROVENANCE_FIXTURE), () => readSADMap());

  const ghost = result.nodes.find((n) => n.id === 'M-02');
  assert.ok(ghost, 'M-02 must still be present in nodes as a ghost stub');
  assert.strictEqual(ghost.verified, false, 'M-02 must be marked verified: false, never promoted');
  assert.strictEqual(ghost.source, 'board');
});

test('the edge to a mixed-provenance endpoint is never silently dropped', () => {
  const result = withMockGraphJson(JSON.stringify(MIXED_PROVENANCE_FIXTURE), () => readSADMap());

  const edge = result.edges.find((e) => e.from === 'M-01' && e.to === 'M-02');
  assert.ok(edge, 'the mixed-provenance edge M-01 -> M-02 must survive unfiltered');
});

test('a board node with no edge to a verified node earns no ghost slot (stays fully hidden)', () => {
  const result = withMockGraphJson(JSON.stringify(MIXED_PROVENANCE_FIXTURE), () => readSADMap());

  const ids = result.nodes.map((n) => n.id);
  assert.ok(!ids.includes('M-03'), 'M-03 has no edge to a verified node and must not appear at all');
});

test('a ghost stub never counts toward coverage.shown', () => {
  const result = withMockGraphJson(JSON.stringify(MIXED_PROVENANCE_FIXTURE), () => readSADMap());

  // 1 verified (M-01) shown; M-02 (ghost) + M-03 (fully hidden) both count as hidden; total = 3.
  assert.deepStrictEqual(result.coverage, { shown: 1, hidden: 2, total: 3, needsRevalidation: 0 });
});

// -------------------------------------------------------------------------------------------
// E20_S10_T05: staleness/revalidation badge surfaced through coverage + per-node flag
// -------------------------------------------------------------------------------------------

const REVALIDATION_FIXTURE = {
  nodes: [
    { id: 'R-01', type: 'service', label: 'Fresh Service', description: 'd', source: 'ast' },
    { id: 'R-02', type: 'service', label: 'Stale Service', description: 'd', source: 'ast', needs_revalidation: true },
    // A board node with needs_revalidation set is a malformed/unexpected input (the flag only ever
    // applies to non-board writers) — must never leak into coverage.needsRevalidation regardless.
    { id: 'R-03', type: 'story', label: 'Board Node', description: 'd', source: 'board', needs_revalidation: true },
  ],
  edges: [],
};

test('a node with needs_revalidation: true is surfaced as needsRevalidation: true on the rendered node', () => {
  const result = withMockGraphJson(JSON.stringify(REVALIDATION_FIXTURE), () => readSADMap());

  const fresh = result.nodes.find((n) => n.id === 'R-01');
  const stale = result.nodes.find((n) => n.id === 'R-02');
  assert.strictEqual(fresh.needsRevalidation, false);
  assert.strictEqual(stale.needsRevalidation, true);
});

test('coverage.needsRevalidation counts only verified nodes flagged needs_revalidation: true', () => {
  const result = withMockGraphJson(JSON.stringify(REVALIDATION_FIXTURE), () => readSADMap());

  // R-03 is board-sourced (never rendered as verified) — its needs_revalidation: true must not
  // leak into the count even though it's technically present in the raw graph.
  assert.strictEqual(result.coverage.needsRevalidation, 1);
});

test('tech_stack, dependencies, and _sources are unaffected by graph.json content', async () => {
  const withFixture = await withMockGraphJson(JSON.stringify(FIXTURE_GRAPH), () => parseArchitecture());
  const withMissing = await withMockGraphJson(null, () => parseArchitecture());

  assert.deepStrictEqual(withFixture.tech_stack, withMissing.tech_stack);
  assert.deepStrictEqual(withFixture.dependencies, withMissing.dependencies);
  assert.deepStrictEqual(withFixture._sources, withMissing._sources);

  // Sanity check that the two runs actually differ where they should (sad_map), so this test would
  // fail loudly if the mock ever stopped taking effect.
  assert.notDeepStrictEqual(withFixture.sad_map, withMissing.sad_map);
  assert.deepStrictEqual(withMissing.sad_map, EMPTY_SAD_MAP);
  assert.strictEqual(withFixture.sad_map.nodes.length, 2);
});

run();
