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

const FIXTURE_GRAPH = {
  nodes: [
    { id: 'E-fixture-01', type: 'epic', label: 'Fixture Epic', description: 'desc', source: 'board' },
    { id: 'E-fixture-02', type: 'story', label: 'Fixture Story', description: 'desc', source: 'board' },
    {
      id: 'E-fixture-03',
      type: 'service',
      label: 'Fixture Superseded Service',
      description: 'desc',
      source: 'board',
      status: 'superseded',
      superseded_by: 'E-fixture-02',
    },
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

  assert.deepStrictEqual(result.nodes, [
    { id: 'E-fixture-01', label: 'Fixture Epic', type: 'epic' },
    { id: 'E-fixture-02', label: 'Fixture Story', type: 'story' },
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
  assert.strictEqual(result.nodes.length, 2, 'only the 2 non-superseded fixture nodes should remain');
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

test('a missing graph.json produces {nodes: [], edges: []} without throwing', () => {
  assert.doesNotThrow(() => {
    const result = withMockGraphJson(null, () => readSADMap());
    assert.deepStrictEqual(result, { nodes: [], edges: [] });
  });
});

test('an empty-string graph.json produces {nodes: [], edges: []} without throwing', () => {
  assert.doesNotThrow(() => {
    const result = withMockGraphJson('', () => readSADMap());
    assert.deepStrictEqual(result, { nodes: [], edges: [] });
  });
});

test('a valid-but-schemaless graph.json ("{}") produces {nodes: [], edges: []} without throwing', () => {
  assert.doesNotThrow(() => {
    const result = withMockGraphJson('{}', () => readSADMap());
    assert.deepStrictEqual(result, { nodes: [], edges: [] });
  });
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
  assert.deepStrictEqual(withMissing.sad_map, { nodes: [], edges: [] });
  assert.strictEqual(withFixture.sad_map.nodes.length, 2);
});

run();
