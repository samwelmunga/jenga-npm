/**
 * @file project/app/api/parsers/lib/board-id-sort.test.js
 * Plain Node `assert` test (same no-framework convention as markdown-dir-reader.test.js) proving the
 * JavaScript board-ID sort agrees with the Python and shell forms: it loads the shared case list
 * tests/fixtures/board-id-sort-cases.json (no copied literal list) and asserts every case.
 *
 * Run directly:
 *   node project/app/api/parsers/lib/board-id-sort.test.js
 * or, from project/app/api/:
 *   npm test
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const { compareBoardIds, boardIdSortKey, sortBoardIds } = require('./board-id-sort');

// This file lives at <repo>/project/app/api/parsers/lib/, so the repo root is five levels up.
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..', '..', '..');
const CASES_PATH = path.join(REPO_ROOT, 'tests', 'fixtures', 'board-id-sort-cases.json');

const cases = JSON.parse(fs.readFileSync(CASES_PATH, 'utf8'));
assert.ok(Array.isArray(cases) && cases.length > 0, 'case list must be a non-empty array');

let checked = 0;

cases.forEach((c, i) => {
  const label = `case ${i} (${JSON.stringify(c.input)})`;
  const before = JSON.stringify(c.input);

  assert.deepStrictEqual(sortBoardIds(c.input), c.expected, `sortBoardIds: ${label}`);

  const viaComparator = c.input.slice().sort(compareBoardIds);
  assert.deepStrictEqual(viaComparator, c.expected, `compareBoardIds: ${label}`);

  assert.strictEqual(JSON.stringify(c.input), before, `input was mutated: ${label}`);
  assert.notStrictEqual(sortBoardIds(c.input), c.input, `sortBoardIds must return a new array: ${label}`);

  // Order is independent of the input arrangement.
  assert.deepStrictEqual(sortBoardIds(c.expected.slice().reverse()), c.expected, `reversed input: ${label}`);
  checked += 1;
});

// Comparator contract: antisymmetric, reflexive-zero, and consistent over every pair in the case list.
const everyName = Array.from(new Set(cases.flatMap((c) => c.input)));
for (const a of everyName) {
  assert.strictEqual(compareBoardIds(a, a), 0, `compareBoardIds(${a}, ${a}) must be 0`);
  for (const b of everyName) {
    assert.strictEqual(
      Math.sign(compareBoardIds(a, b)) + Math.sign(compareBoardIds(b, a)),
      0,
      `antisymmetry for ${a} / ${b}`
    );
  }
}

// Key shape: board IDs sort before non-IDs; missing segments are -1; widths are exact beyond 2^53.
assert.strictEqual(boardIdSortKey('E10_S2')[0], 0);
assert.deepStrictEqual(boardIdSortKey('E10_S2').slice(1, 4), [10n, 2n, -1n]);
assert.strictEqual(boardIdSortKey('README.md')[0], 1);
assert.ok(compareBoardIds('E99999999999999999999', 'E99999999999999999998') > 0, 'exact beyond 2^53');
assert.ok(compareBoardIds('E1', 'E01') > 0, 'equal numbers tie-break by text');

// A frozen input array is sorted without error (no mutation).
const frozen = Object.freeze(['E10', 'E2']);
assert.deepStrictEqual(sortBoardIds(frozen), ['E2', 'E10']);

console.log(`board-id-sort: ${checked} fixture cases and contract checks passed`);
