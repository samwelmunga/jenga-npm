/**
 * @file project/app/api/parsers/dashboard-wide-ids.test.js
 * Plain Node `assert` test that the dashboard's `todo`, `ideas`, `rapports` (also the `/v1/history` rapport reader) and
 * `knowledge-graph` parsers handle three- and four-digit board IDs (E86_S05_T06, audit group 5 of E86_S05). The board
 * parser and the kanban view are covered by `board.mixed-width.test.js`.
 *
 * Every one of these parsers fixes its root at module load from `JENGA_PROJECT_ROOT`, so one scratch project is built and
 * the variable set before any of them is required; nothing outside the temporary directory is read or written.
 *
 *   todo             `E100_S100_T100`, `E1001_S100_T100` and `E100_S100` are extracted exactly (never truncated to
 *                    `E10…`), an epic-only `E1001` and a ref cited mid-line are not, a lowercase ref is upper-cased,
 *                    and a misordered `E1001_S100_T100 - title` line is reported as unrecognized.
 *   ideas            `PROMOTED: E1001`, `PROMOTED: E100`, `PROMOTED: E100_S100` and `PROMOTED: E100_S100_T100` each
 *                    read back as exactly that boardId with state `promoted`.
 *   rapports         rapport, plan and summary files named for wide IDs come back whole: same relative file names, full
 *                    untruncated content naming the wide IDs, and the history reader's summaries.
 *   knowledge-graph  node ids and test links are matched by exact id: E100 carries only E100's test and E1001 only
 *                    E1001's (E10, a text prefix of both, carries none), and a wide board-sourced ghost stub keeps its id.
 *
 * Run directly:
 *   node project/app/api/parsers/dashboard-wide-ids.test.js
 * or, from project/app/api/:
 *   npm test
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dashboard-wide-ids-')));
process.on('exit', () => fs.rmSync(ROOT, { recursive: true, force: true }));
process.env.JENGA_PROJECT_ROOT = ROOT;

function put(rel, text) {
  const full = path.join(ROOT, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, text);
}

fs.mkdirSync(path.join(ROOT, 'project', 'board'), { recursive: true });

put('project/ideas.md', [
  '# Ideas',
  '<!-- scaffolding -->',
  '',
  'Plain idea',
  'Epic promoted, four digits <!-- PROMOTED: E1001 -->',
  'Epic promoted, three digits <!-- PROMOTED: E100 -->',
  'Epic promoted, two digits <!-- PROMOTED: E01 -->',
  'Story promoted <!-- PROMOTED: E100_S100 -->',
  'Task promoted, three digits <!-- PROMOTED: E100_S100_T100 -->',
  'Task promoted, widest <!-- PROMOTED: E10001_S100000_T100000 -->',
  'Rapport then promoted <!-- rapport: project/rapports/problems/E1001_S100_T100-x.md --> <!-- PROMOTED: E1001_S100_T100 -->',
  'Rejected beats promoted <!-- PROMOTED: E1001 --> <!-- REJECTED -->',
  '',
].join('\n'));

put('project/rapports/problems/E100_S100_T100-wide-rapport.md', [
  '# Problem Rapport', '', '**Related Epic:** E100', '**Related Story:** E100_S100', '**Related Task:** E100_S100_T100', '',
  'Body naming E1001_S100_T100 in full.', '',
].join('\n'));
put('project/rapports/problems/E10_S1_T10-narrow-rapport.md', '# Narrow\n\n**Related Task:** E10_S1_T10\n');
put('project/rapports/analysis/E1001-analysis-2026-11-06.md', '# Analysis for E1001\n');
put('project/documentation/summaries/E1001_S100_T100-summary.md', '# Summary\n\n**Task ID:** E1001_S100_T100\n');
put('project/documentation/plans/E100_S100_T100-plan.md', '# Plan\n\n**Task ID:** E100_S100_T100\n');

put('project/knowledge-graph/graph.json', JSON.stringify({
  nodes: [
    { id: 'E10', type: 'epic', label: 'Epic ten', source: 'human' },
    { id: 'E100', type: 'epic', label: 'Epic one hundred', source: 'human' },
    { id: 'E1001', type: 'epic', label: 'Epic one thousand and one', source: 'human' },
    { id: 'E100_S100_T100', type: 'task', label: 'Wide board task', source: 'board' },
  ],
  edges: [{ id: 'edge-1', from: 'E100_S100_T100', to: 'E100', type: 'implements', description: 'implements' }],
}));
put('project/knowledge-graph/test-links.json', JSON.stringify({
  schema_version: 1,
  links: [
    { node_id: 'E100', test_id: 'a', type: 'unit', name: 'covers E100', file: 'tests/a.test.js', line: 1 },
    { node_id: 'E1001', test_id: 'b', type: 'unit', name: 'covers E1001', file: 'tests/b.test.js', line: 2 },
    { node_id: 'E100_S100_T100', test_id: 'c', type: 'unit', name: 'covers the ghost', file: 'tests/c.test.js', line: 3 },
  ],
}));

const { parseTodoContent, readTodoRefs } = require('./todo');
const { readIdeaItems } = require('./ideas');
const { readRapports, readRapportsFull } = require('./rapports');
const { readSADMap } = require('./knowledge-graph');

(async () => {
  // --- todo ---------------------------------------------------------------------------------------------------
  const todoText = [
    'Wide task: E100_S100_T100',
    'Wider task: E1001_S100_T100',
    'Wide story: E100_S100',
    'Lowercase ref: e1001_s100_t100',
    'Epic only, never queues: E1001',
    'Cites project/rapports/problems/E100_S100_T100-x.md mid-line but queues nothing.',
    '<!-- RECONCILED: done already: E100_S10 -->',
    'E1001_S100_T100 - ref written first',
    'E100_S100: ref written first with a colon',
    'Two-digit still works: E01_S02_T03',
    '',
  ].join('\n');
  const todo = parseTodoContent(todoText);
  assert.deepStrictEqual(
    todo.refs,
    ['E100_S100_T100', 'E1001_S100_T100', 'E100_S100', 'E01_S02_T03'],
    'todo refs are exact, upper-cased, de-duplicated, in first-appearance order'
  );
  assert.deepStrictEqual(
    todo.entries.map((e) => [e.ref, e.line]),
    [['E100_S100_T100', 1], ['E1001_S100_T100', 2], ['E100_S100', 3], ['E1001_S100_T100', 4], ['E01_S02_T03', 10]],
    'todo entries keep wide refs and their original line numbers'
  );
  assert.deepStrictEqual(
    todo.unrecognized.map((u) => u.line),
    [8, 9],
    'a wide ref written first (with a dash, or with a colon) is reported as unrecognized, not silently dropped'
  );
  put('project/todo.md', todoText);
  const fromFile = readTodoRefs();
  assert.strictEqual(fromFile.exists, true);
  assert.deepStrictEqual(fromFile.refs, todo.refs, 'readTodoRefs reads the project todo.md the same way');

  // --- ideas --------------------------------------------------------------------------------------------------
  const ideas = await readIdeaItems();
  const find = (prefix) => ideas.find((i) => i.text.startsWith(prefix));
  const expectPromoted = (prefix, id) => {
    const item = find(prefix);
    assert.ok(item, `idea "${prefix}" present`);
    assert.strictEqual(item.state, 'promoted', `${prefix}: state`);
    assert.strictEqual(item.boardId, id, `${prefix}: boardId read exactly, not truncated or re-padded`);
  };
  expectPromoted('Epic promoted, four digits', 'E1001');
  expectPromoted('Epic promoted, three digits', 'E100');
  expectPromoted('Epic promoted, two digits', 'E01');
  expectPromoted('Story promoted', 'E100_S100');
  expectPromoted('Task promoted, three digits', 'E100_S100_T100');
  expectPromoted('Task promoted, widest', 'E10001_S100000_T100000');
  expectPromoted('Rapport then promoted', 'E1001_S100_T100');
  assert.strictEqual(find('Rapport then promoted').rapport, 'project/rapports/problems/E1001_S100_T100-x.md');
  assert.strictEqual(find('Rejected beats promoted').state, 'rejected', 'REJECTED still wins over a wide PROMOTED');
  assert.strictEqual(find('Plain idea').state, 'none');
  assert.strictEqual(ideas.length, 9, 'every idea line is returned once');

  // --- rapports (and the /v1/history reader) ------------------------------------------------------------------
  const full = await readRapportsFull();
  const files = full.filter((e) => e.category !== 'idea').map((e) => `${e.category}:${e.file}`).sort();
  assert.deepStrictEqual(files, [
    'analysis:analysis/E1001-analysis-2026-11-06.md',
    'plans:E100_S100_T100-plan.md',
    'problems:problems/E100_S100_T100-wide-rapport.md',
    'problems:problems/E10_S1_T10-narrow-rapport.md',
    'summaries:E1001_S100_T100-summary.md',
  ], 'every rapport, plan and summary comes back once under its own wide-ID file name');
  const wide = full.find((e) => e.file === 'problems/E100_S100_T100-wide-rapport.md');
  assert.ok(wide.content.includes('**Related Task:** E100_S100_T100'), 'Related Task header intact');
  assert.ok(wide.content.includes('E1001_S100_T100 in full'), 'full content, not truncated');
  assert.strictEqual(full.filter((e) => e.category === 'idea').length, 9, 'ideas aggregate keeps every line');

  const summaries = await readRapports();
  assert.deepStrictEqual(
    summaries.map((s) => s.filename).sort(),
    ['analysis/E1001-analysis-2026-11-06.md', 'problems/E100_S100_T100-wide-rapport.md', 'problems/E10_S1_T10-narrow-rapport.md'],
    'history reader lists every rapport file under its own name'
  );
  assert.strictEqual(summaries.find((s) => s.filename.startsWith('analysis/')).date, '2026-11-06');

  // --- knowledge-graph ----------------------------------------------------------------------------------------
  const sad = readSADMap();
  const node = (id) => sad.nodes.find((n) => n.id === id);
  assert.deepStrictEqual(sad.nodes.map((n) => n.id).sort(), ['E10', 'E100', 'E1001', 'E100_S100_T100'].sort());
  assert.deepStrictEqual(node('E100').tests.map((t) => t.name), ['covers E100'], 'E100 carries only its own test');
  assert.deepStrictEqual(node('E1001').tests.map((t) => t.name), ['covers E1001'], 'E1001 carries only its own test');
  assert.deepStrictEqual(node('E10').tests, [], 'E10, a text prefix of E100 and E1001, carries no test');
  assert.strictEqual(node('E100_S100_T100').verified, false, 'wide board task is a ghost stub');
  assert.deepStrictEqual(node('E100_S100_T100').tests, [], 'a ghost stub is never presented as covered');
  assert.deepStrictEqual(sad.edges.map((e) => [e.from, e.to]), [['E100_S100_T100', 'E100']], 'edge endpoints keep their wide ids');
  assert.deepStrictEqual(sad.coverage, { shown: 3, hidden: 1, total: 4, needsRevalidation: 0, testCovered: 2, testLinksUnrendered: 1 });

  console.log('dashboard-wide-ids.test.js: all assertions passed');
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
