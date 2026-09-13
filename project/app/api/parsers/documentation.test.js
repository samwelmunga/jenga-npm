/**
 * @file project/app/api/parsers/documentation.test.js
 * Plain Node `assert`-based test script for `readDocumentation()` (documentation.js), following
 * the exact no-framework convention already established by `markdown-dir-reader.test.js` and
 * `todo.test.js` — this package has no JS test-runner dependency; the root `package.json`'s `test`
 * script runs `bats tests/*.bats`, shell scripts only.
 *
 * Uses a scratch fixture project tree under `fs.mkdtempSync(os.tmpdir())`, resolved via the
 * `JENGA_PROJECT_ROOT` env override (see `resolve-project-root.js`), so this test never depends on
 * this repo's own real `PROJECT_SUMMARY.md`/`README.md`/`STRATEGY.md`/examples content.
 *
 * Run directly:
 *   node project/app/api/parsers/documentation.test.js
 * or, from project/app/api/:
 *   npm test
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

// ---------------------------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------------------------

const tmpRoots = [];

function makeTmpProjectRoot() {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'jenga-documentation-test-')));
  tmpRoots.push(dir);
  // resolveProjectRoot()'s walk-up marker is project/board — create it so the override path is
  // also independently valid if the env var were ever ignored.
  fs.mkdirSync(path.join(dir, 'project', 'board'), { recursive: true });
  return dir;
}

function writeFile(rootDir, relPath, content) {
  const full = path.join(rootDir, relPath);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, content);
}

function cleanup() {
  for (const dir of tmpRoots) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------------------------
// Minimal test harness (no framework) — matches markdown-dir-reader.test.js's own pattern.
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
      console.log(`  ok — ${name}`);
    } catch (err) {
      failures += 1;
      console.error(`  FAIL — ${name}`);
      console.error(`    ${err.message}`);
    }
  }
  cleanup();
  console.log(`\n${tests.length - failures}/${tests.length} passed`);
  if (failures > 0) process.exit(1);
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

test('aggregates all four sources with correct categories, skipping a missing source', async () => {
  const root = makeTmpProjectRoot();
  writeFile(root, 'project/PROJECT_SUMMARY.md', '# Project Summary\n\nHello summary.');
  writeFile(root, 'README.md', '# My Project\n\nHello readme.');
  // docs/STRATEGY.md intentionally omitted — must be skipped, not thrown.
  writeFile(
    root,
    'project/documentation/examples/foo.md',
    '---\ndate: 2026-01-02\n---\n\nExample content.'
  );
  writeFile(root, 'project/documentation/examples/nested/bar.md', 'Nested example content.');

  const originalEnv = process.env.JENGA_PROJECT_ROOT;
  process.env.JENGA_PROJECT_ROOT = root;
  try {
    delete require.cache[require.resolve('./documentation')];
    delete require.cache[require.resolve('../lib/resolve-project-root')];
    const { readDocumentation } = require('./documentation');
    const entries = await readDocumentation();

    // 2 single-file sources (STRATEGY.md missing) + 2 example files = 4 entries.
    assert.strictEqual(entries.length, 4, `expected 4 entries, got ${entries.length}`);

    const byFile = Object.fromEntries(entries.map((e) => [e.file, e]));

    assert.ok(byFile['PROJECT_SUMMARY.md'], 'PROJECT_SUMMARY.md entry missing');
    assert.strictEqual(byFile['PROJECT_SUMMARY.md'].category, 'summary');
    assert.ok(byFile['PROJECT_SUMMARY.md'].content.includes('Hello summary.'));
    assert.strictEqual(byFile['PROJECT_SUMMARY.md'].date, null);

    assert.ok(byFile['README.md'], 'README.md entry missing');
    assert.strictEqual(byFile['README.md'].category, 'readme');
    assert.ok(byFile['README.md'].content.includes('Hello readme.'));

    assert.ok(!byFile['STRATEGY.md'], 'STRATEGY.md should be skipped, not present, when missing');

    const exampleEntries = entries.filter((e) => e.category === 'example');
    assert.strictEqual(exampleEntries.length, 2, 'expected 2 example entries');
    const foo = exampleEntries.find((e) => e.file === 'foo.md');
    assert.ok(foo, 'foo.md example entry missing');
    assert.strictEqual(foo.date, '2026-01-02');
    assert.ok(foo.content.includes('Example content.'));
    const bar = exampleEntries.find((e) => e.file === path.posix.join('nested', 'bar.md'));
    assert.ok(bar, 'nested/bar.md example entry missing');
    assert.strictEqual(bar.date, null);

    // Every entry shares the same field shape.
    for (const entry of entries) {
      assert.ok('file' in entry && 'data' in entry && 'content' in entry, 'missing base fields');
      assert.ok('category' in entry, 'missing category field');
      assert.ok('date' in entry, 'missing date field');
    }
  } finally {
    if (originalEnv === undefined) delete process.env.JENGA_PROJECT_ROOT;
    else process.env.JENGA_PROJECT_ROOT = originalEnv;
    delete require.cache[require.resolve('./documentation')];
    delete require.cache[require.resolve('../lib/resolve-project-root')];
  }
});

test('all three single-file sources missing and no examples directory yields an empty list', async () => {
  const root = makeTmpProjectRoot();
  // No PROJECT_SUMMARY.md, README.md, STRATEGY.md, or documentation/examples/ at all.

  const originalEnv = process.env.JENGA_PROJECT_ROOT;
  process.env.JENGA_PROJECT_ROOT = root;
  try {
    delete require.cache[require.resolve('./documentation')];
    delete require.cache[require.resolve('../lib/resolve-project-root')];
    const { readDocumentation } = require('./documentation');
    const entries = await readDocumentation();
    assert.deepStrictEqual(entries, [], 'expected an empty array when nothing exists');
  } finally {
    if (originalEnv === undefined) delete process.env.JENGA_PROJECT_ROOT;
    else process.env.JENGA_PROJECT_ROOT = originalEnv;
    delete require.cache[require.resolve('./documentation')];
    delete require.cache[require.resolve('../lib/resolve-project-root')];
  }
});

run();
