#!/usr/bin/env node
'use strict'
// E92_S04_T04: server-render test for PipelineDiagram / pipelineModel. Zero test framework: bundles the component with
// esbuild (CSS import stubbed), renders it with react-dom/server and asserts on the HTML, the technique of
// progress-view.test.cjs. Fixtures follow the GET /v1/pipeline body, the output of scripts/pipeline-stage.sh.
// Run: node project/app/ui/scripts/pipeline-diagram.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'pipeline-diagram-')), 'bundle.cjs')
esbuild.buildSync({
  stdin: {
    contents: `
      import React from 'react'
      import { renderToStaticMarkup } from 'react-dom/server'
      export { default as PipelineDiagram } from './src/components/progress/PipelineDiagram.jsx'
      export { buildPipelineModel, pipelineAriaLabel, IDLE_CAPTION, SNAPSHOT_CAPTION, ACTIVE_MARKER } from './src/components/progress/pipelineModel.js'
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
const { React, renderToStaticMarkup, PipelineDiagram, buildPipelineModel, pipelineAriaLabel } = mod
const render = (data, props) => renderToStaticMarkup(React.createElement(PipelineDiagram, { data, ...props }))

const IDLE_TEXT = 'Idle: nothing queued, running, awaiting test or waiting to roll up'
const SNAPSHOT_TEXT = 'Point-in-time snapshot: reflects the board when it was captured'
const LABELS = { todo: 'To do', do: 'Do', test: 'Test', rollup: 'Rollup' }

// A payload as scripts/pipeline-stage.sh prints it: stage order, `active` in stage order, idle when none.
const payload = (counts) => {
  const stages = ['todo', 'do', 'test', 'rollup'].map(id => ({ id, label: LABELS[id], count: counts[id] || 0, active: (counts[id] || 0) > 0 }))
  const active = stages.filter(s => s.active).map(s => s.id)
  return { schema_version: 1, stages, active, idle: active.length === 0, skipped: 0 }
}
const FIXTURES = {
  'only todo': { counts: { todo: 4 }, active: ['todo'] },
  'mid-run': { counts: { todo: 2, do: 1 }, active: ['todo', 'do'] },
  'awaiting test': { counts: { test: 2 }, active: ['test'] },
  'rollup pending': { counts: { rollup: 1 }, active: ['rollup'] },
  'several at once': { counts: { todo: 7, do: 3, test: 1, rollup: 2 }, active: ['todo', 'do', 'test', 'rollup'] },
}
const IDLE = payload({})

const stageHtml = (html) => html.split('<g class="pipeline-stage"').slice(1).map(s => '<g class="pipeline-stage"' + s.split('</g>')[0])
const idsOf = (html) => stageHtml(html).map(s => s.match(/data-stage="([a-z]+)"/)[1])
const rectOf = (g) => g.match(/<rect [^>]*>/)[0]
const count = (html, needle) => html.split(needle).length - 1

let n = 0
const test = (name, fn) => { fn(); n++; console.log('ok  ' + name) }

// 1. Four stages in order, exactly the active ones carrying marker, thicker outline and count.
for (const [name, f] of Object.entries(FIXTURES)) {
  test(`${name}: four stages in order; exactly the active ones carry the marker, thick outline and count`, () => {
    const html = render(payload(f.counts))
    assert.deepStrictEqual(idsOf(html), ['todo', 'do', 'test', 'rollup'])
    const gs = stageHtml(html)
    assert.strictEqual(gs.length, 4)
    assert.strictEqual(count(html, '● active'), f.active.length, 'marker count')
    gs.forEach((g, i) => {
      const id = ['todo', 'do', 'test', 'rollup'][i]
      const on = f.active.includes(id)
      const rect = rectOf(g)
      assert.ok(g.includes(`data-active="${on}"`), `${id} data-active`)
      assert.strictEqual(g.includes('● active'), on, `${id} marker`)
      assert.ok(rect.includes(on ? 'stroke-width="4"' : 'stroke-width="1"'), `${id} outline: ${rect}`)
      assert.strictEqual(rect.includes('var(--color-progress-in-progress)'), on, `${id} fill`)
      assert.ok(g.includes(`>${LABELS[id]}</text>`), `${id} label`)
      assert.ok(new RegExp(`class="pipeline-count"[^>]*>${f.counts[id] || 0}</text>`).test(g), `${id} count`)
    })
    assert.ok(!html.includes(IDLE_TEXT), 'no idle caption when something is active')
  })
}

// 2. Idle: four normal-state stages and the exact caption.
test('idle payload: four normal stages, no marker, the idle caption', () => {
  const html = render(IDLE)
  assert.deepStrictEqual(idsOf(html), ['todo', 'do', 'test', 'rollup'])
  assert.ok(html.includes(`<p class="pipeline-caption" data-caption="idle">${IDLE_TEXT}</p>`))
  assert.strictEqual(IDLE_TEXT, mod.IDLE_CAPTION)
  assert.ok(!html.includes('\u25CF'), 'no marker')
  assert.ok(!html.includes('var(--color-progress-in-progress)'))
  assert.strictEqual(count(html, 'stroke-width="1"'), 4)
  assert.ok(!html.includes('stroke-width="4"'))
  assert.ok(html.includes('aria-label="Jenga pipeline: no stage active (idle)."'))
})

// 3. pointInTime caption: present with the flag, absent without, independent of the stages.
test('pointInTime shows the snapshot caption; without it the caption is absent', () => {
  for (const data of [IDLE, payload(FIXTURES['mid-run'].counts)]) {
    assert.ok(render(data, { pointInTime: true }).includes(`<p class="pipeline-caption" data-caption="snapshot">${SNAPSHOT_TEXT}</p>`))
    assert.ok(!render(data).includes(SNAPSHOT_TEXT))
    assert.ok(!render(data, { pointInTime: false }).includes(SNAPSHOT_TEXT))
  }
  assert.strictEqual(SNAPSHOT_TEXT, mod.SNAPSHOT_CAPTION)
  // idle plus snapshot shows both captions
  const both = render(IDLE, { pointInTime: true })
  assert.ok(both.includes(IDLE_TEXT) && both.includes(SNAPSHOT_TEXT))
})

// 4. aria-label names the active stages; the svg is role="img".
test('aria-label names the active stages', () => {
  const label = (data) => render(data).match(/<svg [^>]*aria-label="([^"]+)"/)[1]
  assert.ok(render(IDLE).includes('role="img"'))
  assert.strictEqual(label(payload({ todo: 4 })), 'Jenga pipeline: To do (4) active.')
  assert.strictEqual(label(payload({ todo: 2, do: 1 })), 'Jenga pipeline: To do (2) and Do (1) active.')
  assert.strictEqual(label(payload(FIXTURES['several at once'].counts)), 'Jenga pipeline: To do (7), Do (3), Test (1) and Rollup (2) active.')
  const l = label(payload({ test: 2 }))
  assert.ok(l.includes('Test') && !l.includes('Rollup') && !l.includes('To do') && !/\bDo\b/.test(l))
})

// 5. Colour is not the only signal: marker text and outline attribute on the active stage, neither on a normal one.
test('active stage is marked by text and outline as well as fill', () => {
  const gs = stageHtml(render(payload({ do: 3 })))
  const active = gs[1], normal = gs[0]
  assert.ok(active.includes('>● active</text>'))
  assert.ok(active.includes('>3</text>'))
  assert.ok(rectOf(active).includes('stroke-width="4"') && rectOf(normal).includes('stroke-width="1"'))
  assert.ok(!normal.includes('●') && !rectOf(normal).includes('style='))
  // the marker is real text (not aria-hidden, not a pseudo element): present in the markup
  assert.ok(!/aria-hidden/.test(active.match(/<text [^>]*>● active/)[0]))
})

// 6. The model: order, tolerance of missing or malformed stages, derived idle.
test('model: fixed order, missing stage inactive with count 0, idle derived', () => {
  const shuffled = { stages: [{ id: 'rollup', count: 1, active: true }, { id: 'todo', label: 'To do', count: 2, active: true }] }
  const m = buildPipelineModel(shuffled)
  assert.deepStrictEqual(m.stages.map(s => s.id), ['todo', 'do', 'test', 'rollup'])
  assert.deepStrictEqual(m.stages.map(s => s.label), ['To do', 'Do', 'Test', 'Rollup'])
  assert.deepStrictEqual(m.stages[1], { id: 'do', label: 'Do', count: 0, active: false })
  assert.deepStrictEqual(m.stages[3], { id: 'rollup', label: 'Rollup', count: 1, active: true })
  assert.deepStrictEqual(m.active, ['todo', 'rollup'])
  assert.strictEqual(m.idle, false)
  for (const bad of [undefined, null, {}, [], 'x', { stages: 'x' }, { stages: [null, 5, {}] }]) {
    const b = buildPipelineModel(bad)
    assert.strictEqual(b.stages.length, 4)
    assert.deepStrictEqual(b.stages.map(s => [s.count, s.active]), [[0, false], [0, false], [0, false], [0, false]])
    assert.strictEqual(b.idle, true)
    assert.ok(render(bad).includes(IDLE_TEXT), 'a missing payload renders the idle state')
  }
  // a stage without an `active` flag is active when its count is above 0; a malformed count is 0
  assert.strictEqual(buildPipelineModel({ stages: [{ id: 'do', count: 2 }] }).stages[1].active, true)
  assert.strictEqual(buildPipelineModel({ stages: [{ id: 'do', count: -3 }] }).stages[1].count, 0)
  assert.strictEqual(buildPipelineModel({ stages: [{ id: 'do', count: '5' }] }).stages[1].active, false)
  assert.strictEqual(pipelineAriaLabel(buildPipelineModel(undefined)), 'Jenga pipeline: no stage active (idle).')
})

// 7. Static guards: no colour literal in the css or the components, the contrast guard passes, no network, no new dep.
test('contrast guard passes; only var(--color-*) tokens; no colour literal, no network reference', () => {
  const guard = require('./check-theme-contrast.cjs')
  const dir = path.join(uiDir, 'src', 'components', 'progress')
  const css = fs.readFileSync(path.join(dir, 'pipeline.css'), 'utf8')
  assert.deepStrictEqual(guard.findColourLiterals(css), [])
  const r = spawnSync(process.execPath, [path.join(__dirname, 'check-theme-contrast.cjs')], { encoding: 'utf8' })
  assert.strictEqual(r.status, 0, r.stdout + r.stderr)
  const strip = s => s.replace(/\/\*[\s\S]*?\*\//g, '')
  const jsx = strip(fs.readFileSync(path.join(dir, 'PipelineDiagram.jsx'), 'utf8'))
  const model = strip(fs.readFileSync(path.join(dir, 'pipelineModel.js'), 'utf8'))
  for (const [name, src] of [['PipelineDiagram.jsx', jsx], ['pipelineModel.js', model], ['pipeline.css', strip(css)]]) {
    assert.ok(!/#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(/.test(src), `${name}: colour literal`)
    assert.ok(!/https?:\/\/|\burl\(|fetch\(|XMLHttpRequest/.test(src), `${name}: network reference`)
    for (const m of src.matchAll(/(?:fill|stroke|color|background)\s*:\s*(?:'([^']*)'|([^;}',]+))/g)) {
      m[1] = m[1] !== undefined ? m[1] : m[2]
      assert.ok(/^(var\(--color-[a-z-]+\)|none|transparent|inherit|currentColor)\s*$/.test(m[1].trim()), `${name}: non-token colour value "${m[1]}"`)
    }
  }
  // every colour var the component and the css name exists in tokens.css
  const tokens = fs.readFileSync(path.join(uiDir, 'src', 'tokens.css'), 'utf8')
  for (const m of (jsx + css).matchAll(/var\((--color-[a-z-]+)\)/g)) assert.ok(tokens.includes(m[1] + ':'), `${m[1]} is not a token`)
  // imports: React is not even needed under the automatic runtime; nothing outside the package's own dependencies
  const pkg = JSON.parse(fs.readFileSync(path.join(uiDir, 'package.json'), 'utf8'))
  for (const f of ['PipelineDiagram.jsx', 'pipelineModel.js']) {
    for (const m of fs.readFileSync(path.join(dir, f), 'utf8').matchAll(/^import .* from '([^.'][^']*)'/gm)) {
      assert.ok(pkg.dependencies[m[1].split('/')[0]], `${f} imports ${m[1]}, which is not a dependency`)
    }
  }
})

console.log(`pipeline-diagram: ${n} tests passed`)
