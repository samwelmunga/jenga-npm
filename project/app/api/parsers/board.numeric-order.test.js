/**
 * @file project/app/api/parsers/board.numeric-order.test.js
 * Plain Node `assert`-based test for `parsers/board.js` (E86_S02_T05), following the no-framework
 * convention of the sibling `*.test.js` files (see `board.external-refs.test.js`).
 *
 * Verifies `parseBoard()` returns epics, each epic's stories and each story's tasks in numeric ID order
 * (E101 before E1001, S10 before S100, T10 before T100) instead of the filesystem's listing order, and
 * that sorting never mixes one epic's stories (or one story's tasks) into another's: E10 does not get
 * E100's stories. The board is a temporary directory holding mixed-width IDs:
 *   epics   E01, E10, E11, E99, E100, E101, E1001
 *   stories E10 and E100 each carry S2, S10, S100 (E11 carries S1, E1001 carries S1)
 *   tasks   every story of E10 and E100 carries T2, T10, T100
 * and is parsed three times with `fs.readdirSync` made to return the files ascending, descending and
 * rotated, so the assertions hold whatever order the filesystem reports.
 *
 * `BOARD_ROOT` in `board.js` is fixed at module-load time via `resolveProjectRoot()`, so each parse runs
 * in its own child `node` process with `JENGA_PROJECT_ROOT` pointing at the fixture. The child patches
 * `fs.readdirSync` before requiring `board.js`.
 *
 * Run directly:
 *   node project/app/api/parsers/board.numeric-order.test.js
 * or, from project/app/api/:
 *   npm test
 * (`gray-matter` is resolved from the repository's root `node_modules`; in a git worktree, which has
 * none, run with `NODE_PATH=<main checkout>/node_modules`.)
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const API_ROOT = path.resolve(__dirname, '..');

const EPICS = ['E01', 'E10', 'E11', 'E99', 'E100', 'E101', 'E1001'];
// Stories per epic, written below in a lexically-misordered way on purpose (S100 sorts before S10 as text).
const STORY_NUMBERS = {
  E10: [2, 10, 100],
  E100: [2, 10, 100],
  E11: [1],
  E1001: [1],
};
const TASK_NUMBERS = [2, 10, 100];

// Expected order, spelled out literally rather than derived from the comparator under test.
const EXPECTED_EPICS = ['E01', 'E10', 'E11', 'E99', 'E100', 'E101', 'E1001'];
const EXPECTED_STORIES = {
  E01: [],
  E10: ['E10_S2', 'E10_S10', 'E10_S100'],
  E11: ['E11_S1'],
  E99: [],
  E100: ['E100_S2', 'E100_S10', 'E100_S100'],
  E101: [],
  E1001: ['E1001_S1'],
};
const EXPECTED_TASKS = (storyId) => [`${storyId}_T2`, `${storyId}_T10`, `${storyId}_T100`];

function fm(id, parentKey, parentId) {
  const lines = ['---', `id: ${id}`];
  if (parentKey) lines.push(`${parentKey}: ${parentId}`);
  lines.push(`title: Title of ${id}`, 'status: Pending', 'date_created: 2026-11-06', '---', '', `Body of ${id}.`, '');
  return lines.join('\n');
}

function writeBoard(root) {
  const put = (rel, text) => {
    const full = path.join(root, 'project', 'board', rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, text);
  };
  for (const e of EPICS) {
    put(`epics/${e}_epic-${e.toLowerCase()}.md`, fm(e));
    for (const n of STORY_NUMBERS[e] || []) {
      const s = `${e}_S${n}`;
      put(`stories/${s}_story-${n}.md`, fm(s, 'epic_id', e));
      if (e === 'E10' || e === 'E100') {
        for (const t of TASK_NUMBERS) {
          const id = `${s}_T${t}`;
          put(`tasks/${id}_task-${t}.md`, fm(id, 'story_id', s));
        }
      }
    }
  }
}

// Child: patch fs.readdirSync to the requested listing order, parse the board, print one JSON document.
const CHILD = `
const fs = require('fs');
const mode = process.env.LISTING_ORDER;
const real = fs.readdirSync;
fs.readdirSync = function (...args) {
  const list = real.apply(fs, args);
  if (!Array.isArray(list)) return list;
  const asc = [...list].sort();
  if (mode === 'desc') return asc.reverse();
  if (mode === 'rotated') {
    const k = Math.floor(asc.length / 3);
    return asc.slice(k).concat(asc.slice(0, k)).reverse();
  }
  return asc;
};
const { parseBoard } = require(${JSON.stringify(path.join(API_ROOT, 'parsers', 'board.js'))});
parseBoard()
  .then((board) => process.stdout.write(JSON.stringify(board)))
  .catch((e) => { console.error(e.stack); process.exit(1); });
`;

function runBoard(root, listingOrder) {
  const res = spawnSync(process.execPath, ['-e', CHILD], {
    cwd: API_ROOT,
    env: { ...process.env, JENGA_PROJECT_ROOT: root, LISTING_ORDER: listingOrder },
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  assert.strictEqual(res.status, 0, `child failed (${listingOrder}): ${res.stderr}`);
  assert.ok(!/Skipping malformed/.test(res.stderr), `parser skipped a file: ${res.stderr}`);
  return JSON.parse(res.stdout);
}

function assertNumericOrder(board, label) {
  assert.deepStrictEqual(board.map((e) => e.id), EXPECTED_EPICS, `${label}: epics out of numeric order`);

  for (const epic of board) {
    const wantStories = EXPECTED_STORIES[epic.id];
    assert.deepStrictEqual(
      epic.stories.map((s) => s.id),
      wantStories,
      `${label}: stories of ${epic.id} wrong (or mixed with another epic's)`
    );
    for (const story of epic.stories) {
      assert.strictEqual(story.epic_id, epic.id, `${label}: ${story.id} listed under ${epic.id} but belongs to ${story.epic_id}`);
      const wantTasks = epic.id === 'E10' || epic.id === 'E100' ? EXPECTED_TASKS(story.id) : [];
      assert.deepStrictEqual(
        story.tasks.map((t) => t.id),
        wantTasks,
        `${label}: tasks of ${story.id} wrong (or mixed with another story's)`
      );
      for (const task of story.tasks) {
        assert.strictEqual(task.story_id, story.id, `${label}: ${task.id} listed under ${story.id} but belongs to ${task.story_id}`);
      }
    }
  }

  // The headline cases, stated directly.
  const e10 = board.find((e) => e.id === 'E10');
  const e100 = board.find((e) => e.id === 'E100');
  assert.ok(e10.stories.every((s) => s.id.startsWith('E10_S')), `${label}: E10 must hold only its own stories`);
  assert.ok(!e10.stories.some((s) => s.id.startsWith('E100_')), `${label}: E10 must not receive E100's stories`);
  assert.ok(e100.stories.every((s) => s.id.startsWith('E100_S')), `${label}: E100 must hold only its own stories`);
}

let tmp;
try {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'board-numeric-order-'));
  writeBoard(tmp);

  // Sanity: the fixture really is lexically misordered, so the assertions below can fail without the sort.
  const lexicalEpics = [...EPICS].sort();
  assert.notDeepStrictEqual(lexicalEpics, EXPECTED_EPICS, 'fixture must differ from lexical order');

  for (const mode of ['asc', 'desc', 'rotated']) {
    assertNumericOrder(runBoard(tmp, mode), `listing=${mode}`);
  }

  // All three listings produce byte-identical output.
  const asc = JSON.stringify(runBoard(tmp, 'asc'));
  assert.strictEqual(JSON.stringify(runBoard(tmp, 'desc')), asc, 'descending listing must not change the result');
  assert.strictEqual(JSON.stringify(runBoard(tmp, 'rotated')), asc, 'rotated listing must not change the result');

  // The sibling external-refs suite (same parser, byte-identical-output comparisons) must still pass.
  const sibling = spawnSync(process.execPath, [path.join(__dirname, 'board.external-refs.test.js')], {
    cwd: API_ROOT,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  assert.strictEqual(sibling.status, 0, `board.external-refs.test.js failed:\n${sibling.stdout}\n${sibling.stderr}`);

  console.log('board numeric order: epics, stories and tasks in numeric ID order under asc/desc/rotated listings: PASS');
  console.log('board numeric order: E10 does not receive E100 stories, no cross-epic/story mixing: PASS');
  console.log('\nAll E86_S02_T05 board numeric-order checks passed.');
} finally {
  if (tmp) fs.rmSync(tmp, { recursive: true, force: true });
}
