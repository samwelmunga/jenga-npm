#!/usr/bin/env node
'use strict'
// E92_S06_T11: test for the dependency tree in the epic content overlay (EntryDetailPanel.jsx). Zero test framework and no
// DOM: bundles the panel with esbuild (CSS stubbed) and swaps `react` (for component sources only) for a tiny hook shim, so the component's effects run
// synchronously in a hand-rolled harness driven by a stubbed `get`. Rendered output goes through react-dom/server.
// Run: node project/app/ui/scripts/epic-overlay-tree.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'epic-overlay-tree-'))
const shim = path.join(tmp, 'react-shim.js')
fs.writeFileSync(shim, `
  import * as R from ${JSON.stringify(require.resolve('react', { paths: [uiDir] }))}
  const h = () => globalThis.__h
  export const useState = init => h().useState(init)
  export const useEffect = (fn, deps) => h().useEffect(fn, deps)
  export const useRef = v => ({ current: v })
  export default { ...R }
  export const createElement = R.createElement
  export const Fragment = R.Fragment
`)
const purify = path.join(tmp, 'purify-stub.js')
fs.writeFileSync(purify, 'export default { sanitize: html => html }') // DOMPurify needs a window; markdown is not under test
const out = path.join(tmp, 'bundle.cjs')
const built = esbuild.build({
  stdin: {
    contents: `
      import { renderToStaticMarkup } from 'react-dom/server'
      import { createElement as ce } from 'react' // resolved from the bundle entry (stdin has no src/ importer path)
      export { default as EntryDetailPanel, EpicTreeSection, EpicTreeBody, loadEpicGraph } from './src/components/history/EntryDetailPanel.jsx'
      export { renderToStaticMarkup, ce }
    `,
    resolveDir: uiDir,
    loader: 'jsx',
  },
  outfile: out,
  bundle: true,
  platform: 'node',
  format: 'cjs',
  jsx: 'automatic',
  nodePaths: [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')],
  loader: { '.css': 'empty' },
  define: { 'import.meta.env': '{}' },
  plugins: [{
    name: 'react-hook-shim',
    // only the component sources see the shim; react-dom/server keeps the real react
    setup(b) {
      b.onResolve({ filter: /^dompurify$/ }, () => ({ path: purify }))
      b.onResolve({ filter: /^react$/ }, a => (a.importer.includes(path.sep + 'src' + path.sep) ? { path: shim } : null))
    },
  }],
  logLevel: 'silent',
})
let EntryDetailPanel, EpicTreeSection, EpicTreeBody, loadEpicGraph, renderToStaticMarkup, ce // set once the bundle is built

// Minimal hook runtime: one component instance, state slots, effects run after each render when deps changed.
function mount(Comp, initialProps) {
  let props = initialProps, slots = [], deps = [], cleanups = [], i, effects, output
  globalThis.__h = {
    useState(init) {
      const k = i++
      if (!(k in slots)) slots[k] = typeof init === 'function' ? init() : init
      return [slots[k], v => { slots[k] = v; render() }]
    },
    useEffect(fn, d) {
      const k = i++
      const prev = deps[k]
      if (!prev || !d || d.length !== prev.length || d.some((x, j) => x !== prev[j])) {
        effects.push(() => { if (cleanups[k]) cleanups[k](); deps[k] = d; const c = fn(); cleanups[k] = typeof c === 'function' ? c : null })
      }
    },
  }
  function render() {
    i = 0; effects = []
    output = Comp(props)
    const run = effects; effects = []
    run.forEach(f => f())
  }
  render()
  return { html: () => renderToStaticMarkup(output), setProps(p) { props = { ...props, ...p }; render() } }
}

const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b }); return { promise, resolve, reject } }
const flush = () => new Promise(r => setImmediate(r))
const T = (id, story, state, deps) => ({ id, story_id: story, epic_id: id.split('_')[0], title: 'Title ' + id, status: 'x', bucket: 'x', state, depends_on: deps || [], blocked_by: [], unlocked_by: null })
const graph = {
  schema_version: 1, labels: { goal: 'Goal' },
  epics: [{ id: 'E01', title: 'Alpha' }, { id: 'E02', title: 'Beta' }],
  stories: [{ id: 'E01_S01', epic_id: 'E01', title: 'S' }, { id: 'E02_S01', epic_id: 'E02', title: 'S' }],
  tasks: [T('E01_S01_T01', 'E01_S01', 'done'), T('E01_S01_T02', 'E01_S01', 'ready', ['E01_S01_T01']),
    T('E02_S01_T01', 'E02_S01', 'done'), T('E02_S01_T02', 'E02_S01', 'locked', ['E02_S01_T01'])],
  external: null,
}

let n = 0
const test = async (name, fn) => { await fn(); n++; console.log('ok  ' + name) }

;(async () => {
  await built
  ;({ EntryDetailPanel, EpicTreeSection, EpicTreeBody, loadEpicGraph, renderToStaticMarkup, ce } = require(out))
  await test('live: requests /v1/progress-graph?within=<epic> once and renders the tree', async () => {
    const calls = []
    const fetcher = p => { calls.push(p); return Promise.resolve(graph) }
    const m = mount(EpicTreeSection, { epicId: 'E01', fetcher })
    assert.ok(m.html().includes('Loading'), 'spinner while loading')
    await flush()
    assert.deepStrictEqual(calls, ['/v1/progress-graph?within=E01'])
    const html = m.html()
    assert.ok(html.includes('dep-tree') && html.includes('E01_S01_T02'), 'tree rendered')
    assert.ok(!html.includes('E02_S01_T01'), 'only the chosen epic')
  })

  await test('snapshot: no query string; the epic is selected from the whole embedded payload, no server', async () => {
    const calls = []
    assert.strictEqual(loadEpicGraph('E02', p => { calls.push(p); return Promise.resolve(graph) }, true) instanceof Promise, true)
    assert.deepStrictEqual(calls, ['/v1/progress-graph'])
    const html = renderToStaticMarkup(ce(EpicTreeBody, { status: 'ok', graph, epicId: 'E02' }))
    assert.ok(html.includes('E02_S01_T02') && !html.includes('E01_S01_T02'))
  })

  await test('a stale response for the previously opened epic is ignored', async () => {
    const a = deferred(), b = deferred()
    const fetcher = p => (p.endsWith('E01') ? a.promise : b.promise)
    const m = mount(EpicTreeSection, { epicId: 'E01', fetcher })
    m.setProps({ epicId: 'E02' })
    b.resolve(graph)
    await flush()
    a.resolve(graph) // arrives late
    await flush()
    const html = m.html()
    assert.ok(html.includes('E02_S01_T02'), 'B tree shown')
    assert.ok(!html.includes('E01_S01_T02'), 'A tree never shown under B')
  })

  await test('a failed request shows one muted line; the markdown body of the overlay is still shown', async () => {
    const m = mount(EpicTreeSection, { epicId: 'E01', fetcher: () => Promise.reject(new Error('boom')) })
    await flush()
    assert.ok(m.html().includes('panel-empty') && m.html().includes('unavailable'))
    const html = renderToStaticMarkup(ce(EntryDetailPanel, { entry: { type: 'board_item', kind: 'epic', id: 'E01', title: 'Alpha', status: 'x', _content: '# Body text' }, onClose() {} }))
    assert.ok(html.includes('Body text'), 'body present')
  })

  await test('only epic board items mount the section (so only they can request the graph)', () => {
    const base = { id: 'E01_S01', title: 'x', status: 's', _content: 'body' }
    const render = entry => { globalThis.__h = { useState: v => [v, () => {}], useEffect() {} }; return renderToStaticMarkup(ce(EntryDetailPanel, { entry, onClose() {} })) }
    for (const entry of [
      { type: 'board_item', kind: 'story', ...base }, { type: 'board_item', kind: 'task', ...base },
      { type: 'git_commit', sha: 'abc', subject: 's' }, { type: 'rapport', filename: 'f' }, { type: 'idea', text: 't' },
      { type: 'library_entry', file: 'f', content: 'c' },
    ]) assert.ok(!render(entry).includes('epic-tree'), entry.type + ' ' + (entry.kind || ''))
    assert.ok(render({ type: 'board_item', kind: 'epic', ...base, id: 'E01' }).includes('epic-tree'))
  })

  await test('source: effect keyed on the epic id, uses the shared get, css uses tokens only', () => {
    const src = fs.readFileSync(path.join(uiDir, 'src/components/history/EntryDetailPanel.jsx'), 'utf8')
    assert.ok(/\[epicId, fetcher\]/.test(src) && /entry\.kind === 'epic'/.test(src))
    const css = fs.readFileSync(path.join(uiDir, 'src/components/history/history.css'), 'utf8')
    const block = css.slice(css.indexOf('E92_S06_T11'))
    assert.ok(!/#[0-9a-fA-F]{3,8}\b|rgba?\(/.test(block), 'no colour literal')
  })

  console.log(`\n${n} passed`)
})().catch(e => { console.error(e); process.exit(1) })
