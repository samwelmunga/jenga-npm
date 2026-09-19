#!/usr/bin/env node
/**
 * @file scripts/populate-knowledge-graph.entity-resolution.test.js
 * Plain Node `assert`-based unit tests for E20_S10_T04's canonical-key entity-resolution
 * merge-on-write logic in scripts/populate-knowledge-graph.js (canonicalKey, resolveNodeIdentity,
 * mergeGraph's key-based merge branch). No test-framework dependency — same convention as
 * project/app/api/parsers/knowledge-graph.test.js.
 *
 * Why a unit-level test file rather than only CLI-level bats coverage (tests/populate-knowledge-graph.bats):
 * this populator currently only ever computes `source: 'board'` nodes from board frontmatter, whose
 * `id` IS already the canonical key input (an Epic/Story's own stable board id) — so there is no
 * live producer of a "different id, same key" scenario to exercise end-to-end through the CLI yet.
 * The merge machinery is general-purpose infrastructure ahead of its real caller (a future
 * `human`/`ast` writer) — exercising it directly against synthetic node fixtures is the correct
 * level for that, per E20_S10_T04-plan.md.
 *
 * Run directly:
 *   node scripts/populate-knowledge-graph.entity-resolution.test.js
 */

import assert from 'node:assert';
import {
  canonicalKey,
  resolveNodeIdentity,
  mergeGraph,
} from './populate-knowledge-graph.js';

async function main() {

  const tests = [];
  function test(name, fn) {
    tests.push({ name, fn });
  }

  // -----------------------------------------------------------------------------------------
  // canonicalKey()
  // -----------------------------------------------------------------------------------------

  test('canonicalKey: epic/story key on their own normalized id', () => {
    assert.strictEqual(canonicalKey({ id: 'E90', type: 'epic' }), 'epic:e90');
    assert.strictEqual(canonicalKey({ id: 'E90_S01', type: 'story' }), 'story:e90_s01');
  });

  test('canonicalKey: epic/story ids are case- and whitespace-normalized', () => {
    assert.strictEqual(canonicalKey({ id: '  E90  ', type: 'epic' }), canonicalKey({ id: 'e90', type: 'epic' }));
  });

  test('canonicalKey: other node types key on normalized label', () => {
    assert.strictEqual(
      canonicalKey({ id: 'svc-1', type: 'service', label: 'Billing Worker' }),
      canonicalKey({ id: 'svc-2', type: 'service', label: '  billing   worker ' })
    );
  });

  test('canonicalKey: distinct labels never collide (conservative, exact-normalized match only)', () => {
    assert.notStrictEqual(
      canonicalKey({ id: 'svc-1', type: 'service', label: 'Billing Worker' }),
      canonicalKey({ id: 'svc-2', type: 'service', label: 'Billing Workers' })
    );
  });

  test('canonicalKey: a node with no usable key returns null (never over-merges)', () => {
    assert.strictEqual(canonicalKey({ id: 'x', type: 'service' }), null); // no label
    assert.strictEqual(canonicalKey(null), null);
    assert.strictEqual(canonicalKey({ id: 'x' }), null); // no type
  });

  test('canonicalKey: different types with the same label never collide', () => {
    assert.notStrictEqual(
      canonicalKey({ id: 'a', type: 'service', label: 'Auth' }),
      canonicalKey({ id: 'b', type: 'module', label: 'Auth' })
    );
  });

  // -----------------------------------------------------------------------------------------
  // resolveNodeIdentity() — genuine merge case
  // -----------------------------------------------------------------------------------------

  test('resolveNodeIdentity: a computed node matching an existing key under a DIFFERENT id merges into the existing id', () => {
    const nodeMap = new Map([
      ['svc-existing', { id: 'svc-existing', type: 'service', label: 'Billing Worker', description: 'old desc', source: 'ast' }],
    ]);
    const keyIndex = new Map([[canonicalKey({ type: 'service', label: 'Billing Worker' }), 'svc-existing']]);
    const mergeLog = [];

    resolveNodeIdentity(
      nodeMap,
      'svc-new',
      { id: 'svc-new', type: 'service', label: 'Billing Worker', description: 'new desc', source: 'ast' },
      keyIndex,
      mergeLog
    );

    assert.strictEqual(nodeMap.size, 1, 'no second node should be created for the same entity');
    assert.ok(!nodeMap.has('svc-new'), 'the incoming id must not become a new map entry');
    const merged = nodeMap.get('svc-existing');
    assert.strictEqual(merged.id, 'svc-existing', 'the existing (target) id must remain stable');
    assert.strictEqual(merged.description, 'new desc', 'fields update from the incoming node');
    assert.strictEqual(mergeLog.length, 1);
    assert.strictEqual(mergeLog[0].targetId, 'svc-existing');
    assert.strictEqual(mergeLog[0].mergedFromId, 'svc-new');
    assert.ok(mergeLog[0].changedFields.includes('description'));
  });

  test('resolveNodeIdentity: merging never downgrades an existing human/ast source via a lower-precedence board write', () => {
    const nodeMap = new Map([
      ['svc-existing', { id: 'svc-existing', type: 'service', label: 'Billing Worker', source: 'human' }],
    ]);
    const keyIndex = new Map([[canonicalKey({ type: 'service', label: 'Billing Worker' }), 'svc-existing']]);
    const mergeLog = [];

    resolveNodeIdentity(
      nodeMap,
      'svc-new',
      { id: 'svc-new', type: 'service', label: 'Billing Worker', source: 'board' },
      keyIndex,
      mergeLog
    );

    assert.strictEqual(nodeMap.get('svc-existing').source, 'human', 'source must not be downgraded by a board write');
  });

  test('resolveNodeIdentity: merging upgrades a board source to human/ast when the incoming write is verified', () => {
    const nodeMap = new Map([
      ['svc-existing', { id: 'svc-existing', type: 'service', label: 'Billing Worker', source: 'board' }],
    ]);
    const keyIndex = new Map([[canonicalKey({ type: 'service', label: 'Billing Worker' }), 'svc-existing']]);
    const mergeLog = [];

    resolveNodeIdentity(
      nodeMap,
      'svc-new',
      { id: 'svc-new', type: 'service', label: 'Billing Worker', source: 'ast' },
      keyIndex,
      mergeLog
    );

    assert.strictEqual(nodeMap.get('svc-existing').source, 'ast');
    assert.ok(mergeLog[0].changedFields.includes('source'));
  });

  // -----------------------------------------------------------------------------------------
  // resolveNodeIdentity() — legitimate near-miss (must NOT merge)
  // -----------------------------------------------------------------------------------------

  test('resolveNodeIdentity: a near-miss (distinct canonical key) creates a separate node, no merge', () => {
    const nodeMap = new Map([
      ['svc-existing', { id: 'svc-existing', type: 'service', label: 'Billing Worker', source: 'ast' }],
    ]);
    // keyIndex reflects only the existing node's own key — "Billing Workers" (plural) has a
    // distinct canonical key and is absent from the index, so no match is possible.
    const keyIndex = new Map([[canonicalKey({ type: 'service', label: 'Billing Worker' }), 'svc-existing']]);
    const mergeLog = [];

    resolveNodeIdentity(
      nodeMap,
      'svc-other',
      { id: 'svc-other', type: 'service', label: 'Billing Workers', source: 'ast' },
      keyIndex,
      mergeLog
    );

    assert.strictEqual(nodeMap.size, 2, 'a legitimately distinct entity must get its own node');
    assert.ok(nodeMap.has('svc-other'));
    assert.strictEqual(mergeLog.length, 0, 'no merge should be logged for a near-miss');
  });

  test('resolveNodeIdentity: a computed node whose key matches an existing node under the SAME id is a no-op merge (not logged as a key-based merge)', () => {
    const nodeMap = new Map([
      ['E90', { id: 'E90', type: 'epic', label: 'Test Epic', description: 'old', source: 'board' }],
    ]);
    const keyIndex = new Map([[canonicalKey({ id: 'E90', type: 'epic' }), 'E90']]);
    const mergeLog = [];

    resolveNodeIdentity(
      nodeMap,
      'E90',
      { id: 'E90', type: 'epic', label: 'Test Epic', description: 'new', source: 'board' },
      keyIndex,
      mergeLog
    );

    assert.strictEqual(nodeMap.size, 1);
    assert.strictEqual(nodeMap.get('E90').description, 'new', 'plain id-keyed update still applies');
    assert.strictEqual(mergeLog.length, 0, 'matching under the same id is the pre-existing idempotent case, not a key-based merge');
  });

  // -----------------------------------------------------------------------------------------
  // mergeGraph() — end-to-end through the public merge entrypoint
  // -----------------------------------------------------------------------------------------

  test('mergeGraph: existing idempotent-on-id behavior (E20_S09) is not regressed', () => {
    const existing = {
      nodes: [{ id: 'E90', type: 'epic', label: 'Test Epic', description: 'd', source: 'board' }],
      edges: [],
    };
    const computed = {
      nodes: new Map([['E90', { id: 'E90', type: 'epic', label: 'Test Epic', description: 'd', source: 'board' }]]),
      edges: new Map(),
    };

    const first = mergeGraph(existing, computed);
    const second = mergeGraph({ nodes: first.nodes, edges: first.edges }, computed);

    assert.deepStrictEqual(first.nodes, second.nodes);
    assert.strictEqual(second.nodes.length, 1);
    assert.strictEqual(second.mergeLog.length, 0);
  });

  test('mergeGraph: a genuine key-based merge reduces two entries to one and logs the merge', () => {
    const existing = {
      nodes: [{ id: 'svc-existing', type: 'service', label: 'Billing Worker', description: 'old', source: 'ast' }],
      edges: [],
    };
    const computed = {
      nodes: new Map([
        ['svc-new', { id: 'svc-new', type: 'service', label: 'Billing Worker', description: 'updated', source: 'ast' }],
      ]),
      edges: new Map(),
    };

    const result = mergeGraph(existing, computed);

    assert.strictEqual(result.nodes.length, 1);
    assert.strictEqual(result.nodes[0].id, 'svc-existing');
    assert.strictEqual(result.nodes[0].description, 'updated');
    assert.strictEqual(result.mergeLog.length, 1);
  });

  test('mergeGraph: return value is JSON-serializable as exactly {nodes, edges} for graph.json (mergeLog is reporting-only)', () => {
    const existing = { nodes: [], edges: [] };
    const computed = { nodes: new Map(), edges: new Map() };
    const result = mergeGraph(existing, computed);
    const { nodes, edges } = result;
    assert.deepStrictEqual(JSON.parse(JSON.stringify({ nodes, edges })), { nodes: [], edges: [] });
  });

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

  console.log(`\n${tests.length - failures}/${tests.length} passed`);
  if (failures > 0) process.exitCode = 1;
}

main();
