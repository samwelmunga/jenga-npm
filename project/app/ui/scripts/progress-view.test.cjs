#!/usr/bin/env node
'use strict'
// E92_S03_T05: server-render test for ProgressView / PieChart. Zero test framework: bundles the components
// with esbuild (CSS import stubbed), renders them with react-dom/server and asserts on the HTML, the technique
// of findings-table.test.cjs and budget-view-render.cjs.
// The fixture follows the GET /v1/progress body (E92_S03_T01): { schema_version, charts: { tasks, stories,
// epics, backlog } }, where tasks/stories/epics are `levels.<level>` blocks of scripts/board-progress.sh and
// backlog is the `--backlog` output's `levels` (or { empty: true }).
// Run: node project/app/ui/scripts/progress-view.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'progress-view-')), 'bundle.cjs')
esbuild.buildSync({
  // Re-export React and the renderer from the same bundle as the components (one React copy).
  stdin: {
    contents: `
      import React from 'react'
      import { renderToStaticMarkup } from 'react-dom/server'
      export { default as ProgressView, backlogBlock } from './src/components/progress/ProgressView.jsx'
      export { default as PieChart, FULL_CIRCLE_PATH, EMPTY_TEXT } from './src/components/progress/PieChart.jsx'
      export { buildPieModel, progressHeadline } from './src/components/progress/progressModel.js'
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
const mod = require(out)
const { React, renderToStaticMarkup, ProgressView, PieChart, buildPieModel, progressHeadline, backlogBlock } = mod
const view = (data) => renderToStaticMarkup(React.createElement(ProgressView, { data }))
const pie = (block, title) => renderToStaticMarkup(React.createElement(PieChart, { model: buildPieModel(block, title), headline: progressHeadline(block) }))

const TASKS = {
  counts: { Passed: 4, Merged: 1, 'In Progress': 1, Failed: 1, Blocked: 1, Pending: 1, Backlog: 1, Rejected: 3 },
  totals: { done: 5, in_progress: 1, failed: 2, pending: 2, rejected: 3, unknown: 0, denominator: 10 },
}
const STORIES = {
  counts: { Passed: 2, Pending: 1 },
  totals: { done: 2, in_progress: 0, failed: 0, pending: 1, rejected: 0, unknown: 0, denominator: 3 },
}
const EPICS = {
  counts: { Done: 3 },
  totals: { done: 3, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0, denominator: 3 },
}
const BACKLOG_TASKS = {
  counts: { Pending: 2, 'In Progress': 1 },
  totals: { done: 0, in_progress: 1, failed: 0, pending: 2, rejected: 0, unknown: 0, denominator: 3 },
}
const FIXTURE = {
  schema_version: 1,
  charts: {
    tasks: TASKS,
    stories: STORIES,
    epics: EPICS,
    // a queued story also yields its tasks, so the backlog carries more than one level block
    backlog: { tasks: BACKLOG_TASKS, stories: STORIES },
  },
}

const charts = (html) => html.split('<section ').slice(1).map(s => '<section ' + s)
const sliceKeys = (html) => [...html.matchAll(/data-slice="([a-z_]+)"/g)].map(m => m[1])
const legendKeys = (html) => [...html.matchAll(/data-legend="([a-z_]+)"/g)].map(m => m[1])

let n = 0
const test = (name, fn) => { fn(); n++; console.log('ok  ' + name) }

// 1. Four charts titled Tasks, Stories, Epics, Backlog, in that order, each with a headline.
test('four charts in order, each with a headline', () => {
  const html = view(FIXTURE)
  const titles = [...html.matchAll(/data-chart="([^"]+)"/g)].map(m => m[1])
  assert.deepStrictEqual(titles, ['Tasks', 'Stories', 'Epics', 'Backlog'])
  assert.strictEqual((html.match(/data-testid="progress-chart"/g) || []).length, 4)
  assert.ok(html.includes('<h2>Progress</h2>'))
  assert.ok(html.includes('5 of 10 done'), 'tasks headline')
  assert.ok(html.includes('2 of 3 done'), 'stories headline')
  assert.ok(html.includes('3 of 3 done'), 'epics headline')
  assert.ok(html.includes('0 of 3 done'), 'backlog headline')
})

// 2. One legend row per non-zero slice with label, count and percent; rows match slices.
test('legend rows: label, count and percent per non-zero slice', () => {
  const tasks = charts(view(FIXTURE))[0]
  assert.deepStrictEqual(sliceKeys(tasks), ['done', 'in_progress', 'failed', 'pending', 'rejected'])
  assert.deepStrictEqual(legendKeys(tasks), ['done', 'in_progress', 'failed', 'pending', 'rejected'])
  const rows = tasks.match(/<li [^>]*>.*?<\/li>/g)
  assert.strictEqual(rows.length, 5)
  assert.ok(/progress-legend-label">Done<\/span><span class="progress-legend-count">5<\/span><span class="progress-legend-percent">39%<\/span>/.test(rows[0]), rows[0])
  assert.ok(/>Failed or blocked<\/span><span class="progress-legend-count">2<\/span><span class="progress-legend-percent">15%<\/span>/.test(rows[2]), rows[2])
})

// 3. Rejected: own token, label "Rejected (not counted)", and no other slice or row uses that variable.
test('rejected slice and legend row use the rejected token only', () => {
  const html = view(FIXTURE)
  const tasks = charts(html)[0]
  const rejectedPath = tasks.match(/<path [^>]*data-slice="rejected"[^>]*>/)[0]
  assert.ok(rejectedPath.includes('var(--color-progress-rejected)'))
  const rejectedRow = tasks.match(/<li [^>]*data-legend="rejected".*?<\/li>/)[0]
  assert.ok(rejectedRow.includes('var(--color-progress-rejected)'))
  assert.ok(rejectedRow.includes('Rejected (not counted)'))
  // exactly one slice and one swatch carry the variable: no other slice uses it
  const uses = html.match(/var\(--color-progress-rejected\)/g) || []
  assert.strictEqual(uses.length, 2, 'one slice + one swatch in the one chart that has rejected items')
  for (const key of ['done', 'in_progress', 'failed', 'pending']) {
    const p = tasks.match(new RegExp(`<path [^>]*data-slice="${key}"[^>]*>`))[0]
    assert.ok(!p.includes('--color-progress-rejected'), key)
  }
  // the other tokens map as the model says
  assert.ok(tasks.includes('var(--color-progress-done)') && tasks.includes('var(--color-progress-in-progress)'))
  assert.ok(tasks.includes('var(--color-progress-failed)') && tasks.includes('var(--color-progress-pending)'))
})

// 4. A zero bucket has neither slice nor legend row; an empty block says "Nothing to show".
test('zero buckets are omitted', () => {
  const stories = charts(view(FIXTURE))[1]
  assert.deepStrictEqual(sliceKeys(stories), ['done', 'pending'])
  assert.deepStrictEqual(legendKeys(stories), ['done', 'pending'])
  assert.ok(!stories.includes('--color-progress-rejected'))
  assert.ok(!stories.includes('--color-progress-failed'))
})

test('empty blocks render "Nothing to show" with the chart title, no svg', () => {
  const html = view({ schema_version: 1, charts: { tasks: TASKS, stories: { empty: true }, epics: undefined, backlog: { empty: true } } })
  const cs = charts(html)
  assert.strictEqual(cs.length, 4)
  for (const i of [1, 2, 3]) {
    assert.ok(cs[i].includes('Nothing to show'), `chart ${i}`)
    assert.ok(!cs[i].includes('<svg'), `chart ${i} has no svg`)
    assert.ok(!cs[i].includes('<path'), `chart ${i} has no path`)
  }
  assert.ok(cs[1].includes('>Stories</h3>') && cs[2].includes('>Epics</h3>') && cs[3].includes('>Backlog</h3>'))
  assert.ok(!cs[0].includes('Nothing to show'))
  // an all-zero block is empty too, and a missing payload still gives four titled charts
  assert.ok(pie({ counts: {}, totals: { done: 0, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0, denominator: 0 } }, 'Tasks').includes('Nothing to show'))
  const none = view(undefined)
  assert.strictEqual(charts(none).length, 4)
  assert.strictEqual((none.match(/Nothing to show/g) || []).length, 4)
})

// 5. A 100% single slice is a full circle path, not a degenerate arc.
test('single 100% slice renders a full circle path', () => {
  const html = pie({ counts: { Passed: 4 }, totals: { done: 4, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0, denominator: 4 } }, 'Tasks')
  assert.deepStrictEqual(sliceKeys(html), ['done'])
  const d = html.match(/<path [^>]*d="([^"]+)"/)[1]
  assert.strictEqual(d, mod.FULL_CIRCLE_PATH)
  const arcs = d.match(/A/g) || []
  assert.strictEqual(arcs.length, 2, 'two half arcs')
  // the two arcs end at the bottom (0,R) and back at the top (0,-R): a closed circle
  assert.ok(/^M0,-90A90,90,0,1,1,0,90A90,90,0,1,1,0,-90Z$/.test(d), d)
  assert.ok(html.includes('100%'))
  // a rejected-only pie is a single slice as well
  const rej = pie({ counts: { Rejected: 2 }, totals: { done: 0, in_progress: 0, failed: 0, pending: 0, rejected: 2, unknown: 0, denominator: 0 } }, 'Tasks')
  assert.strictEqual(rej.match(/<path [^>]*d="([^"]+)"/)[1], mod.FULL_CIRCLE_PATH)
  // two slices are real arcs, not the full circle
  const two = charts(view(FIXTURE))[1]
  assert.ok(!two.includes(mod.FULL_CIRCLE_PATH))
})

// 6. aria-label with counts on role="img" for every chart.
test('every chart has an aria-label with the counts on role="img"', () => {
  const html = view(FIXTURE)
  const svgs = html.match(/<svg [^>]*>/g)
  assert.strictEqual(svgs.length, 4)
  for (const s of svgs) assert.ok(s.includes('role="img"'), s)
  const labels = svgs.map(s => s.match(/aria-label="([^"]+)"/)[1])
  assert.strictEqual(labels[0], 'Tasks: 13 items. Done: 5 (39%), In progress: 1 (8%), Failed or blocked: 2 (15%), Pending: 2 (15%), Rejected (not counted): 3 (23%).')
  assert.ok(labels[1].startsWith('Stories: 3 items.') && labels[1].includes('Done: 2 (67%)'))
  assert.ok(labels[2].startsWith('Epics: 3 items.'))
  assert.ok(labels[3].startsWith('Backlog: 3 items.') && labels[3].includes('Pending: 2 (67%)'))
  assert.ok(pie({ counts: { Passed: 1 }, totals: { done: 1, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0, denominator: 1 } }, 'Tasks').includes('Tasks: 1 item.'))
})

// 7. The Backlog pie plots the tasks block (decision), with stories then epics as fallbacks.
test('backlog plots the tasks block of the backlog levels', () => {
  assert.strictEqual(backlogBlock(FIXTURE.charts.backlog), BACKLOG_TASKS)
  assert.strictEqual(backlogBlock({ stories: STORIES, epics: EPICS }), STORIES)
  assert.strictEqual(backlogBlock({ epics: EPICS }), EPICS)
  assert.strictEqual(backlogBlock(BACKLOG_TASKS), BACKLOG_TASKS) // already a block
  for (const e of [{ empty: true }, undefined, null, {}, { tasks: { empty: true } }]) assert.deepStrictEqual(backlogBlock(e), { empty: true })
  const backlog = charts(view(FIXTURE))[3]
  assert.deepStrictEqual(sliceKeys(backlog), ['in_progress', 'pending'])
})

// 8. Static guards: no colour literal in progress.css (the contrast guard passes), no new dependency.
test('contrast guard passes and progress.css has no colour literal', () => {
  const guard = require('./check-theme-contrast.cjs')
  const css = fs.readFileSync(path.join(uiDir, 'src', 'components', 'progress', 'progress.css'), 'utf8')
  assert.deepStrictEqual(guard.findColourLiterals(css), [])
  const r = spawnSync(process.execPath, [path.join(__dirname, 'check-theme-contrast.cjs')], { encoding: 'utf8' })
  assert.strictEqual(r.status, 0, r.stdout + r.stderr)
  const src = fs.readFileSync(path.join(uiDir, 'src', 'components', 'progress', 'PieChart.jsx'), 'utf8') +
    fs.readFileSync(path.join(uiDir, 'src', 'components', 'progress', 'ProgressView.jsx'), 'utf8')
  assert.ok(!/#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(/.test(src.replace(/\/\*[\s\S]*?\*\//g, '')), 'no colour literal in the components')
})

test('no new dependency: imports are limited to d3-shape and existing packages', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(uiDir, 'package.json'), 'utf8'))
  assert.ok(pkg.dependencies['d3-shape'])
  const dir = path.join(uiDir, 'src', 'components', 'progress')
  for (const f of ['PieChart.jsx', 'ProgressView.jsx']) {
    for (const m of fs.readFileSync(path.join(dir, f), 'utf8').matchAll(/^import .* from '([^.'][^']*)'/gm)) {
      const name = m[1].startsWith('@') ? m[1].split('/').slice(0, 2).join('/') : m[1].split('/')[0]
      assert.ok(pkg.dependencies[name], `${f} imports ${name}, which is not a dependency`)
    }
  }
})

console.log(`progress-view: ${n} tests passed`)
