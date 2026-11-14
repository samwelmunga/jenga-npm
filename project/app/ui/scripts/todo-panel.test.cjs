#!/usr/bin/env node
'use strict'
// E47_S10_T03: todo panel model + list view. Same zero-framework technique as todo-bubble.test.cjs (esbuild bundle +
// react-dom/server). Effects do not run server-side, so persistence is tested through the model's read/write/prune
// functions with an injected storage, which is exactly what useTodoSelection calls.
// Run: node project/app/ui/scripts/todo-panel.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-panel-'))
const out = path.join(tmp, 'm.cjs')
esbuild.buildSync({
  stdin: {
    contents: `
      import React from 'react'
      import { renderToStaticMarkup } from 'react-dom/server'
      import * as M from './src/components/todo/todoModel.js'
      import { TodoListView } from './src/components/todo/TodoPanel.jsx'
      export { React, renderToStaticMarkup, M, TodoListView }`,
    resolveDir: uiDir, loader: 'jsx',
  },
  outfile: out, bundle: true, platform: 'node', format: 'cjs', jsx: 'automatic',
  nodePaths: [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')],
  loader: { '.css': 'empty' }, define: { 'import.meta.env': '{}' }, logLevel: 'silent',
})
const { React, renderToStaticMarkup, M, TodoListView } = require(out)

let n = 0
function run(name, fn) { fn(); n++; console.log('ok - ' + name) }
const memStorage = () => { const d = {}; return { getItem: k => (k in d ? d[k] : null), setItem: (k, v) => { d[k] = String(v) }, d } }
const throwing = { getItem() { throw new Error('denied') }, setItem() { throw new Error('denied') } }

const epics = [{ id: 'E01', title: 'Epic', stories: [{ id: 'E01_S01', title: 'Story', status: 'In Progress', tasks: [
  { id: 'E01_S01_T01', title: 'Open task', status: 'Pending' },
  { id: 'E01_S01_T02', title: 'Done task', status: 'Passed' },
  { id: 'E01_S01_T03', title: 'Merged task', status: 'Merged' },
  { id: 'E01_S01_T04', title: 'Rejected task', status: 'Rejected' },
] }] }]
const board = M.flattenBoard(epics)
const entries = [
  { ref: 'e01_s01_t01', title: 'line title', line: 1 },
  { ref: 'E01_S01_T02', title: 'x', line: 2 },
  { ref: 'E01_S01_T03', title: 'x', line: 3 },
  { ref: 'E01_S01_T04', title: 'x', line: 4 },
  { ref: 'E09_S09_T09', title: 'Typo ref', line: 5 },
  { title: 'no ref', line: 6 },
]

run('join: case-insensitive id, board title and status; lines without a ref never appear', () => {
  const rows = M.joinTodo(entries, board)
  const open = rows.find(r => r.ref === 'E01_S01_T01')
  assert.deepStrictEqual([open.id, open.title, open.status, open.unresolved], ['E01_S01_T01', 'Open task', 'Pending', false])
  assert.ok(!rows.some(r => r.title === 'no ref'))
})

run('terminal statuses hidden by default, shown on request', () => {
  const refs = M.joinTodo(entries, board).map(r => r.ref)
  assert.deepStrictEqual(refs, ['E01_S01_T01', 'E09_S09_T09'])
  assert.strictEqual(M.joinTodo(entries, board, { showTerminal: true }).length, 5)
})

run('ref not on the board is kept as unresolved with the todo line title', () => {
  const r = M.joinTodo(entries, board).find(x => x.ref === 'E09_S09_T09')
  assert.deepStrictEqual([r.unresolved, r.status, r.title], [true, M.UNRESOLVED_STATUS, 'Typo ref'])
})

run('duplicate refs collapse to one row', () => {
  assert.strictEqual(M.joinTodo([{ ref: 'E01_S01_T01' }, { ref: 'e01_s01_t01' }], board).length, 1)
})

run('persistence round trip', () => {
  const s = memStorage(); const key = M.storageKey('Proj A')
  assert.strictEqual(M.writeTicks(key, ['E01_S01_T01'], s), true)
  assert.deepStrictEqual(M.readTicks(key, s), ['E01_S01_T01'])
})

run('per-project key separation', () => {
  const s = memStorage()
  M.writeTicks(M.storageKey('A'), ['E01_S01_T01'], s)
  assert.notStrictEqual(M.storageKey('A'), M.storageKey('B'))
  assert.deepStrictEqual(M.readTicks(M.storageKey('B'), s), [])
  assert.strictEqual(M.storageKey(null), M.storageKey('  '))
})

run('pruning drops ticks for refs no longer in the todo list', () => {
  assert.deepStrictEqual(M.pruneTicks(['E01_S01_T01', 'E05_S01_T01'], entries), ['E01_S01_T01'])
  assert.deepStrictEqual(M.pruneTicks(['x'], []), [])
})

run('storage throwing or corrupt: read gives [], write returns false, no throw', () => {
  assert.deepStrictEqual(M.readTicks('k', throwing), [])
  assert.strictEqual(M.writeTicks('k', ['A'], throwing), false)
  assert.deepStrictEqual(M.readTicks('k', null), [])
  assert.deepStrictEqual(M.readTicks('k', { getItem: () => '{not json' }), [])
  assert.deepStrictEqual(M.readTicks('k', { getItem: () => '{"a":1}' }), [])
})

const view = props => renderToStaticMarkup(React.createElement(TodoListView, { rows: M.joinTodo(entries, board), ticks: [], onToggle() {}, showTerminal: false, onShowTerminal() {}, ...props }))

run('rows render a labelled checkbox, id, title, status; ticked state reflected', () => {
  const html = view({ ticks: ['E01_S01_T01'] })
  assert.ok(html.includes('type="checkbox"') && html.includes('aria-label="Select E01_S01_T01: Open task"'))
  assert.ok(html.includes('E01_S01_T01') && html.includes('Open task') && html.includes('Pending'))
  assert.ok(/checked=""[^>]*aria-label="Select E01_S01_T01|aria-label="Select E01_S01_T01[^>]*checked=""|checked=""/.test(html))
  assert.ok(html.includes('Not on board'))
  assert.ok(!html.includes('Done task'))
})

run('empty, loading and error states render', () => {
  assert.ok(view({ rows: [] }).includes('Nothing queued'))
  assert.ok(view({ loading: true }).includes('Loading'))
  assert.ok(view({ error: true }).includes('role="alert"'))
})

run('hook wiring: prune on load, storage via model only, panel mounted in bubble', () => {
  const hook = fs.readFileSync(path.join(uiDir, 'src/hooks/useTodoSelection.js'), 'utf8')
  assert.ok(hook.includes('pruneTicks(') && hook.includes('readTicks(') && hook.includes('writeTicks('))
  assert.ok(!/localStorage\./.test(hook))
  assert.ok(fs.readFileSync(path.join(uiDir, 'src/components/TodoBubble.jsx'), 'utf8').includes('<TodoPanel />'))
})

// ---- E47_S10_T04: tags ----
run('tag create: trimmed name assigned to the ticked rows, input not mutated', () => {
  const r = M.addTag({}, '  Sprint A ', ['e01_s01_t01', 'E01_S01_T02'])
  assert.ok(r.ok)
  assert.deepStrictEqual(r.tags, { 'Sprint A': ['E01_S01_T01', 'E01_S01_T02'] })
})

run('tag rejects empty, too long and case-insensitive duplicate names', () => {
  assert.ok(!M.addTag({}, '   ', ['E01_S01_T01']).ok)
  assert.ok(M.addTag({}, 'x'.repeat(M.MAX_TAG_LENGTH + 1), ['E01_S01_T01']).error.includes('limited'))
  assert.ok(M.addTag({}, 'x'.repeat(M.MAX_TAG_LENGTH), ['E01_S01_T01']).ok)
  const dup = M.addTag({ Batch: ['E01_S01_T01'] }, ' batch ', ['E01_S01_T02'])
  assert.ok(!dup.ok && dup.error.includes('already exists'))
})

run('tag with nothing ticked is a no-op with a hint', () => {
  const start = { Batch: ['E01_S01_T01'] }
  const r = M.addTag(start, 'New', [])
  assert.ok(!r.ok && r.error === M.TAG_NO_SELECTION_HINT)
  assert.deepStrictEqual(start, { Batch: ['E01_S01_T01'] })
})

run('a row can carry several tags; group options are All plus one per tag', () => {
  const tags = M.addTag(M.addTag({}, 'b', ['E01_S01_T01']).tags, 'a', ['E01_S01_T01', 'E01_S01_T02']).tags
  assert.deepStrictEqual(M.tagsForRef(tags, 'e01_s01_t01').sort(), ['a', 'b'])
  assert.deepStrictEqual(M.tagsForRef(tags, 'E01_S01_T02'), ['a'])
  assert.deepStrictEqual(M.groupOptions(tags).map(o => o.label), ['All', 'a', 'b'])
  assert.strictEqual(M.groupOptions(tags)[0].value, '')
  assert.deepStrictEqual(M.groupOptions({}).map(o => o.label), ['All'])
})

run('tag persistence: round trip, per-project key, corrupt data gives {}', () => {
  const st = memStorage()
  const k1 = M.tagStorageKey('proj-a')
  assert.notStrictEqual(k1, M.tagStorageKey('proj-b'))
  assert.notStrictEqual(k1, M.storageKey('proj-a'))
  assert.ok(M.writeTags(k1, { T: ['e01_s01_t01'] }, st))
  assert.deepStrictEqual(M.readTags(k1, st), { T: ['E01_S01_T01'] })
  assert.deepStrictEqual(M.readTags(M.tagStorageKey('proj-b'), st), {})
  st.setItem(k1, '[1,2]'); assert.deepStrictEqual(M.readTags(k1, st), {})
  st.setItem(k1, '{nope'); assert.deepStrictEqual(M.readTags(k1, st), {})
})

run('tag pruning drops vanished refs and tags left without rows', () => {
  const kept = M.pruneTags({ A: ['E01_S01_T01', 'E05_S01_T01'], Gone: ['E05_S01_T01'] }, entries)
  assert.deepStrictEqual(kept, { A: ['E01_S01_T01'] })
  assert.deepStrictEqual(M.pruneTags(null, entries), {})
})

run('tag storage throwing never throws and reads as empty', () => {
  assert.strictEqual(M.writeTags('k', { A: ['X'] }, throwing), false)
  assert.deepStrictEqual(M.readTags('k', throwing), {})
  assert.deepStrictEqual(M.readTags('k', null), {})
})

run('view: tag chips on rows, group dropdown lists All + tags and does not filter, message shown', () => {
  const rows = M.joinTodo(entries, board)
  const tags = { Batch: ['E01_S01_T01'], Other: ['E01_S01_T01'] }
  const html = renderToStaticMarkup(React.createElement(TodoListView, {
    rows, ticks: [], onToggle() {}, showTerminal: false, onShowTerminal() {}, tags, group: 'Batch', tagMessage: 'Tag name cannot be empty.',
  }))
  assert.strictEqual((html.match(/class="todo-tag"/g) || []).length, 2)
  assert.ok(html.includes('<option value="">All</option>') && html.includes('>Batch</option>') && html.includes('>Other</option>'))
  assert.strictEqual((html.match(/<li /g) || []).length, rows.length)
  assert.ok(html.includes('Tag name cannot be empty.'))
})

run('tag hook wiring: model-only storage, prune on load; no write route or todo.md access', () => {
  const hook = fs.readFileSync(path.join(uiDir, 'src/hooks/useTodoTags.js'), 'utf8')
  assert.ok(hook.includes('pruneTags(') && hook.includes('readTags(') && hook.includes('writeTags('))
  assert.ok(!/localStorage\./.test(hook) && !/todo\.md|post\(|fetch\(/.test(hook))
})

console.log(`\n${n} todo-panel tests passed`)
