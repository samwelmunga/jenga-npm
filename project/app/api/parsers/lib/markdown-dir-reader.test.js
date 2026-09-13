/**
 * @file project/app/api/parsers/lib/markdown-dir-reader.test.js
 * Plain Node `assert`-based test script for `readMarkdownDirRecursive()`, following the same
 * no-framework convention already established by `knowledge-graph.test.js` and
 * `resolve-project-root.test.js` (this package has no JS test-runner dependency; the root
 * `package.json`'s `test` script runs `bats tests/*.bats`, shell scripts only).
 *
 * Uses real filesystem fixtures under `fs.mkdtempSync(os.tmpdir())` rather than mocking `fs` —
 * matches `resolve-project-root.test.js`'s approach, since the recursive walk's correctness is
 * precisely about how it behaves against a real directory tree.
 *
 * Run directly:
 *   node project/app/api/parsers/lib/markdown-dir-reader.test.js
 * or, from project/app/api/:
 *   npm test
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { readMarkdownDirRecursive } = require('./markdown-dir-reader');

// ---------------------------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------------------------

const tmpRoots = [];

function makeTmpDir(prefix) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  tmpRoots.push(dir);
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

test('non-existent root directory returns an empty array rather than throwing', () => {
  const bogus = path.join(os.tmpdir(), 'markdown-dir-reader-does-not-exist-' + Date.now());
  const result = readMarkdownDirRecursive(bogus, {});
  assert.deepStrictEqual(result, []);
});

test('recursively walks nested subdirectories and parses frontmatter + content', () => {
  const root = makeTmpDir('markdown-dir-reader-walk-');
  writeFile(root, 'problems/foo.md', '---\ndate: 2026-09-13\n---\nFoo body content.\n');
  writeFile(root, 'analysis/nested/bar.md', '---\ntitle: Bar\n---\nBar body.\n');
  writeFile(root, 'notes.txt', 'not a markdown file, must be ignored');

  const result = readMarkdownDirRecursive(root, {});
  const files = result.map((e) => e.file).sort();
  assert.deepStrictEqual(files, ['analysis/nested/bar.md', 'problems/foo.md']);

  const foo = result.find((e) => e.file === 'problems/foo.md');
  assert.strictEqual(foo.data.date instanceof Date || foo.data.date === '2026-09-13', true);
  assert.strictEqual(foo.content, 'Foo body content.');

  const bar = result.find((e) => e.file === 'analysis/nested/bar.md');
  assert.strictEqual(bar.data.title, 'Bar');
  assert.strictEqual(bar.content, 'Bar body.');
});

test('file with no frontmatter yields an empty data object and full content', () => {
  const root = makeTmpDir('markdown-dir-reader-no-frontmatter-');
  writeFile(root, 'plain.md', 'Just a plain markdown body, no frontmatter.\n');

  const result = readMarkdownDirRecursive(root, {});
  assert.strictEqual(result.length, 1);
  assert.deepStrictEqual(result[0].data, {});
  assert.strictEqual(result[0].content, 'Just a plain markdown body, no frontmatter.');
});

test('category derivation via a lookup object, keyed by top-level subdirectory', () => {
  const root = makeTmpDir('markdown-dir-reader-category-object-');
  writeFile(root, 'problems/foo.md', 'Foo.\n');
  writeFile(root, 'analysis/bar.md', 'Bar.\n');
  writeFile(root, 'root-level.md', 'Root level, no subdirectory.\n');

  const categorize = { problems: 'problem', analysis: 'analysis-report', _default: 'misc' };
  const result = readMarkdownDirRecursive(root, categorize);

  const byFile = Object.fromEntries(result.map((e) => [e.file, e.category]));
  assert.strictEqual(byFile['problems/foo.md'], 'problem');
  assert.strictEqual(byFile['analysis/bar.md'], 'analysis-report');
  assert.strictEqual(byFile['root-level.md'], 'misc');
});

test('category derivation via a lookup object with no matching key or _default falls back to uncategorized', () => {
  const root = makeTmpDir('markdown-dir-reader-category-object-nodefault-');
  writeFile(root, 'unknown-dir/foo.md', 'Foo.\n');

  const result = readMarkdownDirRecursive(root, { problems: 'problem' });
  assert.strictEqual(result[0].category, 'uncategorized');
});

test('category derivation via a function receives both the top-level segment and the relative path', () => {
  const root = makeTmpDir('markdown-dir-reader-category-fn-');
  writeFile(root, 'examples/deep/nested.md', 'Nested.\n');
  writeFile(root, 'top.md', 'Top level.\n');

  const seen = [];
  const categorize = (topLevelSegment, relativeFilePath) => {
    seen.push({ topLevelSegment, relativeFilePath });
    return topLevelSegment === null ? 'root' : `cat-${topLevelSegment}`;
  };

  const result = readMarkdownDirRecursive(root, categorize);
  const byFile = Object.fromEntries(result.map((e) => [e.file, e.category]));
  assert.strictEqual(byFile['examples/deep/nested.md'], 'cat-examples');
  assert.strictEqual(byFile['top.md'], 'root');

  const topEntry = seen.find((s) => s.relativeFilePath === 'top.md');
  assert.strictEqual(topEntry.topLevelSegment, null);
  const nestedEntry = seen.find((s) => s.relativeFilePath === 'examples/deep/nested.md');
  assert.strictEqual(nestedEntry.topLevelSegment, 'examples');
});

test('categorize omitted entirely defaults every entry to uncategorized', () => {
  const root = makeTmpDir('markdown-dir-reader-no-categorize-');
  writeFile(root, 'foo.md', 'Foo.\n');

  const result = readMarkdownDirRecursive(root);
  assert.strictEqual(result[0].category, 'uncategorized');
});

test('malformed file (invalid frontmatter YAML) is skipped with a console.warn, not aborting the whole walk', () => {
  const root = makeTmpDir('markdown-dir-reader-malformed-');
  writeFile(root, 'good.md', 'Good file.\n');
  // Invalid YAML between the frontmatter delimiters — gray-matter's underlying js-yaml parse
  // throws on this, which readMarkdownDirRecursive must catch and skip rather than propagate.
  writeFile(root, 'bad.md', '---\ninvalid: [unclosed\n---\nBad body.\n');

  const originalWarn = console.warn;
  const warnCalls = [];
  console.warn = (...args) => warnCalls.push(args.join(' '));

  let result;
  try {
    result = readMarkdownDirRecursive(root, {});
  } finally {
    console.warn = originalWarn;
  }

  assert.strictEqual(result.length, 1);
  assert.strictEqual(result[0].file, 'good.md');
  assert.strictEqual(warnCalls.length >= 1, true);
  assert.strictEqual(warnCalls[0].includes('[markdown-dir-reader]'), true);
});

test('file path is returned relative to rootDir, not absolute', () => {
  const root = makeTmpDir('markdown-dir-reader-relative-path-');
  writeFile(root, 'sub/deep/file.md', 'Deep.\n');

  const result = readMarkdownDirRecursive(root, {});
  assert.strictEqual(result[0].file, 'sub/deep/file.md');
  assert.strictEqual(path.isAbsolute(result[0].file), false);
});

run();
