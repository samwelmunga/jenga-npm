/**
 * @file project/app/api/lib/resolve-project-title.test.js
 * E47_S09_T01 — plain-`assert` tests (no framework), same style as resolve-project-root.test.js,
 * using real filesystem (and real `git init`) fixtures.
 *   node project/app/api/lib/resolve-project-title.test.js
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { resolveProjectTitle, titleFromStrategy, stripGeneric, DEFAULT_TITLE } = require('./resolve-project-title');

const tmpRoots = [];
function makeProject(files = {}, { git = null } = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'jenga-title-')));
  tmpRoots.push(dir);
  fs.mkdirSync(path.join(dir, 'project', 'board'), { recursive: true });
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), content);
  }
  if (git) {
    execFileSync('git', ['init', '-q', dir], { stdio: 'ignore' });
    if (git.origin) execFileSync('git', ['-C', dir, 'remote', 'add', 'origin', git.origin], { stdio: 'ignore' });
  }
  return dir;
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

const STRATEGY = 'project/documentation/STRATEGY.md';

test('stripGeneric removes strategy words and separators', () => {
  assert.strictEqual(stripGeneric('Jenga AI Strategy'), 'Jenga AI');
  assert.strictEqual(stripGeneric('Strategy: Acme'), 'Acme');
  assert.strictEqual(stripGeneric('Strategy Brief'), '');
  assert.strictEqual(stripGeneric('Acme - Strategy Document'), 'Acme');
});

test('strategy explicit project field wins over H1', () => {
  assert.strictEqual(titleFromStrategy('# Strategy Brief\n\n**Project:** Acme Rockets\n'), 'Acme Rockets');
});

test('strategy H1 is used and cleaned', () => {
  const root = makeProject({ [STRATEGY]: '# Jenga AI Strategy\n\ntext\n', 'README.md': '# Readme Name\n' });
  assert.strictEqual(resolveProjectTitle({ root }), 'Jenga AI');
});

test('generic-only strategy H1 falls through to README H1', () => {
  const root = makeProject({ [STRATEGY]: '# Strategy Brief\n', 'README.md': '<p>x</p>\n\n# **Jenga** [AI](http://x)\n' });
  assert.strictEqual(resolveProjectTitle({ root }), 'Jenga AI');
});

test('paths.strategy from workflow.json is honoured', () => {
  const root = makeProject({
    'project/configs/workflow.json': JSON.stringify({ paths: { strategy: 'docs-x/strat.md' } }),
    'docs-x/strat.md': '# Custom Path Co Strategy\n',
    [STRATEGY]: '# Wrong Co Strategy\n',
  });
  assert.strictEqual(resolveProjectTitle({ root }), 'Custom Path Co');
});

test('README H1 ignores headings inside code fences', () => {
  const root = makeProject({ 'README.md': '```sh\n# not a title\n```\n# Real Title\n' });
  assert.strictEqual(resolveProjectTitle({ root }), 'Real Title');
});

test('git repo name from origin remote when no strategy/README', () => {
  const root = makeProject({ 'package.json': '{"name":"pkg-name"}' }, { git: { origin: 'https://github.com/o/My-Repo.git' } });
  assert.strictEqual(resolveProjectTitle({ root }), 'My-Repo');
});

test('git repo name from toplevel basename when there is no remote', () => {
  const root = makeProject({ 'package.json': '{"name":"pkg-name"}' }, { git: {} });
  assert.strictEqual(resolveProjectTitle({ root }), path.basename(root));
});

test('package.json name is the last resort (no git)', () => {
  const root = makeProject({ 'package.json': '{"name":"pkg-name"}' });
  assert.strictEqual(resolveProjectTitle({ root }), 'pkg-name');
});

test('nothing resolvable yields the safe default, never "undefined"', () => {
  const root = makeProject({ 'package.json': '{ not json' });
  const title = resolveProjectTitle({ root });
  assert.strictEqual(title, DEFAULT_TITLE);
  assert.ok(!/undefined/.test(title));
});

test('no root and no resolvable project root yields the default', () => {
  const prev = process.env.JENGA_PROJECT_ROOT;
  process.env.JENGA_PROJECT_ROOT = path.join(os.tmpdir(), 'jenga-nope-' + Date.now());
  try {
    assert.strictEqual(resolveProjectTitle(), DEFAULT_TITLE);
  } finally {
    if (prev === undefined) delete process.env.JENGA_PROJECT_ROOT;
    else process.env.JENGA_PROJECT_ROOT = prev;
  }
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
