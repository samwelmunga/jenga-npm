/**
 * @file project/app/api/routes/pipeline.test.js
 * E92_S04_T02 - plain-`assert` tests (no framework), same style as routes/progress.test.js.
 * Runs GET /v1/pipeline (through a real express app on an ephemeral port) against a fixture project in a temp
 * dir with JENGA_PROJECT_ROOT set; the live project/board/, project/todo.md and project/queue/ are never read.
 *   node project/app/api/routes/pipeline.test.js
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const express = require('express');

const { locateAgentScript } = require('../lib/run-board-progress');
const pipelineRouter = require('./pipeline');

const REPO_SCRIPTS = path.resolve(__dirname, '..', '..', '..', '..', 'scripts');
// pipeline-stage.sh and everything it calls from its own directory.
const SCRIPT_FILES = [
  'pipeline-stage.sh', 'todo_manager.sh', 'board-progress.sh', 'resolve-root.sh', path.join('lib', 'board-ids.sh'),
];

const tmpRoots = [];
const NO_SUCH_DIR = path.join(os.tmpdir(), 'jenga-pipeline-no-such-dir-' + process.pid);

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

/** A throwaway project with two in-progress tasks, one queued todo entry, and a tester and a scrum queue line. */
function makeProject() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'jenga-pipeline-')));
  tmpRoots.push(root);
  fs.mkdirSync(path.join(root, 'project', 'configs'), { recursive: true });
  fs.writeFileSync(path.join(root, 'project', 'configs', 'workflow.json'), '{}\n');
  writeItem(root, 'E01', 'In Progress');
  writeItem(root, 'E01_S01', 'In Progress');
  writeItem(root, 'E01_S01_T01', 'In Progress');
  writeItem(root, 'E01_S01_T02', 'In Progress');
  writeItem(root, 'E01_S01_T03', 'Pending');
  fs.writeFileSync(path.join(root, 'project', 'todo.md'), '# Todo\n\nShip the first story: E01_S01\n');
  const queue = path.join(root, 'project', 'queue');
  fs.mkdirSync(queue, { recursive: true });
  fs.writeFileSync(path.join(queue, 'tester_triggers.jsonl'), '{"type":"test_assignment","task_id":"E01_S01_T01"}\n');
  fs.writeFileSync(path.join(queue, 'scrum_triggers.jsonl'),
    '{"type":"story_rollup","story_id":"E01_S01"}\n{"type":"status_review"}\nnot json\n');
  return root;
}

function installScripts(root, relDir) {
  for (const rel of SCRIPT_FILES) {
    const dest = path.join(root, relDir, rel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(path.join(REPO_SCRIPTS, rel), dest);
  }
}

/** A stand-in pipeline-stage.sh at <root>/scripts, which is searched first. */
function installStub(root, body) {
  const dest = path.join(root, 'scripts', 'pipeline-stage.sh');
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, `#!/usr/bin/env bash\n${body}\n`, { mode: 0o755 });
}

/** The script run directly against `root`, the reference the API payload is compared with. */
function directRun(root) {
  const out = execFileSync('bash', [path.join(REPO_SCRIPTS, 'pipeline-stage.sh'), '--root', root], {
    encoding: 'utf8',
    env: { ...process.env, JENGA_PROJECT_ROOT: root },
  });
  return JSON.parse(out);
}

async function getPipeline(root, router = pipelineRouter) {
  const app = express();
  app.use('/v1/pipeline', router);
  const server = await new Promise(resolve => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const prev = process.env.JENGA_PROJECT_ROOT;
  process.env.JENGA_PROJECT_ROOT = root;
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/v1/pipeline`);
    return { status: res.status, body: await res.json() };
  } finally {
    if (prev === undefined) delete process.env.JENGA_PROJECT_ROOT;
    else process.env.JENGA_PROJECT_ROOT = prev;
    await new Promise(resolve => server.close(resolve));
  }
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('envelope: data is the script JSON, error is null', async () => {
  const root = makeProject();
  const { status, body } = await getPipeline(root);
  assert.strictEqual(status, 200);
  assert.strictEqual(body.error, null);
  assert.ok(body.meta && body.meta.timestamp && body.meta.version);
  assert.strictEqual(body.data.schema_version, 1);
  assert.deepStrictEqual(body.data.stages.map(s => s.id), ['todo', 'do', 'test', 'rollup']);
});

test('data.stages equals the stages of a direct run of scripts/pipeline-stage.sh on the same fixture', async () => {
  const root = makeProject();
  const direct = directRun(root);
  const { body } = await getPipeline(root);
  assert.deepStrictEqual(body.data.stages, direct.stages);
  assert.deepStrictEqual(body.data, direct);
  // The fixture lights every stage: 1 todo entry, 2 in-progress tasks, 1 test_assignment, 1 story_rollup (status_review not counted).
  assert.deepStrictEqual(body.data.stages.map(s => s.count), [1, 2, 1, 1]);
  assert.strictEqual(body.data.skipped, 1);
});

test('project-root install layout (node_modules/@jenga-ai/agent/scripts only) resolves the script', async () => {
  const root = makeProject();
  const rel = path.join('node_modules', '@jenga-ai', 'agent', 'scripts');
  installScripts(root, rel);
  assert.strictEqual(
    locateAgentScript('pipeline-stage.sh', { projectRoot: root, fallbackDir: NO_SUCH_DIR }),
    path.join(root, rel, 'pipeline-stage.sh')
  );
  const { status, body } = await getPipeline(root, pipelineRouter.createPipelineRouter({ fallbackDir: NO_SUCH_DIR }));
  assert.strictEqual(status, 200);
  assert.deepStrictEqual(body.data.stages, directRun(root).stages);
});

test('monorepo layout: <root>/scripts wins, then the checkout relative to this file', async () => {
  const root = makeProject();
  installScripts(root, 'scripts');
  assert.strictEqual(
    locateAgentScript('pipeline-stage.sh', { projectRoot: root, fallbackDir: NO_SUCH_DIR }),
    path.join(root, 'scripts', 'pipeline-stage.sh')
  );
  const own = await getPipeline(root, pipelineRouter.createPipelineRouter({ fallbackDir: NO_SUCH_DIR }));
  assert.strictEqual(own.status, 200);
  assert.deepStrictEqual(own.body.data.stages, directRun(root).stages);
  // A bare fixture root (no scripts of its own) still resolves, through the checkout this test file lives in.
  const bare = makeProject();
  assert.strictEqual(locateAgentScript('pipeline-stage.sh', { projectRoot: bare }), path.join(REPO_SCRIPTS, 'pipeline-stage.sh'));
  const { status, body } = await getPipeline(bare);
  assert.strictEqual(status, 200);
  assert.deepStrictEqual(body.data.stages, directRun(bare).stages);
});

test('a missing script gives a 500 error envelope that names the places searched', async () => {
  const root = makeProject();
  const { status, body } = await getPipeline(root, pipelineRouter.createPipelineRouter({ fallbackDir: NO_SUCH_DIR }));
  assert.strictEqual(status, 500);
  assert.strictEqual(body.data, null);
  assert.strictEqual(body.error.code, 'INTERNAL_ERROR');
  assert.match(body.error.message, /pipeline-stage\.sh not found/);
  assert.ok(body.error.message.includes(path.join(root, 'scripts')));
  assert.ok(body.error.message.includes(path.join('node_modules', '@jenga-ai', 'agent', 'scripts')));
});

test('a script failure gives a 500 error envelope carrying the exit code and stderr', async () => {
  const root = makeProject();
  installStub(root, 'echo "stub: board exploded" >&2\nexit 1');
  const { status, body } = await getPipeline(root);
  assert.strictEqual(status, 500);
  assert.strictEqual(body.data, null);
  assert.strictEqual(body.error.code, 'INTERNAL_ERROR');
  assert.match(body.error.message, /pipeline-stage\.sh failed \(1\)/);
  assert.match(body.error.message, /stub: board exploded/);
});

test('output that is not JSON gives a 500 error envelope', async () => {
  const root = makeProject();
  installStub(root, 'echo "not json at all"');
  const { status, body } = await getPipeline(root);
  assert.strictEqual(status, 500);
  assert.match(body.error.message, /not JSON/);
});

test('the route is given --root with the resolved project root', async () => {
  const root = makeProject();
  installStub(root, 'printf \'{"schema_version":1,"stages":[],"args":"%s %s"}\\n\' "$1" "$2"');
  const { body } = await getPipeline(root);
  assert.strictEqual(body.data.args, `--root ${root}`);
});

test('the route contains no stage ids, no status names and no counting arithmetic', () => {
  const statusName = /\b(Pending|In Progress|Passed|Passed with remarks|Failed|Rejected|Blocked|Backlog|Done|Merged|Publicized|Privatized|Deployed to (Stage|Prod))\b/;
  const stageId = /['"](todo|do|test|rollup)['"]/;
  const arithmetic = /\+\+|--(?=[a-z]*\s*[;)=])|\+=|-=|\.reduce\(|\.filter\(|Math\./;
  const src = fs.readFileSync(path.join(__dirname, 'pipeline.js'), 'utf8');
  assert.ok(!statusName.test(src), 'pipeline.js names a status');
  assert.ok(!stageId.test(src), 'pipeline.js names a stage');
  assert.ok(!arithmetic.test(src), 'pipeline.js does arithmetic');
});

test('server.js mounts the router at /v1/pipeline', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');
  assert.match(src, /app\.use\('\/v1\/pipeline',\s+pipelineRouter\)/);
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
