/**
 * @file project/app/api/parsers/board.usage-fields.test.js
 * Plain Node `assert`-based test for `parsers/board.js` and `routes/board.js` (E76_S03_T06),
 * following the no-framework convention of the sibling `*.test.js` files (see
 * `board.external-refs.test.js`, whose child-process fixture pattern this file reuses).
 *
 * Verifies the dashboard's board consumer carries the per-task and per-story token-accounting
 * fields documented in `templates/SCRUM_BOARD_SCHEMA.md` ("Usage fields (per-task token accounting)"
 * and "Usage fields on stories (per-story token accounting)") through to the `/board` response:
 *   - an item whose frontmatter carries the fields returns them, with their numeric values (numbers,
 *     not strings), and `usage_possibly_incomplete` as the literal `true`;
 *   - an item without the fields returns without them: the keys are absent, never `null`, never `0`
 *     (absence means "not measured"; an explicit `0` in frontmatter stays a measured `0`);
 *   - an item carrying only some of the fields returns exactly those, and nothing is filled in;
 *   - nothing else changes: the whole board minus the `usage_*` keys is byte-identical to the same
 *     board written without them, so sibling fields keep their values and their order.
 *
 * `BOARD_ROOT` in `board.js` is fixed at module-load time via `resolveProjectRoot()`, so each fixture
 * board is parsed in its own child `node` process with `JENGA_PROJECT_ROOT` pointing at the fixture.
 * That lets one run compare a "with" board against a "stripped" twin.
 *
 * Run directly:
 *   node project/app/api/parsers/board.usage-fields.test.js
 * or, from project/app/api/:
 *   npm test
 * (`express` and `gray-matter` resolve from `project/app/api/node_modules`; in a git worktree, which
 * has none, run with `NODE_PATH=<main checkout>/project/app/api/node_modules`.)
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const API_ROOT = path.resolve(__dirname, '..');

const TASK_USAGE_KEYS = [
  'usage_input_tokens',
  'usage_output_tokens',
  'usage_cache_write_tokens',
  'usage_cache_read_tokens',
  'usage_total_tokens',
  'usage_transcripts',
  'usage_measured_on',
  'usage_possibly_incomplete',
];
const STORY_USAGE_KEYS = [
  'usage_tasks_input_tokens',
  'usage_tasks_output_tokens',
  'usage_tasks_cache_write_tokens',
  'usage_tasks_cache_read_tokens',
  'usage_tasks_total_tokens',
  'usage_overhead_input_tokens',
  'usage_overhead_output_tokens',
  'usage_overhead_cache_write_tokens',
  'usage_overhead_cache_read_tokens',
  'usage_overhead_total_tokens',
  'usage_total_tokens',
  'usage_measured_on',
  'usage_possibly_incomplete',
];
const ALL_USAGE_KEYS = Array.from(new Set([...TASK_USAGE_KEYS, ...STORY_USAGE_KEYS]));
const isTokenKey = (k) => /_tokens$/.test(k) || k === 'usage_transcripts';

// On-disk shape per templates/SCRUM_BOARD_SCHEMA.md: plain decimal digits, no separators.
const TASK_FULL = [
  'usage_input_tokens: 1200',
  'usage_output_tokens: 3400',
  'usage_cache_write_tokens: 56000',
  'usage_cache_read_tokens: 780000',
  'usage_total_tokens: 840600',
  'usage_transcripts: 2',
  'usage_measured_on: 2026-10-25',
  'usage_possibly_incomplete: true',
];
// Partial: a measured explicit zero next to missing siblings. The zero must stay 0, and the missing
// fields must not be filled in with 0.
const TASK_PARTIAL = ['usage_input_tokens: 0', 'usage_output_tokens: 42', 'usage_transcripts: 1'];
const STORY_FULL = [
  'usage_tasks_input_tokens: 1200',
  'usage_tasks_output_tokens: 3400',
  'usage_tasks_cache_write_tokens: 56000',
  'usage_tasks_cache_read_tokens: 780000',
  'usage_tasks_total_tokens: 840600',
  'usage_overhead_input_tokens: 100',
  'usage_overhead_output_tokens: 200',
  'usage_overhead_cache_write_tokens: 3000',
  'usage_overhead_cache_read_tokens: 40000',
  'usage_overhead_total_tokens: 43300',
  'usage_total_tokens: 883900',
  'usage_measured_on: 2026-10-25',
  'usage_possibly_incomplete: true',
];
const STORY_PARTIAL = ['usage_tasks_total_tokens: 500', 'usage_total_tokens: 500', 'usage_measured_on: 2026-10-26'];

function item(id, parentKey, parentId, usage) {
  // usage_* deliberately sit in the middle of the frontmatter, between sibling keys, so key-order
  // preservation is observable.
  const lines = ['---', `id: ${id}`];
  if (parentKey) lines.push(`${parentKey}: ${parentId}`);
  lines.push(`title: Title of ${id}`, 'status: Pending', 'date_created: 2026-10-06');
  if (usage) lines.push(...usage);
  lines.push('docs: ["README.md"]', 'priority: P1', '---', '', `# ${id}`, '', `Body of ${id}.`, '');
  return lines.join('\n');
}

// E01 carries the fields (when withUsage). E02 never does.
//   E01_S01 story full,    tasks: T01 full, T02 partial, T03 none
//   E01_S02 story partial, task:  T01 none
//   E01_S03 story none,    task:  T01 full (a task may be measured under an unmeasured story)
function writeBoard(root, withUsage) {
  const u = (lines) => (withUsage ? lines : null);
  const put = (rel, text) => {
    const full = path.join(root, 'project', 'board', rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, text);
  };
  put('epics/E01_with-usage.md', item('E01', null, null, null));
  put('stories/E01_S01_full.md', item('E01_S01', 'epic_id', 'E01', u(STORY_FULL)));
  put('tasks/E01_S01_T01_full.md', item('E01_S01_T01', 'story_id', 'E01_S01', u(TASK_FULL)));
  put('tasks/E01_S01_T02_partial.md', item('E01_S01_T02', 'story_id', 'E01_S01', u(TASK_PARTIAL)));
  put('tasks/E01_S01_T03_none.md', item('E01_S01_T03', 'story_id', 'E01_S01', null));
  put('stories/E01_S02_partial.md', item('E01_S02', 'epic_id', 'E01', u(STORY_PARTIAL)));
  put('tasks/E01_S02_T01_none.md', item('E01_S02_T01', 'story_id', 'E01_S02', null));
  put('stories/E01_S03_none.md', item('E01_S03', 'epic_id', 'E01', null));
  put('tasks/E01_S03_T01_full.md', item('E01_S03_T01', 'story_id', 'E01_S03', u(TASK_FULL)));
  put('epics/E02_plain.md', item('E02', null, null, null));
  put('stories/E02_S01_plain.md', item('E02_S01', 'epic_id', 'E02', null));
  put('tasks/E02_S01_T01_plain.md', item('E02_S01_T01', 'story_id', 'E02_S01', null));
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

const byId = (board, id) => flatten(board).find((i) => i.id === id);
const usageKeysOf = (obj) => Object.keys(obj).filter((k) => k.startsWith('usage_'));

// Remove usage_* keys from an item, recursing into nested stories/tasks, preserving order.
function stripTree(obj) {
  const copy = { ...obj };
  for (const k of ALL_USAGE_KEYS) delete copy[k];
  if (Array.isArray(copy.stories)) copy.stories = copy.stories.map(stripTree);
  if (Array.isArray(copy.tasks)) copy.tasks = copy.tasks.map(stripTree);
  return copy;
}

// Parse a `key: value` fixture line for the expected value, independent of the code under test.
function expectedFrom(lines) {
  const out = {};
  for (const l of lines) {
    const [k, v] = l.split(': ');
    out[k] = v === 'true' ? true : /^\d+$/.test(v) ? Number(v) : v;
  }
  return out;
}

// `usage_measured_on` is an ISO date in the frontmatter. gray-matter's YAML core reads a bare date as
// a Date, which JSON-serialises as a full ISO timestamp, exactly as `date_created` already does; so
// compare it by its date part.
function assertUsage(it, expected) {
  assert.deepStrictEqual(usageKeysOf(it).sort(), Object.keys(expected).sort(), `${it.id}: usage key set differs`);
  for (const [k, v] of Object.entries(expected)) {
    if (k === 'usage_measured_on') {
      assert.ok(String(it[k]).startsWith(v), `${it.id}.${k} = ${it[k]}, expected a ${v} date`);
    } else if (k === 'usage_possibly_incomplete') {
      assert.strictEqual(it[k], true, `${it.id}.${k} is not the literal true`);
    } else {
      assert.strictEqual(typeof it[k], 'number', `${it.id}.${k} is ${typeof it[k]}, expected a number`);
      assert.ok(Number.isInteger(it[k]) && it[k] >= 0, `${it.id}.${k} is not a non-negative integer`);
      assert.strictEqual(it[k], v, `${it.id}.${k} changed`);
    }
  }
}

function assertNoUsage(it) {
  for (const k of ALL_USAGE_KEYS) {
    assert.ok(!(k in it), `${it.id} gained ${k}`);
  }
  // Serialised form too: nothing like "usage_...": null or 0 anywhere in the item's own keys.
  assert.deepStrictEqual(usageKeysOf(it), []);
}

const tests = [];
function test(name, fn) {
  tests.push({ name, fn });
}

const rootWith = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'board-usage-with-')));
const rootStripped = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'board-usage-stripped-')));
writeBoard(rootWith, true);
writeBoard(rootStripped, false);

let withBoard;
let strippedBoard;

test('parser runs over a board carrying usage fields without error or skipped files', () => {
  withBoard = runBoard(rootWith);
  strippedBoard = runBoard(rootStripped);
  assert.strictEqual(withBoard.board.length, 2);
  assert.strictEqual(flatten(withBoard.board).length, 12, '2 epics + 4 stories + 6 tasks present');
  assert.deepStrictEqual(
    flatten(withBoard.board).map((i) => i.id),
    flatten(strippedBoard.board).map((i) => i.id),
    'same items, same order, as the stripped twin'
  );
});

test('a task with all eight usage fields returns them, numeric, with usage_possibly_incomplete as true', () => {
  for (const id of ['E01_S01_T01', 'E01_S03_T01']) {
    const task = byId(withBoard.board, id);
    assertUsage(task, expectedFrom(TASK_FULL));
    assert.strictEqual(task.usage_total_tokens, 840600);
    assert.strictEqual(task.usage_transcripts, 2);
  }
});

test('a story with all thirteen usage fields returns them, numeric, with usage_possibly_incomplete as true', () => {
  const story = byId(withBoard.board, 'E01_S01');
  assertUsage(story, expectedFrom(STORY_FULL));
  assert.strictEqual(story.usage_tasks_total_tokens, 840600);
  assert.strictEqual(story.usage_overhead_total_tokens, 43300);
  assert.strictEqual(story.usage_total_tokens, 883900);
});

test('a partially measured task returns exactly the fields it carries; an explicit 0 stays 0, missing ones stay absent', () => {
  const task = byId(withBoard.board, 'E01_S01_T02');
  assertUsage(task, expectedFrom(TASK_PARTIAL));
  assert.strictEqual(task.usage_input_tokens, 0, 'a measured zero must stay a zero');
  for (const k of TASK_USAGE_KEYS) {
    if (!(k in expectedFrom(TASK_PARTIAL))) assert.ok(!(k in task), `${k} was filled in on a partial task`);
  }
  assert.ok(!('usage_possibly_incomplete' in task), 'usage_possibly_incomplete must never be written as false');
});

test('a partially measured story returns exactly the fields it carries and nothing is filled in', () => {
  const story = byId(withBoard.board, 'E01_S02');
  assertUsage(story, expectedFrom(STORY_PARTIAL));
  for (const k of STORY_USAGE_KEYS) {
    if (!(k in expectedFrom(STORY_PARTIAL))) assert.ok(!(k in story), `${k} was filled in on a partial story`);
  }
});

test('items without usage fields stay without them, never null and never 0', () => {
  for (const id of ['E01', 'E01_S03', 'E01_S01_T03', 'E01_S02_T01', 'E02', 'E02_S01', 'E02_S01_T01']) {
    assertNoUsage(byId(withBoard.board, id));
  }
  // A measured child does not leak usage onto its unmeasured parent or siblings.
  assertNoUsage(byId(withBoard.board, 'E01_S03'));
  for (const it of flatten(withBoard.board)) {
    for (const k of usageKeysOf(it)) {
      assert.notStrictEqual(it[k], null, `${it.id}.${k} is null`);
      if (isTokenKey(k)) assert.strictEqual(typeof it[k], 'number', `${it.id}.${k} is not numeric`);
    }
  }
});

test('whole board minus usage_* is byte-identical to the stripped board (existing fields unchanged)', () => {
  assert.strictEqual(JSON.stringify(withBoard.board.map(stripTree)), JSON.stringify(strippedBoard.board));
  // And no stripped-board item carries a usage key at all.
  for (const it of flatten(strippedBoard.board)) assertNoUsage(it);
});

test('sibling fields keep their order when usage_* are present', () => {
  const task = byId(withBoard.board, 'E01_S01_T01');
  const keys = Object.keys(task);
  assert.deepStrictEqual(keys.slice(0, 6), ['id', 'story_id', 'title', 'status', 'date_created', 'usage_input_tokens']);
  assert.ok(keys.indexOf('docs') > keys.indexOf('usage_possibly_incomplete'), 'docs must still follow the usage block');
  assert.ok(keys.indexOf('priority') > keys.indexOf('docs'));
});

test('GET /board and GET /board/:epicId return 200 with the usage fields included', () => {
  assert.strictEqual(withBoard.all.status, 200);
  assert.strictEqual(withBoard.one.status, 200);
  assert.strictEqual(
    JSON.stringify(withBoard.all.body.data),
    JSON.stringify(withBoard.board),
    'route output differs from parseBoard() output'
  );
  const epic = withBoard.one.body.data;
  assert.strictEqual(epic.id, 'E01');
  const story = epic.stories.find((s) => s.id === 'E01_S01');
  assert.strictEqual(story.usage_total_tokens, 883900);
  assert.strictEqual(story.usage_possibly_incomplete, true);
  assert.strictEqual(story.tasks.find((t) => t.id === 'E01_S01_T01').usage_total_tokens, 840600);
  assertNoUsage(story.tasks.find((t) => t.id === 'E01_S01_T03'));
  // The same absence holds in the HTTP payload, not just in the parser output.
  const wire = withBoard.all.body.data.find((e) => e.id === 'E02');
  assertNoUsage(wire.stories[0].tasks[0]);
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
