/**
 * @file project/app/api/parsers/board.external-refs.test.js
 * Plain Node `assert`-based test for `parsers/board.js` and `routes/board.js` (E71_S03_T03),
 * following the no-framework convention of the sibling `*.test.js` files (see `rapports.test.js`).
 *
 * Verifies the dashboard's board consumer is absent-safe for the optional `external_refs` list and
 * the `external_refs_declined` / `external_refs_declined_note` skip marker documented in
 * `templates/SCRUM_BOARD_SCHEMA.md` ("External Refs Fields"):
 *   - no item carrying the fields is skipped, dropped, or crashes the parser;
 *   - the fields' sibling frontmatter keys keep their values and their order;
 *   - an item without the fields renders byte-identically to the same board with the fields
 *     stripped from every file (i.e. to what the parser produced before the schema change).
 *
 * `BOARD_ROOT` in `board.js` is fixed at module-load time via `resolveProjectRoot()`, so each
 * fixture board is parsed in its own child `node` process with `JENGA_PROJECT_ROOT` pointing at
 * the fixture. That lets one run compare a "with" board against a "stripped" twin.
 *
 * Run directly:
 *   node project/app/api/parsers/board.external-refs.test.js
 * or, from project/app/api/:
 *   npm test
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const API_ROOT = path.resolve(__dirname, '..');
const EXTERNAL_KEYS = ['external_refs', 'external_refs_declined', 'external_refs_declined_note'];

// On-disk shape per templates/SCRUM_BOARD_SCHEMA.md: block list of mappings under external_refs.
const REFS_EPIC = [
  'external_refs:',
  '  - system: jira',
  '    kind: issue',
  '    key: PROJ-123',
  '    linked_on: 2026-10-06',
  'external_refs_declined: true',
  'external_refs_declined_note: "Skipped 2026-10-06: user chose not to link this item."',
];
const REFS_STORY = [
  'external_refs:',
  '  - system: confluence',
  '    kind: page',
  '    url: https://example.atlassian.net/wiki/spaces/PROJ/pages/123456',
  '    linked_on: 2026-10-06',
  '  - system: jira',
  '    kind: issue',
  '    key: PROJ-124',
  '    linked_on: 2026-10-06',
  'external_refs_declined: true',
  'external_refs_declined_note: "Skipped 2026-10-06: user chose not to link this item."',
];
const REFS_TASK = [
  'external_refs:',
  '  - system: bitbucket',
  '    kind: pull-request',
  '    url: https://bitbucket.org/acme/repo/pull-requests/7',
  '    linked_on: 2026-10-06',
  'external_refs_declined: true',
  'external_refs_declined_note: "Skipped 2026-10-06: user chose not to link this item."',
];

function item(id, parentKey, parentId, extra, withRefs) {
  // external_refs* deliberately sit in the middle of the frontmatter, between sibling keys, so
  // key-order preservation is observable.
  const lines = ['---', `id: ${id}`];
  if (parentKey) lines.push(`${parentKey}: ${parentId}`);
  lines.push(`title: Title of ${id}`, 'status: Pending', 'date_created: 2026-10-06');
  if (withRefs) lines.push(...withRefs);
  lines.push('docs: ["README.md"]', 'priority: P1', '---', '', `# ${id}`, '', `Body of ${id}.`, '');
  return lines.join('\n');
}

function writeBoard(root, withRefs) {
  const put = (rel, text) => {
    const full = path.join(root, 'project', 'board', rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, text);
  };
  // E01 family carries the fields (when withRefs); E02 family never does.
  put('epics/E01_with-refs.md', item('E01', null, null, null, withRefs && REFS_EPIC));
  put('stories/E01_S01_with-refs.md', item('E01_S01', 'epic_id', 'E01', null, withRefs && REFS_STORY));
  put('tasks/E01_S01_T01_with-refs.md', item('E01_S01_T01', 'story_id', 'E01_S01', null, withRefs && REFS_TASK));
  put('epics/E02_plain.md', item('E02', null, null, null, null));
  put('stories/E02_S01_plain.md', item('E02_S01', 'epic_id', 'E02', null, null));
  put('tasks/E02_S01_T01_plain.md', item('E02_S01_T01', 'story_id', 'E02_S01', null, null));
}

// Child script: parse the board and exercise the Express router, print one JSON document.
const CHILD = `
const http = require('http');
const express = require('express');
const { parseBoard } = require(${JSON.stringify(path.join(API_ROOT, 'parsers', 'board.js'))});
const router = require(${JSON.stringify(path.join(API_ROOT, 'routes', 'board.js'))});
const get = (port, p) => new Promise((resolve, reject) => {
  http.get({ port, path: p }, (res) => {
    let b = '';
    res.on('data', (c) => (b += c));
    res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(b) }));
  }).on('error', reject);
});
(async () => {
  const board = await parseBoard();
  const app = express();
  app.use('/board', router);
  const server = app.listen(0);
  const port = server.address().port;
  const all = await get(port, '/board');
  const one = await get(port, '/board/E01');
  server.close();
  process.stdout.write(JSON.stringify({ board, all, one }));
})().catch((e) => { console.error(e.stack); process.exit(1); });
`;

function runBoard(root) {
  const res = spawnSync(process.execPath, ['-e', CHILD], {
    cwd: API_ROOT,
    env: { ...process.env, JENGA_PROJECT_ROOT: root },
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  assert.strictEqual(res.status, 0, `child failed: ${res.stderr}`);
  assert.ok(!/Skipping malformed/.test(res.stderr), `parser skipped a file: ${res.stderr}`);
  return JSON.parse(res.stdout);
}

function flatten(board) {
  const out = [];
  for (const e of board) {
    out.push(e);
    for (const s of e.stories) {
      out.push(s);
      for (const t of s.tasks) out.push(t);
    }
  }
  return out;
}

function stripExternal(obj) {
  const copy = { ...obj };
  for (const k of EXTERNAL_KEYS) delete copy[k];
  return copy;
}

// Remove external_refs* keys from an item, recursing into nested stories/tasks, preserving order.
function stripTree(obj) {
  const copy = stripExternal(obj);
  if (Array.isArray(copy.stories)) copy.stories = copy.stories.map(stripTree);
  if (Array.isArray(copy.tasks)) copy.tasks = copy.tasks.map(stripTree);
  return copy;
}

const tests = [];
function test(name, fn) {
  tests.push({ name, fn });
}

const rootWith = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'board-extrefs-with-')));
const rootStripped = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'board-extrefs-stripped-')));
writeBoard(rootWith, true);
writeBoard(rootStripped, false);

let withBoard;
let strippedBoard;

test('parser runs over a board carrying external_refs and the skip marker without error or skipped files', () => {
  withBoard = runBoard(rootWith);
  strippedBoard = runBoard(rootStripped);
  assert.strictEqual(withBoard.board.length, 2);
  assert.strictEqual(flatten(withBoard.board).length, 6, 'all 2 epics + 2 stories + 2 tasks present');
  assert.deepStrictEqual(
    flatten(withBoard.board).map((i) => i.id),
    flatten(strippedBoard.board).map((i) => i.id),
    'same items, same order, as the stripped twin'
  );
  assert.deepStrictEqual(
    flatten(withBoard.board).map((i) => i._file),
    flatten(strippedBoard.board).map((i) => i._file)
  );
});

test('items carrying the fields keep external_refs and the skip marker intact at every level', () => {
  const [epic] = withBoard.board.filter((e) => e.id === 'E01');
  const story = epic.stories[0];
  const task = story.tasks[0];
  for (const it of [epic, story, task]) {
    assert.ok(Array.isArray(it.external_refs) && it.external_refs.length >= 1, `${it.id} lost external_refs`);
    assert.strictEqual(it.external_refs_declined, true);
    assert.match(it.external_refs_declined_note, /^Skipped 2026-10-06/);
  }
  assert.strictEqual(epic.external_refs[0].system, 'jira');
  assert.strictEqual(epic.external_refs[0].key, 'PROJ-123');
  assert.strictEqual(story.external_refs.length, 2);
  assert.strictEqual(story.external_refs[0].url, 'https://example.atlassian.net/wiki/spaces/PROJ/pages/123456');
  assert.strictEqual(task.external_refs[0].kind, 'pull-request');
  // Parser does not mutate nested entry key order.
  assert.deepStrictEqual(Object.keys(story.external_refs[0]), ['system', 'kind', 'url', 'linked_on']);
});

test('sibling fields keep their values and order when external_refs* are present', () => {
  for (const [w, s] of flatten(withBoard.board).map((w, i) => [w, flatten(strippedBoard.board)[i]])) {
    // Nested containers are compared separately by the whole-tree test below.
    const wKeys = Object.keys(stripExternal(w));
    const sKeys = Object.keys(s);
    assert.deepStrictEqual(wKeys, sKeys, `${w.id}: key set/order changed`);
    for (const k of wKeys) {
      if (k === 'stories' || k === 'tasks') continue;
      assert.strictEqual(JSON.stringify(w[k]), JSON.stringify(s[k]), `${w.id}.${k} changed`);
    }
  }
});

test('whole board minus external_refs* is byte-identical to the stripped board (nothing else changed)', () => {
  assert.strictEqual(JSON.stringify(withBoard.board.map(stripTree)), JSON.stringify(strippedBoard.board));
});

test('items without the fields render byte-identically with and without fields elsewhere on the board', () => {
  const plainWith = withBoard.board.find((e) => e.id === 'E02');
  const plainStripped = strippedBoard.board.find((e) => e.id === 'E02');
  assert.ok(plainWith && plainStripped);
  assert.strictEqual(JSON.stringify(plainWith), JSON.stringify(plainStripped));
  for (const k of EXTERNAL_KEYS) {
    assert.ok(!(k in plainWith), `plain epic gained ${k}`);
    assert.ok(!(k in plainWith.stories[0]), `plain story gained ${k}`);
    assert.ok(!(k in plainWith.stories[0].tasks[0]), `plain task gained ${k}`);
  }
});

test('GET /board and GET /board/:epicId return 200 with the same data, fields included', () => {
  assert.strictEqual(withBoard.all.status, 200);
  assert.strictEqual(withBoard.one.status, 200);
  assert.strictEqual(
    JSON.stringify(withBoard.all.body.data),
    JSON.stringify(withBoard.board),
    'route output differs from parseBoard() output'
  );
  assert.strictEqual(withBoard.one.body.data.id, 'E01');
  assert.strictEqual(withBoard.one.body.data.external_refs[0].key, 'PROJ-123');
  assert.strictEqual(withBoard.one.body.data.stories[0].tasks[0].external_refs_declined, true);
});

(async () => {
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
  fs.rmSync(rootWith, { recursive: true, force: true });
  fs.rmSync(rootStripped, { recursive: true, force: true });
  console.log(`\n${tests.length - failures}/${tests.length} passed`);
  if (failures > 0) process.exitCode = 1;
})();
