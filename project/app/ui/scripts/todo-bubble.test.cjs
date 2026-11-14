#!/usr/bin/env node
'use strict'
// E47_S10_T02: render test for the floating todo bubble (components/TodoBubble.jsx) and its mount in App.jsx.
// Zero test framework: esbuild bundle (CSS stubbed) + react-dom/server, the technique of progress-tab.test.cjs.
// Server rendering runs no effects, so Esc is exercised through the exported `handlePanelKeyDown` (what the
// component's document keydown listener calls) and snapshot mode through the real api/client.js with a stubbed `document`.
// Run: node project/app/ui/scripts/todo-bubble.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-bubble-'))

function bundle(name, contents) {
  const out = path.join(tmp, name + '.cjs')
  esbuild.buildSync({
    stdin: { contents, resolveDir: uiDir, loader: 'jsx' },
    outfile: out,
    bundle: true,
    platform: 'node',
    format: 'cjs',
    jsx: 'automatic',
    nodePaths: [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')],
    loader: { '.css': 'empty' },
    define: { 'import.meta.env': '{}' },
    logLevel: 'silent',
  })
  return out
}
const COMMON = `
  import React from 'react'
  import { renderToStaticMarkup } from 'react-dom/server'
  import TodoBubble, { TodoBubbleView, shouldShowTodoBubble, handlePanelKeyDown, BUBBLE_TABS } from './src/components/TodoBubble.jsx'
  export { React, renderToStaticMarkup, TodoBubble, TodoBubbleView, shouldShowTodoBubble, handlePanelKeyDown, BUBBLE_TABS }
`
let n = 0
function run(name, fn) { fn(); n++; console.log('ok - ' + name) }

delete global.document // live page: no embedded snapshot element
const L = require(bundle('live', COMMON))
const html = (tab, props) => L.renderToStaticMarkup(L.React.createElement(L.TodoBubble, { activeTab: tab, ...props }))

run('visible on Backlog and Active Sprint (live)', () => {
  for (const tab of ['board', 'active-sprint']) {
    const out = html(tab)
    assert.ok(out.includes('class="todo-bubble"'), tab)
    assert.ok(out.includes('aria-label="Open todo list"'))
    assert.ok(out.includes('<button'))
    assert.ok(!out.includes('class="todo-bubble-panel"') && !out.includes('role="dialog"'), 'panel starts closed')
  }
})

run('hidden on every other tab', () => {
  for (const tab of ['progress', 'history', 'architecture', 'rapports', 'documentation', 'security', 'budget']) {
    assert.strictEqual(html(tab), '', tab)
  }
})

run('hidden in snapshot mode (explicit prop)', () => {
  assert.strictEqual(html('board', { snapshot: true }), '')
  assert.strictEqual(html('active-sprint', { snapshot: true }), '')
  assert.strictEqual(L.shouldShowTodoBubble('board', true), false)
  assert.deepStrictEqual(L.BUBBLE_TABS, ['board', 'active-sprint'])
})

run('hidden in snapshot mode (real client.js sees the embedded element)', () => {
  global.document = { getElementById: (id) => id === 'jenga-dashboard-data' ? { textContent: JSON.stringify({ routes: {} }) } : null }
  const S = require(bundle('snap', COMMON))
  const out = S.renderToStaticMarkup(S.React.createElement(S.TodoBubble, { activeTab: 'board' }))
  assert.strictEqual(out, '')
  delete global.document
})

run('open panel: dialog, labelled close button, aria-expanded', () => {
  const out = L.renderToStaticMarkup(L.React.createElement(L.TodoBubbleView, { open: true, onToggle() {}, onClose() {} }))
  assert.ok(out.includes('role="dialog"') && out.includes('aria-label="Close todo list"') && out.includes('aria-expanded="true"'))
  const closed = L.renderToStaticMarkup(L.React.createElement(L.TodoBubbleView, { open: false, onToggle() {}, onClose() {} }))
  assert.ok(closed.includes('aria-expanded="false"') && !closed.includes('role="dialog"'))
})

run('Esc closes; other keys and already-handled Esc do not', () => {
  let closed = 0
  const close = () => { closed++ }
  assert.strictEqual(L.handlePanelKeyDown({ key: 'Escape', defaultPrevented: false }, close), true)
  assert.strictEqual(closed, 1)
  assert.strictEqual(L.handlePanelKeyDown({ key: 'Enter', defaultPrevented: false }, close), false)
  assert.strictEqual(L.handlePanelKeyDown({ key: 'Escape', defaultPrevented: true }, close), false)
  assert.strictEqual(closed, 1)
})

run('App.jsx mounts the bubble with the active tab', () => {
  const app = fs.readFileSync(path.join(uiDir, 'src', 'App.jsx'), 'utf8')
  assert.ok(app.includes("import TodoBubble from './components/TodoBubble'"))
  assert.ok(app.includes('<TodoBubble activeTab={activeTab} />'))
})

run('stylesheet uses no colour literals', () => {
  const css = fs.readFileSync(path.join(uiDir, 'src', 'components', 'todo-bubble.css'), 'utf8')
  assert.ok(!/#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(/.test(css))
})

console.log(`\n${n} todo-bubble tests passed`)
