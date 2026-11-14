#!/usr/bin/env node
'use strict'
// E92_S06_T07: server-render test for EpicProgressBar / epicBarModel. Zero test framework: bundles the component with
// esbuild (CSS import stubbed), renders it with react-dom/server and asserts on the HTML, the technique of
// pipeline-diagram.test.cjs. Fixtures follow one epic entry plus story entries of GET /v1/progress-cards.
// Run: node project/app/ui/scripts/epic-progress-bar.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'epic-progress-bar-')), 'bundle.cjs')
esbuild.buildSync({
  stdin: {
    contents: `
      import React from 'react'
      import { renderToStaticMarkup } from 'react-dom/server'
      export { default as EpicProgressBar } from './src/components/progress/EpicProgressBar.jsx'
      export { buildEpicBarModel } from './src/components/progress/epicBarModel.js'
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
  logLevel: 'silent',
})
const { React, renderToStaticMarkup, EpicProgressBar, buildEpicBarModel } = require(out)
const render = (epic, stories, labels) => renderToStaticMarkup(React.createElement(EpicProgressBar, { epic, stories, labels }))

const LABELS = { card_bar_aria: '%d of %d stories complete, %d%% of tasks done' }
const totals = (done, denominator) => ({ done, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0, denominator })
const epic = (complete, done, denominator) => ({ id: 'E01', stories: { complete }, tasks: { totals: totals(done, denominator) } })
const story = (id, stop, complete = false) => ({ id, stop, complete })

const STORIES = [
  story('E01_S01', 'done', true),
  story('E01_S02', 'in_progress'),
  story('E01_S03', 'failed'),
  story('E01_S04', 'pending'),
  story('E01_S05', 'rejected'),
]
const EPIC = epic(1, 7, 20)

const stopsOf = (html) => html.split('<span class="epic-bar-stop"').slice(1).map(s => s.split('</span>')[0])
const count = (html, needle) => html.split(needle).length - 1

let n = 0
const test = (name, fn) => { fn(); n++; console.log('ok  ' + name) }

test('model: one stop per story in order with the script bucket, percent from tasks.totals, aria filled', () => {
  const m = buildEpicBarModel(EPIC, STORIES, LABELS)
  assert.deepStrictEqual(m.stops.map(s => s.id), STORIES.map(s => s.id))
  assert.deepStrictEqual(m.stops.map(s => s.bucket), ['done', 'in_progress', 'failed', 'pending', 'rejected'])
  assert.strictEqual(m.percent, 35)
  assert.strictEqual(m.completeStories, 1)
  assert.strictEqual(m.totalStories, 5)
  assert.strictEqual(m.ariaLabel, '1 of 5 stories complete, 35% of tasks done')
})

test('model: percent rounds to a whole number', () => {
  assert.strictEqual(buildEpicBarModel(epic(0, 1, 3), [], LABELS).percent, 33)
  assert.strictEqual(buildEpicBarModel(epic(0, 2, 3), [], LABELS).percent, 67)
})

test('model: only a complete story is done; a partly done story is in progress', () => {
  const m = buildEpicBarModel(EPIC, [story('A', 'done', false), story('B', 'in_progress'), story('C', 'done', true)], LABELS)
  assert.deepStrictEqual(m.stops.map(s => s.bucket), ['pending', 'in_progress', 'done'])
})

test('render: one stop per story, no text inside the stops, percent text beside the bar', () => {
  const html = render(EPIC, STORIES, LABELS)
  const stops = stopsOf(html)
  assert.strictEqual(stops.length, 5)
  stops.forEach(s => assert.ok(s.endsWith('>'), 'stop has no content: ' + s))
  assert.ok(html.includes('<span class="epic-bar-percent" aria-hidden="true">35%</span>'))
  assert.ok(html.indexOf('epic-bar-track') < html.indexOf('epic-bar-percent'))
  assert.strictEqual(count(html, 'data-bucket="done"'), 1)
  assert.strictEqual(count(html, 'data-bucket="in_progress"'), 1)
  assert.strictEqual(count(html, 'data-bucket="rejected"'), 1)
})

test('render: wrapper is role=img with the filled aria-label and no other label text', () => {
  const html = render(EPIC, STORIES, LABELS)
  assert.ok(html.includes('role="img"'))
  assert.ok(html.includes('aria-label="1 of 5 stories complete, 35% of tasks done"'))
  const text = html.replace(/<[^>]*>/g, '')
  assert.strictEqual(text, '35%')
})

test('render: 0 stories, stories with 0 tasks, and missing labels do not throw', () => {
  const none = render(epic(0, 0, 0), [], LABELS)
  assert.ok(none.includes('0%') && none.includes('epic-bar-track'))
  assert.strictEqual(stopsOf(none).length, 0)
  const noTasks = render(epic(0, 0, 0), [story('S1', 'pending'), story('S2', 'pending')], LABELS)
  assert.strictEqual(stopsOf(noTasks).length, 2)
  assert.ok(noTasks.includes('0%'))
  assert.doesNotThrow(() => render(EPIC, STORIES, undefined))
  assert.doesNotThrow(() => render(EPIC, STORIES, {}))
  assert.doesNotThrow(() => render(undefined, undefined, undefined))
})

test('css: bar rules use only tokens, no colour literal, no animation or transition', () => {
  const css = fs.readFileSync(path.join(uiDir, 'src', 'components', 'progress', 'progress.css'), 'utf8')
  const start = css.indexOf('EpicProgressBar')
  assert.ok(start > 0)
  const bar = css.slice(start)
  assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(bar), 'colour literal in bar css')
  assert.ok(!/animation|transition|@keyframes/.test(bar), 'animation in bar css')
  for (const b of ['done', 'in-progress', 'failed', 'pending', 'rejected']) assert.ok(bar.includes(`var(--color-progress-${b})`), b)
})

console.log(`${n} passed`)
