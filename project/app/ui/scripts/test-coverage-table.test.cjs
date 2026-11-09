#!/usr/bin/env node
'use strict'
// E83_S03_T04: tests for the read-only "Test coverage" table on the Architecture tab. Zero test framework:
// bundles the component with esbuild (CSS stubbed), server-renders it with react-dom/server and asserts on
// the HTML, plus direct assertions on the pure helpers in coverageOverlay.js. Fixtures mirror the
// readSADMap() payload shape (project/app/api/parsers/knowledge-graph.js, E83_S03_T02).
// Run: node project/app/ui/scripts/test-coverage-table.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'test-cov-table-')), 'bundle.cjs')
esbuild.buildSync({
  stdin: {
    contents: `
      import React from 'react'
      import { renderToStaticMarkup } from 'react-dom/server'
      export { default } from './src/components/architecture/TestCoverageTable.jsx'
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
const { React, renderToStaticMarkup, coverageRows, coverageSummaryText, coverageEmptyText } = mod
const TestCoverageTable = mod.default

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

const t = (name, file, line, type = 'unit') => ({ name, type, file, line })
const node = (id, tests, extra = {}) => ({ id, label: id, type: 'service', verified: true, source: 'ast', needsRevalidation: false, tests, ...extra })
const render = (nodes, coverage) => renderToStaticMarkup(React.createElement(TestCoverageTable, { nodes, coverage }))
const count = (html, needle) => html.split(needle).length - 1
const EMPTY = 'No test links recorded for the nodes on this map.'

const nodes = [
  node('n-b', [t('zeta', 'tests/b.test.js', 30), t('alpha', 'tests/b.test.js', 10, 'integration')]),
  node('n-a', [t('mid', 'tests/a.test.js', 5)]),
  node('n-none', []),
  node('n-ghost', [t('hidden', 'tests/g.test.js', 1)], { verified: false }),
]
const coverage = { shown: 4, hidden: 0, total: 4, needsRevalidation: 0, testCovered: 2, testLinksUnrendered: 0 }

test('coverageRows: one row per (covered node, test), sorted by node label then test name', () => {
  const rows = coverageRows(nodes)
  assert.deepStrictEqual(
    rows.map(r => `${r.nodeLabel}|${r.name}`),
    ['n-a|mid', 'n-b|alpha', 'n-b|zeta']
  )
})

test('coverageRows: ghost stubs, uncovered nodes and bad input yield no rows', () => {
  assert.strictEqual(coverageRows([node('x', []), node('g', [t('a', 'f', 1)], { verified: false })]).length, 0)
  assert.deepStrictEqual(coverageRows(undefined), [])
  assert.deepStrictEqual(coverageRows(null), [])
})

test('coverageSummaryText: N of M, and nothing when no node is rendered', () => {
  assert.strictEqual(coverageSummaryText(coverage), '2 of 4 rendered nodes covered by tests')
  assert.strictEqual(coverageSummaryText({ shown: 0, testCovered: 0 }), '')
  assert.strictEqual(coverageSummaryText(undefined), '')
})

test('coverageEmptyText: base sentence, plus the unrendered count when above 0', () => {
  assert.strictEqual(coverageEmptyText({ testCovered: 0, testLinksUnrendered: 0 }), EMPTY)
  assert.strictEqual(coverageEmptyText(undefined), EMPTY)
  assert.strictEqual(
    coverageEmptyText({ testCovered: 0, testLinksUnrendered: 5 }),
    `${EMPTY} 5 test links exist for nodes that are not shown on this map (board-sourced or unverified).`
  )
  assert.ok(coverageEmptyText({ testLinksUnrendered: 1 }).includes('1 test link exists'))
})

test('table: summary line and one row per (node, test) in the stated order', () => {
  const html = render(nodes, coverage)
  assert.ok(html.includes('2 of 4 rendered nodes covered by tests'))
  assert.strictEqual(count(html, '<tr'), 4) // header + 3 rows
  const order = ['mid', 'alpha', 'zeta'].map(n => html.indexOf(`<td>${n}</td>`))
  assert.ok(order.every(i => i > -1))
  assert.ok(order[0] < order[1] && order[1] < order[2])
  assert.ok(html.includes('tests/b.test.js:10'))
  assert.ok(html.includes('integration'))
  assert.ok(!html.includes('hidden'))
  assert.ok(!html.includes(EMPTY))
})

test('empty state: testCovered 0 shows only the one line, no table', () => {
  const html = render(nodes.map(n => ({ ...n, tests: [] })), { ...coverage, testCovered: 0 })
  assert.ok(html.includes(EMPTY))
  assert.ok(!html.includes('<table'))
  assert.ok(!html.includes('covered by tests'))
})

test('empty state: real-graph shape (no rendered nodes, unrendered links) names the count', () => {
  const html = render([], { shown: 0, hidden: 346, total: 346, needsRevalidation: 0, testCovered: 0, testLinksUnrendered: 5 })
  assert.ok(html.includes('5 test links exist for nodes that are not shown on this map (board-sourced or unverified).'))
  assert.ok(!html.includes('<table'))
  assert.ok(!html.includes('0 of 0'))
})

test('empty state: missing coverage and nodes render the one-liner without error', () => {
  assert.ok(render(undefined, undefined).includes(EMPTY))
})

test('read-only: locations are plain text, no link, button, input or handler markup', () => {
  const html = render(nodes, coverage)
  for (const needle of ['<a ', 'href=', '<button', '<input', '<select', 'onclick', 'role="button"', 'dangerouslySetInnerHTML']) {
    assert.ok(!html.toLowerCase().includes(needle.toLowerCase()), `unexpected ${needle}`)
  }
})

test('text is escaped, never injected as markup', () => {
  const evil = [node('n', [t('<img src=x onerror=alert(1)>', 'tests/x.test.js', 1)], { label: '<b>bold</b>' })]
  const html = render(evil, { shown: 1, testCovered: 1, testLinksUnrendered: 0 })
  assert.ok(!html.includes('<img'))
  assert.ok(!html.includes('<b>'))
  assert.ok(html.includes('&lt;img'))
})

if (failures > 0) {
  console.log(`\n${failures} test(s) failed`)
  process.exit(1)
}
console.log('\nall tests passed')
