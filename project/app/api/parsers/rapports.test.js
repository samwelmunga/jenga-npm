/**
 * @file project/app/api/parsers/rapports.test.js
 * Plain Node `assert`-based test script for `parsers/rapports.js` (E58_S01_T03), following the
 * same no-framework convention already established by `lib/markdown-dir-reader.test.js` and
 * `lib/resolve-project-root.test.js` (this package has no JS test-runner dependency; the root
 * `package.json`'s `test` script runs `bats tests/*.bats`, shell scripts only).
 *
 * Covers two things:
 *   1. Regression guard for `readRapports()` — the pre-existing, `GET /v1/history`-consumed
 *      export — asserting its truncated `content_summary` shape is completely unchanged by this
 *      task's addition of `readRapportsFull()`.
 *   2. `readRapportsFull()`'s new 6-category aggregate: full untruncated content, an explicit
 *      `category` field per entry, and non-throwing behavior when a source directory/file is
 *      missing (using a scratch fixture that deliberately omits `project/rapports/tests`,
 *      `project/documentation/plans`, and `project/ideas.md` entirely).
 *
 * Both `RAPPORTS_ROOT`/`DOCUMENTATION_SUMMARIES_ROOT`/`DOCUMENTATION_PLANS_ROOT` in `rapports.js`
 * and `IDEAS_FILE` in `ideas.js` are computed once at module-load time via `resolveProjectRoot()`
 * (see `lib/resolve-project-root.js`), so the scratch fixture is built and `JENGA_PROJECT_ROOT` is
 * set *before* `./rapports` is ever required — matching `resolve-project-root.test.js`'s own
 * override mechanism.
 *
 * Run directly:
 *   node project/app/api/parsers/rapports.test.js
 * or, from project/app/api/:
 *   npm test
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

// ---------------------------------------------------------------------------------------------
// Fixture setup — must happen before requiring `./rapports`, since its root paths (and the
// `ideas.js` root path it transitively depends on) are resolved once at module-load time.
// ---------------------------------------------------------------------------------------------

function makeTmpDir(prefix) {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
}

function writeFile(root, relPath, content) {
  const full = path.join(root, relPath);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, content);
}

const FIXTURE_ROOT = makeTmpDir('rapports-full-fixture-');

// Satisfies resolveProjectRoot()'s project/board marker (not strictly required since the
// JENGA_PROJECT_ROOT override below takes precedence over the walk-up, but harmless to include).
fs.mkdirSync(path.join(FIXTURE_ROOT, 'project', 'board'), { recursive: true });

// project/rapports/{analysis,problems} present; project/rapports/tests deliberately absent.
// Note: the frontmatter date is deliberately quoted ("2026-09-01") rather than bare — an
// unquoted YAML date is parsed by gray-matter/js-yaml into a native `Date` object, which is the
// same defect class already documented and fixed elsewhere for board frontmatter (E06_S05_T03).
// Neither readRapports() nor readRapportsFull() attempts that normalization (both simply
// `String()` whatever frontmatter.date holds, mirroring the pre-existing, unmodified behavior of
// readRapports()), so this fixture sticks to the quoted-string form real rapport files use.
const LONG_ANALYSIS_BODY =
  '---\ndate: "2026-09-01"\n---\n' +
  'Analysis body deliberately padded past three hundred characters so that a regression which ' +
  'accidentally truncated readRapportsFull()\'s content the same way readRapports() truncates ' +
  'content_summary would be caught by this test. Padding padding padding padding padding padding ' +
  'padding padding padding padding padding padding padding padding end-of-body-marker.';
writeFile(FIXTURE_ROOT, 'project/rapports/analysis/foo.md', LONG_ANALYSIS_BODY);
writeFile(FIXTURE_ROOT, 'project/rapports/problems/bar.md', 'Problem body, no frontmatter.');

// project/documentation/summaries present; project/documentation/plans deliberately absent.
writeFile(FIXTURE_ROOT, 'project/documentation/summaries/baz-summary.md', 'Summary body.');

// project/ideas.md deliberately absent entirely (no file written).

process.env.JENGA_PROJECT_ROOT = FIXTURE_ROOT;

const { readRapports, readRapportsFull } = require('./rapports');

function cleanup() {
  fs.rmSync(FIXTURE_ROOT, { recursive: true, force: true });
  delete process.env.JENGA_PROJECT_ROOT;
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
// readRapports() regression guard — must stay exactly as it was before this task.
// ---------------------------------------------------------------------------------------------

test('readRapports() still returns only project/rapports entries, truncated to content_summary', async () => {
  const results = await readRapports();
  assert.strictEqual(results.length, 2, 'should only see the 2 files under project/rapports');

  const filenames = results.map((r) => r.filename).sort();
  assert.deepStrictEqual(filenames, [
    path.join('analysis', 'foo.md'),
    path.join('problems', 'bar.md'),
  ]);

  for (const entry of results) {
    assert.deepStrictEqual(Object.keys(entry).sort(), [
      'content_summary',
      'date',
      'filename',
      'type',
    ]);
    assert.strictEqual(entry.type, 'rapport');
    assert.strictEqual(entry.content_summary.length <= 300, true, 'content_summary must stay truncated to 300 chars');
  }

  const foo = results.find((r) => r.filename === path.join('analysis', 'foo.md'));
  assert.strictEqual(foo.date, '2026-09-01');
  // Full body is longer than 300 chars — content_summary must be the truncated prefix, not the
  // full body, and must not itself carry a category field (readRapports()'s shape is unchanged).
  assert.strictEqual(foo.content_summary.length, 300);
  assert.strictEqual('category' in foo, false);
});

test('readRapports() never surfaces summaries/plans/ideas sources (unchanged scope)', async () => {
  const results = await readRapports();
  const filenames = results.map((r) => r.filename);
  assert.strictEqual(filenames.some((f) => f.includes('summary')), false);
});

// ---------------------------------------------------------------------------------------------
// readRapportsFull() — the new 6-category aggregate.
// ---------------------------------------------------------------------------------------------

test('readRapportsFull() returns full untruncated content for entries from present sources', async () => {
  const results = await readRapportsFull();

  const analysisEntry = results.find((e) => e.category === 'analysis');
  assert.ok(analysisEntry, 'expected an analysis-category entry');
  assert.strictEqual(analysisEntry.content.length > 300, true, 'content must not be truncated');
  assert.strictEqual(analysisEntry.content.includes('end-of-body-marker'), true);
  assert.strictEqual(analysisEntry.date, '2026-09-01');

  const problemEntry = results.find((e) => e.category === 'problems');
  assert.ok(problemEntry, 'expected a problems-category entry');
  assert.strictEqual(problemEntry.content, 'Problem body, no frontmatter.');

  const summaryEntry = results.find((e) => e.category === 'summaries');
  assert.ok(summaryEntry, 'expected a summaries-category entry');
  assert.strictEqual(summaryEntry.content, 'Summary body.');
});

test('readRapportsFull() every entry carries an explicit category from the 6-value taxonomy', async () => {
  const results = await readRapportsFull();
  const allowed = new Set(['analysis', 'problems', 'tests', 'summaries', 'plans', 'idea']);
  assert.strictEqual(results.length > 0, true);
  for (const entry of results) {
    assert.strictEqual(allowed.has(entry.category), true, `unexpected category: ${entry.category}`);
  }
});

test('readRapportsFull() contributes zero entries from missing sources without throwing', async () => {
  const results = await readRapportsFull();
  const categories = results.map((e) => e.category);

  // project/rapports/tests, project/documentation/plans, and project/ideas.md were never
  // created in the fixture — none of their categories should appear, and readRapportsFull()
  // above must not have thrown getting here.
  assert.strictEqual(categories.includes('tests'), false);
  assert.strictEqual(categories.includes('plans'), false);
  assert.strictEqual(categories.includes('idea'), false);
});

test('readRapportsFull() entries carry the full { file, data, content, category, date } shape', async () => {
  const results = await readRapportsFull();
  for (const entry of results) {
    assert.deepStrictEqual(Object.keys(entry).sort(), ['category', 'content', 'data', 'date', 'file']);
  }
});

run();
