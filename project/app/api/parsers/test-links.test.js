/**
 * @file project/app/api/parsers/test-links.test.js
 * Plain Node `assert`-based test script for `readTestLinks()` (test-links.js). No test framework,
 * same convention as knowledge-graph.test.js.
 *
 * Run directly:
 *   node project/app/api/parsers/test-links.test.js
 * or, from project/app/api/:
 *   npm test
 *
 * Fixtures are injected by patching fs.readFileSync for the one path ending in
 * project/knowledge-graph/test-links.json; the real generated file is never read or touched.
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const LINKS_SUFFIX = path.join('project', 'knowledge-graph', 'test-links.json');
const originalReadFileSync = fs.readFileSync;

// undefined = passthrough; null = simulate a missing file (ENOENT); string = mocked file content.
let mockLinksJson;

fs.readFileSync = function patchedReadFileSync(filePath, ...rest) {
  if (mockLinksJson !== undefined && typeof filePath === 'string' && filePath.endsWith(LINKS_SUFFIX)) {
    if (mockLinksJson === null) {
      const err = new Error(`ENOENT: no such file or directory, open '${filePath}'`);
      err.code = 'ENOENT';
      throw err;
    }
    return mockLinksJson;
  }
  return originalReadFileSync.call(fs, filePath, ...rest);
};

function withMock(value, fn) {
  const previous = mockLinksJson;
  mockLinksJson = value;
  try {
    return fn();
  } finally {
    mockLinksJson = previous;
  }
}

const { readTestLinks } = require('./test-links');

let passed = 0;
function test(name, fn) {
  fn();
  passed += 1;
  console.log(`ok - ${name}`);
}

const link = (node_id, name, extra = {}) => ({
  node_id,
  test_id: `tests/${name}.bats`,
  type: 'e2e',
  name,
  file: `tests/${name}.bats`,
  line: 1,
  ...extra,
});

const FIXTURE = JSON.stringify({
  schema_version: 1,
  generated_from: { graph_sha256: 'x', tests: {} },
  links: [
    link('E06_S05', 'alpha', { type: 'unit', line: 12 }),
    link('E06_S05', 'beta', { line: 30 }),
    link('E07_S01', 'gamma'),
  ],
});

test('linked node with two tests maps both, with name/type/file/line only', () => {
  const result = withMock(FIXTURE, () => readTestLinks());
  assert.strictEqual(result.total, 3);
  assert.strictEqual(result.byNode.E06_S05.length, 2);
  assert.deepStrictEqual(result.byNode.E06_S05[0], {
    name: 'alpha',
    type: 'unit',
    file: 'tests/alpha.bats',
    line: 12,
  });
  assert.deepStrictEqual(Object.keys(result.byNode.E06_S05[1]).sort(), ['file', 'line', 'name', 'type']);
  assert.strictEqual(result.byNode.E06_S05[1].name, 'beta');
  assert.strictEqual(result.byNode.E07_S01.length, 1);
});

test('node with no tests is absent from the map', () => {
  const result = withMock(FIXTURE, () => readTestLinks());
  assert.strictEqual(result.byNode.E99_S99, undefined);
  assert.strictEqual('E99_S99' in result.byNode, false);
});

test('missing file yields an empty map and does not throw', () => {
  const result = withMock(null, () => readTestLinks());
  assert.deepStrictEqual(result, { byNode: {}, total: 0 });
});

test('unparseable file yields an empty map and does not throw', () => {
  assert.deepStrictEqual(withMock('{ not json', () => readTestLinks()), { byNode: {}, total: 0 });
  assert.deepStrictEqual(withMock('', () => readTestLinks()), { byNode: {}, total: 0 });
});

test('wrong shape (no links array) yields an empty map', () => {
  for (const body of ['[]', 'null', '{}', '{"links":{"a":1}}', '{"links":"x"}', '42']) {
    assert.deepStrictEqual(withMock(body, () => readTestLinks()), { byNode: {}, total: 0 }, body);
  }
});

test('a link without node_id is skipped while valid links are kept', () => {
  const body = JSON.stringify({
    schema_version: 1,
    links: [
      link('E06_S05', 'keep-1'),
      { test_id: 't', type: 'unit', name: 'orphan', file: 'f', line: 1 },
      { node_id: '', name: 'blank' },
      { node_id: 7, name: 'numeric' },
      null,
      'junk',
      link('E06_S05', 'keep-2'),
    ],
  });
  const result = withMock(body, () => readTestLinks());
  assert.strictEqual(result.total, 2);
  assert.deepStrictEqual(Object.keys(result.byNode), ['E06_S05']);
  assert.deepStrictEqual(
    result.byNode.E06_S05.map((l) => l.name),
    ['keep-1', 'keep-2']
  );
});

test('prototype-ish node ids are treated as plain keys', () => {
  const body = JSON.stringify({ links: [link('__proto__', 'p'), link('constructor', 'c')] });
  const result = withMock(body, () => readTestLinks());
  assert.strictEqual(result.total, 2);
  assert.strictEqual(Object.getPrototypeOf(result.byNode), Object.prototype);
  assert.strictEqual(result.byNode.constructor.length, 1);
});

console.log(`\n${passed} tests passed`);
