#!/usr/bin/env node
'use strict'
// E83_S03_T03: tests for the read-only covered-node overlay on the SAD map. Zero test framework: bundles
// the component with esbuild (CSS stubbed), server-renders it with react-dom/server and asserts on the
// HTML, plus direct assertions on the pure helpers in coverageOverlay.js. Fixtures mirror the readSADMap()
// payload shape (project/app/api/parsers/knowledge-graph.js, E83_S03_T02).
// Run: node project/app/ui/scripts/sad-covered-overlay.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'sad-covered-')), 'bundle.cjs')
esbuild.buildSync({
  stdin: {
    contents: `
      import React from 'react'
      import { renderToStaticMarkup } from 'react-dom/server'
      export { default } from './src/components/architecture/SADMap.jsx'
      export * from './src/components/architecture/coverageOverlay.js'
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
  nodePaths: [path.join(uiDir, 'node_modules')],
  loader: { '.css': 'empty' },
  logLevel: 'silent',
})
const mod = require(out)
const { React, renderToStaticMarkup, isCoveredNode, testTitleLines, titleWithTests, formatTestLine } = mod
const SADMap = mod.default

let failures = 0
function test(name, fn) {
  try {
    fn()
    console.log(`ok - ${name}`)
  } catch (err) {
    failures++
    console.log(`not ok - ${name}\n  ${err.message}`)
  }
}

const mkTests = n =>
  Array.from({ length: n }, (_, i) => ({ name: `case ${i + 1}`, type: 'unit', file: `tests/a${i + 1}.test.js`, line: i + 10 }))
const node = (id, extra = {}) => ({ id, label: id, type: 'service', verified: true, source: 'ast', needsRevalidation: false, tests: [], ...extra })
const render = (nodes, edges = []) => renderToStaticMarkup(React.createElement(SADMap, { nodes, edges, coverage: null }))
const count = (html, needle) => html.split(needle).length - 1

test('isCoveredNode: only verified, non-cluster nodes with tests', () => {
  assert.strictEqual(isCoveredNode(node('a', { tests: mkTests(1) })), true)
  assert.strictEqual(isCoveredNode(node('a')), false)
  assert.strictEqual(isCoveredNode(node('a', { tests: mkTests(2), verified: false })), false)
  assert.strictEqual(isCoveredNode(node('a', { tests: mkTests(2), isCluster: true })), false)
  assert.strictEqual(isCoveredNode(node('a', { tests: undefined })), false)
  assert.strictEqual(isCoveredNode(null), false)
})

test('formatTestLine: type · name · file:line', () => {
  assert.strictEqual(formatTestLine({ type: 'unit', name: 'adds', file: 'x/y.test.js', line: 7 }), 'unit · adds · x/y.test.js:7')
})

test('testTitleLines: cap at 8 with +N more', () => {
  assert.strictEqual(testTitleLines(mkTests(3)).length, 3)
  assert.strictEqual(testTitleLines(mkTests(8)).length, 8)
  assert.ok(!testTitleLines(mkTests(8)).some(l => l.includes('more')))
  const nine = testTitleLines(mkTests(9))
  assert.strictEqual(nine.length, 9)
  assert.strictEqual(nine[8], '+1 more')
  const twenty = testTitleLines(mkTests(20))
  assert.strictEqual(twenty[8], '+12 more')
  assert.strictEqual(twenty[7], 'unit · case 8 · tests/a8.test.js:17')
})

test('titleWithTests: appends lines for covered nodes only', () => {
  const covered = node('a', { tests: mkTests(2) })
  assert.strictEqual(titleWithTests('a', covered), 'a\nunit · case 1 · tests/a1.test.js:10\nunit · case 2 · tests/a2.test.js:11')
  assert.strictEqual(titleWithTests('a', node('b')), 'a')
  assert.strictEqual(titleWithTests('a', node('g', { verified: false, tests: mkTests(1) })), 'a')
})

test('render: covered node gets a badge with its count; uncovered, ghost and cluster do not', () => {
  const html = render(
    [node('covered', { tests: mkTests(3) }), node('plain'), node('ghost', { verified: false, source: 'board', tests: mkTests(2) })],
    [{ from: 'covered', to: 'plain' }]
  )
  assert.strictEqual(count(html, 'sad-node-covered-badge'), 1)
  assert.ok(/class="sad-node-covered-badge"[^]*?<text[^>]*>3<\/text>/.test(html))
})

test('render: collapsed cluster of covered nodes gets no badge, no test lines and no legend', () => {
  // Collapse is client state; emulate a cluster node by passing one in the node list directly.
  const html = render([{ id: '__cluster__service', label: 'service (1)', type: 'service', isCluster: true, tests: mkTests(2) }])
  assert.strictEqual(count(html, 'sad-node-covered-badge'), 0)
  assert.strictEqual(count(html, 'sad-covered-legend'), 0)
  assert.ok(!html.includes('unit · case'))
})

test('render: <title> lists each test, capped at 8 with +N more', () => {
  const html = render([node('big', { tests: mkTests(10) })])
  assert.ok(html.includes('unit · case 1 · tests/a1.test.js:10'))
  assert.ok(html.includes('unit · case 8 · tests/a8.test.js:17'))
  assert.ok(!html.includes('unit · case 9 ·'))
  assert.ok(html.includes('+2 more'))
})

test('render: legend only when a covered node is on screen', () => {
  assert.strictEqual(count(render([node('a', { tests: mkTests(1) })]), 'sad-covered-legend"'), 1)
  assert.strictEqual(count(render([node('a')]), 'sad-covered-legend'), 0)
  assert.strictEqual(count(render([node('g', { verified: false, source: 'board', tests: mkTests(1) })]), 'sad-covered-legend'), 0)
})

test('render: overlay adds no href or extra handler markup and no hex literal in the badge', () => {
  const html = render([node('a', { tests: mkTests(1) })])
  assert.ok(!/href=/.test(html))
  const badge = html.slice(html.indexOf('sad-node-covered-badge'), html.indexOf('</g>', html.indexOf('sad-node-covered-badge')))
  assert.ok(badge.includes('var(--color-chart-covered)') && badge.includes('var(--color-chart-covered-ring)'))
  assert.ok(!/#[0-9a-fA-F]{3,8}/.test(badge))
})

test('tokens.css defines the covered tokens in the light, media-query dark and data-theme dark blocks', () => {
  const css = fs.readFileSync(path.join(uiDir, 'src', 'tokens.css'), 'utf8')
  assert.strictEqual(css.split('--color-chart-covered:').length - 1, 3)
  assert.strictEqual(css.split('--color-chart-covered-ring:').length - 1, 3)
})

if (failures > 0) {
  console.log(`${failures} test(s) failed`)
  process.exit(1)
}
console.log('all passed')
