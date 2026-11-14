/**
 * @file project/app/api/routes/progress-graph.test.js
 * E92_S06_T05 - plain-`assert` tests, same fixture technique as progress.test.js.
 *   node project/app/api/routes/progress-graph.test.js
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const express = require('express');

const progressGraphRouter = require('./progress-graph');

const REPO_SCRIPTS = path.resolve(__dirname, '..', '..', '..', '..', 'scripts');
const NO_SUCH_DIR = path.join(os.tmpdir(), 'jenga-progress-graph-no-such-dir-' + process.pid);
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
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'jenga-progress-graph-')));
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

function directGraph(root, extra = ['--graph']) {
  const out = execFileSync('bash', [path.join(REPO_SCRIPTS, 'board-progress.sh'), ...extra, '--root', root], {
    encoding: 'utf8',
  });
  return JSON.parse(out);
}

/** GET /v1/progress-graph on a router mounted at /v1/progress-graph with JENGA_PROJECT_ROOT (and optionally the language) set. */
async function getGraph(root, { router = progressGraphRouter, lang, query = '' } = {}) {
  const app = express();
  app.use('/v1/progress-graph', router);
  const server = await new Promise(resolve => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const prevRoot = process.env.JENGA_PROJECT_ROOT;
  const prevLang = process.env.JENGA_PROGRESS_LANG;
  process.env.JENGA_PROJECT_ROOT = root;
  if (lang === undefined) delete process.env.JENGA_PROGRESS_LANG; else process.env.JENGA_PROGRESS_LANG = lang;
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/v1/progress-graph${query}`);
    return { status: res.status, body: await res.json() };
  } finally {
    if (prevRoot === undefined) delete process.env.JENGA_PROJECT_ROOT; else process.env.JENGA_PROJECT_ROOT = prevRoot;
    if (prevLang === undefined) delete process.env.JENGA_PROGRESS_LANG; else process.env.JENGA_PROGRESS_LANG = prevLang;
    await new Promise(resolve => server.close(resolve));
  }
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('returns the full --graph JSON (with tasks and state) untouched, plus labels and lang', async () => {
  const root = makeProject();
  const direct = directGraph(root);
  const { status, body } = await getGraph(root);
  assert.strictEqual(status, 200);
  assert.strictEqual(body.error, null);
  assert.deepStrictEqual(body.data.tasks, direct.tasks);
  assert.ok(body.data.tasks.length > 0 && body.data.tasks.every(t => typeof t.state === 'string'));
  assert.deepStrictEqual(body.data.epics, direct.epics);
  assert.deepStrictEqual(body.data.stories, direct.stories);
  assert.strictEqual(body.data.lang, 'en');
  assert.strictEqual(body.data.labels.ready_to_take, 'Ready to take');
});

test('?within=E01 and ?within=E01_S02 return the restricted output', async () => {
  const root = makeProject();
  for (const id of ['E01', 'E01_S02']) {
    const direct = directGraph(root, ['--graph', '--within', id]);
    const { status, body } = await getGraph(root, { query: `?within=${id}` });
    assert.strictEqual(status, 200);
    assert.deepStrictEqual(body.data.tasks, direct.tasks);
    assert.deepStrictEqual(body.data.stories, direct.stories);
    assert.deepStrictEqual(body.data.external, direct.external);
  }
  const story = await getGraph(root, { query: '?within=E01_S02' });
  assert.deepStrictEqual(story.body.data.tasks.map(t => t.id), ['E01_S02_T01']);
});

test('malformed within values are a 400 error envelope and nothing is run', async () => {
  const root = makeProject();
  const nowhere = path.join(os.tmpdir(), 'jenga-progress-graph-no-such-dir-' + process.pid);
  // A router whose script cannot be found: a 400 (not the 500 "not found") proves the script was never reached.
  const router = progressGraphRouter.createProgressGraphRouter({ fallbackDir: nowhere, projectRoot: root });
  for (const q of ['?within=X1', '?within=E01_S02_T01', '?within=', '?within=E01;touch%20x', '?within=%24(id)', '?within=E01&within=E02']) {
    const { status, body } = await getGraph(root, { router, query: q });
    assert.strictEqual(status, 400, q);
    assert.strictEqual(body.data, null);
    assert.strictEqual(body.error.code, 'INVALID_QUERY_PARAM');
  }
});

test('an unknown but well-formed id maps the script exit 2 to a 400 envelope', async () => {
  const root = makeProject();
  const { status, body } = await getGraph(root, { query: '?within=E99' });
  assert.strictEqual(status, 400);
  assert.strictEqual(body.data, null);
  assert.strictEqual(body.error.code, 'INVALID_QUERY_PARAM');
  assert.match(body.error.message, /unknown epic id/);
});

test('an empty board gives 200 { empty: true, labels, lang }', async () => {
  const root = makeProject({ empty: true });
  const { status, body } = await getGraph(root);
  assert.strictEqual(status, 200);
  assert.strictEqual(body.data.empty, true);
  assert.ok(Object.keys(body.data.labels).length > 0);
  assert.strictEqual(body.data.lang, 'en');
  assert.ok(!('tasks' in body.data));
});

test('a missing script gives the 500 error envelope', async () => {
  const root = makeProject();
  const router = progressGraphRouter.createProgressGraphRouter({ fallbackDir: NO_SUCH_DIR });
  const { status, body } = await getGraph(root, { router });
  assert.strictEqual(status, 500);
  assert.strictEqual(body.error.code, 'INTERNAL_ERROR');
  assert.match(body.error.message, /board-progress\.sh not found/);
});

test('JENGA_PROGRESS_LANG=sv gives Swedish labels and lang "sv"', async () => {
  const root = makeProject();
  const en = await getGraph(root);
  const sv = await getGraph(root, { lang: 'sv' });
  assert.strictEqual(sv.body.data.lang, 'sv');
  assert.notStrictEqual(sv.body.data.labels.ready_to_take, en.body.data.labels.ready_to_take);
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
