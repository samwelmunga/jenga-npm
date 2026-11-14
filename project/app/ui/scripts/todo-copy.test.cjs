#!/usr/bin/env node
'use strict'
// E47_S10_T05: mark/unmark, /jenga string, clipboard paths and control markup. Same esbuild + react-dom/server technique
// as todo-panel.test.cjs. Run: node project/app/ui/scripts/todo-copy.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-copy-'))
const out = path.join(tmp, 'm.cjs')
esbuild.buildSync({
  stdin: {
    contents: `
      import React from 'react'
      import { renderToStaticMarkup } from 'react-dom/server'
      import * as M from './src/components/todo/todoModel.js'
      import { copyText } from './src/components/todo/clipboard.js'
      import { TodoListView } from './src/components/todo/TodoPanel.jsx'
      export { React, renderToStaticMarkup, M, copyText, TodoListView }`,
    resolveDir: uiDir, loader: 'jsx',
  },
  outfile: out, bundle: true, platform: 'node', format: 'cjs', jsx: 'automatic',
  nodePaths: [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')],
  loader: { '.css': 'empty' }, define: { 'import.meta.env': '{}' }, logLevel: 'silent',
})
const { React, renderToStaticMarkup, M, copyText, TodoListView } = require(out)

let n = 0
const tests = []
const run = (name, fn) => tests.push([name, fn])

const rows = ['E02_S01_T00', 'E05_S01_T01', 'E102_S09_T10'].map(id => ({ ref: id, id, title: 't', status: 'Pending', unresolved: false }))
const tags = { Batch: ['E05_S01_T01', 'E102_S09_T10'] }

run('format: canonical ids, comma+space, list order, ticked only', () => {
  assert.strictEqual(M.formatJengaCommand(rows, ['E102_S09_T10', 'E02_S01_T00']), '/jenga E02_S01_T00, E102_S09_T10')
  assert.strictEqual(M.formatJengaCommand(rows, ['E05_S01_T01']), '/jenga E05_S01_T01')
})
run('format: empty selection gives empty string', () => {
  assert.strictEqual(M.formatJengaCommand(rows, []), '')
  assert.strictEqual(M.formatJengaCommand(rows, ['E99_S99_T99']), '')
  assert.strictEqual(M.formatJengaCommand(null, null), '')
})
run('apply: mark All ticks every row; unmark All clears them', () => {
  assert.deepStrictEqual(M.applyMark([], 'mark', rows, tags, ''), rows.map(r => r.ref))
  assert.deepStrictEqual(M.applyMark(rows.map(r => r.ref), 'unmark', rows, tags, ''), [])
})
run('apply: a tag group touches exactly that group, other ticks stay, no duplicates', () => {
  assert.deepStrictEqual(M.applyMark(['E02_S01_T00', 'E05_S01_T01'], 'mark', rows, tags, 'Batch'), ['E02_S01_T00', 'E05_S01_T01', 'E102_S09_T10'])
  assert.deepStrictEqual(M.applyMark(rows.map(r => r.ref), 'unmark', rows, tags, 'Batch'), ['E02_S01_T00'])
  assert.deepStrictEqual(M.applyMark(['X'], 'mark', rows, tags, 'Missing'), ['X'])
})
run('view: list unfiltered, copy button disabled with no ticks, aria-label, mark controls present', () => {
  const html = renderToStaticMarkup(React.createElement(TodoListView, { rows, ticks: [], onToggle() {}, showTerminal: false, onShowTerminal() {}, tags }))
  assert.strictEqual((html.match(/<li /g) || []).length, rows.length)
  assert.ok(/<button[^>]*class="todo-copy"[^>]*disabled/.test(html) || /<button[^>]*disabled[^>]*class="todo-copy"/.test(html))
  assert.ok(html.includes('aria-label="Copy /jenga command for ticked rows"'))
  assert.ok(html.includes('>Apply</button>') && html.includes('>Mark</option>') && html.includes('>Unmark</option>'))
})
run('view: copy button enabled with a tick; confirmation and error states render', () => {
  const base = { rows, ticks: ['E02_S01_T00'], onToggle() {}, showTerminal: false, onShowTerminal() {}, tags }
  const on = renderToStaticMarkup(React.createElement(TodoListView, base))
  assert.ok(!/class="todo-copy"[^>]*disabled/.test(on) && !/disabled=""[^>]*class="todo-copy"/.test(on))
  assert.ok(renderToStaticMarkup(React.createElement(TodoListView, { ...base, copyState: 'copied' })).includes('Copied'))
  assert.ok(renderToStaticMarkup(React.createElement(TodoListView, { ...base, copyState: 'failed' })).includes('Copy failed'))
})
run('clipboard: navigator.clipboard path', async () => {
  let got
  const r = await copyText('x', { navigator: { clipboard: { writeText: async t => { got = t } } }, document: undefined })
  assert.deepStrictEqual([r.ok, r.method, got], [true, 'clipboard', 'x'])
})
const fakeDoc = (ok) => {
  const log = { appended: 0, removed: 0, value: null }
  const area = { setAttribute() {}, style: {}, select() {}, set value(v) { log.value = v } }
  return { log, doc: { body: { appendChild() { log.appended++ }, removeChild() { log.removed++ } }, createElement: () => area, execCommand: c => c === 'copy' && ok } }
}
run('clipboard: fallback when navigator.clipboard is unavailable', async () => {
  const { log, doc } = fakeDoc(true)
  const r = await copyText('/jenga A', { navigator: {}, document: doc })
  assert.deepStrictEqual([r.ok, r.method, log.value, log.appended, log.removed], [true, 'fallback', '/jenga A', 1, 1])
})
run('clipboard: fallback when writeText rejects', async () => {
  const { doc } = fakeDoc(true)
  const r = await copyText('x', { navigator: { clipboard: { writeText: async () => { throw new Error('denied') } } }, document: doc })
  assert.strictEqual(r.method, 'fallback')
})
run('clipboard: both failing reports an error and never throws', async () => {
  const { log, doc } = fakeDoc(false)
  assert.deepStrictEqual(await copyText('x', { navigator: {}, document: doc }), { ok: false, method: 'none' })
  assert.strictEqual(log.removed, 1)
  assert.strictEqual((await copyText('x', { navigator: undefined, document: undefined })).ok, false)
})

;(async () => {
  for (const [name, fn] of tests) { await fn(); n++; console.log('ok - ' + name) }
  console.log(`\n${n} todo-copy tests passed`)
})().catch(e => { console.error(e); process.exit(1) })
