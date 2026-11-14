/**
 * @file project/app/api/routes/progress-cards.test.js
 * E92_S06_T04 - plain-`assert` tests, same fixture technique as progress.test.js.
 *   node project/app/api/routes/progress-cards.test.js
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const express = require('express');

const progressCardsRouter = require('./progress-cards');

const REPO_SCRIPTS = path.resolve(__dirname, '..', '..', '..', '..', 'scripts');
const NO_SUCH_DIR = path.join(os.tmpdir(), 'jenga-progress-cards-no-such-dir-' + process.pid);
const tmpRoots = [];

function writeItem(root, id, status) {
  const epic = id.split('_')[0];
  const isTask = /_S\d+_T\d+$/.test(id);
  const isStory = !isTask && /_S\d+$/.test(id);
  const dir = path.join(root, 'project', 'board', isTask ? 'tasks' : isStory ? 'stories' : 'epics');
  fs.mkdirSync(dir, { recursive: true });
  const lines = ['---', `id: ${id}`];
  if (isTask) lines.push(`story_id: ${id.replace(/_T\d+$/, '')}`);
  if (id !== epic) lines.push(`epic_id: ${epic}`);
  lines.push(`title: "Fixture ${id}"`, `status: ${status}`, '---', '', `# Fixture ${id}`, '');
  fs.writeFileSync(path.join(dir, `${id}_fixture.md`), lines.join('\n'));
}

function makeProject({ empty = false } = {}) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'jenga-progress-cards-')));
  tmpRoots.push(root);
  fs.mkdirSync(path.join(root, 'project', 'configs'), { recursive: true });
  fs.writeFileSync(path.join(root, 'project', 'configs', 'workflow.json'), '{}\n');
  if (empty) {
    for (const d of ['epics', 'stories', 'tasks']) fs.mkdirSync(path.join(root, 'project', 'board', d), { recursive: true });
    return root;
  }
  writeItem(root, 'E01', 'In Progress');
  writeItem(root, 'E01_S01', 'In Progress');
  writeItem(root, 'E01_S02', 'Pending');
  writeItem(root, 'E01_S01_T01', 'Passed');
  writeItem(root, 'E01_S01_T02', 'In Progress');
  writeItem(root, 'E01_S02_T01', 'Passed');
  return root;
}

function directGraph(root) {
  const out = execFileSync('bash', [path.join(REPO_SCRIPTS, 'board-progress.sh'), '--graph', '--counts-only', '--root', root], {
    encoding: 'utf8',
  });
  return JSON.parse(out);
}

/** GET / on a router mounted at /v1/progress-cards with JENGA_PROJECT_ROOT (and optionally the language) set. */
async function getCards(root, { router = progressCardsRouter, lang } = {}) {
  const app = express();
  app.use('/v1/progress-cards', router);
  const server = await new Promise(resolve => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const prevRoot = process.env.JENGA_PROJECT_ROOT;
  const prevLang = process.env.JENGA_PROGRESS_LANG;
  process.env.JENGA_PROJECT_ROOT = root;
  if (lang === undefined) delete process.env.JENGA_PROGRESS_LANG; else process.env.JENGA_PROGRESS_LANG = lang;
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/v1/progress-cards`);
    return { status: res.status, body: await res.json() };
  } finally {
    if (prevRoot === undefined) delete process.env.JENGA_PROJECT_ROOT; else process.env.JENGA_PROJECT_ROOT = prevRoot;
    if (prevLang === undefined) delete process.env.JENGA_PROGRESS_LANG; else process.env.JENGA_PROGRESS_LANG = prevLang;
    await new Promise(resolve => server.close(resolve));
  }
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('returns epics and stories from --graph --counts-only untouched, plus labels and lang, with no tasks key', async () => {
  const root = makeProject();
  const direct = directGraph(root);
  const { status, body } = await getCards(root);
  assert.strictEqual(status, 200);
  assert.strictEqual(body.error, null);
  assert.strictEqual(body.data.schema_version, direct.schema_version);
  assert.deepStrictEqual(body.data.epics, direct.epics);
  assert.deepStrictEqual(body.data.stories, direct.stories);
  assert.ok(!('tasks' in body.data));
  assert.strictEqual(body.data.lang, 'en');
  assert.ok(body.data.labels && Object.keys(body.data.labels).length > 0);
  assert.strictEqual(body.data.labels.ready_to_take, 'Ready to take');
});

test('an empty board gives 200 { empty: true, labels, lang }', async () => {
  const root = makeProject({ empty: true });
  const { status, body } = await getCards(root);
  assert.strictEqual(status, 200);
  assert.strictEqual(body.data.empty, true);
  assert.ok(Object.keys(body.data.labels).length > 0);
  assert.strictEqual(body.data.lang, 'en');
  assert.ok(!('epics' in body.data));
});

test('a missing script gives the /v1/progress 500 error envelope', async () => {
  const root = makeProject();
  const router = progressCardsRouter.createProgressCardsRouter({ fallbackDir: NO_SUCH_DIR });
  const { status, body } = await getCards(root, { router });
  assert.strictEqual(status, 500);
  assert.strictEqual(body.data, null);
  assert.strictEqual(body.error.code, 'INTERNAL_ERROR');
  assert.match(body.error.message, /board-progress\.sh not found/);
});

test('a failing labels script still returns the counts with labels: {}', async () => {
  const root = makeProject();
  // The project's own scripts/ wins the search: a labels script that exits 1, and board-progress.sh copied from the repo.
  const dir = path.join(root, 'scripts');
  fs.mkdirSync(path.join(dir, 'lib'), { recursive: true });
  for (const rel of ['board-progress.sh', 'resolve-root.sh', path.join('lib', 'board-ids.sh')]) {
    fs.copyFileSync(path.join(REPO_SCRIPTS, rel), path.join(dir, rel));
  }
  fs.writeFileSync(path.join(dir, 'progress-labels-json.sh'), '#!/usr/bin/env bash\necho boom >&2\nexit 1\n');
  const { status, body } = await getCards(root);
  assert.strictEqual(status, 200);
  assert.deepStrictEqual(body.data.labels, {});
  assert.deepStrictEqual(body.data.epics, directGraph(root).epics);
});

test('JENGA_PROGRESS_LANG=sv gives Swedish labels and lang "sv"', async () => {
  const root = makeProject();
  const en = await getCards(root);
  const sv = await getCards(root, { lang: 'sv' });
  assert.strictEqual(sv.status, 200);
  assert.strictEqual(sv.body.data.lang, 'sv');
  assert.notStrictEqual(sv.body.data.labels.ready_to_take, en.body.data.labels.ready_to_take);
  assert.deepStrictEqual(Object.keys(sv.body.data.labels), Object.keys(en.body.data.labels));
});

(async () => {
  let failed = 0;
  for (const { name, fn } of tests) {
    try { await fn(); console.log(`ok   ${name}`); }
    catch (err) { failed++; console.log(`FAIL ${name}\n     ${err.stack || err.message}`); }
  }
  for (const r of tmpRoots) fs.rmSync(r, { recursive: true, force: true });
  console.log(`\n${tests.length - failed}/${tests.length} passed`);
  process.exit(failed ? 1 : 0);
})();
