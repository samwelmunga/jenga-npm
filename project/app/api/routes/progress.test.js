/**
 * @file project/app/api/routes/progress.test.js
 * E92_S03_T01 - plain-`assert` tests (no framework), same style as lib/resolve-project-title.test.js.
 * Runs GET /v1/progress (through a real express app on an ephemeral port) against a fixture board in a temp
 * dir with JENGA_PROJECT_ROOT set; the live project/board/ and project/todo.md are never read.
 *   node project/app/api/routes/progress.test.js
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const express = require('express');

const { locateAgentScript, runBoardProgress, BoardProgressError } = require('../lib/run-board-progress');
const progressRouter = require('./progress');

// The monorepo checkout's scripts/ (project/app/api/routes -> repo root); the source the fixtures copy from.
const REPO_SCRIPTS = path.resolve(__dirname, '..', '..', '..', '..', 'scripts');
// board-progress.sh and the two files it needs next to it.
const SCRIPT_FILES = ['board-progress.sh', 'resolve-root.sh', path.join('lib', 'board-ids.sh')];

const tmpRoots = [];
const NO_SUCH_DIR = path.join(os.tmpdir(), 'jenga-progress-no-such-dir-' + process.pid);

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

/** A throwaway project: E01 with stories S01 (4 tasks) and S02 (1 task), a todo file only when `todo` is given. */
function makeProject({ todo = null } = {}) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'jenga-progress-')));
  tmpRoots.push(root);
  fs.mkdirSync(path.join(root, 'project', 'configs'), { recursive: true });
  fs.writeFileSync(path.join(root, 'project', 'configs', 'workflow.json'), '{}\n');
  writeItem(root, 'E01', 'In Progress');
  writeItem(root, 'E01_S01', 'In Progress');
  writeItem(root, 'E01_S02', 'Pending');
  writeItem(root, 'E01_S01_T01', 'Passed');
  writeItem(root, 'E01_S01_T02', 'In Progress');
  writeItem(root, 'E01_S01_T03', 'Rejected');
  writeItem(root, 'E01_S01_T04', 'Pending');
  writeItem(root, 'E01_S02_T01', 'Passed');
  if (todo !== null) fs.writeFileSync(path.join(root, 'project', 'todo.md'), todo);
  return root;
}

/** Copy the script and its two helpers under <root>/<relDir>. */
function installScripts(root, relDir) {
  for (const rel of SCRIPT_FILES) {
    const dest = path.join(root, relDir, rel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(path.join(REPO_SCRIPTS, rel), dest);
  }
}

/** The script run directly against `root`, the reference the API payload is compared with. */
function directRun(root, scope) {
  const todo = path.join(root, 'project', 'todo.md');
  const out = execFileSync('bash', [path.join(REPO_SCRIPTS, 'board-progress.sh'), scope, '--root', root], {
    encoding: 'utf8',
    env: { ...process.env, JENGA_TODO_FILE: todo },
  });
  return JSON.parse(out);
}

/** GET / on a router mounted at /v1/progress, with JENGA_PROJECT_ROOT set to `root` for the call. */
async function getProgress(root, router = progressRouter) {
  const app = express();
  app.use('/v1/progress', router);
  const server = await new Promise(resolve => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const prev = process.env.JENGA_PROJECT_ROOT;
  process.env.JENGA_PROJECT_ROOT = root;
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/v1/progress`);
    return { status: res.status, body: await res.json() };
  } finally {
    if (prev === undefined) delete process.env.JENGA_PROJECT_ROOT;
    else process.env.JENGA_PROJECT_ROOT = prev;
    await new Promise(resolve => server.close(resolve));
  }
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('envelope: charts carry tasks, stories, epics and backlog; error is null', async () => {
  const root = makeProject();
  const { status, body } = await getProgress(root);
  assert.strictEqual(status, 200);
  assert.strictEqual(body.error, null);
  assert.ok(body.meta && body.meta.timestamp && body.meta.version);
  assert.strictEqual(body.data.schema_version, 1);
  assert.deepStrictEqual(Object.keys(body.data.charts).sort(), ['backlog', 'epics', 'stories', 'tasks']);
});

test('charts.tasks/stories/epics equal the levels printed by board-progress.sh --all (counts and totals untouched)', async () => {
  const root = makeProject();
  const direct = directRun(root, '--all');
  const { body } = await getProgress(root);
  assert.deepStrictEqual(body.data.charts.tasks.totals, direct.levels.tasks.totals);
  assert.deepStrictEqual(body.data.charts.tasks, direct.levels.tasks);
  assert.deepStrictEqual(body.data.charts.stories, direct.levels.stories);
  assert.deepStrictEqual(body.data.charts.epics, direct.levels.epics);
  assert.strictEqual(body.data.schema_version, direct.schema_version);
  // Rejected is reported separately and sits outside the denominator (progress-visualisation.md section 5): 5 tasks - 1 rejected.
  assert.strictEqual(body.data.charts.tasks.totals.denominator, 4);
  assert.strictEqual(body.data.charts.tasks.totals.rejected, 1);
});

test('backlog is { empty: true } when project/todo.md is missing', async () => {
  const root = makeProject();
  const { status, body } = await getProgress(root);
  assert.strictEqual(status, 200);
  assert.deepStrictEqual(body.data.charts.backlog, { empty: true });
});

test('backlog is { empty: true } when project/todo.md has no real entries', async () => {
  const root = makeProject({ todo: '# Todo\n\n<!-- Format: <mission title>: <E##_S##> -->\n\n' });
  const { body } = await getProgress(root);
  assert.deepStrictEqual(body.data.charts.backlog, { empty: true });
});

test('a queued story yields its tasks; the fixture todo is read through JENGA_TODO_FILE, not the live one', async () => {
  const root = makeProject({ todo: '# Todo\n\nShip the first story: E01_S01\n' });
  const direct = directRun(root, '--backlog');
  const { body } = await getProgress(root);
  const backlog = body.data.charts.backlog;
  assert.deepStrictEqual(backlog, direct.levels);
  assert.deepStrictEqual(Object.keys(backlog).sort(), ['stories', 'tasks']);
  assert.strictEqual(backlog.tasks.totals.denominator, 3); // 4 queued tasks, 1 of them Rejected (outside the denominator)
  assert.strictEqual(backlog.stories.totals.denominator, 1);
  // E01_S02 and its task are not queued, so they are absent from the backlog but present in the whole board.
  assert.strictEqual(body.data.charts.tasks.totals.denominator, 4);
});

test('a queued task alone yields only the tasks level', async () => {
  const root = makeProject({ todo: 'Fix one: E01_S02_T01\n' });
  const { body } = await getProgress(root);
  assert.deepStrictEqual(Object.keys(body.data.charts.backlog), ['tasks']);
  assert.strictEqual(body.data.charts.backlog.tasks.totals.denominator, 1);
});

test('project-root install layout (node_modules/@jenga-ai/agent/scripts only) resolves the script', async () => {
  const root = makeProject({ todo: 'Ship: E01_S01\n' });
  const rel = path.join('node_modules', '@jenga-ai', 'agent', 'scripts');
  installScripts(root, rel);
  assert.strictEqual(
    locateAgentScript('board-progress.sh', { projectRoot: root, fallbackDir: NO_SUCH_DIR }),
    path.join(root, rel, 'board-progress.sh')
  );
  const router = progressRouter.createProgressRouter({ fallbackDir: NO_SUCH_DIR });
  const { status, body } = await getProgress(root, router);
  assert.strictEqual(status, 200);
  assert.deepStrictEqual(body.data.charts.tasks.totals, directRun(root, '--all').levels.tasks.totals);
});

test('monorepo layout: <root>/scripts wins, then the checkout relative to this file', async () => {
  const root = makeProject();
  installScripts(root, 'scripts');
  assert.strictEqual(
    locateAgentScript('board-progress.sh', { projectRoot: root, fallbackDir: NO_SUCH_DIR }),
    path.join(root, 'scripts', 'board-progress.sh')
  );
  // A bare fixture root (no scripts of its own) still resolves, through the checkout this test file lives in.
  const bare = makeProject();
  assert.strictEqual(locateAgentScript('board-progress.sh', { projectRoot: bare }), path.join(REPO_SCRIPTS, 'board-progress.sh'));
  const { status } = await getProgress(bare);
  assert.strictEqual(status, 200);
});

test('locateAgentScript returns null for an unknown script and rejects a path as the name', () => {
  const root = makeProject();
  assert.strictEqual(locateAgentScript('no-such-script.sh', { projectRoot: root }), null);
  assert.throws(() => locateAgentScript('../board-progress.sh', { projectRoot: root }), /plain file name/);
});

test('a missing script gives a 500 error envelope that names the places searched', async () => {
  const root = makeProject();
  const router = progressRouter.createProgressRouter({ fallbackDir: NO_SUCH_DIR });
  const { status, body } = await getProgress(root, router);
  assert.strictEqual(status, 500);
  assert.strictEqual(body.data, null);
  assert.strictEqual(body.error.code, 'INTERNAL_ERROR');
  assert.match(body.error.message, /board-progress\.sh not found/);
  assert.ok(body.error.message.includes(path.join(root, 'scripts')));
  assert.ok(body.error.message.includes(path.join('node_modules', '@jenga-ai', 'agent', 'scripts')));
});

test('exit 2 from the script becomes a BoardProgressError carrying its stderr, and the route answers 500', async () => {
  const root = makeProject();
  await assert.rejects(
    () => runBoardProgress(['--no-such-scope'], { projectRoot: root }),
    err => err instanceof BoardProgressError && err.exitCode === 2 && /board-progress\.sh/.test(err.stderr) && err.message.includes(err.stderr)
  );
  // An unresolvable board is exit 2 too: a project root whose board directories do not exist.
  const empty = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'jenga-progress-bare-')));
  tmpRoots.push(empty);
  const { status, body } = await getProgress(empty);
  assert.strictEqual(status, 500);
  assert.strictEqual(body.error.code, 'INTERNAL_ERROR');
  assert.ok(body.error.message.length > 0);
});

test('exit 3 (empty scope) is returned as { empty: true }, not thrown', async () => {
  const root = makeProject();
  const result = await runBoardProgress(['--backlog'], { projectRoot: root });
  assert.deepStrictEqual(result, { empty: true });
});

test('the helper and the route contain no status names and no counting arithmetic', () => {
  const statusName = /\b(Pending|In Progress|Passed|Passed with remarks|Failed|Rejected|Blocked|Backlog|Done|Merged|Publicized|Privatized|Deployed to (Stage|Prod))\b/;
  const arithmetic = /\+\+|--(?=[a-z]*\s*[;)=])|\+=|-=|\.length\b|\.reduce\(|\.filter\(|Math\./;
  for (const rel of [path.join('..', 'lib', 'run-board-progress.js'), 'progress.js']) {
    const src = fs.readFileSync(path.join(__dirname, rel), 'utf8');
    assert.ok(!statusName.test(src), `${rel} names a status`);
    assert.ok(!arithmetic.test(src), `${rel} does arithmetic`);
  }
});

test('server.js mounts the router at /v1/progress', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');
  assert.match(src, /app\.use\('\/v1\/progress',\s+progressRouter\)/);
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
  for (const d of tmpRoots) fs.rmSync(d, { recursive: true, force: true });
  console.log(`\n${tests.length - failures}/${tests.length} passed`);
  if (failures > 0) process.exitCode = 1;
})();
