/**
 * @file project/app/api/lib/resolve-project-root.test.js
 * Plain Node `assert`-based test script for `resolveProjectRoot()`, following the same no-framework
 * convention already established by `project/app/api/parsers/knowledge-graph.test.js` (this package
 * has no JS test-runner dependency; the root `package.json`'s `test` script runs `bats tests/*.bats`,
 * shell scripts only).
 *
 * Unlike `knowledge-graph.test.js`, this suite uses real filesystem fixtures under
 * `fs.mkdtempSync(os.tmpdir())` (real directories and a real symlink) rather than mocking `fs` — the
 * resolver's correctness is precisely about how it behaves against real `realpathSync`/`statSync`
 * calls, so a mock would test the mock rather than the resolver.
 *
 * Run directly:
 *   node project/app/api/lib/resolve-project-root.test.js
 * or, from project/app/api/:
 *   npm test
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { resolveProjectRoot, OVERRIDE_ENV_VAR, PROJECT_MARKER } = require('./resolve-project-root');

// ---------------------------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------------------------

const tmpRoots = [];

/** Create a fresh scratch directory under the real OS tmp dir, tracked for cleanup. */
function makeTmpDir(prefix) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  tmpRoots.push(dir);
  return dir;
}

/** Create `<dir>/project/board` so `dir` satisfies the project-root marker check. */
function markAsProjectRoot(dir) {
  fs.mkdirSync(path.join(dir, PROJECT_MARKER), { recursive: true });
}

function cleanup() {
  for (const dir of tmpRoots) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------------------------
// Minimal test harness (no framework) — matches knowledge-graph.test.js's own pattern.
// ---------------------------------------------------------------------------------------------

const tests = [];
function test(name, fn) {
  tests.push({ name, fn });
}

async function run() {
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
  cleanup();

  console.log(`\n${tests.length - failures}/${tests.length} passed`);
  if (failures > 0) {
    process.exitCode = 1;
  }
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

test('override env var resolves to that directory', () => {
  const projectRoot = makeTmpDir('jenga-override-');
  markAsProjectRoot(projectRoot);

  const result = resolveProjectRoot({ env: { [OVERRIDE_ENV_VAR]: projectRoot } });
  assert.strictEqual(result, projectRoot);
});

test('override env var takes precedence even when cwd also has a marker', () => {
  const overrideRoot = makeTmpDir('jenga-override-precedence-');
  markAsProjectRoot(overrideRoot);
  const cwdRoot = makeTmpDir('jenga-cwd-should-be-ignored-');
  markAsProjectRoot(cwdRoot);

  const result = resolveProjectRoot({
    cwd: cwdRoot,
    env: { [OVERRIDE_ENV_VAR]: overrideRoot },
  });
  assert.strictEqual(result, overrideRoot);
});

test('override env var pointing at a non-existent directory throws', () => {
  const bogus = path.join(os.tmpdir(), 'jenga-does-not-exist-' + Date.now());
  assert.throws(
    () => resolveProjectRoot({ env: { [OVERRIDE_ENV_VAR]: bogus } }),
    /does not exist/
  );
});

test('override env var pointing at a file (not a directory) throws', () => {
  const dir = makeTmpDir('jenga-override-file-');
  const filePath = path.join(dir, 'not-a-directory.txt');
  fs.writeFileSync(filePath, 'hello');

  assert.throws(
    () => resolveProjectRoot({ env: { [OVERRIDE_ENV_VAR]: filePath } }),
    /is not a directory/
  );
});

test('walk-up finds a project/board marker several levels above cwd', () => {
  const projectRoot = makeTmpDir('jenga-walkup-');
  markAsProjectRoot(projectRoot);
  const deepCwd = path.join(projectRoot, 'a', 'b', 'c', 'd');
  fs.mkdirSync(deepCwd, { recursive: true });

  const result = resolveProjectRoot({ cwd: deepCwd, env: {} });
  assert.strictEqual(result, projectRoot);
});

test('walk-up finds a project/board marker at cwd itself', () => {
  const projectRoot = makeTmpDir('jenga-walkup-self-');
  markAsProjectRoot(projectRoot);

  const result = resolveProjectRoot({ cwd: projectRoot, env: {} });
  assert.strictEqual(result, projectRoot);
});

test('symlinked cwd resolves via realpath to the real project root', () => {
  const projectRoot = makeTmpDir('jenga-symlink-target-');
  markAsProjectRoot(projectRoot);
  const nestedReal = path.join(projectRoot, 'nested', 'dir');
  fs.mkdirSync(nestedReal, { recursive: true });

  const linkParent = makeTmpDir('jenga-symlink-link-');
  const symlinkPath = path.join(linkParent, 'link-to-nested');
  fs.symlinkSync(nestedReal, symlinkPath, 'dir');

  const result = resolveProjectRoot({ cwd: symlinkPath, env: {} });
  assert.strictEqual(result, projectRoot);
});

test('no marker found within the bounded walk and no override set throws a descriptive error', () => {
  // A scratch tree with no project/board anywhere in its ancestry within the walk bound. os.tmpdir()
  // itself must not accidentally contain a project/board directory for this to hold — true in every
  // normal CI/dev environment.
  const isolated = makeTmpDir('jenga-no-marker-');
  const deepIsolated = path.join(isolated, 'x', 'y', 'z');
  fs.mkdirSync(deepIsolated, { recursive: true });

  assert.throws(
    () => resolveProjectRoot({ cwd: deepIsolated, env: {} }),
    /Could not locate a project root/
  );
});

test('non-existent cwd with no override throws a descriptive error (not a raw ENOENT)', () => {
  const bogusCwd = path.join(os.tmpdir(), 'jenga-bogus-cwd-' + Date.now());
  assert.throws(
    () => resolveProjectRoot({ cwd: bogusCwd, env: {} }),
    /does not exist/
  );
});

run();
