#!/usr/bin/env node
'use strict'
// E92_S03_T06: test for the Progress tab (ProgressTab.jsx) and its registration in App.jsx. Zero test framework: bundles
// the components with esbuild (CSS import stubbed), renders with react-dom/server and asserts on the HTML, the technique
// of progress-view.test.cjs. Server rendering does not run effects, so the fetch is exercised through the tab's own
// `loadProgress(fetcher)` (what the effect calls) and the three states through `ProgressTabBody`, which is what
// `ProgressTab` renders from its state.
// Bundles: A takes a mocked `get`; B contains the real api/client.js and runs with a stubbed `document` carrying
// the embedded snapshot element (B, and C for an error envelope), to prove snapshot mode answers from routes.progress with no network call.
// E92_S04_T05 adds the pipeline diagram under the pies: loadPipeline, the two sections failing independently, the
// point-in-time caption (snapshot only) and client.js's isEmbeddedSnapshot().
// Run: node project/app/ui/scripts/progress-tab.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'progress-tab-'))

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
    define: { 'import.meta.env': '{}' }, // Vite-only; api/client.js reads VITE_API_BASE_URL from it
    logLevel: 'silent',
  })
  return out
}
const COMMON = `
  import React from 'react'
  import { renderToStaticMarkup } from 'react-dom/server'
  import ProgressTab, { loadProgress, loadPipeline, ProgressTabBody } from './src/tabs/ProgressTab.jsx'
  import { isEmbeddedSnapshot } from './src/api/client.js'
  export { React, renderToStaticMarkup, ProgressTab, loadProgress, loadPipeline, ProgressTabBody, isEmbeddedSnapshot }
`
const A = require(bundle('a', COMMON))
const { React, renderToStaticMarkup, ProgressTab, loadProgress, loadPipeline, ProgressTabBody, isEmbeddedSnapshot } = A
const render = (props) => renderToStaticMarkup(React.createElement(ProgressTabBody, props))

// Payload in the GET /v1/progress shape (E92_S03_T01), as in progress-view.test.cjs.
const block = (counts, totals) => ({ counts, totals })
const TASKS = block({ Passed: 4, 'In Progress': 1, Failed: 1, Pending: 2 },
  { done: 4, in_progress: 1, failed: 1, pending: 2, rejected: 0, unknown: 0, denominator: 8 })
const STORIES = block({ Passed: 2, Pending: 1 },
  { done: 2, in_progress: 0, failed: 0, pending: 1, rejected: 0, unknown: 0, denominator: 3 })
const EPICS = block({ Done: 3 },
  { done: 3, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0, denominator: 3 })
const BACKLOG = { tasks: block({ Pending: 2, 'In Progress': 1 },
  { done: 0, in_progress: 1, failed: 0, pending: 2, rejected: 0, unknown: 0, denominator: 3 }) }
const PAYLOAD = { schema_version: 1, charts: { tasks: TASKS, stories: STORIES, epics: EPICS, backlog: BACKLOG } }

// Payload in the GET /v1/pipeline shape (scripts/pipeline-stage.sh): one In Progress task and one queued story_rollup.
const PIPELINE = {
  schema_version: 1,
  stages: [
    { id: 'todo', label: 'To do', count: 0, active: false },
    { id: 'do', label: 'Do', count: 1, active: true },
    { id: 'test', label: 'Test', count: 0, active: false },
    { id: 'rollup', label: 'Rollup', count: 1, active: true },
  ],
  active: ['do', 'rollup'],
  idle: false,
  skipped: 0,
}
const PIPE_OK = { loading: false, error: null, data: PIPELINE }
const SNAP_CAPTION = 'Point-in-time snapshot'

const count = (html, needle) => html.split(needle).length - 1

let n = 0
const run = async (name, fn) => { await fn(); n++; console.log('ok  ' + name) }

;(async () => {
  await run('mocked get: the tab fetches /v1/progress and the state renders the four charts', async () => {
    const calls = []
    const result = await loadProgress(async (p) => { calls.push(p); return PAYLOAD })
    assert.deepStrictEqual(calls, ['/v1/progress'])
    assert.strictEqual(result.error, null)
    const html = render({ loading: false, ...result })
    assert.strictEqual(count(html, 'data-testid="progress-view"'), 1)
    assert.strictEqual(count(html, 'data-chart='), 4, html)
    for (const t of ['Tasks', 'Stories', 'Epics', 'Backlog']) assert.ok(html.includes('>' + t + '<'), 'missing chart ' + t)
    assert.ok(!html.includes('loading-spinner') && !html.includes('error-message'))
  })

  await run('first render of the tab itself is the shared loading state', () => {
    const html = renderToStaticMarkup(React.createElement(ProgressTab))
    assert.ok(html.includes('class="loading-spinner"'), html)
    assert.ok(!html.includes('progress-view') && !html.includes('error-message'))
    assert.ok(render({ loading: true, error: null, data: null }).includes('class="loading-spinner"'))
  })

  await run('failed fetch: ErrorMessage with the message, no throw, no charts (rejection and synchronous throw)', async () => {
    for (const fetcher of [
      () => Promise.reject(new Error('HTTP 500')),
      () => { throw new Error('HTTP 500') },
    ]) {
      const result = await loadProgress(fetcher) // must resolve, not reject
      assert.strictEqual(result.data, null)
      const html = render({ loading: false, ...result })
      assert.ok(html.includes('class="error-message"') && html.includes('HTTP 500'), html)
      assert.ok(!html.includes('progress-view') && !html.includes('loading-spinner'))
    }
  })

  await run('App.jsx registers the Progress tab (TABS entry, import, render switch); existing tabs still listed', () => {
    // App.jsx is not server-rendered here (it mounts the leave guard and fetches health/board); its registry is read as text.
    const src = fs.readFileSync(path.join(uiDir, 'src', 'App.jsx'), 'utf8')
    assert.ok(/import ProgressTab from '\.\/tabs\/ProgressTab'/.test(src), 'import missing')
    assert.ok(/\{ id: 'progress', label: 'Progress' \}/.test(src), 'TABS entry missing')
    assert.ok(/activeTab === 'progress' && <ProgressTab \/>/.test(src), 'render switch missing')
    const tabs = src.slice(src.indexOf('const TABS = ['), src.indexOf(']\n', src.indexOf('const TABS = [')))
    for (const id of ['board', 'active-sprint', 'history', 'architecture', 'rapports', 'documentation', 'security']) {
      assert.ok(tabs.includes(`id: '${id}'`), 'existing tab dropped: ' + id)
    }
    assert.strictEqual(count(tabs, "id: 'progress'"), 1)
  })

  await run('snapshot mode: renders from embedded routes.progress, with no network call', async () => {
    let fetches = 0
    global.fetch = () => { fetches++; return Promise.reject(new Error('network is off')) }
    const snapshot = { routes: { progress: { data: PAYLOAD, error: null } } }
    // api/client.js looks up this element once per page load (memoized), so set it before bundle B first calls get().
    global.document = { getElementById: (id) => id === 'jenga-dashboard-data' ? { textContent: JSON.stringify(snapshot) } : null }
    const B = require(bundle('b', COMMON))
    const result = await B.loadProgress() // default fetcher: the real api/client.js get()
    assert.strictEqual(fetches, 0, 'snapshot mode must not call fetch')
    assert.strictEqual(result.error, null)
    assert.deepStrictEqual(result.data, PAYLOAD)
    const html = B.renderToStaticMarkup(B.React.createElement(B.ProgressTabBody, { loading: false, ...result }))
    assert.strictEqual(count(html, 'data-chart='), 4)
    assert.strictEqual(fetches, 0)
  })

  await run('snapshot mode: an error envelope for routes.progress becomes the error state, still no network call', async () => {
    let fetches = 0
    global.fetch = () => { fetches++; return Promise.reject(new Error('network is off')) }
    const snapshot = { routes: { progress: { data: null, error: { message: 'progress unavailable' } } } }
    global.document = { getElementById: () => ({ textContent: JSON.stringify(snapshot) }) }
    const C = require(bundle('c', COMMON))
    const result = await C.loadProgress()
    assert.strictEqual(fetches, 0)
    const html = C.renderToStaticMarkup(C.React.createElement(C.ProgressTabBody, { loading: false, ...result }))
    assert.ok(html.includes('class="error-message"') && html.includes('progress unavailable'), html)
  })

  await run('mocked get: the tab also fetches /v1/pipeline; the diagram renders below the four pies', async () => {
    const calls = []
    const result = await loadPipeline(async (p) => { calls.push(p); return PIPELINE })
    assert.deepStrictEqual(calls, ['/v1/pipeline'])
    assert.strictEqual(result.error, null)
    const html = render({ loading: false, error: null, data: PAYLOAD, pipeline: { loading: false, ...result } })
    assert.strictEqual(count(html, 'data-chart='), 4)
    assert.strictEqual(count(html, 'data-testid="pipeline-diagram"'), 1)
    assert.ok(html.indexOf('data-testid="progress-view"') < html.indexOf('data-testid="pipeline-diagram"'), 'diagram must follow the pies')
    assert.ok(html.includes('data-stage="do" data-active="true"') && html.includes('data-stage="rollup" data-active="true"'))
    assert.ok(html.includes('data-stage="todo" data-active="false"') && html.includes('data-stage="test" data-active="false"'))
  })

  await run('failed pipeline fetch: ErrorMessage in the pipeline section only, the pies stay (rejection and throw)', async () => {
    for (const fetcher of [
      () => Promise.reject(new Error('pipeline HTTP 500')),
      () => { throw new Error('pipeline HTTP 500') },
    ]) {
      const result = await loadPipeline(fetcher) // must resolve, not reject
      assert.strictEqual(result.data, null)
      const html = render({ loading: false, error: null, data: PAYLOAD, pipeline: { loading: false, ...result } })
      assert.strictEqual(count(html, 'data-chart='), 4, 'the pies must survive a failed pipeline fetch')
      assert.strictEqual(count(html, 'class="error-message"'), 1, html)
      assert.ok(html.includes('pipeline HTTP 500') && !html.includes('pipeline-diagram'))
    }
  })

  await run('failed progress fetch with a good pipeline: the error shows for the pies, the diagram still renders', () => {
    const html = render({ loading: false, error: new Error('HTTP 500'), data: null, pipeline: PIPE_OK })
    assert.ok(html.includes('class="error-message"') && !html.includes('progress-view'))
    assert.strictEqual(count(html, 'data-testid="pipeline-diagram"'), 1)
  })

  await run('pipeline still loading: the diagram section shows the shared spinner while the pies render', () => {
    const html = render({ loading: false, error: null, data: PAYLOAD, pipeline: { loading: true, error: null, data: null } })
    assert.strictEqual(count(html, 'data-chart='), 4)
    assert.ok(html.includes('class="loading-spinner"') && !html.includes('pipeline-diagram'))
  })

  await run('point-in-time caption: shown with pointInTime, absent without it (live page)', () => {
    const live = render({ loading: false, error: null, data: PAYLOAD, pipeline: PIPE_OK, pointInTime: false })
    const dflt = render({ loading: false, error: null, data: PAYLOAD, pipeline: PIPE_OK })
    const snap = render({ loading: false, error: null, data: PAYLOAD, pipeline: PIPE_OK, pointInTime: true })
    assert.ok(!live.includes(SNAP_CAPTION) && !dflt.includes(SNAP_CAPTION), 'a live page must not carry the caption')
    assert.strictEqual(count(snap, 'data-caption="snapshot"'), 1)
    assert.ok(snap.includes(SNAP_CAPTION))
  })

  await run('isEmbeddedSnapshot: false with no document and with no embedded element', () => {
    delete global.document
    const live1 = require(bundle('live1', COMMON))
    assert.strictEqual(live1.isEmbeddedSnapshot(), false)
    global.document = { getElementById: () => null }
    const live2 = require(bundle('live2', COMMON))
    assert.strictEqual(live2.isEmbeddedSnapshot(), false)
    delete global.document
  })

  await run('isEmbeddedSnapshot: true when the embedded element is present, and the tab hands it to the diagram', async () => {
    let fetches = 0
    global.fetch = () => { fetches++; return Promise.reject(new Error('network is off')) }
    const snapshot = { routes: { progress: { data: PAYLOAD, error: null }, pipeline: { data: PIPELINE, error: null } } }
    global.document = { getElementById: (id) => id === 'jenga-dashboard-data' ? { textContent: JSON.stringify(snapshot) } : null }
    const D = require(bundle('d', COMMON))
    assert.strictEqual(D.isEmbeddedSnapshot(), true)
    const [progress, pipeline] = await Promise.all([D.loadProgress(), D.loadPipeline()])
    assert.strictEqual(fetches, 0, 'snapshot mode must not call fetch')
    assert.deepStrictEqual(pipeline.data, PIPELINE)
    const html = D.renderToStaticMarkup(D.React.createElement(D.ProgressTabBody, {
      loading: false, ...progress, pipeline: { loading: false, ...pipeline }, pointInTime: D.isEmbeddedSnapshot(),
    }))
    assert.strictEqual(count(html, 'data-chart='), 4)
    assert.ok(html.includes(SNAP_CAPTION))
    assert.strictEqual(fetches, 0)
  })

  await run('snapshot mode: an error envelope for routes.pipeline fails that section only', async () => {
    global.fetch = () => Promise.reject(new Error('network is off'))
    const snapshot = { routes: { progress: { data: PAYLOAD, error: null }, pipeline: { data: null, error: { message: 'pipeline unavailable' } } } }
    global.document = { getElementById: () => ({ textContent: JSON.stringify(snapshot) }) }
    const E = require(bundle('e', COMMON))
    const [progress, pipeline] = await Promise.all([E.loadProgress(), E.loadPipeline()])
    const html = E.renderToStaticMarkup(E.React.createElement(E.ProgressTabBody, {
      loading: false, ...progress, pipeline: { loading: false, ...pipeline }, pointInTime: true,
    }))
    assert.strictEqual(count(html, 'data-chart='), 4)
    assert.ok(html.includes('class="error-message"') && html.includes('pipeline unavailable') && !html.includes('pipeline-diagram'))
  })

  console.log(`\n${n} progress-tab tests passed`)
})().catch((err) => { console.error(err); process.exit(1) })
