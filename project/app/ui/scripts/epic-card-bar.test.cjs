#!/usr/bin/env node
'use strict'
// E92_S06_T08: wiring test for the epic card progress bar. Zero test framework: bundles BoardView with esbuild (CSS
// stubbed), server-renders it with and without /v1/progress-cards data, and reads the three wired sources for the
// request, import and handler assertions. Run: node project/app/ui/scripts/epic-card-bar.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'epic-card-bar-')), 'bundle.cjs')
esbuild.buildSync({
  stdin: {
    contents: `
      import React from 'react'
      import { renderToStaticMarkup } from 'react-dom/server'
      export { default as BoardView } from './src/components/board/BoardView.jsx'
      export { React, renderToStaticMarkup }
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
  define: { 'import.meta.env': '{}' }, // BoardView reaches api/client.js through EntryDetailPanel (E92_S06_T11); Vite-only global
  logLevel: 'silent',
})
const { React, renderToStaticMarkup, BoardView } = require(out)
const render = (epics, cards) => renderToStaticMarkup(React.createElement(BoardView, { epics, cards }))

const src = (rel) => fs.readFileSync(path.join(uiDir, 'src', rel), 'utf8')
const count = (html, needle) => html.split(needle).length - 1

const totals = (done, denominator) => ({ done, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0, denominator })
const EPICS = [
  { id: 'E01', title: 'First', status: 'In Progress', stories: [{ id: 'E01_S01', title: 'S1', status: 'Passed', tasks: [] }] },
  { id: 'E02', title: 'Second', status: 'Pending', stories: [] },
]
const CARDS = {
  epics: [{ id: 'E01', stories: { complete: 1 }, tasks: { totals: totals(3, 4) } }],
  stories: [
    { id: 'E01_S01', epic_id: 'E01', complete: true, stop: 'done' },
    { id: 'E01_S02', epic_id: 'E01', complete: false, stop: 'pending' },
    { id: 'E09_S01', epic_id: 'E09', complete: true, stop: 'done' },
  ],
  labels: { card_bar_aria: '%d of %d stories complete, %d%% of tasks done' },
  lang: 'en',
}

let n = 0
const test = (name, fn) => { fn(); n++; console.log('ok  ' + name) }

test('an epic with an entry renders the bar and percent in its header; an epic without one renders as before', () => {
  const html = render(EPICS, CARDS)
  assert.strictEqual(count(html, 'class="epic-bar"'), 1)
  assert.ok(html.includes('>75%</span>'))
  assert.strictEqual(count(html, 'class="epic-bar-stop"'), 2, 'only this epic\'s own stories become stops')
  assert.ok(html.includes('aria-label="1 of 2 stories complete, 75% of tasks done"'))
  const e2 = html.slice(html.indexOf('Second'))
  assert.ok(!e2.includes('epic-bar'))
  const header = html.slice(html.indexOf('epic-header'), html.indexOf('epic-bar'))
  assert.ok(header.includes('epic-title') && header.includes('epic-id'), 'bar follows title and id inside the header')
})

test('no card data (loading, failed request, snapshot without the key): board identical to before, no bar, no banner', () => {
  const base = render(EPICS, null)
  assert.ok(!base.includes('epic-bar'))
  assert.ok(base.includes('First') && base.includes('Second'))
  assert.strictEqual(render(EPICS, undefined), base)
  assert.strictEqual(render(EPICS, {}), base)
  assert.strictEqual(render(EPICS, { epics: 'x', stories: null, labels: null }), base)
  assert.ok(!/error/i.test(base.replace(/class="[^"]*"/g, '')))
})

test('title and collapse toggle are still rendered with their roles', () => {
  const html = render(EPICS, CARDS)
  assert.ok(html.includes('class="epic-title"') && html.includes('role="button"'))
  assert.ok(html.includes('aria-expanded="false"'))
})

test('source: handlers untouched in EpicCard', () => {
  const s = src('components/board/EpicCard.jsx')
  assert.ok(s.includes("onClick={() => onSelect('epic', epic)}"))
  assert.ok(s.includes('onClick={hasStories ? toggle : undefined}'))
  assert.ok(s.includes('<EpicProgressBar'))
})

test('source: BoardTab requests progress-cards through get, in parallel, never feeding the error state', () => {
  const s = src('tabs/BoardTab.jsx')
  assert.ok(s.includes("get('/v1/board')") && s.includes("get('/v1/progress-cards')"))
  const cardsCall = s.slice(s.indexOf("get('/v1/progress-cards')"), s.indexOf('}, [])'))
  assert.ok(!cardsCall.includes('setError') && !cardsCall.includes('setLoading'))
  assert.ok(cardsCall.includes('.catch('))
  // a separate statement after the board chain closes (not chained onto it), so it is requested in parallel
  const before = s.slice(0, s.indexOf("get('/v1/progress-cards')")).trimEnd()
  assert.ok(before.endsWith('setLoading(false))'), 'requested without awaiting the board')
  assert.ok(!/\.then\([^)]*\)\s*\.then/.test(s))
})

test('source: the three files never touch the graph route or the dependency tree component', () => {
  for (const f of ['tabs/BoardTab.jsx', 'components/board/BoardView.jsx', 'components/board/EpicCard.jsx']) {
    const s = src(f)
    assert.ok(!/progress-graph/.test(s), f + ' references the graph route')
    assert.ok(!/DependencyTree|dependency-tree|dependencyTree/i.test(s), f + ' references the dependency tree')
  }
})

console.log(`${n} passed`)
