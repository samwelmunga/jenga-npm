#!/usr/bin/env node
'use strict'
// E92_S12_T04: server-side render of the real epic tree over a CAPTURED snapshot payload, for tests/dashboard-snapshot-progress-graph.bats.
// Zero test framework and no DOM: bundles EpicTreeBody (the component the epic overlay renders from the graph it loaded; in a snapshot
// `get('/v1/progress-graph')` returns the embedded payload whole and the model selects the epic) with esbuild, CSS stubbed, DOMPurify stubbed
// (markdown is not under test), and renders it with react-dom/server. Prints ONE JSON object of facts read back from the markup, so a
// caller asserts on facts and not on a markup string:
//   { epic, empty, bands: [{ story, ghost, undecomposed }], starts: [{ story, ghost, undecomposed, text, aria, count }], taskNodes: [id],
//     goalText, ghostEdges, htmlBytes, goalDesign, castle, tree }
// E92_S13_T06: `--design <star|citadel|facade|tree|none>` chooses the goal design the way a browser does, through a stored choice: a stub
// `window.localStorage` that answers with that id (`none` = no storage at all, which must give the citadel, as in a file:// page with
// storage blocked; any other string is stored as is, so an unknown value must give the citadel too). Without the flag nothing is stubbed
// and the page's own default applies. The extra facts are read back from the markup: goalDesign (data-goal-design), castle { kind, towers,
// wallShare, dashed, effects } (the citadel and the facade) and tree { stage, branches, stubs, pills, effects } (the seasons tree).
// Usage: node render-captured-epic-tree.cjs --data <snapshot-data.json | snapshot.html> --epic <E##>
// A .html input is read the way the page reads it: the JSON in <script id="jenga-dashboard-data">, so the render input is what the file
// carries and nothing else (no server, no fetch).
const fs = require('fs')
const os = require('os')
const path = require('path')

function arg(name) {
  const i = process.argv.indexOf(name)
  return i > 0 ? process.argv[i + 1] : undefined
}
const dataFile = arg('--data')
const epic = arg('--epic')
const design = arg('--design')
if (!dataFile || !epic) {
  console.error('usage: render-captured-epic-tree.cjs --data <snapshot-data.json|snapshot.html> --epic <E##>')
  process.exit(2)
}

function readArtifact(file) {
  const text = fs.readFileSync(file, 'utf8')
  if (/\.html?$/i.test(file)) {
    const m = text.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/)
    if (!m) throw new Error('no embedded jenga-dashboard-data element in ' + file)
    return JSON.parse(m[1])
  }
  return JSON.parse(text)
}

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'render-captured-epic-tree-'))
const purify = path.join(tmp, 'purify-stub.js')
fs.writeFileSync(purify, 'export default { sanitize: html => html }')
const out = path.join(tmp, 'bundle.cjs')
async function main() {
  await esbuild.build({
    stdin: {
      contents: `
        import { renderToStaticMarkup } from 'react-dom/server'
        import { createElement as ce } from 'react'
        export { EpicTreeBody } from './src/components/history/EntryDetailPanel.jsx'
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
    plugins: [{ name: 'purify-stub', setup(b) { b.onResolve({ filter: /^dompurify$/ }, () => ({ path: purify })) } }],
    logLevel: 'silent',
  })
  const { EpicTreeBody, renderToStaticMarkup, ce } = require(out)

  const art = readArtifact(dataFile)
  const env = art.routes && art.routes.progressGraph
  if (!env || env.error || !env.data) {
    console.error('routes.progressGraph is missing or carries an error')
    process.exit(1)
  }
  // E92_S13_T06: the stored goal design, answered by a stub storage (set before the render, removed after it)
  if (design === 'none') {
    globalThis.window = { get localStorage() { throw new Error('storage blocked') } }
  } else if (design) {
    globalThis.window = { localStorage: { getItem: () => design, setItem() {}, removeItem() {} } }
  }
  const html = renderToStaticMarkup(ce(EpicTreeBody, { status: 'ok', graph: env.data, epicId: epic }))
  delete globalThis.window

  const attr = (tag, name) => { const m = tag.match(new RegExp(`\\b${name}="([^"]*)"`)); return m ? m[1] : null }
  const text = s => s.replace(/&amp;/g, '&').replace(/&#x27;/g, "'").replace(/&quot;/g, '"')
  const bands = [...html.matchAll(/<rect class="(dt-band[^"]*)"[^>]*data-story="([^"]+)"[^>]*>/g)].map(m => ({
    story: m[2], ghost: /\bdt-band-ghost\b/.test(m[1]), undecomposed: /data-undecomposed="true"/.test(m[0]),
  }))
  const starts = [...html.matchAll(/<g class="(dt-start[^"]*)"[^>]*data-start="([^"]+)"[^>]*>([\s\S]*?)<\/g>/g)].map(m => {
    const tag = m[0].slice(0, m[0].indexOf('>') + 1)
    const body = m[3]
    const t = body.match(/class="dt-start-ghost-text"[^>]*>([^<]*)</)
    const c = body.match(/class="dt-start-count"[^>]*>([^<]*)</)
    return {
      story: m[2], ghost: /\bdt-start-ghost\b/.test(m[1]), undecomposed: /data-undecomposed="true"/.test(tag),
      text: t ? text(t[1]) : null, aria: attr(tag, 'aria-label') ? text(attr(tag, 'aria-label')) : null, count: c ? c[1] : null,
    }
  })
  const goal = html.match(/class="dt-goal-count"[^>]*>([^<]*)</)
  const all = (re, i = 1) => [...html.matchAll(re)].map(m => m[i])
  const goalTag = html.match(/<g[^>]*data-goal-design="([^"]+)"[^>]*>/)
  const castleTag = html.match(/<g[^>]*data-castle="(citadel|facade)"[^>]*data-wall-share="([^"]*)"[^>]*>/)
  const treeTag = html.match(/<g[^>]*data-castle="tree"[^>]*data-stage="([^"]*)"[^>]*>/) || html.match(/<g[^>]*data-stage="([^"]*)"[^>]*data-castle="tree"[^>]*>/)
  const effects = [...new Set(all(/data-effect="([^"]+)"/g))]
  console.log(JSON.stringify({
    epic,
    empty: /class="dt-empty"/.test(html),
    bands,
    starts,
    taskNodes: [...html.matchAll(/data-node="([^"]+)"/g)].map(m => m[1]),
    goalText: goal ? text(goal[1]) : null,
    ghostEdges: (html.match(/dt-edge-ghost/g) || []).length,
    goalDesign: goalTag ? goalTag[1] : null,
    castle: castleTag ? {
      kind: castleTag[1],
      towers: all(/data-tower="([^"]+)"/g),
      wallShare: castleTag[2],
      dashed: all(/<g class="cc-tower cc-tower-undecomposed[^"]*"[^>]*data-tower="([^"]+)"/g).concat(all(/<g class="cc-tower cf-tower cc-tower-undecomposed[^"]*"[^>]*data-tower="([^"]+)"/g)),
      effects,
    } : null,
    tree: treeTag ? {
      stage: treeTag[1],
      branches: all(/data-branch="([^"]+)"/g),
      stubs: all(/data-stub="([^"]+)"/g),
      pills: (html.match(/class="tr-pill"/g) || []).length,
      effects,
    } : null,
    htmlBytes: html.length,
  }))
}
main().catch(e => { console.error(e && e.stack || e); process.exit(1) })
