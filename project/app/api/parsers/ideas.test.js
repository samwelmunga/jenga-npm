/**
 * @file project/app/api/parsers/ideas.test.js
 * Plain Node `assert` test for `readIdeaItems()` / `readIdeas()` in `parsers/ideas.js` (E35_S04_T01).
 * Uses a scratch project root via JENGA_PROJECT_ROOT, set before requiring the parser (IDEAS_FILE
 * is resolved at module load). Never touches the real project/ideas.md.
 *
 * Run: node project/app/api/parsers/ideas.test.js
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ideas-test-'));
fs.mkdirSync(path.join(root, 'project', 'board'), { recursive: true });
process.env.JENGA_PROJECT_ROOT = root;
const ideasFile = path.join(root, 'project', 'ideas.md');

const { readIdeas, readIdeaItems } = require('./ideas');

(async () => {
  // Missing file -> []
  assert.deepStrictEqual(await readIdeaItems(), []);
  assert.deepStrictEqual(await readIdeas(), []);

  const lines = [
    '# Ideas',
    '<!-- template comment -->',
    '',
    'Plain idea',
    'Story promoted <!-- PROMOTED: E12_S03 -->',
    'Task promoted <!-- PROMOTED: E12_S03_T02 -->',
    'Bare promoted <!-- PROMOTED -->',
    'Declined idea <!-- REJECTED -->',
    'Linked <!-- rapport: project/rapports/problems/x.md -->',
    'Rapport then promoted <!-- rapport: project/rapports/problems/x.md --> <!-- PROMOTED: E61_S01 -->',
    'Promoted then rapport <!-- PROMOTED: E61_S01 --> <!-- rapport: project/rapports/problems/x.md -->',
    'Both tags <!-- PROMOTED: E1_S1 --> <!-- REJECTED -->',
  ];
  fs.writeFileSync(ideasFile, lines.join('\n') + '\n');
  const before = fs.readFileSync(ideasFile, 'utf8');

  const items = await readIdeaItems();
  const item = (text, state, boardId, rapport) => ({ text, state, boardId, rapport });
  const R = 'project/rapports/problems/x.md';
  assert.deepStrictEqual(items, [
    item('Plain idea', 'none', null, null),
    item('Story promoted', 'promoted', 'E12_S03', null),
    item('Task promoted', 'promoted', 'E12_S03_T02', null),
    item('Bare promoted', 'promoted', null, null),
    item('Declined idea', 'rejected', null, null),
    item('Linked', 'none', null, R),
    item('Rapport then promoted', 'promoted', 'E61_S01', R),
    item('Promoted then rapport', 'promoted', 'E61_S01', R),
    item('Both tags', 'rejected', null, null),
  ]);

  // readIdeas() shape unchanged
  const legacy = await readIdeas();
  assert.strictEqual(legacy.length, 9);
  assert.deepStrictEqual(Object.keys(legacy[0]), ['file', 'data', 'content', 'category', 'date']);
  assert.strictEqual(legacy[1].content, 'Story promoted <!-- PROMOTED: E12_S03 -->');
  assert.strictEqual(legacy[0].category, 'idea');

  // Read-only
  assert.strictEqual(fs.readFileSync(ideasFile, 'utf8'), before);

  fs.rmSync(root, { recursive: true, force: true });
  console.log('ideas.test.js: all assertions passed');
})().catch((e) => { console.error(e); process.exit(1); });
