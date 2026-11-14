#!/usr/bin/env node
'use strict'
// E92_S03_T07: server-render the dashboard's progress view for a snapshot's embedded data, with no browser and no
// server. Bundles src/components/progress/ProgressView.jsx with esbuild (CSS import stubbed) and renders it with
// react-dom/server, the same technique as budget-view-render.cjs.
//
// As a module:  const { renderProgressView, progressFromSnapshot } = require('./progress-view-render.cjs')
// As a CLI:     node progress-view-render.cjs [--pipeline | --tab] <snapshot.html | snapshot.json>
//   Reads `routes.progress.data` (the body of GET /v1/progress: { schema_version, charts }) from the
//   `jenga-dashboard-data` JSON embedded in a snapshot HTML, or from a capture artifact, and prints the
//   ProgressView HTML. It exits 1 with a message on stderr when the file carries no `routes.progress.data`
//   (a snapshot taken before E92_S03, or a route that failed), so a missing chart is never printed as a blank one.
//   --pipeline (E92_S04_T05) prints instead the PipelineDiagram for `routes.pipeline.data` (the body of GET /v1/pipeline),
//   with the point-in-time caption a snapshot shows; it exits 1 when the file carries no `routes.pipeline.data`.
//   --tab prints the Progress tab as a snapshot shows it: the pies, then the diagram, point-in-time; it exits 1 when
//   either payload is missing.
// It needs esbuild and react-dom from project/app/ui/node_modules (or project/app/node_modules).
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')

let cached = null
function load() {
  if (cached) return cached
  const esbuild = require('esbuild')
  const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'progress-view-render-')), 'bundle.cjs')
  esbuild.buildSync({
    stdin: {
      contents: `
        import React from 'react'
        import { renderToStaticMarkup } from 'react-dom/server'
        import ProgressView from './src/components/progress/ProgressView.jsx'
        import PipelineDiagram from './src/components/progress/PipelineDiagram.jsx'
        import { ProgressTabBody } from './src/tabs/ProgressTab.jsx'
        export { React, renderToStaticMarkup, ProgressView, PipelineDiagram, ProgressTabBody }
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
    define: { 'import.meta.env': '{}' }, // Vite-only; api/client.js (imported by ProgressTab.jsx) reads VITE_API_BASE_URL from it
    logLevel: 'silent',
  })
  cached = require(out)
  return cached
}

/** The progress view's static HTML for a `/v1/progress` data payload ({ schema_version, charts }). */
function renderProgressView(data) {
  const { React, renderToStaticMarkup, ProgressView } = load()
  return renderToStaticMarkup(React.createElement(ProgressView, { data }))
}

/**
 * The pipeline diagram's static HTML for a `/v1/pipeline` data payload. `pointInTime` defaults to true: this helper
 * renders snapshots, where `isEmbeddedSnapshot()` is true and the tab passes the flag to the diagram.
 */
function renderPipelineDiagram(data, { pointInTime = true } = {}) {
  const { React, renderToStaticMarkup, PipelineDiagram } = load()
  return renderToStaticMarkup(React.createElement(PipelineDiagram, { data, pointInTime }))
}

/** The Progress tab as a snapshot shows it (pies, then the diagram), from the two route payloads. */
function renderProgressTab({ progress, pipeline }, { pointInTime = true } = {}) {
  const { React, renderToStaticMarkup, ProgressTabBody } = load()
  return renderToStaticMarkup(React.createElement(ProgressTabBody, {
    loading: false, error: null, data: progress, pipeline: { loading: false, error: null, data: pipeline }, pointInTime,
  }))
}

/**
 * The `routes.progress.data` payload from the JSON a snapshot HTML embeds (or the capture artifact itself);
 * undefined when the artifact has none.
 */
function progressFromSnapshot(text) {
  const m = text.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)
  const parsed = JSON.parse(m ? m[1] : text)
  return parsed?.routes?.progress?.data
}

/** The `routes.pipeline.data` payload from the same JSON; undefined when the artifact has none. */
function pipelineFromSnapshot(text) {
  const m = text.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)
  const parsed = JSON.parse(m ? m[1] : text)
  return parsed?.routes?.pipeline?.data
}

module.exports = {
  renderProgressView, progressFromSnapshot, renderPipelineDiagram, pipelineFromSnapshot, renderProgressTab, load,
}

if (require.main === module) {
  const args = process.argv.slice(2)
  const mode = args.includes('--pipeline') ? 'pipeline' : args.includes('--tab') ? 'tab' : 'progress'
  const file = args.find(a => !a.startsWith('--'))
  if (!file) {
    console.error('usage: progress-view-render.cjs [--pipeline | --tab] <snapshot.html | snapshot.json>')
    process.exit(2)
  }
  const text = fs.readFileSync(file, 'utf8')
  const progress = progressFromSnapshot(text)
  const pipeline = pipelineFromSnapshot(text)
  const missing = []
  if (mode !== 'pipeline' && !progress) missing.push('routes.progress.data')
  if (mode !== 'progress' && !pipeline) missing.push('routes.pipeline.data')
  if (missing.length) {
    console.error('progress-view-render.cjs: ' + file + ' carries no ' + missing.join(' or '))
    process.exit(1)
  }
  process.stdout.write(
    mode === 'pipeline' ? renderPipelineDiagram(pipeline)
      : mode === 'tab' ? renderProgressTab({ progress, pipeline })
        : renderProgressView(progress),
  )
}
