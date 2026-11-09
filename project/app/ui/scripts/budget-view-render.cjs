#!/usr/bin/env node
'use strict'
// E76_S03_T07: server-render the dashboard's budget view for a board payload, with no browser and no server.
// Bundles src/components/budget/BudgetView.jsx with esbuild (CSS import stubbed) and renders it with
// react-dom/server, the same technique as findings-table.test.cjs.
//
// As a module:  const { renderBudgetView, boardFromSnapshotHtml } = require('./budget-view-render.cjs')
// As a CLI:     node budget-view-render.cjs <snapshot.html | snapshot.json | board.json>
//   Reads the board (`routes.board.data` of a capture artifact or of the `jenga-dashboard-data` JSON embedded
//   in a snapshot HTML, or a bare epics array) and prints the budget view's HTML. It prints nothing at all
//   when the board carries no usage field (the public-mirror guard: no view, no placeholder).
// It needs esbuild and react-dom from project/app/ui/node_modules (or project/app/node_modules).
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')

let cached = null
function load() {
  if (cached) return cached
  const esbuild = require('esbuild')
  const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'budget-view-')), 'bundle.cjs')
  esbuild.buildSync({
    stdin: {
      contents: `
        import React from 'react'
        import { renderToStaticMarkup } from 'react-dom/server'
        import BudgetView from './src/components/budget/BudgetView.jsx'
        export * from './src/components/budget/budgetModel.js'
        export { React, renderToStaticMarkup, BudgetView }
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
  cached = require(out)
  return cached
}

/** The budget view's static HTML for a `/v1/board` payload; '' when there is nothing to show. */
function renderBudgetView(epics) {
  const { React, renderToStaticMarkup, BudgetView } = load()
  return renderToStaticMarkup(React.createElement(BudgetView, { epics }))
}

/** The `routes.board.data` payload from the JSON a snapshot HTML embeds (or the capture artifact itself). */
function boardFromSnapshot(text) {
  const m = text.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)
  const parsed = JSON.parse(m ? m[1] : text)
  if (Array.isArray(parsed)) return parsed
  return parsed?.routes?.board?.data
}

module.exports = { renderBudgetView, boardFromSnapshot, load }

if (require.main === module) {
  const file = process.argv[2]
  if (!file) {
    console.error('usage: budget-view-render.cjs <snapshot.html | snapshot.json | board.json>')
    process.exit(2)
  }
  process.stdout.write(renderBudgetView(boardFromSnapshot(fs.readFileSync(file, 'utf8'))))
}
