/**
 * @file project/app/api/parsers/board.mixed-width.test.js
 * Plain Node `assert` test for the dashboard's board path with a mixed-width board (E86_S05_T06,
 * audit group 5 of E86_S05). Follows the no-framework convention of `board.numeric-order.test.js`.
 *
 * Ordering is E86_S02_T05's job and is pinned by `board.numeric-order.test.js`. This file pins GROUPING
 * and COMPLETENESS: with epics E01, E10, E99, E100, E1001 on one board,
 *   - E10 owns only its own stories (never E100's or E1001's, which share its text prefix);
 *   - E100 owns S1, S10 and S100 (S1 is a text prefix of S10 and S100), and each story owns only its own tasks,
 *     including E100_S100_T100;
 *   - E1001 owns E1001_S100 and E1001_S100_T100 (T100 under a different epic's S100 does not collide);
 *   - no epic, story or task is dropped, duplicated or listed under a parent it does not belong to;
 *   - `project/todo.md` queues wide IDs exactly (`_queued` on E100_S100, E100_S100_T100 and E1001_S100_T100 and on
 *     nothing else; an epic-only `E1001` line and a rapport filename citing E10_S1_T10 queue nothing);
 *   - the kanban view (`project/app/ui/src/components/board/kanbanColumns.js`, an ES module, loaded with a
 *     dynamic `import()`) places every item in exactly one column or deliberately excludes it (an unqueued
 *     `Pending` item), so the buckets plus the exclusions add up to every item on the board;
 *   - `GET /v1/board/:epicId` (routes/board.js, mounted on a throwaway express app) resolves an epic by exact
 *     id: E10, E100 and E1001 each return themselves, and E1 is a 404, not a prefix match.
 *
 * `BOARD_ROOT` in `board.js` and the todo path are resolved from `JENGA_PROJECT_ROOT`, so the fixture is built and the
 * variable set before `board.js` is first required.
 *
 * Run directly:
 *   node project/app/api/parsers/board.mixed-width.test.js
 * or, from project/app/api/:
 *   npm test
 * (`gray-matter` is resolved from the repository's root `node_modules`; in a git worktree, which has none, run with
 * `NODE_PATH=<main checkout>/node_modules`, or rely on the walk-up to it when the worktree lives under the checkout.)
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { pathToFileURL } = require('url');

const ROOT = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'board-mixed-width-')));
process.on('exit', () => fs.rmSync(ROOT, { recursive: true, force: true }));
process.env.JENGA_PROJECT_ROOT = ROOT;

// id -> status. Written literally; the parent of each id is derived from the id text only inside the fixture writer.
const EPICS = { E01: 'Passed', E10: 'In Progress', E99: 'Merged', E100: 'In Progress', E1001: 'In Progress' };
const STORIES = {
  E01: { E01_S1: 'Passed' },
  E10: { E10_S1: 'In Progress', E10_S2: 'Pending' },
  E99: { E99_S1: 'Merged' },
  E100: { E100_S1: 'Passed', E100_S10: 'In Progress', E100_S100: 'Pending' },
  E1001: { E1001_S100: 'In Progress' },
};
const TASKS = {
  E01_S1: { E01_S1_T1: 'Passed' },
  E10_S1: { E10_S1_T1: 'Passed', E10_S1_T10: 'In Progress' },
  E100_S1: { E100_S1_T1: 'Passed' },
  E100_S10: { E100_S10_T10: 'In Progress' },
  E100_S100: { E100_S100_T100: 'Pending' },
  E1001_S100: { E1001_S100_T100: 'Pending' },
};

function writeFixture() {
  const put = (rel, text) => {
    const full = path.join(ROOT, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, text);
  };
  const fm = (id, status, parentKey, parentId) =>
    ['---', `id: ${id}`, ...(parentKey ? [`${parentKey}: ${parentId}`] : []), `title: "Title of ${id}"`, `status: ${status}`,
      'date_created: "2026-11-06"', '---', '', `Body of ${id}.`, ''].join('\n');

  for (const [e, status] of Object.entries(EPICS)) {
    put(`project/board/epics/${e}_epic.md`, fm(e, status));
    for (const [s, sStatus] of Object.entries(STORIES[e] || {})) {
      put(`project/board/stories/${s}_story.md`, fm(s, sStatus, 'epic_id', e));
      for (const [t, tStatus] of Object.entries(TASKS[s] || {})) {
        put(`project/board/tasks/${t}_task.md`, fm(t, tStatus, 'story_id', s));
      }
    }
  }
  put('project/todo.md', [
    '# Todo',
    '',
    'Queue the wide task: E100_S100_T100',
    'Queue the wide story: E100_S100',
    'Queue the other wide task: E1001_S100_T100',
    'Epic only, never queues anything: E1001',
    'Cites project/rapports/problems/E10_S1_T10-note.md mid-line but queues nothing.',
    '',
  ].join('\n'));
}
writeFixture();

const { parseBoard } = require('./board');

const EXPECTED_EPIC_ORDER = ['E01', 'E10', 'E99', 'E100', 'E1001'];
const EXPECTED_QUEUED = ['E100_S100', 'E100_S100_T100', 'E1001_S100_T100'];

(async () => {
  const board = await parseBoard();

  // --- Grouping ---------------------------------------------------------------------------------------------
  assert.deepStrictEqual(board.map((e) => e.id), EXPECTED_EPIC_ORDER, 'epics: every epic present once, in numeric order');

  for (const epic of board) {
    assert.deepStrictEqual(
      epic.stories.map((s) => s.id),
      Object.keys(STORIES[epic.id]),
      `stories of ${epic.id}: exactly its own, none borrowed from a text-prefix sibling`
    );
    for (const story of epic.stories) {
      assert.strictEqual(story.epic_id, epic.id, `${story.id} listed under ${epic.id} but belongs to ${story.epic_id}`);
      assert.deepStrictEqual(
        story.tasks.map((t) => t.id),
        Object.keys(TASKS[story.id] || {}),
        `tasks of ${story.id}: exactly its own`
      );
      for (const task of story.tasks) {
        assert.strictEqual(task.story_id, story.id, `${task.id} listed under ${story.id} but belongs to ${task.story_id}`);
      }
    }
  }

  const byId = (id) => {
    for (const e of board) {
      if (e.id === id) return e;
      for (const s of e.stories) {
        if (s.id === id) return s;
        for (const t of s.tasks) if (t.id === id) return t;
      }
    }
    return undefined;
  };

  // The spec's named cases, spelled out.
  assert.deepStrictEqual(byId('E10').stories.map((s) => s.id), ['E10_S1', 'E10_S2'], 'E10 owns only E10_S1 and E10_S2');
  assert.deepStrictEqual(byId('E100').stories.map((s) => s.id), ['E100_S1', 'E100_S10', 'E100_S100'], 'E100 owns S1, S10, S100');
  assert.deepStrictEqual(byId('E100_S100').tasks.map((t) => t.id), ['E100_S100_T100'], 'E100_S100 owns the T100 task');
  assert.deepStrictEqual(byId('E100_S10').tasks.map((t) => t.id), ['E100_S10_T10'], 'E100_S10 does not collect E100_S100 or E100_S1 tasks');
  assert.deepStrictEqual(byId('E100_S1').tasks.map((t) => t.id), ['E100_S1_T1'], 'E100_S1 does not collect E100_S10 or E100_S100 tasks');
  assert.deepStrictEqual(byId('E1001_S100').tasks.map((t) => t.id), ['E1001_S100_T100'], 'E1001_S100 owns its T100, apart from E100_S100_T100');
  assert.deepStrictEqual(byId('E1001').stories.map((s) => s.id), ['E1001_S100']);
  assert.deepStrictEqual(byId('E01').stories.map((s) => s.id), ['E01_S1'], 'E01 keeps its zero-padded id');

  // --- Completeness: nothing dropped or duplicated -----------------------------------------------------------
  const expectedIds = [];
  for (const e of Object.keys(EPICS)) {
    expectedIds.push(e);
    for (const s of Object.keys(STORIES[e] || {})) {
      expectedIds.push(s);
      for (const t of Object.keys(TASKS[s] || {})) expectedIds.push(t);
    }
  }
  const seen = [];
  for (const e of board) {
    seen.push(e.id);
    for (const s of e.stories) {
      seen.push(s.id);
      for (const t of s.tasks) seen.push(t.id);
    }
  }
  assert.strictEqual(new Set(seen).size, seen.length, 'no id appears twice in the parsed tree');
  assert.deepStrictEqual([...seen].sort(), [...expectedIds].sort(), 'every board item is in the parsed tree, none invented');
  assert.strictEqual(seen.length, 20, 'sanity: the fixture holds 5 epics, 7 stories and 8 tasks');

  // --- ids are carried unchanged: no re-padding or truncation --------------------------------------------------
  assert.strictEqual(byId('E1001').id, 'E1001');
  assert.strictEqual(byId('E100_S100_T100').id, 'E100_S100_T100');
  assert.ok(byId('E01'), 'E01 present as E01, not E1');
  assert.strictEqual(byId('E1'), undefined, 'no re-padded E1');

  // --- todo.md queue flags -------------------------------------------------------------------------------------
  const queued = [];
  for (const id of expectedIds) if (byId(id)._queued === true) queued.push(id);
  assert.deepStrictEqual(queued.sort(), [...EXPECTED_QUEUED].sort(), '_queued on exactly the wide ids todo.md names');
  for (const id of expectedIds) {
    if (!EXPECTED_QUEUED.includes(id)) assert.ok(!('_queued' in byId(id)), `${id} must carry no _queued field`);
  }

  // --- Kanban buckets (ES module, dynamic import) --------------------------------------------------------------
  const kanbanUrl = pathToFileURL(path.resolve(__dirname, '../../ui/src/components/board/kanbanColumns.js')).href;
  const { KANBAN_COLUMNS, flattenBoardItems, bucketIntoColumns } = await import(kanbanUrl);

  const flat = flattenBoardItems(board);
  assert.deepStrictEqual(flat.map((i) => i.id), seen, 'flattening keeps every item, in tree order');

  const buckets = bucketIntoColumns(flat);
  assert.deepStrictEqual(Object.keys(buckets), KANBAN_COLUMNS.map((c) => c.key), 'one bucket per column');

  const bucketed = Object.values(buckets).flat().map((i) => i.id);
  assert.strictEqual(new Set(bucketed).size, bucketed.length, 'no item sits in two columns');

  // The only deliberate exclusion: an unqueued Pending item (E10_S2).
  const excluded = seen.filter((id) => !bucketed.includes(id));
  assert.deepStrictEqual(excluded, ['E10_S2'], 'only the unqueued Pending story is excluded from the kanban view');
  assert.strictEqual(bucketed.length + excluded.length, seen.length, 'buckets plus exclusions account for every item');

  const idsIn = (key) => buckets[key].map((i) => i.id);
  assert.deepStrictEqual(
    idsIn('in-progress'),
    ['E10', 'E10_S1', 'E10_S1_T10', 'E100', 'E100_S10', 'E100_S10_T10', 'E1001', 'E1001_S100',
      'E100_S100', 'E100_S100_T100', 'E1001_S100_T100'],
    'In Progress: native items first, then the three queued Pending items, each group in numeric order'
  );
  assert.deepStrictEqual(
    buckets['in-progress'].filter((i) => i._promotedFromStatus).map((i) => i.id),
    EXPECTED_QUEUED,
    'exactly the queued wide ids are marked as promoted'
  );
  assert.deepStrictEqual(idsIn('done'), ['E01', 'E01_S1', 'E01_S1_T1', 'E10_S1_T1', 'E100_S1', 'E100_S1_T1']);
  assert.deepStrictEqual(idsIn('merged'), ['E99', 'E99_S1']);

  // --- GET /v1/board/:epicId resolves an epic by exact id, never by prefix ---------------------------------------
  const http = require('http');
  const express = require('express');
  const app = express();
  app.use('/v1/board', require('../routes/board'));
  const server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const get = (urlPath) =>
    new Promise((resolve, reject) => {
      http
        .get({ host: '127.0.0.1', port: server.address().port, path: urlPath }, (res) => {
          let body = '';
          res.setEncoding('utf8');
          res.on('data', (c) => (body += c));
          res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(body) }));
        })
        .on('error', reject);
    });
  try {
    for (const id of EXPECTED_EPIC_ORDER) {
      const res = await get(`/v1/board/${id}`);
      assert.strictEqual(res.status, 200, `GET /v1/board/${id}`);
      assert.strictEqual(res.body.data.id, id, `GET /v1/board/${id} returns epic ${id}, not a text-prefix sibling`);
      assert.deepStrictEqual(res.body.data.stories.map((s) => s.id), Object.keys(STORIES[id]));
    }
    assert.strictEqual((await get('/v1/board/e100')).body.data.id, 'E100', 'lookup stays case-insensitive');
    assert.strictEqual((await get('/v1/board/E1')).status, 404, 'E1 is not a prefix match for E10, E100 or E1001');
    assert.strictEqual((await get('/v1/board/E100_S1')).status, 404, 'a story id is not an epic id');
  } finally {
    server.close();
  }

  console.log('board.mixed-width.test.js: all assertions passed');
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
