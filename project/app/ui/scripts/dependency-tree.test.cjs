#!/usr/bin/env node
'use strict'
// E92_S06_T10 / E92_S06_T20: render test for DependencyTree (tree v2). Zero test framework and no DOM: the component is
// bundled with esbuild (CSS import stubbed) twice. Once with real React and react-dom/server (static render), once with
// `react` swapped, for the component sources only, for a tiny hook runtime (technique of epic-overlay-tree.test.cjs) so
// hover, focus, click and Enter can be driven through the handlers the component really sets, and the result is
// rendered to markup. The CSS and the JSX are parsed as text for the reduced-motion and no-colour-literal rules.
// E92_S13_T02: the citadel is now the DEFAULT goal design. The tests written for the star (halo, ring, sparks, the goal edge
// inset, the star's text positions) pin the star: they render with a star-only registry and a model laid out for the star's
// fixed disc area ({ goalArea: 'disc' }), which is byte-identical to the layout they were written against. The citadel's own
// tests (its states, stacking, bridge, roof and battlements, lean, foundation, labels, edges, pure SVG) are at the end, and
// render with the real registry and the castle layout.
// Run: node project/app/ui/scripts/dependency-tree.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { pathToFileURL } = require('url')

const uiDir = path.join(__dirname, '..')
const compDir = path.join(uiDir, 'src', 'components', 'progress')
const esbuild = require('esbuild')
const css = fs.readFileSync(path.join(compDir, 'dependency-tree.css'), 'utf8')
const jsx = fs.readFileSync(path.join(compDir, 'DependencyTree.jsx'), 'utf8')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dependency-tree-'))
const nodePaths = [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')]
const entry = `
  import React from 'react'
  import { renderToStaticMarkup } from 'react-dom/server'
  export { default as DependencyTree } from './src/components/progress/DependencyTree.jsx'
  export { buildDependencyTreeModel, unfoldGroups, FOLD_THRESHOLD, GOAL_NODE_ID, LAYOUT } from './src/components/progress/dependencyTreeModel.js'
  export { default as StarGoal } from './src/components/progress/StarGoal.jsx'
  export { GOAL_RENDERERS } from './src/components/progress/goalDesigns.js'
  export * as dayNight from './src/components/progress/dayNightModel.js'
  export { React, renderToStaticMarkup }
`
const build = (fn, outfile, plugins) => fn({
  stdin: { contents: entry, resolveDir: uiDir, loader: 'jsx' },
  outfile, bundle: true, platform: 'node', format: 'cjs', jsx: 'automatic', nodePaths, loader: { '.css': 'empty' }, logLevel: 'silent', plugins,
})
const outReal = path.join(tmp, 'real.cjs')
build(esbuild.buildSync, outReal)
const shim = path.join(tmp, 'react-shim.js')
fs.writeFileSync(shim, `
  import * as R from ${JSON.stringify(require.resolve('react', { paths: [uiDir] }))}
  const h = () => globalThis.__h
  export const useState = init => h().useState(init)
  export const useRef = init => h().useRef(init)
  export const useEffect = (fn, deps) => h().useEffect(fn, deps)
  export default { ...R }
  export const createElement = R.createElement
  export const Fragment = R.Fragment
`)
const outHook = path.join(tmp, 'hook.cjs')
const hookBuilt = build(esbuild.build, outHook, [{
  name: 'react-hook-shim',
  setup(b) { b.onResolve({ filter: /^react$/ }, a => (a.importer.includes(path.sep + 'src' + path.sep) ? { path: shim } : null)) },
}])
const REAL = require(outReal)
const { React, renderToStaticMarkup, unfoldGroups, FOLD_THRESHOLD, LAYOUT, StarGoal, GOAL_RENDERERS, dayNight } = REAL
const STAR_ONLY = Object.freeze({ star: StarGoal })
const CitadelTree = REAL.DependencyTree // the real registry: the citadel is the default design
const buildCastleModelOf = REAL.buildDependencyTreeModel // the castle layout (the default goal area)
const DependencyTree = props => CitadelTree({ renderers: STAR_ONLY, ...props })
const buildDependencyTreeModel = (g, id, l, o) => REAL.buildDependencyTreeModel(g, id, l, { goalArea: 'disc', ...o })
let hook // set once the hook bundle is built

/** Minimal hook runtime: one component instance, state slots; a setter re-renders the component. */
function mount(Comp, initialProps) {
  const props = initialProps
  const slots = []
  let i = 0
  let output
  globalThis.__h = {
    useState(init) {
      const k = i++
      if (!(k in slots)) slots[k] = typeof init === 'function' ? init() : init
      return [slots[k], v => { slots[k] = v; render() }]
    },
    // E92_S06_T21: useZoomPan keeps a ref and effects; the refs persist, the effects (measuring, fitting) need a DOM and do not run here
    useRef(init) {
      const k = i++
      if (!(k in slots)) slots[k] = { current: init }
      return slots[k]
    },
    useEffect() { i++ },
  }
  function render() { i = 0; output = Comp(props) }
  render()
  const all = (node, pred, acc = []) => {
    if (Array.isArray(node)) { node.forEach(c => all(c, pred, acc)); return acc }
    if (!node || typeof node !== 'object' || !node.props) return acc
    if (pred(node)) acc.push(node)
    all(node.props.children, pred, acc)
    return acc
  }
  const byAttr = (name, value) => all(output, el => el.props && el.props[name] === value)[0]
  return {
    html: () => renderToStaticMarkup(output),
    node: id => byAttr('data-node', id),
    header: id => byAttr('data-toggle', id),
    fire: (el, handler, arg) => { assert.ok(el && typeof el.props[handler] === 'function', `no ${handler} handler`); el.props[handler](arg) },
  }
}

const EN = {
  goal: 'Goal', ready_to_take: 'Ready to take', nothing_ready: 'Nothing ready', tree_empty: 'No tasks to show',
  unlocked_by: '%s unlocked by %s', state_done: 'Done', state_ready: 'Ready', state_locked: 'Locked',
  state_failed: 'Failed', state_rejected: 'Rejected', in_progress: 'In progress',
  gate_waiting: 'Waiting for a dependency (locked)', gate_open: 'Dependency done (unlocked)', group_tasks: '%d tasks',
  show_all: 'Show all %d', collapse: 'Collapse', goal_reached: 'Goal reached!', goal_progress: '%d / %d done · %d %%', epic_decomposed: '%d/%d stories decomposed',
  tip_depends_on: 'Depends on', tip_unlocks: 'Unlocks', tip_goal_direct: 'Leads straight to the goal',
}
const SV = {
  goal: 'Mål', ready_to_take: 'Redo att ta', nothing_ready: 'Inget redo', tree_empty: 'Inga uppgifter att visa',
  unlocked_by: '%s låstes upp av %s', state_done: 'Klar', state_ready: 'Redo', state_locked: 'Låst',
  state_failed: 'Misslyckad', state_rejected: 'Avvisad', in_progress: 'Pågår',
  gate_waiting: 'Väntar på beroende (låst)', gate_open: 'Beroendet är klart (upplåst)', group_tasks: '%d uppgifter',
  show_all: 'Visa alla %d', collapse: 'Fäll ihop', goal_reached: 'Mål nått!', goal_progress: '%d / %d klara · %d %%', epic_decomposed: '%d/%d berättelser nedbrutna',
  tip_depends_on: 'Beror på', tip_unlocks: 'Låser upp', tip_goal_direct: 'Leder direkt till målet',
}
const BUCKET = { done: 'done', in_progress: 'in_progress', ready: 'pending', locked: 'pending', failed: 'failed', rejected: 'rejected' }
const T = (id, story, state, deps, unlockedBy) => ({
  id, story_id: story, epic_id: 'E01', title: 'Title ' + id, status: 'x', bucket: BUCKET[state], state,
  depends_on: deps || [], blocked_by: [], unlocked_by: unlockedBy || null,
})
const graph = (tasks, labels, stories) => ({
  schema_version: 1, labels, epics: [{ id: 'E01', title: 'Goal epic' }],
  stories: stories || [{ id: 'E01_S01', epic_id: 'E01', title: 'First' }, { id: 'E01_S02', epic_id: 'E01', title: 'Second' }],
  tasks, external: null,
})
const S1 = 'E01_S01'
const S2 = 'E01_S02'
const ALL = [
  T('E01_S01_T01', S1, 'done', []),
  T('E01_S01_T02', S1, 'in_progress', ['E01_S01_T01'], 'E01_S01_T01'),
  T('E01_S01_T03', S1, 'ready', ['E01_S01_T01'], 'E01_S01_T01'),
  T('E01_S02_T01', S2, 'locked', ['E01_S01_T02']),
  T('E01_S02_T02', S2, 'failed', []),
  T('E01_S02_T03', S2, 'rejected', []),
  T('E01_S02_T04', S2, 'ready', []),
]
// Six same-state tasks in one column of one story fold into one group; one cross-story dependent hangs off it.
const GROUPED = [
  T('E01_S01_T01', S1, 'done', []),
  ...[1, 2, 3, 4, 5, 6].map(n => T('E01_S01_T1' + n, S1, 'done', ['E01_S01_T01'])),
  T('E01_S01_T20', S1, 'ready', ['E01_S01_T01']),
  T('E01_S02_T01', S2, 'locked', ['E01_S01_T11']),
]
const GROUP = 'group:E01_S01|1|done'
const model = (g, labels) => buildDependencyTreeModel(g, 'E01', labels)
const mountTree = (g, labels) => mount(props => hook.DependencyTree({ renderers: STAR_ONLY, ...props }), { model: hook.buildDependencyTreeModel(g, 'E01', labels, { goalArea: 'disc' }), labels })
const render = (g, labels) => renderToStaticMarkup(React.createElement(DependencyTree, { model: model(g, labels), labels }))

/** The markup of one card: from its data-node attribute to the next card, the goal or the next collapse header. */
function nodeHtml(html, id) {
  const start = html.indexOf(`data-node="${id}"`)
  assert.ok(start >= 0, 'node ' + id)
  const ends = [html.indexOf('data-node="', start + 1), html.indexOf('data-goal="', start + 1)].filter(x => x > 0)
  return html.slice(start, Math.min(...ends))
}
/** The class attribute of one card (React writes className before data-node). */
const classOf = (html, id) => html.match(new RegExp(`class="([^"]*)" data-node="${id}"`))[1]
/** The markup of the tooltip (from its own class to the end of the stage). */
const tipOf = html => html.slice(html.indexOf('class="dt-tip'), html.indexOf('data-testid="dt-ready"'))
const count = (s, re) => (s.match(re) || []).length
const stripComments = s => s.replace(/\/\*[\s\S]*?\*\//g, '')

;(async () => {
  await hookBuilt
  hook = require(outHook)
  let n = 0
  const test = (name, fn) => { fn(); n++; console.log('ok  ' + name) }

  test('one band and one start node per story; the start node carries id, done/total, title and a bar', () => {
    const html = render(graph(ALL, EN), EN)
    assert.strictEqual(count(html, /class="dt-band( |")/g), 2)
    assert.strictEqual(count(html, /class="dt-start( |")/g), 2)
    const s1 = html.split('data-start="E01_S01"')[1].split('</g>')[0]
    assert.ok(s1.includes('>E01_S01<') && s1.includes('>First<'))
    assert.ok(/class="dt-start-count"[^>]*>\d\/\d</.test(s1), 'done/total text')
    assert.ok(s1.includes('dt-start-bar'), 'mini bar')
  })

  test('tasks without an in-epic dependency originate at their story start node; edges are drawn after the band fills', () => {
    const html = render(graph(ALL, EN), EN)
    for (const id of ['E01_S01_T01', 'E01_S02_T02', 'E01_S02_T03', 'E01_S02_T04']) {
      const sid = id.slice(0, 7)
      assert.ok(html.includes(`data-from="story:${sid}" data-to="${id}"`), 'start edge ' + id)
    }
    assert.ok(!html.includes('data-to="E01_S01_T02" data-kind="start"') && !/data-from="story:E01_S01" data-to="E01_S01_T02"/.test(html), 'a task with a dependency does not hang off the start node')
    const lastBand = html.lastIndexOf('class="dt-band')
    const firstEdge = html.indexOf('class="dt-edge ')
    const firstCard = html.indexOf('data-node=')
    assert.ok(lastBand > 0 && firstEdge > lastBand, 'edges after (above) the bands in paint order')
    assert.ok(firstCard > html.lastIndexOf('class="dt-edge '), 'cards after the edges')
    assert.ok(html.indexOf('class="dt-bands') < html.indexOf('class="dt-edges"'))
  })

  test('edges run dependency to dependent; cross-story edges are dotted; only tasks nothing depends on reach the goal', () => {
    const html = render(graph(ALL, EN), EN)
    assert.ok(html.includes('data-from="E01_S01_T01" data-to="E01_S01_T02"'))
    assert.ok(!html.includes('data-from="E01_S01_T02" data-to="E01_S01_T01"'))
    const edge = (from, to) => html.match(new RegExp(`<path class="([^"]*)" data-from="${from}" data-to="${to}"`))
    assert.ok(/dt-edge-cross/.test(edge('E01_S01_T02', 'E01_S02_T01')[1]), 'cross-story edge dotted')
    assert.ok(!/dt-edge-cross/.test(edge('E01_S01_T01', 'E01_S01_T02')[1]), 'same-story edge solid')
    const toGoal = [...html.matchAll(/data-from="([^"]+)" data-to="goal"/g)].map(m => m[1]).sort()
    assert.deepStrictEqual(toGoal, ['E01_S01_T03', 'E01_S02_T01', 'E01_S02_T02', 'E01_S02_T03', 'E01_S02_T04'])
    assert.ok(!toGoal.includes('E01_S01_T01') && !toGoal.includes('E01_S01_T02'), 'tasks with dependents do not')
  })

  test('edge geometry: from the right edge of the dependency to the left edge (gate included) of the dependent', () => {
    const m = model(graph(ALL, EN), EN)
    const html = renderToStaticMarkup(React.createElement(DependencyTree, { model: m, labels: EN }))
    const d = html.match(/data-from="E01_S01_T01" data-to="E01_S01_T02"[^>]* d="([^"]+)"/)[1]
    const from = m.nodes.find(x => x.id === 'E01_S01_T01')
    const to = m.nodes.find(x => x.id === 'E01_S01_T02')
    assert.ok(d.startsWith(`M${from.x + LAYOUT.cardW} ${from.y + LAYOUT.cardH / 2} `), d)
    assert.ok(d.endsWith(` ${to.x - LAYOUT.gateR} ${to.y + LAYOUT.cardH / 2}`), d)
  })

  test('gates: none without a dependency, closed while waiting, open when every dependency is done', () => {
    const html = render(graph(ALL, EN), EN)
    const none = ['E01_S01_T01', 'E01_S02_T02', 'E01_S02_T03', 'E01_S02_T04']
    for (const id of none) assert.ok(!nodeHtml(html, id).includes('class="dt-gate'), id + ' has no gate')
    assert.ok(nodeHtml(html, 'E01_S02_T01').includes('data-gate="closed"'), 'waiting task: closed gate')
    assert.ok(nodeHtml(html, 'E01_S01_T03').includes('data-gate="open"'), 'ready task with done dependency: open gate')
    assert.ok(nodeHtml(html, 'E01_S01_T02').includes('data-gate="open"'), 'in-progress task with done dependency: open gate')
    assert.ok(nodeHtml(html, 'E01_S02_T01').includes('<title>Waiting for a dependency (locked)</title>'))
    assert.ok(nodeHtml(html, 'E01_S01_T03').includes('<title>Dependency done (unlocked)</title>'))
  })

  test('status marks on the right: tick, half dot, plus, cross; a locked task has the closed gate and no mark', () => {
    const html = render(graph(ALL, EN), EN)
    const expect = { E01_S01_T01: 'done', E01_S01_T02: 'in_progress', E01_S01_T03: 'ready', E01_S02_T02: 'failed', E01_S02_T03: 'rejected', E01_S02_T04: 'ready' }
    for (const [id, mark] of Object.entries(expect)) {
      const h = nodeHtml(html, id)
      assert.ok(h.includes(`data-mark="${mark}"`), id + ' mark ' + mark)
      assert.ok(h.includes(`translate(${LAYOUT.cardW - 22} ${LAYOUT.cardH / 2})`), id + ' mark on the right')
    }
    // every ready task shows the plus, with or without a dependency
    assert.ok(nodeHtml(html, 'E01_S01_T03').includes('dt-mark-plus') && nodeHtml(html, 'E01_S02_T04').includes('dt-mark-plus'))
    const locked = nodeHtml(html, 'E01_S02_T01')
    assert.ok(locked.includes('data-state="locked"') && !locked.includes('data-mark='), 'locked: no status mark')
    assert.ok(!locked.includes('dt-mark-plus') && locked.includes('data-gate="closed"'))
    const marks = new Set(Object.keys(expect).map(id => nodeHtml(html, id).match(/data-mark="[a-z_]+"[^>]*>(.*?)<\/g>/s)[0].replace(/ready|done/g, '')).values())
    assert.ok(marks.size >= 4, 'distinct marks')
    assert.ok(nodeHtml(html, 'E01_S01_T02').includes('M0 -7 A7 7 0 0 1 0 7 Z'), 'half dot')
    assert.ok(nodeHtml(html, 'E01_S02_T02').includes('M-5.5 -5.5 L5.5 5.5 M5.5 -5.5 L-5.5 5.5'), 'cross')
  })

  test('E92_S09_T02: every startable task is drawn ready (dashed state class, ring, plus); the padlock is the only difference', () => {
    const tasks = [
      T('E01_S01_T01', S1, 'done', []),
      T('E01_S01_T02', S1, 'ready', []), // never had a dependency
      T('E01_S01_T03', S1, 'ready', ['E01_S01_T01'], 'E01_S01_T01'), // every dependency done
      { ...T('E01_S02_T01', S2, 'locked', ['E01_S01_T01']), blocked_by: ['E01_S01'] }, // own done, its story still waits
      { ...T('E01_S02_T02', S2, 'locked', []), blocked_by: ['E01_S01'] }, // locked only through its story
    ]
    const stories = [
      { id: S1, epic_id: 'E01', title: 'First', depends_on: [] },
      { id: S2, epic_id: 'E01', title: 'Second', depends_on: ['E01_S01'] },
    ]
    const html = render(graph(tasks, EN, stories), EN)
    for (const id of ['E01_S01_T02', 'E01_S01_T03']) {
      const h = nodeHtml(html, id)
      assert.ok(/(^| )dt-state-ready( |$)/.test(classOf(html, id)), id + ': ready class (dashed border)')
      assert.ok(h.includes('class="dt-ring"'), id + ': ready ring')
      assert.ok(h.includes('dt-mark-plus') && h.includes('data-mark="ready"'), id + ': plus mark')
    }
    assert.ok(!nodeHtml(html, 'E01_S01_T02').includes('class="dt-gate'), 'no dependency: no padlock')
    assert.ok(nodeHtml(html, 'E01_S01_T03').includes('data-gate="open"'), 'dependencies done: open padlock')
    // the two cards differ only by the padlock: strip the gate badge, the id and the title, and the markup is the same
    const bare = id => nodeHtml(html, id)
      .replace(/<g class="[^"]*" $/, '') // the start of the next card
      .replace(/<g class="dt-gate[\s\S]*?<\/g><\/g>/, '')
      .replace(new RegExp(id, 'g'), 'ID').replace(/ transform="translate\([^)]*\)"/, '')
      .replace(/ x="(12|18)"/g, ' x="X"').replace(/ \(Dependency done \(unlocked\)\)/, '')
      .replace(/(<\/g>)+$/, '') // the card's own closing tags
    assert.strictEqual(bare('E01_S01_T02'), bare('E01_S01_T03'))
    // a locked task never gets the ready style, and one locked through its story shows the closed padlock
    for (const id of ['E01_S02_T01', 'E01_S02_T02']) {
      const h = nodeHtml(html, id)
      assert.ok(!/dt-state-ready/.test(classOf(html, id)) && !h.includes('class="dt-ring"') && !h.includes('dt-mark-plus'), id + ': not ready-styled')
      assert.ok(h.includes('data-gate="closed"'), id + ': closed padlock')
    }
  })

  test('every state keeps an accessible name built from the state word, the id and the title', () => {
    const html = render(graph(ALL, EN), EN)
    const expect = { E01_S01_T01: 'Done', E01_S01_T02: 'In progress', E01_S01_T03: 'Ready', E01_S02_T01: 'Locked', E01_S02_T02: 'Failed', E01_S02_T03: 'Rejected' }
    for (const [id, name] of Object.entries(expect)) {
      assert.ok(nodeHtml(html, id).includes(`aria-label="${name}: ${id} Title ${id}`), id)
    }
    assert.ok(nodeHtml(html, 'E01_S02_T01').includes('(Waiting for a dependency (locked))'), 'gate in the name')
  })

  // The final prototype values (tree-prototype.html, lockIcon): the open shackle sits about 1 px lower than the first version.
  const OPEN_SHACKLE = 'M-2.8 0 V-3.4 A2.8 2.8 0 0 1 2.8 -3.4 V-2.3'
  const CLOSED_SHACKLE = 'M-2.8 0 V-2.6 A2.8 2.8 0 0 1 2.8 -2.6 V0'

  test('the padlock path values are the prototype\'s final ones; the open shackle lies inside the badge circle', () => {
    const html = render(graph(ALL, EN), EN)
    const open = nodeHtml(html, 'E01_S01_T03').match(/<g class="dt-gate[^>]*data-gate="open"[\s\S]*?<\/g><\/g>/)[0]
    const closed = nodeHtml(html, 'E01_S02_T01').match(/<g class="dt-gate[^>]*data-gate="closed"[\s\S]*?<\/g><\/g>/)[0]
    assert.ok(open.includes(`d="${OPEN_SHACKLE}"`) && closed.includes(`d="${CLOSED_SHACKLE}"`))
    assert.ok(open.includes('<g transform="translate(0 -1)">') && open.includes('x="-4.5" y="0" width="9" height="6.5" rx="1.5"'))
    const prototype = path.join(__dirname, '..', '..', '..', 'documentation', 'prototypes', 'E92_S06', 'tree-prototype.html')
    const repoPrototype = path.join(__dirname, '..', '..', '..', '..', 'project', 'documentation', 'prototypes', 'E92_S06', 'tree-prototype.html')
    for (const f of [prototype, repoPrototype]) {
      if (fs.existsSync(f)) { const p = fs.readFileSync(f, 'utf8'); assert.ok(p.includes(OPEN_SHACKLE) && p.includes(CLOSED_SHACKLE), 'prototype values') }
    }
    // geometry: the shackle is M V A V with a semicircle (the end points are one diameter apart), stroked
    const r = Number(open.match(/<circle class="dt-gate-disc" r="([\d.]+)"/)[1])
    const stroke = Number(css.match(/\.dt-lock-shackle\s*\{[^}]*stroke-width:\s*([\d.]+)/)[1])
    const lift = Number(open.match(/<g transform="translate\(0 (-?[\d.]+)\)">/)[1])
    // OPEN_SHACKLE = M mx my V vy A rx ry rot large sweep ex ey V vy2: a semicircle (the end points are one diameter apart)
    const [mx, my, vy, rx, , , , , ex, ey, vy2] = OPEN_SHACKLE.match(/-?\d+(\.\d+)?/g).map(Number)
    assert.ok(Math.abs(ex - mx - 2 * rx) < 1e-9, 'end points one diameter apart')
    const top = vy - rx // sweep 1, left to right: over the top
    const xs = [mx, ex]
    const ys = [my, vy, ey, top, vy2]
    const half = stroke / 2
    const box = { x0: Math.min(...xs) - half, x1: Math.max(...xs) + half, y0: Math.min(...ys) + lift - half, y1: Math.max(...ys) + lift + half }
    for (const [x, y] of [[box.x0, box.y0], [box.x1, box.y0], [box.x0, box.y1], [box.x1, box.y1]]) {
      assert.ok(Math.hypot(x, y) < r, `shackle bbox corner (${x}, ${y}) inside the badge circle of radius ${r}`)
    }
    assert.ok(box.y0 > -r, 'top of the shackle below the top of the circle')
  })

  test('hover highlights the whole upstream and downstream chain and dims the rest', () => {
    const g = graph([
      T('E01_S01_T01', S1, 'done', []), T('E01_S01_T02', S1, 'done', ['E01_S01_T01']), T('E01_S01_T03', S1, 'ready', ['E01_S01_T02']),
      T('E01_S02_T01', S2, 'done', []), T('E01_S02_T02', S2, 'ready', ['E01_S02_T01']),
    ], EN)
    const m = mountTree(g, EN)
    assert.ok(!m.html().includes('dt-dim'), 'nothing dimmed at rest')
    m.fire(m.node('E01_S01_T02'), 'onPointerEnter')
    const html = m.html()
    const dimmed = id => /dt-dim/.test(classOf(html, id))
    for (const id of ['E01_S01_T01', 'E01_S01_T02', 'E01_S01_T03']) assert.ok(!dimmed(id), id + ' in the chain')
    for (const id of ['E01_S02_T01', 'E01_S02_T02']) assert.ok(dimmed(id), id + ' dimmed')
    assert.ok(/dt-hl/.test(classOf(html, 'E01_S01_T02')), 'hovered card highlighted')
    assert.ok(/class="dt-edge[^"]*dt-edge-dim"[^>]*data-from="E01_S02_T01" data-to="E01_S02_T02"/.test(html), 'edge of the other chain dimmed')
    assert.ok(!/dt-edge-dim"[^>]*data-from="E01_S01_T01" data-to="E01_S01_T02"/.test(html), 'edge of this chain kept')
    m.fire(m.node('E01_S01_T02'), 'onPointerLeave')
    assert.ok(!m.html().includes('dt-dim') && !m.html().includes('dt-tip'), 'leaving restores everything')
  })

  test('keyboard focus does the same as hover and blur clears it', () => {
    const m = mountTree(graph(ALL, EN), EN)
    m.fire(m.node('E01_S02_T01'), 'onFocus')
    const html = m.html()
    assert.ok(/dt-dim/.test(classOf(html, 'E01_S02_T04')) && /dt-hl/.test(classOf(html, 'E01_S02_T01')))
    assert.ok(html.includes('data-tip-for="E01_S02_T01"'))
    assert.ok(nodeHtml(html, 'E01_S02_T01').includes('tabindex="0"'), 'cards are focusable')
    m.fire(m.node('E01_S02_T01'), 'onBlur')
    assert.ok(!m.html().includes('dt-dim'))
  })

  test('tooltip lists depends on, unlocks, and "leads straight to the goal" when nothing is downstream', () => {
    const m = mountTree(graph(ALL, EN), EN)
    m.fire(m.node('E01_S01_T02'), 'onPointerEnter')
    let tip = tipOf(m.html())
    assert.ok(tip.includes('E01_S01_T02 · In progress') && tip.includes('Depends on') && tip.includes('E01_S01_T01 ✓'), 'depends on, done marked')
    assert.ok(tip.includes('Unlocks') && tip.includes('E01_S02_T01') && !tip.includes('Leads straight'), 'unlocks')
    m.fire(m.node('E01_S02_T01'), 'onPointerEnter')
    tip = tipOf(m.html())
    assert.ok(tip.includes('Leads straight to the goal') && !tip.includes('Unlocks'), 'nothing downstream')
    m.fire(m.node('E01_S02_T04'), 'onPointerEnter')
    tip = tipOf(m.html())
    assert.ok(tip.includes('Leads straight to the goal') && !tip.includes('Depends on'), 'no dependency, no depends-on line')
  })

  test('a group of 6 same-state tasks is one stacked card with "Show all 6"', () => {
    assert.strictEqual(FOLD_THRESHOLD, 3) // E92_S11_T03: lowered from 5; GROUPED's six done tasks fold either way
    const html = mountTree(graph(GROUPED, EN), EN).html()
    assert.ok(html.includes(`data-node="${GROUP}"`) && html.includes('data-kind="group"'))
    const card = nodeHtml(html, GROUP)
    assert.ok(card.includes('6 tasks · Done') && card.includes('Show all 6'), 'group text')
    assert.strictEqual(count(card, /class="dt-box-stack"/g), 2, 'stacked look')
    assert.ok(card.includes('role="button"') && card.includes('aria-expanded="false"'))
    for (const id of ['E01_S01_T11', 'E01_S01_T16']) assert.ok(!html.includes(`data-node="${id}"`), id + ' folded')
    assert.ok(html.includes('data-node="E01_S01_T20"'), 'the other state stays a card')
    assert.ok(html.includes(`data-from="E01_S01_T01" data-to="${GROUP}"`) && html.includes(`data-from="${GROUP}" data-to="E01_S02_T01"`), 'edges via the group')
  })

  test('click and Enter expand a group; the expanded group has a collapse header; collapsing restores the stacked card', () => {
    for (const via of ['click', 'enter', 'space']) {
      const m = mountTree(graph(GROUPED, EN), EN)
      const open = () => {
        const el = m.node(GROUP)
        if (via === 'click') m.fire(el, 'onClick')
        else m.fire(el, 'onKeyDown', { key: via === 'enter' ? 'Enter' : ' ', preventDefault() {} })
      }
      open()
      let html = m.html()
      assert.ok(!html.includes(`data-node="${GROUP}"`), via + ': stacked card gone')
      for (const id of ['E01_S01_T11', 'E01_S01_T12', 'E01_S01_T13', 'E01_S01_T14', 'E01_S01_T15', 'E01_S01_T16']) assert.ok(html.includes(`data-node="${id}"`), via + ' ' + id)
      assert.ok(html.includes(`data-toggle="${GROUP}"`) && html.includes('▾ Collapse · 6 tasks'), via + ': collapse header')
      m.fire(m.header(GROUP), 'onKeyDown', { key: 'Tab' })
      assert.ok(m.html().includes(`data-toggle="${GROUP}"`), 'other keys do nothing')
      m.fire(m.header(GROUP), via === 'click' ? 'onClick' : 'onKeyDown', via === 'click' ? undefined : { key: 'Enter', preventDefault() {} })
      html = m.html()
      assert.ok(html.includes(`data-node="${GROUP}"`) && !html.includes('data-toggle=') && !html.includes('data-node="E01_S01_T11"'), via + ': collapsed again')
    }
  })

  test('hovering a group highlights the chains of all its members', () => {
    const g = graph([...GROUPED, T('E01_S02_T02', S2, 'locked', ['E01_S01_T14']), T('E01_S02_T03', S2, 'done', [])], EN)
    const m = mountTree(g, EN)
    m.fire(m.node(GROUP), 'onPointerEnter')
    const html = m.html()
    const dimmed = id => /dt-dim/.test(classOf(html, id))
    assert.ok(!dimmed(GROUP) && !dimmed('E01_S01_T01'), 'group and its dependency')
    assert.ok(!dimmed('E01_S02_T01') && !dimmed('E01_S02_T02'), 'dependents of different members')
    assert.ok(dimmed('E01_S02_T03') && dimmed('E01_S01_T20'), 'unrelated cards dimmed')
    const tip = tipOf(html)
    assert.ok(tip.includes('6 tasks · Done') && tip.includes('E01_S01_T11, E01_S01_T12') && tip.includes('Unlocks'))
  })

  const goalOf = html => html.split('class="dt-node dt-goal')[1].split('</svg>')[0]
  // E92_S09_T04: the goal draws the script's epic_progress (section 5.1), so each fixture states it as board-progress.sh
  // would for these tasks (one story, every task in it); the view never counts the tasks itself.
  const withProgress = (g, ep) => ({ ...g, epics: g.epics.map(e => (e.id === 'E01' ? { ...e, epic_progress: ep } : e)) })
  const ep = (stories, decomposed, tasksDone, tasksDen, percent, goalReached = false) =>
    ({ stories, decomposed, tasks_done: tasksDone, tasks_denominator: tasksDen, percent, goal_reached: goalReached })
  const pct = (done, total) => {
    const tasks = [T('E01_S01_T01', S1, done >= 1 ? 'done' : 'ready', [])]
    for (let i = 2; i <= total; i++) tasks.push(T('E01_S01_T0' + i, S1, i <= done ? 'done' : 'ready', ['E01_S01_T01']))
    const g = withProgress(graph(tasks, EN, [{ id: 'E01_S01', epic_id: 'E01', title: 'First' }]),
      ep(1, 1, done, total, Math.floor((100 * done) / total), done === total))
    const html = render(g, EN)
    return { html, goal: goalOf(html) }
  }

  test('goal: halo strength and radius are monotonic in the completed share; the star fills in step', () => {
    const shares = [pct(0, 4), pct(2, 4), pct(4, 4)]
    const read = ({ html, goal }) => ({
      opacity: Number(goal.match(/--goal-halo-opacity:([\d.]+)/)[1]),
      scale: Number(goal.match(/--goal-halo-scale:([\d.]+)/)[1]),
      fill: Number(html.match(/class="dt-starfill-rect"[^>]*height="([\d.]+)"/)[1]),
      progress: Number(goal.match(/data-progress="([\d.]+)"/)[1]),
    })
    const [a, b, c] = shares.map(read)
    assert.deepStrictEqual([a.progress, b.progress, c.progress], [0, 0.5, 1])
    assert.ok(a.opacity < b.opacity && b.opacity < c.opacity, `strength ${a.opacity} < ${b.opacity} < ${c.opacity}`)
    assert.ok(a.scale < b.scale && b.scale < c.scale, `radius ${a.scale} < ${b.scale} < ${c.scale}`)
    assert.ok(a.opacity < 0.1 && c.opacity > 0.4, 'barely visible near 0 %, strongest near 100 %')
    assert.ok(a.fill < b.fill && b.fill < c.fill, `star fill height ${a.fill} < ${b.fill} < ${c.fill}`)
    assert.ok(Math.abs(b.fill - (41 * 0.5 + 1)) < 0.01 && Math.abs(c.fill - 42) < 0.01 && Math.abs(a.fill - 1) < 0.01, 'fill height = 41 x share + 1')
    assert.ok(!shares[0].goal.includes('dt-complete') && !shares[1].goal.includes('dt-complete'))
  })

  test('goal: text is the epic title and "X / Y done · N %"; at 100 % done class, shimmer, exactly five sparks, reached label', () => {
    const mid = pct(2, 4).goal
    assert.ok(mid.includes('>Goal epic<') && mid.includes('>2 / 4 done · 50 %<') && mid.includes('>Goal<'), 'in progress text')
    assert.ok(!mid.includes('dt-shimmer') && count(mid, /class="dt-spark"/g) === 0 && !mid.includes('Goal reached!'))
    const { html, goal } = pct(4, 4)
    assert.ok(goal.startsWith(' dt-complete"'), 'done class on the goal')
    assert.strictEqual(count(goal, /class="dt-spark"/g), 5, 'five sparks')
    assert.strictEqual(count(goal, /class="dt-shimmer"/g), 1, 'one shimmer')
    assert.ok(goal.includes('>Goal reached!<') && goal.includes('>4 / 4 done · 100 %<') && !goal.includes('>Goal<'))
    assert.ok(html.includes('dt-halo-grad dt-complete'), 'halo gradient turns green too')
    const svGraph = withProgress(graph([T('E01_S01_T01', S1, 'done', []), T('E01_S01_T02', S1, 'done', ['E01_S01_T01'])], SV, [{ id: 'E01_S01', epic_id: 'E01', title: 'First' }]), ep(1, 1, 2, 2, 100, true))
    const sv = renderToStaticMarkup(React.createElement(DependencyTree, { model: model(svGraph, SV), labels: SV }))
    assert.ok(sv.includes('Mål nått!') && sv.includes('2 / 2 klara · 100 %'))
  })

  test('E92_S09_T04: the goal shows the epic percent: 30 %, then 60 % not reached, with decomposed/stories while some stories have no task', () => {
    const tasks = [T('E01_S01_T01', S1, 'done', []), T('E01_S01_T02', S1, 'ready', ['E01_S01_T01'])]
    const at = (progress, labels) => goalOf(render(withProgress(graph(tasks, labels), progress), labels))
    const thirty = at(ep(5, 3, 3, 6, 30), EN)
    assert.ok(thirty.includes('>3 / 6 done · 30 %<') && thirty.includes('>3/5 stories decomposed<'), 'counts beside the percent')
    assert.ok(thirty.includes('· 3 / 6 done · 30 % · 3/5 stories decomposed"'), 'the aria label carries the same counts')
    assert.ok(!thirty.startsWith(' dt-complete"'))
    const sixty = at(ep(5, 3, 6, 6, 60), EN)
    assert.ok(sixty.includes('>6 / 6 done · 60 %<') && sixty.includes('>3/5 stories decomposed<'))
    assert.ok(!sixty.startsWith(' dt-complete"') && !sixty.includes('Goal reached!'), 'all tasks done is not the goal while stories are undecomposed')
    const full = at(ep(5, 5, 10, 10, 100, true), EN)
    assert.ok(full.startsWith(' dt-complete"') && full.includes('>10 / 10 done · 100 %<') && !full.includes('stories decomposed'))
    const sv = at(ep(5, 3, 3, 6, 30), SV)
    assert.ok(sv.includes('>3 / 6 klara · 30 %<') && sv.includes('>3/5 berättelser nedbrutna<'))
  })

  // E92_S10_T02: every task done but a story's own status Failed: the script states 99 %, no goal and failed_stories. The goal
  // draws no completion (no done class, no sparks, no "Goal reached!") and its name line names the failed story instead;
  // the payload labels win, an older payload without them falls back to the English words in DependencyTree.jsx.
  test('E92_S10_T02: a failed story: the goal shows 99 %, no "Goal reached!", and names the failed story', () => {
    const tasks = [T('E01_S01_T01', S1, 'done', []), T('E01_S01_T02', S1, 'done', ['E01_S01_T01'])]
    const stated = (failed, percent = 99) => ({ ...ep(2, 2, 2, 2, percent, false), failed_stories: failed })
    const at = (progress, labels) => goalOf(render(withProgress(graph(tasks, labels), progress), labels))
    // the failed line wraps into tspans (at most 24 characters each); its text is the tspans joined by spaces
    const failedLine = g => {
      const m = g.match(/class="dt-goal-name dt-goal-failed"[^>]*>(.*?)<\/text>/)
      return m ? m[1].split('</tspan>').map(x => x.replace(/<[^>]*>/g, '')).filter(Boolean).join(' ') : null
    }
    const one = at(stated(['E01_S02']), EN)
    assert.ok(!one.startsWith(' dt-complete"') && !one.includes('Goal reached!') && !one.includes('100 %'), one)
    assert.strictEqual(count(one, /class="dt-spark"/g), 0)
    assert.ok(one.includes('>2 / 2 done · 99 %<'), 'the stated percent')
    assert.strictEqual(failedLine(one), 'Goal not reached - E01_S02 has failed', one)
    assert.strictEqual(count(one, /<tspan /g), 2, 'two lines: "Goal not reached -" and "E01_S02 has failed"')
    assert.ok(one.includes(' · Goal not reached - E01_S02 has failed"'), 'the aria label names it too')
    // the lines under the name move down by the extra line
    assert.ok(/class="dt-goal-title" y="113"/.test(one) && /class="dt-goal-count" y="131"/.test(one), one)
    const two = at(stated(['E01_S02', 'E01_S05']), EN)
    assert.strictEqual(failedLine(two), 'Goal not reached - E01_S02 and 1 more have failed', two)
    const sv = at(stated(['E01_S02']), { ...SV, goal_failed: 'Målet ej nått - %s har misslyckats', goal_failed_more: 'Målet ej nått - %s och %d till har misslyckats' })
    assert.strictEqual(failedLine(sv), 'Målet ej nått - E01_S02 har misslyckats', sv)
    // below the cap the goal keeps its plain name line
    const low = at(stated(['E01_S02'], 66), EN)
    assert.ok(!low.includes('dt-goal-failed') && low.includes('>Goal<') && /class="dt-goal-title" y="98"/.test(low), low)
  })

  // E92_S11_T02 (user decision 2026-11-15): a done card whose dependency is not done shows a "?" in the in-progress yellow
  // at the mark position (where a ready card has its plus), with a tooltip naming the dependency; the payload labels win,
  // an older payload without them falls back to the English words in DependencyTree.jsx; without unfinished_deps the
  // card is drawn exactly as before.
  test('E92_S11_T02: a done card whose dependency is not done shows a yellow "?" with a tooltip naming it, en and sv', () => {
    const U = (t, unfinished) => ({ ...t, unfinished_deps: unfinished })
    const tasks = [
      T('E01_S01_T01', S1, 'failed', []),
      U(T('E01_S01_T02', S1, 'done', ['E01_S01_T01']), ['E01_S01_T01']),
      U(T('E01_S02_T01', S2, 'done', ['E01_S01_T01']), ['E01_S01_T01', 'E01_S01']),
      T('E01_S02_T02', S2, 'done', []),
    ]
    const EN2 = { ...EN, dep_unfinished: 'Done although dependency %s is not done - check the dependency', dep_unfinished_more: 'Done although dependency %s and %d more are not done - check the dependencies' }
    const SV2 = { ...SV, dep_unfinished: 'Klar trots att beroendet %s inte är klart - kontrollera beroendet', dep_unfinished_more: 'Klar trots att beroendet %s och %d till inte är klara - kontrollera beroendena' }
    const html = render(graph(tasks, EN2), EN2)
    const one = nodeHtml(html, 'E01_S01_T02')
    assert.ok(one.includes('data-mark="unfinished"') && one.includes('class="dt-mark-q"') && />\?<\/text>/.test(one), one)
    assert.ok(one.includes('<title>Done although dependency E01_S01_T01 is not done - check the dependency</title>'), one)
    assert.ok(!one.includes('data-mark="done"'), 'the "?" takes the mark position of the tick')
    assert.ok(one.includes('(Done although dependency E01_S01_T01 is not done - check the dependency)"'), 'the aria label says it in words')
    assert.ok(classOf(html, 'E01_S01_T02').includes('dt-state-done'), 'still a done card')
    const two = nodeHtml(html, 'E01_S02_T01')
    assert.ok(two.includes('<title>Done although dependency E01_S01_T01 and 1 more are not done - check the dependencies</title>'), two)
    // a done card without the key keeps its tick, and no other card gets the "?"
    assert.ok(nodeHtml(html, 'E01_S02_T02').includes('data-mark="done"'))
    assert.strictEqual(count(html, /data-mark="unfinished"/g), 2)
    // Swedish words from the payload
    const sv = render(graph(tasks, SV2), SV2)
    assert.ok(nodeHtml(sv, 'E01_S01_T02').includes('<title>Klar trots att beroendet E01_S01_T01 inte är klart - kontrollera beroendet</title>'))
    assert.ok(nodeHtml(sv, 'E01_S02_T01').includes('<title>Klar trots att beroendet E01_S01_T01 och 1 till inte är klara - kontrollera beroendena</title>'))
    // a payload without the labels falls back to the English words, never to a bare key
    const fb = render(graph(tasks, EN), EN)
    assert.ok(nodeHtml(fb, 'E01_S01_T02').includes('<title>Done although dependency E01_S01_T01 is not done - check the dependency</title>'))
    assert.ok(!/dep_unfinished/.test(fb))
    // the hover tooltip names it too
    const m = mountTree(graph(tasks, EN2), EN2)
    m.fire(m.node('E01_S01_T02'), 'onPointerEnter')
    assert.ok(tipOf(m.html()).includes('class="dt-tip-row dt-tip-unfinished">Done although dependency E01_S01_T01 is not done - check the dependency<'), tipOf(m.html()))
    // the "?" is drawn in the in-progress yellow
    assert.ok(/\.dt-mark-q\s*\{[^}]*fill:\s*var\(--color-progress-in-progress\)/.test(css), 'yellow "?"')
  })

  test('E92_S11_T02: a payload without unfinished_deps (an older script) renders exactly as before', () => {
    const plain = [T('E01_S01_T01', S1, 'failed', []), T('E01_S01_T02', S1, 'done', ['E01_S01_T01']), T('E01_S02_T01', S2, 'done', [])]
    const stated = plain.map(t => ({ ...t, unfinished_deps: [] }))
    const a = render(graph(plain, EN), EN)
    assert.strictEqual(render(graph(stated, EN), EN), a, 'an empty list draws nothing new')
    assert.ok(!a.includes('data-mark="unfinished"') && !a.includes('dt-mark-q') && nodeHtml(a, 'E01_S01_T02').includes('data-mark="done"'))
  })

  test('goal: no radiating pulse any more (halo breathes, the ring pulse belongs to ready cards only)', () => {
    assert.ok(!/dt-goal[^{]*\{[^}]*animation:[^}]*pulse/.test(css))
    const motion = [...css.matchAll(/([^{}]+)\{[^{}]*animation:\s*([a-z-]+)/g)].map(m => [m[1].trim(), m[2]])
    for (const [sel, name] of motion) if (/dt-halo|dt-goal|dt-shimmer|dt-spark/.test(sel)) assert.ok(/breathe|shimmer|twinkle/.test(name), `${sel} -> ${name}`)
    assert.ok(!/radiat/i.test(css + jsx))
  })

  test('goal node is part of the tree: the goal edge ends at the goal ring', () => {
    const m = model(graph(ALL, EN), EN)
    const html = renderToStaticMarkup(React.createElement(DependencyTree, { model: m, labels: EN }))
    const d = html.match(/data-from="E01_S02_T04" data-to="goal"[^>]* d="([^"]+)"/)[1]
    assert.ok(d.endsWith(` ${m.goal.x - 46} ${m.goal.y}`), d)
    assert.ok(html.includes('aria-label="Goal: E01 Goal epic"') && html.includes('data-goal="E01"'))
  })

  test('ready list and unlocked-by lines render below the drawing', () => {
    const html = render(graph(ALL, EN), EN)
    assert.ok(html.includes('Ready to take') && html.includes('data-ready="E01_S01_T03"'))
    assert.ok(html.includes('E01_S01_T02 unlocked by E01_S01_T01'))
  })

  test('empty model (zero tasks) renders tree_empty only; an edge-free epic with tasks draws its tree; nothing_ready renders its label and no list', () => {
    // E92_S09_T01 (user request 2026-11-15): only an epic with zero tasks shows the empty state.
    const html = render(graph([], EN), EN)
    assert.ok(html.includes('No tasks to show') && !html.includes('<svg'))
    // One task and no dependency edge: the tree is drawn (start node, the task card, the goal), not the empty label.
    const flat = render(graph([T('E01_S01_T01', S1, 'done', [])], EN), EN)
    assert.ok(flat.includes('<svg') && !flat.includes('No tasks to show'), 'edge-free epic draws its tree')
    assert.ok(flat.includes('data-node="E01_S01_T01"') && flat.includes('data-start="E01_S01"') && flat.includes('data-goal="E01"'))
    assert.ok(renderToStaticMarkup(React.createElement(DependencyTree, { model: null, labels: SV })).includes('Inga uppgifter att visa'))
    const g = graph([T('E01_S01_T01', S1, 'done', []), T('E01_S01_T02', S1, 'locked', ['E01_S01_T01'])], EN)
    const h2 = render(g, EN)
    assert.ok(h2.includes('Nothing ready') && !h2.includes('dt-ready-list'))
  })

  test('Swedish labels render, in the cards, the group card, the gates and the tooltip', () => {
    const html = render(graph(ALL, SV), SV)
    for (const s of ['Mål', 'Redo att ta', 'Klar: E01_S01_T01', 'Låst: E01_S02_T01', 'Pågår: E01_S01_T02', 'Misslyckad: ', 'Avvisad: ', 'E01_S01_T02 låstes upp av E01_S01_T01', 'Väntar på beroende (låst)', 'Beroendet är klart (upplåst)']) {
      assert.ok(html.includes(s), s)
    }
    const m = mountTree(graph(GROUPED, SV), SV)
    const grouped = m.html()
    assert.ok(grouped.includes('6 uppgifter · Klar') && grouped.includes('Visa alla 6'))
    m.fire(m.node('E01_S01_T20'), 'onPointerEnter')
    assert.ok(m.html().includes('Beror på') && m.html().includes('Leder direkt till målet'))
    m.fire(m.node(GROUP), 'onClick')
    assert.ok(m.html().includes('▾ Fäll ihop · 6 uppgifter'))
  })

  test('a payload without the new keys falls back to English words, never to a bare key', () => {
    const OLD = { goal: 'Goal', state_done: 'Done' }
    const m = mountTree(graph(GROUPED, OLD), OLD)
    const html = m.html()
    // E92_S10_T01: GROUPED's E01_S02_T01 is in state locked (its own dependency is done, so before T01 the old fallback gave
    // it the open gate and this asserted that no 'Waiting' word appeared). Under the padlock rule a locked task carries the
    // closed padlock, so the English fallback of gate_waiting must now appear.
    assert.ok(html.includes('6 tasks') && html.includes('Show all 6'))
    assert.ok(html.includes('Waiting for a dependency (locked)'), 'gate_waiting falls back to its English words')
    assert.ok(!/>(group_tasks|show_all|collapse|goal_progress|gate_open|gate_waiting)</.test(html))
    m.fire(m.node(GROUP), 'onClick')
    assert.ok(m.html().includes('Collapse'))
  })

  // ---- E92_S12_T03: an undecomposed story is drawn as a dashed, labelled band and start node with no task node ----
  const ZM = await import(pathToFileURL(path.join(compDir, 'zoomPanModel.js')).href)
  const GHOST_EN = { ...EN, story_undecomposed: 'Not broken down yet', story_undecomposed_aria: '%s - not broken down into tasks yet' }
  const GHOST_SV = { ...SV, story_undecomposed: 'Inte nedbruten ännu', story_undecomposed_aria: '%s - ännu inte nedbruten i uppgifter' }
  const S3 = 'E01_S03'
  // the example epic of the story: three stories, the first decomposed and the other two not broken down into tasks yet
  const STORIES3 = [
    { id: S1, epic_id: 'E01', title: 'First', decomposed: true },
    { id: S2, epic_id: 'E01', title: 'Second', decomposed: false },
    { id: S3, epic_id: 'E01', title: 'Third', decomposed: false },
  ]
  const ONE = [T('E01_S01_T01', S1, 'done', []), T('E01_S01_T02', S1, 'ready', ['E01_S01_T01'], 'E01_S01_T01')]
  /** The markup of one start node: its own g up to the first closing g (a ghost start node has no nested g). */
  const startOf = (html, id) => html.split(`data-start="${id}"`)[1].split('</g>')[0]
  const edgeTag = (html, from, to) => html.match(new RegExp(`<path class="([^"]*)" data-from="${from}" data-to="${to}"[^>]*>`))

  test('E92_S12_T03: the example epic draws three bands and three start nodes, the two undecomposed ones dashed, labelled and with no task node', () => {
    const html = render(graph(ONE, GHOST_EN, STORIES3), GHOST_EN)
    assert.strictEqual(count(html, /class="dt-band( |")/g), 3, 'three bands')
    assert.strictEqual(count(html, /class="dt-start( |")/g), 3, 'three start nodes')
    assert.strictEqual(count(html, /dt-band-ghost/g), 2)
    assert.strictEqual(count(html, /dt-start-ghost( |")/g), 2)
    assert.strictEqual(count(html, /data-node="/g), 2, 'only the two tasks of the decomposed story are nodes')
    for (const [sid, title] of [[S2, 'Second'], [S3, 'Third']]) {
      const st = startOf(html, sid)
      assert.ok(st.includes(`>${sid}<`) && st.includes(`>${title}<`), 'id and title')
      assert.ok(/class="dt-start-count"[^>]*>0\/0</.test(st), '0/0')
      assert.ok(/class="dt-start-ghost-text"[^>]*>Not broken down yet</.test(st), 'label text from the payload')
      assert.ok(!st.includes('dt-start-bar'), 'no mini bar: it must not read as 0 % progress')
      assert.ok(st.includes('data-undecomposed="true"'))
      assert.ok(!html.includes(`data-node="${sid}_T`), 'no task node in ' + sid)
      assert.ok(new RegExp(`class="dt-band[^"]*dt-band-ghost" data-story="${sid}" data-undecomposed="true"`).test(html), 'ghost band ' + sid)
    }
    const s1 = startOf(html, S1)
    assert.ok(!s1.includes('dt-start-ghost') && !s1.includes('data-undecomposed') && s1.includes('dt-start-bar'), 'the decomposed story keeps its bar and gains nothing')
  })

  test('E92_S12_T03: the start node of an undecomposed story has an aria label with the id, the title and the not-broken-down text', () => {
    const html = render(graph(ONE, GHOST_EN, STORIES3), GHOST_EN)
    const st = startOf(html, S2)
    assert.ok(st.includes('role="group"'), 'role')
    assert.ok(st.includes('aria-label="E01_S02 Second - not broken down into tasks yet"'), st.slice(0, 240))
    assert.ok(st.includes('<title>E01_S02 Second - not broken down into tasks yet</title>'), 'the same sentence as the tooltip')
    assert.ok(!startOf(html, S1).includes('aria-label'), 'a decomposed start node is as before')
    const sv = render(graph(ONE, GHOST_SV, STORIES3), GHOST_SV)
    assert.ok(startOf(sv, S3).includes('aria-label="E01_S03 Third - ännu inte nedbruten i uppgifter"'))
    assert.ok(/dt-start-ghost-text"[^>]*>Inte nedbruten ännu</.test(startOf(sv, S3)))
  })

  test('E92_S12_T03: a decomposed story, the goal text and the percent render as before', () => {
    const plain = render(graph(ALL, EN), EN)
    const flagged = render(graph(ALL, EN, [{ id: S1, epic_id: 'E01', title: 'First', decomposed: true }, { id: S2, epic_id: 'E01', title: 'Second', decomposed: true }]), EN)
    assert.strictEqual(flagged, plain, 'decomposed: true everywhere is byte-identical to a payload without the flag')
    // beside undecomposed stories, the decomposed story and its cards are the same markup as without them
    const beside = render(graph(ONE, GHOST_EN, STORIES3), GHOST_EN)
    const alone = render(graph(ONE, GHOST_EN, [STORIES3[0]]), GHOST_EN)
    assert.strictEqual(startOf(beside, S1), startOf(alone, S1))
    assert.strictEqual(nodeHtml(beside, 'E01_S01_T01'), nodeHtml(alone, 'E01_S01_T01'))
    assert.strictEqual(count(alone, /dt-band-ghost|dt-start-ghost|dt-edge-ghost|data-undecomposed/g), 0, 'nothing ghost without an undecomposed story')
  })

  test('E92_S12_T03: the ghost edge to the goal is dashed, distinct from the ready edge, aria-hidden, and one per ghost band', () => {
    const html = render(graph(ONE, GHOST_EN, STORIES3), GHOST_EN)
    for (const sid of [S2, S3]) {
      const e = edgeTag(html, `story:${sid}`, 'goal')
      assert.ok(e, 'ghost edge ' + sid)
      assert.ok(/dt-edge-ghost/.test(e[1]) && /dt-edge-goal/.test(e[1]), e[1])
      assert.ok(!/dt-edge-(ready|done|locked|active|failed|rejected)/.test(e[1]), 'neither the ready edge nor a state colour: ' + e[1])
      assert.ok(/data-kind="ghost"/.test(e[0]))
    }
    assert.strictEqual(count(html, /data-kind="ghost"/g), 2)
    assert.ok(!edgeTag(html, `story:${S1}`, 'goal'), 'the decomposed story has no ghost edge')
    const edgesAt = html.indexOf('class="dt-edges"')
    assert.ok(/^class="dt-edges" aria-hidden="true"/.test(html.slice(edgesAt)), 'the edge group is aria-hidden')
    assert.ok(html.indexOf('data-kind="ghost"') > edgesAt && html.indexOf('data-kind="ghost"') < html.indexOf('class="dt-start'), 'drawn inside the edge group, below the start nodes')
  })

  test('E92_S12_T03: a payload without the two new labels still renders: the dashed outline remains, the text and the aria label are omitted', () => {
    for (const labels of [EN, {}, null]) {
      const html = render(graph(ONE, labels || {}, STORIES3), labels || {})
      assert.strictEqual(count(html, /class="dt-band( |")/g), 3)
      assert.strictEqual(count(html, /dt-start-ghost( |")/g), 2)
      assert.strictEqual(count(html, /dt-band-ghost/g), 2)
      const st = startOf(html, S2)
      assert.ok(!st.includes('dt-start-ghost-text') && !st.includes('aria-label') && !st.includes('role='), 'no text, no aria label')
      assert.ok(!st.includes('dt-start-bar'), 'still no bar')
      assert.ok(st.includes('>E01_S02<') && st.includes('>Second<') && /class="dt-start-count"[^>]*>0\/0</.test(st), 'id, title and 0/0 stay')
      assert.ok(!/story_undecomposed/.test(html), 'never a bare key and no English fallback word')
      assert.ok(!html.includes('not broken down') && !html.includes('Not broken down'))
      assert.ok(edgeTag(html, `story:${S2}`, 'goal'), 'the ghost edge is drawn anyway')
    }
  })

  test('E92_S12_T03: an undecomposed story that still has task nodes (only rejected ones) gets the same dashed outline and label', () => {
    const rejectedOnly = [...ONE, T('E01_S02_T01', S2, 'rejected', [])]
    const stories = [STORIES3[0], { id: S2, epic_id: 'E01', title: 'Second', decomposed: false }]
    const html = render(graph(rejectedOnly, GHOST_EN, stories), GHOST_EN)
    assert.strictEqual(count(html, /class="dt-band( |")/g), 2)
    assert.ok(html.includes('data-node="E01_S02_T01"'), 'its rejected task node stays')
    const st = startOf(html, S2)
    assert.ok(st.includes('dt-start-ghost') && st.includes('aria-label="E01_S02 Second - not broken down into tasks yet"'))
    assert.ok(/dt-start-ghost-text"[^>]*>Not broken down yet</.test(st) && !st.includes('dt-start-bar'))
    assert.ok(/dt-band-ghost" data-story="E01_S02"/.test(html))
    assert.ok(!edgeTag(html, `story:${S2}`, 'goal'), 'a story with a task node reaches the goal through its task, not a ghost edge')
    assert.ok(edgeTag(html, 'E01_S02_T01', 'goal'))
  })

  test('E92_S12_T03: the dash of the ghost outline and the ghost edge differs from every other dash on the map; only tokens are used', () => {
    const rules = [...stripComments(css).matchAll(/([^{}]+)\{([^{}]*)\}/g)]
      .map(m => ({ sel: m[1].trim(), dash: (m[2].match(/stroke-dasharray:\s*([^;]+)/) || [])[1] })).filter(r => r.dash)
    const dashOf = sel => { const r = rules.find(x => x.sel === sel); assert.ok(r, 'rule ' + sel); return r.dash.trim() }
    const outline = dashOf('.dep-tree .dt-band-ghost')
    assert.strictEqual(dashOf('.dep-tree .dt-start-ghost .dt-start-box'), outline, 'band and start node share the outline dash')
    const edge = dashOf('.dep-tree .dt-edge-ghost')
    assert.strictEqual(outline, '9 4')
    assert.strictEqual(edge, '10 3 2 3')
    const others = rules.filter(r => !/ghost/.test(r.sel)).map(r => r.dash.trim())
    assert.ok(others.length >= 5, 'the other dashes were found: ' + others.join(' | '))
    assert.ok(!others.includes(outline) && !others.includes(edge), 'unique among ' + others.join(' | '))
    assert.ok(others.includes('5 3') && others.includes('2 3') && others.includes('2 5'), 'ready card, rejected card, cross-story edge')
    // the new rules colour with existing tokens only
    const ghostBlocks = [...stripComments(css).matchAll(/([^{}]*ghost[^{}]*)\{([^{}]*)\}/g)].map(m => m[2]).join(' ')
    const used = [...new Set([...ghostBlocks.matchAll(/var\((--[a-z0-9-]+)/g)].map(m => m[1]))]
    assert.deepStrictEqual(used.sort(), ['--color-border-strong', '--color-text-muted'])
  })

  test('E92_S12_T03: a fit measured with ghost bands covers every band and the goal; no band is assumed to hold a task', () => {
    const g = graph(ONE, GHOST_EN, STORIES3)
    const m = model(g, GHOST_EN)
    const html = renderToStaticMarkup(React.createElement(DependencyTree, { model: m, labels: GHOST_EN }))
    assert.strictEqual(m.bands.length, 3)
    const ghosts = m.bands.filter(b => b.undecomposed)
    assert.strictEqual(ghosts.length, 2)
    for (const b of ghosts) assert.strictEqual(b.h, LAYOUT.bandPad * 3 + LAYOUT.cardH, 'an empty band is as tall as the layout gives it')
    // bands follow one another with the band gap, and the drawing is as tall as the last band plus its padding
    for (let i = 1; i < m.bands.length; i++) assert.strictEqual(m.bands[i].y, m.bands[i - 1].y + m.bands[i - 1].h + LAYOUT.bandGap)
    const last = m.bands[m.bands.length - 1]
    assert.ok(m.layout.height >= last.y + last.h + LAYOUT.pad, 'the measured content height includes the ghost bands')
    // the component's own box (the viewBox before the first measured fit) is the layout plus the 10 unit margin on each side
    const vb = html.match(/<svg class="dt-svg" viewBox="(-?[\d.]+) (-?[\d.]+) ([\d.]+) ([\d.]+)"/).slice(1).map(Number)
    const box = { x: vb[0], y: vb[1], w: vb[2], h: vb[3] }
    assert.strictEqual(box.w, m.layout.width + 20)
    assert.ok(box.h >= m.layout.height + 20)
    // Fit: the whole box lands inside the viewport, at an ordinary scale, and the last ghost band is inside it
    const size = { w: 900, h: 560 }
    const v = ZM.fitView(box, size)
    assert.ok(v.k >= ZM.MIN_SCALE && v.k <= ZM.MAX_SCALE && Number.isFinite(v.x) && Number.isFinite(v.y))
    assert.ok(box.w * v.k <= size.w + 1e-9 && box.h * v.k <= size.h + 1e-9, 'the fitted drawing fits the viewport')
    const bottom = v.y + v.k * (last.y + last.h)
    const top = v.y + v.k * m.bands[0].y
    assert.ok(top >= 0 && bottom <= size.h, `all bands inside the viewport (${top.toFixed(1)}..${bottom.toFixed(1)})`)
    // the same epic without its ghost bands is shorter: the extra bands really are part of what Fit measures
    const without = model(graph(ONE, GHOST_EN, [STORIES3[0]]), GHOST_EN)
    assert.ok(m.layout.height > without.layout.height)
    // unfolding keeps the ghost bands (the component re-folds from model.stories): the layout is the same
    const unfolded = unfoldGroups(m, ['group:none'])
    assert.deepStrictEqual(unfolded.bands.map(b => [b.storyId, b.y, b.h, b.undecomposed === true]), m.bands.map(b => [b.storyId, b.y, b.h, b.undecomposed === true]))
    assert.strictEqual(unfolded.layout.height, m.layout.height)
  })

  /** Split css into top-level blocks, tracking brace depth; returns [{ head, body }] for each top-level rule. */
  function topLevel(src) {
    const text = stripComments(src)
    const blocks = []
    let depth = 0
    let start = 0
    let head = ''
    for (let i = 0; i < text.length; i++) {
      const c = text[i]
      if (c === '{') { if (depth === 0) { head = text.slice(start, i).trim(); start = i + 1 } depth++ }
      else if (c === '}') { depth--; if (depth === 0) { blocks.push({ head, body: text.slice(start, i) }); start = i + 1 } }
    }
    return blocks
  }

  test('every animation declaration is inside prefers-reduced-motion: no-preference AND for a root without data-motion="off"', () => {
    const blocks = topLevel(css)
    const motion = /(^|[\s;{])(animation|transition)(-[a-z-]+)?\s*:/
    const names = new Set()
    for (const b of blocks) {
      if (/^@media\s*\(prefers-reduced-motion:\s*no-preference\)$/.test(b.head)) {
        // inside: every rule, each selector of it, must start from the :root that has no data-motion="off"
        for (const rule of b.body.split('}').map(r => r.trim()).filter(Boolean)) {
          const [sel, decl] = rule.split('{')
          if (!motion.test(decl)) continue
          for (const one of sel.split(',')) assert.ok(one.trim().startsWith(':root:not([data-motion="off"])'), `animation selector not gated by data-motion: ${one.trim()}`)
          const m = decl.match(/animation:\s*([a-z-]+)/)
          if (m) names.add(m[1])
        }
        continue
      }
      assert.ok(!motion.test(b.body), `motion declaration outside the reduced-motion guard: ${b.head}`)
    }
    assert.deepStrictEqual([...names].sort(), ['dn-drift', 'dn-flap', 'dt-blink', 'dt-breathe', 'dt-flow', 'dt-ring-pulse', 'dt-shimmer', 'dt-twinkle'])
    for (const k of names) assert.ok(new RegExp(`@keyframes\\s+${k}\\b`).test(css), 'keyframes ' + k)
    assert.ok(css.includes(':root:not([data-motion="off"])'))
  })

  test('no # colour literal and no functional colour in the css or the jsx', () => {
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(stripComments(css)), 'css')
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(stripComments(jsx)), 'jsx')
    assert.ok(!/\b(rgb|rgba|hsl|hsla|oklch|color-mix)\(/.test(stripComments(css) + jsx), 'no functional colours')
    assert.ok(!/\b(white|black)\b\s*[;}"']/.test(stripComments(css)), 'no colour names')
  })

  test('every var(--...) token exists in tokens.css for the light and the dark theme', () => {
    const tokens = fs.readFileSync(path.join(uiDir, 'src', 'tokens.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
    const local = new Set(['--goal-c', '--dt-shine', '--goal-halo-opacity', '--goal-halo-scale'])
    // E92_S13_T02: the --cc-* custom properties are the citadel's palette hook, defined in the .dt-castle rule from tokens
    // (the next test) and the --dn-* custom properties are the shared day and night hook of .dn-scene (E92_S13_T04, mapped from
    // --color-sky-* tokens, tested there); every other var() must be a token of tokens.css for both themes
    const used = [...new Set([...css.matchAll(/var\((--[a-z0-9-]+)/g)].map(m => m[1]))].filter(t => !local.has(t) && !t.startsWith('--cc-') && !t.startsWith('--dn-'))
    assert.ok(used.length >= 8, 'tokens used')
    assert.ok(used.some(t => t.startsWith('--color-progress-')))
    const blocks = topLevel(tokens)
    const light = blocks.filter(b => b.head === ':root').map(b => b.body).join('\n')
    const dark = blocks.filter(b => /prefers-color-scheme:\s*dark/.test(b.head) || /data-theme="dark"/.test(b.head)).map(b => b.body).join('\n')
    const darkAll = dark + '\n' + (tokens.match(/data-theme="dark"\][^{]*\{[^}]*\}/g) || []).join('\n')
    for (const t of used) {
      assert.ok(new RegExp(t + '\\s*:').test(light), `${t} defined for light`)
      assert.ok(new RegExp(t + '\\s*:').test(darkAll), `${t} defined for dark`)
    }
  })

  test('no word is hard-coded in the jsx: every user-visible string passes through a label', () => {
    const src = stripComments(jsx).split('const FALLBACK')[0] + stripComments(jsx).split('const STATE_LABEL_KEY')[1]
    // JSX text nodes between tags that contain a letter would be a hard-coded word
    const text = [...src.matchAll(/<[A-Za-z][^<>]*>([^<>{}\n]*[A-Za-z][^<>{}\n]*)<\//g)].map(m => m[1].trim()).filter(Boolean)
    assert.deepStrictEqual(text, [], 'hard-coded JSX text: ' + text.join(' | '))
  })

  // ===================== E92_S13_T02: the citadel, the default goal design =====================
  const CEN = { ...EN, castle_tower: '%s: %d of %d done', castle_tower_failed: '%s: %d of %d done, %d failed', castle_tower_undecomposed: '%s: not broken down yet', story_undecomposed: 'Not broken down yet', story_undecomposed_aria: '%s - not broken down into tasks yet' }
  const CSV = { ...SV, castle_tower: '%s: %d av %d klara', castle_tower_failed: '%s: %d av %d klara, misslyckade: %d', castle_tower_undecomposed: '%s: inte nedbruten ännu' }
  const SID = i => `E01_S${String(i).padStart(2, '0')}`
  // spec: one entry per story { states: [...task states], deps: [story numbers], undec }. The payload facts a real script states
  // (story `complete`, `decomposed`, epic_progress) are written here as the script would; the view derives none of them.
  const castleGraph = (spec, labels, percent = 40, reached = false) => {
    const stories = []
    const tasks = []
    spec.forEach((st, k) => {
      const sid = SID(k + 1)
      const states = st.undec ? [] : st.states
      stories.push({ id: sid, epic_id: 'E01', title: 'Story ' + (k + 1), depends_on: (st.deps || []).map(SID), decomposed: !st.undec, complete: !st.undec && states.length > 0 && states.every(x => x === 'done') })
      states.forEach((state, i) => tasks.push(T(`${sid}_T${String(i + 1).padStart(2, '0')}`, sid, state, [])))
    })
    const g = graph(tasks, labels, stories)
    return withProgress(g, ep(spec.length, spec.filter(x => !x.undec).length, tasks.filter(t => t.state === 'done').length, tasks.filter(t => t.state !== 'rejected').length, percent, reached))
  }
  const citadelModel = (g, labels) => buildCastleModelOf(g, 'E01', labels)
  const renderCitadel = (g, labels) => renderToStaticMarkup(React.createElement(CitadelTree, { model: citadelModel(g, labels), labels }))
  const goalHtml = html => { const a = html.indexOf('class="dt-node dt-goal'); return html.slice(a, html.indexOf('</svg>', a)) }
  // the towers only: the bastions of the wall are small towers of layers too
  const towersHtml = html => html.slice(html.indexOf('class="cc-towers"'), html.indexOf('class="cc-wall-front"'))
  const towerOf = (html, sid) => {
    const a = html.indexOf(`data-tower="${sid}"`)
    assert.ok(a > 0, 'tower ' + sid)
    // the tower's own markup ends where the next tower, stack, bridge or the front wall begins
    const ends = ['data-bridge="', 'data-stack="', 'data-tower="', 'class="cc-wall-front"'].map(k => html.indexOf(k, a + 1)).filter(x => x > 0)
    return html.slice(html.lastIndexOf('<g ', a), Math.min(...ends))
  }
  const D = 'done', P = 'in_progress', R = 'ready', F = 'failed', X = 'rejected'
  // S1 is the base (all done); S2 and S3 stand on it; S4 stands on a bridge between S2 and S3; S5 is not broken down and S6 stands on it;
  // S3 has a failed task and a rejected one; S2 has every other state
  const MIXED = [
    { states: [D, D, D] },
    { states: [D, P, R, R], deps: [1] },
    { states: [D, F, R, X], deps: [1] },
    { states: [R, R], deps: [2, 3] },
    { undec: true },
    { states: [D, D], deps: [5] },
  ]

  test('E92_S13_T02: the citadel is the default design: it draws the castle and no star, ring, disc, halo or spark; the text under it is the old goal text', () => {
    const html = renderCitadel(castleGraph(MIXED, CEN, 61), CEN)
    const goal = goalHtml(html)
    assert.ok(goal.includes('data-goal-design="citadel"') && goal.includes('data-castle="citadel"'))
    for (const star of ['dt-star-outline', 'dt-star-fill', 'dt-goal-ring', 'dt-goal-disc', 'dt-halo', 'dt-shimmer', 'dt-spark']) assert.ok(!goal.includes(star), star)
    assert.ok(goal.includes('>Goal<') && goal.includes('>Goal epic<') && /class="dt-goal-count"[^>]*>\d+ \/ \d+ done · 61 %</.test(goal), 'goal name, title and count unchanged')
    assert.ok(/dt-goal-decomposed"[^>]*>5\/6 stories decomposed</.test(goal), 'decomposed line unchanged')
    // the text lines are under the castle box, in the same order and spacing as before (18, 36 and 52 under the name line)
    const m = citadelModel(castleGraph(MIXED, CEN, 61), CEN)
    const y = c => Number(goal.match(new RegExp(`class="${c}"[^>]* y="([\\d.]+)"`))[1])
    const top = m.castle.text.top
    assert.deepStrictEqual([y('dt-goal-name'), y('dt-goal-title'), y('dt-goal-count')], [top, top + 18, top + 36])
    assert.ok(top >= m.castle.box.bottom, 'the text starts under the castle')
    assert.ok(!/<canvas|<foreignObject|<image|<script|<img/.test(html), 'pure SVG')
  })

  test('E92_S13_T02: the star and the citadel are both registered; the selector shows both, the citadel is chosen without a stored choice, the star is drawn when chosen', () => {
    assert.deepStrictEqual(Object.keys(GOAL_RENDERERS), ['star', 'citadel', 'facade', 'tree']) // E92_S13_T07 registered the seasons tree
    const html = renderCitadel(castleGraph(MIXED, CEN, 61), CEN)
    assert.ok(html.includes('data-testid="dt-goal-design"') && html.includes('data-goal-design="star"') && html.includes('data-goal-design="citadel"'))
    const was = globalThis.window
    try {
      globalThis.window = { localStorage: { getItem: () => 'star', setItem() {} } }
      const star = renderToStaticMarkup(React.createElement(CitadelTree, { model: citadelModel(castleGraph(MIXED, CEN, 61), CEN), labels: CEN }))
      assert.ok(goalHtml(star).includes('dt-star-outline') && !goalHtml(star).includes('data-castle="citadel"'), 'a stored star draws the star')
      globalThis.window = { localStorage: { getItem: () => 'nonsense', setItem() {} } }
      assert.ok(renderCitadel(castleGraph(MIXED, CEN, 61), CEN).includes('data-castle="citadel"'), 'an unknown stored value falls back to the citadel')
      globalThis.window = { get localStorage() { throw new Error('blocked') } }
      assert.ok(renderCitadel(castleGraph(MIXED, CEN, 61), CEN).includes('data-castle="citadel"'), 'blocked storage falls back to the citadel')
    } finally {
      if (was === undefined) delete globalThis.window
      else globalThis.window = was
    }
  })

  test('E92_S13_T02: every layer state has its own shape: grain, hatch and a pulled-out block, wireframe, crack; no state is colour alone', () => {
    const html = renderCitadel(castleGraph(MIXED, CEN, 40), CEN)
    const layerStates = [...towersHtml(html).matchAll(/class="cc-layer" data-state="([a-z_]+)"/g)].map(m => m[1])
    // 3 + 4 + 3 + 2 counted tasks of S1..S4, none for the foundation, 2 on the foundation's story: one layer per counted task
    assert.strictEqual(layerStates.length, 3 + 4 + 3 + 2 + 2)
    assert.strictEqual(count(towersHtml(html), /class="cc-layer" data-state="done"/g), 3 + 1 + 1 + 2)
    const s1 = towerOf(html, SID(1))
    const s2 = towerOf(html, SID(2))
    const s3 = towerOf(html, SID(3))
    assert.ok(s1.includes('class="cc-grain"') && !s1.includes('cc-crack') && !s1.includes('cc-pull') && !/cc-pend/.test(s1), 'done: wood grain only')
    assert.ok(s2.includes('class="cc-pull"') && s2.includes('url(#dt-castle-hatch-E01)'), 'in progress: a pulled-out block, hatched')
    assert.ok(count(s2, /class="cc-layer" data-state="pending"/g) === 2 && s2.includes('cc-pend'), 'pending: wireframe')
    assert.ok(s3.includes('class="cc-crack"') && s3.includes('class="cc-layer" data-state="failed"'), 'failed: cracked')
    assert.ok(html.includes('<pattern id="dt-castle-hatch-E01"'), 'the hatch pattern is defined')
    // the shapes are separate from the colour: each state has markup of its own in the drawing (the css only paints them)
    const cssCastle = css.slice(css.indexOf('goal: the citadel'))
    for (const cls of ['cc-grain', 'cc-pull-side', 'cc-pend', 'cc-crack', 'cc-found-p']) assert.ok(cssCastle.includes('.' + cls), cls)
    assert.ok(/\.cc-pend \{[^}]*stroke-dasharray/.test(cssCastle) && /\.cc-found-p \{[^}]*stroke-dasharray: 11 4/.test(cssCastle), 'dashes carry pending and the foundation')
  })

  test('E92_S13_T02: a rejected task is a block lying beside the tower and is not a layer; an undecomposed story is a dashed foundation with "?", with no layer, roof or battlements', () => {
    const html = renderCitadel(castleGraph(MIXED, CEN, 40), CEN)
    const s3 = towerOf(html, SID(3))
    assert.strictEqual(count(s3, /class="cc-layer"/g), 3, 'three counted tasks, the rejected one is no layer')
    assert.strictEqual(count(s3, /class="cc-loose-block"/g), 1)
    const s5 = towerOf(html, SID(5))
    assert.ok(s5.includes('data-undecomposed="true"') && s5.includes('class="cc-foundation"') && s5.includes('>?</text>'))
    assert.ok(count(s5, /class="cc-p cc-found-p"/g) >= 6 && !s5.includes('cc-layer') && !s5.includes('cc-roof') && !s5.includes('cc-battlements'))
    assert.ok(s5.includes('data-status="pending"'), 'the status base is still drawn for it')
  })

  test('E92_S13_T02: stacking on one tower, a bridge, roof versus battlements, and a leaning tower', () => {
    const html = renderCitadel(castleGraph(MIXED, CEN, 40), CEN)
    const m = citadelModel(castleGraph(MIXED, CEN, 40), CEN)
    const t = Object.fromEntries(m.castle.towers.map(x => [x.storyId, x]))
    // S2 and S3 stand on S1's top; S1 is on the table
    assert.deepStrictEqual([t[SID(1)].stacking, t[SID(2)].stacking, t[SID(3)].stacking, t[SID(4)].stacking], ['ground', 'tower', 'tower', 'bridge'])
    assert.strictEqual(t[SID(2)].base, t[SID(1)].topY, 'S2 stands on the top of S1')
    assert.strictEqual(t[SID(3)].base, t[SID(1)].topY)
    assert.ok(html.indexOf(`data-stack="${SID(1)}"`) < html.indexOf(`data-stack="${SID(2)}"`) && html.indexOf(`data-stack="${SID(2)}"`) < html.indexOf(`data-stack="${SID(3)}"`), 'drawn bottom to top, inside the tower they stand on')
    // S4 has two supports: a bridge deck (S2 and S3 are the ends), data-bridge in the markup
    assert.ok(html.includes(`data-bridge="${SID(4)}"`) && html.includes('class="cc-p cc-deck-front"') && towerOf(html, SID(4)).includes('data-stacking="bridge"'))
    // a finished leaf tower has a roof with a flag, a finished tower that carries others battlements, an unfinished one neither
    const done = castleGraph([{ states: [D, D] }, { states: [D, D], deps: [1] }, { states: [D], deps: [1] }, { states: [D, R] }], CEN, 80)
    const dh = renderCitadel(done, CEN)
    assert.ok(towerOf(dh, SID(1)).includes('data-top="battlements"') && dh.includes('class="cc-battlements"'), 'a finished tower that carries others: battlements')
    assert.strictEqual(count(dh.slice(0, dh.indexOf('class="cc-wall-front"')), /class="cc-roof"/g), 2, 'the two finished leaf towers have a roof')
    assert.ok(towerOf(dh, SID(2)).includes('data-top="roof"') && dh.includes('class="cc-flag'), 'finished leaf: roof and flag')
    assert.ok(towerOf(dh, SID(4)).includes('data-top="none"'), 'unfinished: neither')
    assert.ok(!towerOf(dh, SID(1)).includes('cc-roof"'), 'no roof where there are battlements')
    // a tower with a failed task leans, with what stands on it: skewX on its stack
    assert.ok(towerOf(html, SID(3)).includes('cc-lean'))
    const stack3 = html.slice(html.lastIndexOf('<g ', html.indexOf(`data-stack="${SID(3)}"`)), html.indexOf(`data-stack="${SID(3)}"`) + 200)
    assert.ok(/skewX\(-7\)/.test(stack3), 'the failed tower is sheared: ' + stack3)
    assert.ok(!/skewX/.test(html.slice(html.lastIndexOf('<g ', html.indexOf(`data-stack="${SID(2)}"`)), html.indexOf(`data-stack="${SID(2)}"`) + 200)), 'a tower with no failed task stands upright')
  })

  test('E92_S13_T02: the curtain wall is built from the gate by the wall share; the gate, bastions and table are drawn; the effects group is empty', () => {
    const none = renderCitadel(castleGraph(MIXED, CEN, 0), CEN)
    const half = renderCitadel(castleGraph(MIXED, CEN, 50), CEN)
    const all = renderCitadel(castleGraph([{ states: [D, D] }], CEN, 100, true), CEN)
    const built = h => count(h, /class="cc-wall-block" data-built="true"/g)
    const total = h => count(h, /class="cc-wall-block"/g)
    const m = citadelModel(castleGraph(MIXED, CEN, 50), CEN)
    assert.strictEqual(built(none), 0)
    assert.strictEqual(built(half), Math.round(m.castle.wall.count * 0.5), 'the share comes from the model')
    assert.strictEqual(built(all), total(all))
    assert.strictEqual(total(half), m.castle.wall.count)
    assert.ok(half.includes('class="cc-gate"') && count(half, /class="cc-bastion"/g) === 4 && half.includes('class="cc-table"'))
    assert.ok(half.includes('data-castle-effects="goal-reached" aria-hidden="true"></g>'), 'the goal-reached effects group exists and is empty')
    assert.ok(all.includes('cc-flag-reached'), 'the finished castle flies the done flag')
  })

  test('E92_S13_T02: each tower and the castle have labels and tooltips from the payload, English and Swedish; a payload without them falls back to English', () => {
    const g = castleGraph(MIXED, CEN, 40)
    const en = renderCitadel(g, CEN)
    assert.ok(en.includes('aria-label="E01_S02: 1 of 4 done"') && en.includes('<title>E01_S02: 1 of 4 done</title>'))
    assert.ok(en.includes('aria-label="E01_S03: 1 of 3 done, 1 failed"') && en.includes('<title>E01_S03: 1 of 3 done, 1 failed</title>'), 'the failed count is added')
    assert.ok(en.includes('aria-label="E01_S05 Story 5: not broken down yet"'), 'an undecomposed story says so')
    const sv = renderCitadel(castleGraph(MIXED, CSV, 40), CSV)
    assert.ok(sv.includes('aria-label="E01_S02: 1 av 4 klara"') && sv.includes('aria-label="E01_S03: 1 av 3 klara, misslyckade: 1"') && sv.includes('inte nedbruten ännu'))
    const bare = renderCitadel(castleGraph(MIXED, {}, 40), {})
    assert.ok(bare.includes('aria-label="E01_S02: 1 of 4 done"'), 'English fallback words')
    // a tower is an image of its own inside the goal group, so a screen reader reaches it; the castle keeps the goal label
    assert.strictEqual(count(goalHtml(en), /data-tower="/g), 6)
    assert.ok(/<g class="dt-node dt-goal[^>]*role="group" aria-label="Goal: E01 Goal epic · /.test(en) && count(en, /role="img"/g) >= 6)
  })

  test('E92_S13_T02: the goal edges end at the castle, spread over several points, and never at the old inset', () => {
    const g = castleGraph([{ states: [D, D] }, { states: [D, R], deps: [1] }, { states: [R], deps: [1] }, { states: [D, D, D] }, { undec: true }], CEN, 50)
    const m = citadelModel(g, CEN)
    const html = renderCitadel(g, CEN)
    const ends = [...html.matchAll(/data-to="goal"[^>]* d="M[^"]* ([\d.-]+) ([\d.-]+)"/g)].map(x => [Number(x[1]), Number(x[2])])
    const sources = [...html.matchAll(/data-to="goal"/g)].length
    assert.ok(sources >= 4 && ends.length === sources, 'one end per goal edge')
    assert.strictEqual(new Set(ends.map(e => e.join(','))).size, ends.length, 'no two edges end on one point')
    const { box } = m.castle
    for (const [x, y] of ends) {
      assert.notStrictEqual(x, m.goal.x - 46, 'not the star inset')
      assert.ok(x >= m.goal.x + box.left - 1 && x <= m.goal.x + 1, `x ${x} is at the castle`)
      assert.ok(y >= m.goal.y + box.top && y <= m.goal.y + box.bottom, `y ${y} is within the castle height`)
    }
    // sorted by the height of their sources, so none crosses another: the ends go down as the sources do
    const startsY = [...html.matchAll(/data-to="goal"[^>]* d="M[^ ]* ([\d.-]+) /g)].map(x => Number(x[1]))
    const order = ends.map((e, i) => i).sort((a, b) => startsY[a] - startsY[b] || a - b)
    for (let i = 1; i < order.length; i++) assert.ok(ends[order[i]][1] >= ends[order[i - 1]][1], 'ends are in order of their sources')
    assert.ok(!/GOAL_EDGE_INSET/.test(fs.readFileSync(path.join(compDir, 'CitadelGoal.jsx'), 'utf8') + jsx), 'GOAL_EDGE_INSET is not used for the goal')
  })

  test('E92_S13_T02: the citadel source has no colour literal, no hard-coded word and no animation; its css has one palette hook', () => {
    const src = stripComments(fs.readFileSync(path.join(compDir, 'CitadelGoal.jsx'), 'utf8'))
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(src) && !/\b(rgb|rgba|hsl|hsla|oklch|color-mix)\(/.test(src), 'no colour literal')
    const text = [...src.matchAll(/<[A-Za-z][^<>]*>([^<>{}\n]*[A-Za-z][^<>{}\n]*)<\//g)].map(x => x[1].trim()).filter(Boolean)
    assert.deepStrictEqual(text, [], 'hard-coded JSX text: ' + text.join(' | '))
    assert.ok(!/animation|<animate|setInterval|requestAnimationFrame/.test(src), 'nothing moves, so reduced motion has nothing to stop')
    const cs = css.slice(css.indexOf('goal: the citadel'), css.indexOf('/* day and night (E92_S13_T04)')) // the day and night section has the only movement, tested in E92_S13_T04
    const hook = cs.slice(cs.indexOf('.dt-castle {'), cs.indexOf('}', cs.indexOf('.dt-castle {')))
    const defined = [...hook.matchAll(/(--cc-[a-z-]+):\s*var\((--color-castle-[a-z-]+)\)/g)]
    const used = new Set([...cs.matchAll(/var\((--cc-[a-z-]+)\)/g)].map(x => x[1]))
    assert.ok(defined.length >= 20 && [...used].every(u => defined.some(d => d[1] === u)), 'every --cc-* in use is defined once, from a token, in the hook')
    const tokens = fs.readFileSync(path.join(uiDir, 'src', 'tokens.css'), 'utf8')
    for (const d of defined) assert.strictEqual(count(tokens, new RegExp(d[2] + '\\s*:', 'g')), 3, `${d[2]} is defined for light and for dark (two blocks)`)
    assert.ok(!/@keyframes|animation\s*:/.test(cs), 'no animation in the citadel rules')
  })

  // ===================== E92_S13_T03: the facade, the flat design of the same castle model =====================
  const withFacadeChoice = fn => {
    const was = globalThis.window
    try {
      globalThis.window = { localStorage: { getItem: () => 'facade', setItem() {} } }
      return fn()
    } finally {
      if (was === undefined) delete globalThis.window
      else globalThis.window = was
    }
  }
  const renderFacade = (g, labels) => withFacadeChoice(() => renderToStaticMarkup(React.createElement(CitadelTree, { model: citadelModel(g, labels), labels })))
  const facadeTowerOf = (html, sid) => {
    const a = html.indexOf(`data-tower="${sid}"`)
    assert.ok(a > 0, 'facade tower ' + sid)
    const ends = ['data-bridge="', 'data-stack="', 'data-tower="', 'class="cf-gate"'].map(k => html.indexOf(k, a + 1)).filter(x => x > 0)
    return html.slice(html.lastIndexOf('<g ', a), Math.min(...ends))
  }
  const facadeTowers = html => html.slice(html.indexOf('class="cc-towers cf-towers"'), html.indexOf('class="cf-gate"'))
  const FMIX = [
    { states: [D, D, P, R, R] },
    { states: [D, D, F, X], deps: [1] },
    { states: [D, D], deps: [1] },
    { states: [R, R], deps: [2, 3] },
    { undec: true },
    { states: [D, D], deps: [5] },
  ]

  test('E92_S13_T03: the facade is registered as one entry, drawn when chosen and never by default; the text under it is the old goal text under the facade box', () => {
    assert.ok('facade' in GOAL_RENDERERS && GOAL_RENDERERS.facade.goalArea === 'facade' && GOAL_RENDERERS.star && GOAL_RENDERERS.citadel, 'the star and the citadel are still registered')
    assert.ok(renderCitadel(castleGraph(FMIX, CEN, 61), CEN).includes('data-castle="citadel"'), 'the citadel is still the default')
    const html = renderFacade(castleGraph(FMIX, CEN, 61), CEN)
    const goal = goalHtml(html)
    assert.ok(goal.includes('data-goal-design="facade"') && goal.includes('data-castle="facade"') && !goal.includes('data-castle="citadel"'))
    for (const x of ['dt-star-outline', 'dt-goal-ring', 'dt-goal-disc', 'dt-halo', 'dt-shimmer', 'dt-spark', 'cc-table', 'cc-wall-block']) assert.ok(!goal.includes(x), x)
    assert.ok(html.includes('data-goal-design="facade"') && /data-testid="dt-goal-design"/.test(html), 'the selector offers it')
    assert.ok(goal.includes('>Goal<') && goal.includes('>Goal epic<') && /class="dt-goal-count"[^>]*>\d+ \/ \d+ done · 61 %</.test(goal) && /dt-goal-decomposed"[^>]*>5\/6 stories decomposed</.test(goal), 'the text lines are unchanged')
    const m = unfoldGroups(citadelModel(castleGraph(FMIX, CEN, 61), CEN), new Set(), { goalArea: 'facade' })
    const y = c => Number(goal.match(new RegExp(`class="${c}"[^>]* y="([\\d.]+)"`))[1])
    const top = m.castle.facade.text.top
    assert.deepStrictEqual([y('dt-goal-name'), y('dt-goal-title'), y('dt-goal-count')], [top, top + 18, top + 36])
    assert.ok(top >= m.castle.facade.box.bottom && m.layout.goalArea === 'facade', 'the text starts under the facade, in the facade area')
    assert.ok(!/<canvas|<foreignObject|<image|<script|<img/.test(html), 'pure SVG')
  })

  test('E92_S13_T03: the citadel and the facade are drawn from the SAME model object, and agree on every tower, layer, stacking and the wall share', () => {
    const m = citadelModel(castleGraph(FMIX, CEN, 61), CEN)
    assert.ok(m.castle.source && m.castle.source === m.castle.facade.source, 'one castle model object for both geometries')
    assert.ok(m.castle.source.towers.length === 6 && m.castle.source.wall.percent === 61)
    const pick = t => ({ id: t.storyId, status: t.status, stacking: t.stacking, supports: t.supports, top: t.top, lean: t.lean, undecomposed: t.undecomposed, layers: t.layers.map(l => [l.direction, l.state, l.blockStates.join()]), loose: t.looseCount })
    assert.deepStrictEqual(m.castle.facade.towers.map(pick), m.castle.towers.map(pick), 'every tower is the same in both')
    assert.deepStrictEqual(m.castle.facade.roots, m.castle.roots)
    assert.strictEqual(m.castle.facade.wall.share, m.castle.wall.share)
    // the facade layout counts nothing: its towers are the model's towers, one layer per model layer
    for (const t of m.castle.facade.towers) assert.strictEqual(t.layers.length, m.castle.source.towers.find(x => x.storyId === t.storyId).layers.length)
    // changing the model changes both: the same input gives the same output, so two builds agree
    assert.deepStrictEqual(citadelModel(castleGraph(FMIX, CEN, 61), CEN).castle.facade, m.castle.facade)
    const facade = renderFacade(castleGraph(FMIX, CEN, 61), CEN)
    const citadel = renderCitadel(castleGraph(FMIX, CEN, 61), CEN)
    for (let i = 1; i <= 6; i++) assert.strictEqual(count(facade, new RegExp(`data-tower="${SID(i)}"`, 'g')), count(citadel, new RegExp(`data-tower="${SID(i)}"`, 'g')), 'one tower per story in both')
    assert.strictEqual(count(facadeTowers(facade), /class="cf-layer"/g), count(towersHtml(citadel), /class="cc-layer"/g), 'the same number of layers in both (bastions excluded)')
  })

  test('E92_S13_T03: every layer state has its own shape in the facade: block ends or a long block, grain, hatch with a dashed slot and a pulled-out block, wireframe, crack; no state is colour alone', () => {
    const html = renderFacade(castleGraph(FMIX, CEN, 40), CEN)
    const s1 = facadeTowerOf(html, SID(1))
    const s2 = facadeTowerOf(html, SID(2))
    assert.deepStrictEqual([...s1.matchAll(/class="cf-layer" data-state="([a-z_]+)" data-form="([a-z]+)"/g)].map(x => `${x[1]}:${x[2]}`), ['done:ends', 'done:long', 'in_progress:ends', 'pending:long', 'pending:ends'], 'layers alternate: block ends, then one long block')
    assert.strictEqual(count(s1, /class="cf-blk cc-done"/g), 3, 'done: three block ends')
    assert.strictEqual(count(s1, /class="cf-blk cf-long cc-done"/g), 1, 'done: one long block')
    assert.ok(s1.includes('class="cf-grain"') && s1.includes('class="cc-grain"'), 'done: end grain arcs on a block end, grain lines on a long block')
    assert.strictEqual(count(s1, /class="cf-slot"/g), 1, 'in progress: a dashed slot behind the pulled-out middle block')
    assert.strictEqual(count(s1, /class="cf-pull"/g), 1)
    assert.ok(s1.includes('url(#dt-facade-hatch-E01)') && html.includes('<pattern id="dt-facade-hatch-E01"'), 'in progress: hatched, the pattern is defined')
    assert.strictEqual(count(s1, /class="cf-blk cc-pend"/g) + count(s1, /class="cf-blk cf-long cc-pend"/g), 1 + 3, 'pending: wireframe blocks')
    assert.ok(!s1.includes('cc-crack') && !s1.includes('cc-fail'), 'no crack on a tower with no failed task')
    assert.strictEqual(count(s2, /class="cc-crack"/g), 3, 'failed: every block of the failed layer is cracked')
    assert.strictEqual(count(s2, /class="cf-blk cc-fail"/g), 3)
    // a long block in progress juts out at its end
    const long = renderFacade(castleGraph([{ states: [D, P] }], CEN, 40), CEN)
    assert.ok(facadeTowerOf(long, SID(1)).includes('cf-pull cf-stub'), 'in progress, long block: a hatched stub')
    // the shapes are separate from the colour: the css only paints them
    const cssFacade = css.slice(css.indexOf('goal: the facade'))
    for (const cls of ['cf-grain', 'cf-slot', 'cf-pull', 'cf-found']) assert.ok(cssFacade.includes('.' + cls), cls)
    assert.ok(/\.cf-blk\.cc-pend \{[^}]*stroke-dasharray/.test(cssFacade) && /\.cf-found \{[^}]*stroke-dasharray/.test(cssFacade), 'dashes carry pending and the foundation')
  })

  test('E92_S13_T03: a rejected task is a block lying beside the tower and not a layer; an undecomposed story is a sparsely dashed foundation with "?" and no layer, roof or battlements', () => {
    const html = renderFacade(castleGraph(FMIX, CEN, 40), CEN)
    const s2 = facadeTowerOf(html, SID(2))
    assert.strictEqual(count(s2, /class="cf-layer"/g), 3, 'three counted tasks, the rejected one is no layer')
    assert.strictEqual(count(s2, /class="cc-loose-block"/g), 1)
    const s5 = facadeTowerOf(html, SID(5))
    assert.ok(s5.includes('data-undecomposed="true"') && s5.includes('class="cc-foundation"') && s5.includes('>?</text>'))
    assert.ok(count(s5, /class="cf-found/g) >= 2 && !s5.includes('cf-layer') && !s5.includes('cc-roof') && !s5.includes('cc-battlements'))
    assert.ok(s5.includes('data-status="pending"'))
  })

  test('E92_S13_T03: stacking on one tower, a bridge, roof versus battlements, a leaning tower and a dashed foundation, in the facade', () => {
    const g = castleGraph(FMIX, CEN, 40)
    const html = renderFacade(g, CEN)
    const m = citadelModel(g, CEN)
    const t = Object.fromEntries(m.castle.facade.towers.map(x => [x.storyId, x]))
    assert.deepStrictEqual([t[SID(1)].stacking, t[SID(2)].stacking, t[SID(3)].stacking, t[SID(4)].stacking], ['ground', 'tower', 'tower', 'bridge'])
    assert.strictEqual(t[SID(2)].base, t[SID(1)].topY, 'S2 stands on the top of S1')
    assert.strictEqual(t[SID(3)].base, t[SID(1)].topY)
    assert.ok(html.indexOf(`data-stack="${SID(1)}"`) < html.indexOf(`data-stack="${SID(2)}"`), 'drawn inside the tower they stand on')
    assert.ok(html.includes(`data-bridge="${SID(4)}"`) && html.includes('class="cc-p cc-deck-front"') && facadeTowerOf(html, SID(4)).includes('data-stacking="bridge"'), 'a bridge deck for two supports')
    assert.ok(t[SID(4)].deck.x2 > t[SID(4)].deck.x1 && t[SID(4)].base === Math.min(t[SID(2)].topY, t[SID(3)].topY))
    const done = castleGraph([{ states: [D, D] }, { states: [D, D], deps: [1] }, { states: [D], deps: [1] }, { states: [D, R] }], CEN, 80)
    const dh = renderFacade(done, CEN)
    assert.ok(facadeTowerOf(dh, SID(1)).includes('data-top="battlements"') && facadeTowerOf(dh, SID(1)).includes('class="cc-battlements"') && !facadeTowerOf(dh, SID(1)).includes('cc-roof"'), 'a finished tower that carries others: battlements, no roof')
    assert.strictEqual(count(facadeTowers(dh), /class="cc-roof"/g), 2, 'the two finished leaf towers have a roof')
    assert.ok(facadeTowerOf(dh, SID(2)).includes('data-top="roof"') && facadeTowerOf(dh, SID(2)).includes('class="cc-flag'), 'roof and flag')
    assert.ok(facadeTowerOf(dh, SID(4)).includes('data-top="none"'))
    // the failed tower leans with what stands on it
    assert.ok(facadeTowerOf(html, SID(2)).includes('cc-lean'))
    const stackOf = sid => html.slice(html.lastIndexOf('<g ', html.indexOf(`data-stack="${sid}"`)), html.indexOf(`data-stack="${sid}"`) + 200)
    assert.ok(/skewX\(-4\)/.test(stackOf(SID(2))), 'the failed tower is sheared: ' + stackOf(SID(2)))
    assert.ok(!/skewX/.test(stackOf(SID(3))), 'a tower with no failed task stands upright')
  })

  test('E92_S13_T03: the curtain wall grows outward from the main building in BOTH directions by the model\'s wall share; the gate is a pulled-out block; the effects group is empty', () => {
    const wallOf = pct => citadelModel(castleGraph(FMIX, CEN, pct), CEN).castle.facade.wall
    for (const pct of [0, 20, 33, 50, 75, 89, 100]) {
      const w = wallOf(pct)
      assert.strictEqual(w.built, Math.round(w.count * pct / 100), 'built is the model share of the segments and bastions: ' + pct)
      const parts = [...w.segments, ...w.bastions]
      assert.strictEqual(parts.filter(x => x.built).length, w.built)
      const side = sd => w.segments.filter(x => x.side === sd).sort((a, b) => a.k - b.k)
      for (const sd of ['left', 'right']) {
        const ks = side(sd).map(x => x.built)
        assert.deepStrictEqual(ks, [...ks].sort((a, b) => b - a), `${sd}: the built segments are the ones nearest the building`)
      }
      const l = side('left').filter(x => x.built).length
      const r = side('right').filter(x => x.built).length
      assert.ok(Math.abs(l - r) <= 1 && (w.built < 2 || (l > 0 && r > 0) || w.built > w.segments.length), `both directions grow together at ${pct} % (${l} left, ${r} right)`)
      for (const sg of side('left')) assert.ok(sg.x2 <= -w.rowHalf, 'left segments lie left of the building')
      for (const sg of side('right')) assert.ok(sg.x1 >= w.rowHalf, 'right segments lie right of the building')
    }
    const none = renderFacade(castleGraph(FMIX, CEN, 0), CEN)
    const half = renderFacade(castleGraph(FMIX, CEN, 50), CEN)
    const all = renderFacade(castleGraph([{ states: [D, D] }], CEN, 100, true), CEN)
    const built = h => count(h, /class="cf-wall-block" data-built="true"/g)
    assert.strictEqual(built(none), 0)
    assert.strictEqual(built(half), wallOf(50).segments.filter(x => x.built).length)
    assert.strictEqual(built(all), count(all, /class="cf-wall-block"/g), 'a finished castle has its whole wall')
    assert.ok(half.includes('data-side="left"') && half.includes('data-side="right"'))
    assert.ok(/class="cf-gate" data-gate-built="true"/.test(half) && /class="cf-gate" data-gate-built="false"/.test(none), 'the gate is a dark block once the wall has started, a slot before')
    assert.ok(half.includes('class="cc-p cf-gate-door"') && !none.includes('cf-gate-door'))
    assert.strictEqual(count(half, /class="cf-bastion"/g), 2, 'a bastion at each end')
    assert.ok(half.includes('class="cf-ground"') && half.includes('class="cf-ground-line"'), 'the drawing-board ground')
    assert.ok(half.includes('data-castle-effects="goal-reached" aria-hidden="true"></g>'), 'the goal-reached effects group exists and is empty')
    assert.ok(all.includes('cc-flag-reached'), 'the finished castle flies the done flag')
  })

  test('E92_S13_T03: each tower has the same aria label and tooltip as in the citadel, English and Swedish; a payload without them falls back to English', () => {
    const g = castleGraph(FMIX, CEN, 40)
    const labelsOf = html => [...html.matchAll(/data-tower="([^"]+)"[^>]* aria-label="([^"]*)"/g)].map(x => [x[1], x[2]])
    assert.deepStrictEqual(labelsOf(renderFacade(g, CEN)), labelsOf(renderCitadel(g, CEN)), 'the same label for every tower')
    const en = renderFacade(g, CEN)
    assert.ok(en.includes('aria-label="E01_S02: 2 of 3 done, 1 failed"') && en.includes('<title>E01_S02: 2 of 3 done, 1 failed</title>') && en.includes('aria-label="E01_S05 Story 5: not broken down yet"'))
    const sv = renderFacade(castleGraph(FMIX, CSV, 40), CSV)
    assert.ok(sv.includes('aria-label="E01_S01: 2 av 5 klara"') && sv.includes('inte nedbruten ännu'))
    assert.ok(renderFacade(castleGraph(FMIX, {}, 40), {}).includes('aria-label="E01_S01: 2 of 5 done"'), 'English fallback words')
    assert.strictEqual(count(goalHtml(en), /data-tower="/g), 6)
    assert.ok(/<g class="dt-node dt-goal[^>]*role="group" aria-label="Goal: E01 Goal epic · /.test(en))
  })

  test('E92_S13_T03: the goal edges end down the left edge of the facade, spread over several points, and never at the old inset', () => {
    const g = castleGraph([{ states: [D, D] }, { states: [D, R], deps: [1] }, { states: [R], deps: [1] }, { states: [D, D, D] }, { undec: true }], CEN, 50)
    const html = renderFacade(g, CEN)
    const m = unfoldGroups(citadelModel(g, CEN), new Set(), { goalArea: 'facade' })
    const ends = [...html.matchAll(/data-to="goal"[^>]* d="M[^"]* ([\d.-]+) ([\d.-]+)"/g)].map(x => [Number(x[1]), Number(x[2])])
    assert.ok(ends.length >= 4 && ends.length === count(html, /data-to="goal"/g))
    assert.strictEqual(new Set(ends.map(e => e.join(','))).size, ends.length, 'no two edges end on one point')
    const { box } = m.castle.facade
    for (const [x, y] of ends) {
      assert.notStrictEqual(x, m.goal.x - 46, 'not the star inset')
      assert.ok(x >= m.goal.x + box.left - 1 && x <= m.goal.x + 1, `x ${x} is at the facade`)
      assert.ok(y >= m.goal.y + box.top && y <= m.goal.y + box.bottom, `y ${y} is within the facade height`)
    }
    const startsY = [...html.matchAll(/data-to="goal"[^>]* d="M[^ ]* ([\d.-]+) /g)].map(x => Number(x[1]))
    const order = ends.map((e, i) => i).sort((a, b) => startsY[a] - startsY[b] || a - b)
    for (let i = 1; i < order.length; i++) assert.ok(ends[order[i]][1] >= ends[order[i - 1]][1], 'ends are in order of their sources')
  })

  test('E92_S13_T03: the facade source has no colour literal, no hard-coded word and no animation; its css uses the citadel\'s one palette hook and no token of its own', () => {
    const src = stripComments(fs.readFileSync(path.join(compDir, 'FacadeGoal.jsx'), 'utf8'))
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(src) && !/\b(rgb|rgba|hsl|hsla|oklch|color-mix)\(/.test(src), 'no colour literal')
    const text = [...src.matchAll(/<[A-Za-z][^<>]*>([^<>{}\n]*[A-Za-z][^<>{}\n]*)<\//g)].map(x => x[1].trim()).filter(Boolean)
    assert.deepStrictEqual(text, [], 'hard-coded JSX text: ' + text.join(' | '))
    assert.ok(!/animation|<animate|setInterval|requestAnimationFrame/.test(src), 'nothing moves')
    assert.ok(!/<canvas|<foreignObject|<image|<script|<img/.test(src), 'pure SVG')
    const cf = css.slice(css.indexOf('goal: the facade'), css.indexOf('/* day and night (E92_S13_T04)'))
    assert.ok(!/@keyframes|animation\s*:/.test(cf) && !/#[0-9a-fA-F]{3,8}\b/.test(stripComments(cf)))
    const hook = css.slice(css.indexOf('.dt-castle {'), css.indexOf('}', css.indexOf('.dt-castle {')))
    const defined = new Set([...hook.matchAll(/(--cc-[a-z-]+):/g)].map(x => x[1]))
    const used = [...new Set([...stripComments(cf).matchAll(/var\((--[a-z0-9-]+)/g)].map(x => x[1]))]
    assert.ok(used.length >= 8 && used.every(u => defined.has(u) || u === '--color-progress-failed'), 'every colour of the facade is a --cc-* of the hook (or the failed colour): ' + used.join(' '))
    const cap = stripComments(fs.readFileSync(path.join(compDir, 'castleCaption.js'), 'utf8'))
    assert.ok(/castle_tower_undecomposed/.test(cap) && /castle_tower_failed/.test(cap) && /castleCaption/.test(fs.readFileSync(path.join(compDir, 'CitadelGoal.jsx'), 'utf8')) && /towerCaption/.test(src), 'one caption function for both designs')
  })

  // ===================== E92_S13_T04: day and night for the citadel and the facade =====================
  const DN_START = css.indexOf('/* day and night (E92_S13_T04)')
  const DN_END = css.indexOf('/* end E92_S13_T04 */')
  const dnCss = css.slice(DN_START, DN_END)
  const tokensText = fs.readFileSync(path.join(uiDir, 'src', 'tokens.css'), 'utf8')
  const DN_SRC = ['DayNightScene.jsx', 'CitadelGoal.jsx', 'FacadeGoal.jsx'].map(f => [f, stripComments(fs.readFileSync(path.join(compDir, f), 'utf8'))])
  const StarGoalSource = () => fs.readFileSync(path.join(compDir, 'StarGoal.jsx'), 'utf8')
  const REACHED = [{ states: [D, D, D] }, { states: [D, D], deps: [1] }]
  const designHtml = {
    citadel: (g, l) => renderCitadel(g, l),
    facade: (g, l) => renderFacade(g, l),
  }
  const layoutOf = (design, g) => (design === 'citadel' ? citadelModel(g, CEN).castle : citadelModel(g, CEN).castle.facade)
  const sunOf = html => {
    const m = html.match(/class="dn-sun" data-percent="(\d+)" transform="translate\(([-\d.]+) ([-\d.]+)\) scale\(([-\d.]+)\)"/)
    assert.ok(m, 'the sun is drawn')
    return { percent: Number(m[1]), x: Number(m[2]), y: Number(m[3]), k: Number(m[4]) }
  }

  test('E92_S13_T04: day and night are the theme, read by CSS alone: both halves are in the markup of both designs, the theme tokens say which one shows, and there is no control of its own', () => {
    for (const design of ['citadel', 'facade']) {
      const html = designHtml[design](castleGraph(MIXED, CEN, 61), CEN)
      const goal = goalHtml(html)
      assert.ok(goal.includes('class="dt-castle dn-scene"') && goal.includes('class="dn-sky') && goal.includes('class="dn-day"') && goal.includes('class="dn-night"'), design + ': a scene with both halves')
      assert.ok(!/data-theme|prefers-color-scheme|matchMedia/.test(goal), design + ': the markup does not read the theme')
      assert.ok(!/<script|<button|role="switch"|aria-label="[^"]*(day|night)/i.test(goal), design + ': no separate day and night control')
    }
    // the two display tokens carry the theme: day shows in the light theme, night in the dark one (the media block, the attribute block)
    assert.ok(/\.dep-tree \.dn-day \{ display: var\(--theme-day-display\); \}/.test(dnCss) && /\.dep-tree \.dn-night \{ display: var\(--theme-night-display\); \}/.test(dnCss))
    const tok = stripComments(tokensText)
    assert.strictEqual(count(tok, /--theme-day-display:\s*inline;/g), 1, 'the day half shows in the light block only')
    assert.strictEqual(count(tok, /--theme-day-display:\s*none;/g), 2, 'and is hidden in the two dark blocks')
    assert.strictEqual(count(tok, /--theme-night-display:\s*none;/g), 1)
    assert.strictEqual(count(tok, /--theme-night-display:\s*inline;/g), 2)
    // what the light and the dark block say, in order: light first, then the media block, then the attribute block
    const order = [...tok.matchAll(/--theme-day-display:\s*(inline|none)/g)].map(m => m[1])
    assert.deepStrictEqual(order, ['inline', 'none', 'none'])
    assert.ok(!/\[data-day\]|data-night|\.is-night|\.is-day/.test(dnCss + css), 'no class or attribute of its own switches day and night')
  })

  test('E92_S13_T04: the sun\'s height follows the epic percent the payload states, in both designs; it is not recomputed', () => {
    for (const design of ['citadel', 'facade']) {
      let last = Infinity
      for (const pct of [0, 25, 50, 75, 100]) {
        const g = castleGraph(MIXED, CEN, pct)
        const frame = dayNight.skyFrame(layoutOf(design, g))
        const sun = sunOf(designHtml[design](g, CEN))
        const want = dayNight.sunPosition(frame, pct)
        assert.strictEqual(sun.percent, pct)
        assert.ok(Math.abs(sun.x - want.x) < 0.02 && Math.abs(sun.y - want.y) < 0.02, `${design} ${pct} %: the sun stands where the model says (${sun.y} vs ${want.y})`)
        assert.ok(sun.y < last, `${design}: the sun rises with the percent`)
        last = sun.y
      }
    }
    // a percent the payload does not state is zero: the sun is low, nothing is derived from the tasks
    const noProgress = { ...castleGraph(MIXED, CEN, 61), epics: castleGraph(MIXED, CEN, 61).epics.map(e => ({ ...e, epic_progress: undefined })) }
    assert.strictEqual(sunOf(designHtml.citadel(noProgress, CEN)).percent, 0)
  })

  test('E92_S13_T04: birds fly only when the goal is reached: an epic that has not reached it (failed or undecomposed story included) shows none; sparks are gone', () => {
    for (const design of ['citadel', 'facade']) {
      const flocks = dayNight.BIRD_FLOCKS
      const birds = flocks.reduce((a, f) => a + f.length, 0)
      for (const [name, spec, pct] of [['in progress', MIXED, 61], ['a failed story', FMIX, 99], ['an undecomposed story', [{ states: [D, D] }, { undec: true }], 50], ['percent 100 but the goal not stated', REACHED, 100]]) {
        const goal = goalHtml(designHtml[design](castleGraph(spec, CEN, pct, false), CEN))
        assert.strictEqual(count(goal, /class="dn-bird"/g), 0, `${design}, ${name}: no birds`)
        assert.strictEqual(count(goal, /class="dn-star"/g), 0, `${design}, ${name}: no twinkling stars`)
        assert.ok(goal.includes('data-castle-effects="goal-reached" aria-hidden="true"></g>'), `${design}, ${name}: the effects group is empty`)
      }
      const goal = goalHtml(designHtml[design](castleGraph(REACHED, CEN, 100, true), CEN))
      assert.strictEqual(count(goal, /class="dn-bird"/g), birds, design + ': the flocks fly when the goal is reached')
      assert.strictEqual(count(goal, /class="dn-flock"/g), flocks.length)
      assert.strictEqual(count(goal, /class="dn-star"/g), dayNight.TWINKLE_STARS.length, design + ': the stars twinkle when the goal is reached')
      const fx = goal.slice(goal.indexOf('data-castle-effects'))
      assert.ok(fx.includes('class="dn-day dn-birds"') && fx.includes('class="dn-night dn-stars"'), 'birds belong to the day half and stars to the night half')
      for (const old of ['dt-spark', 'dt-twinkles', 'dt-shimmer', 'dt-halo']) assert.ok(!goal.includes(old), `${design}: ${old} is gone from the goal`)
    }
  })

  test('E92_S13_T04: night: every finished layer shows a lit window (shown by night only), the gate is lit, and nothing else gets one', () => {
    const g = castleGraph(MIXED, CEN, 40)
    const cit = towersHtml(renderCitadel(g, CEN))
    assert.strictEqual(count(cit, /class="cc-win cc-win-[lr] dn-night"/g), count(cit, /class="cc-layer" data-state="done"/g), 'citadel: one window per finished layer')
    assert.ok(count(cit, /class="cc-win /g) === 3 + 1 + 1 + 2)
    assert.ok(!/cc-win/.test(towerOf(renderCitadel(g, CEN), SID(4))), 'a tower with no finished layer has no window')
    const fac = facadeTowers(renderFacade(castleGraph(FMIX, CEN, 40), CEN))
    assert.strictEqual(count(fac, /class="cf-win dn-night"/g), count(fac, /data-state="done" data-form="ends"/g), 'facade: one window per finished block-end layer')
    assert.ok(count(fac, /class="cf-win /g) > 0)
    for (const rule of ['.cc-win-l', '.cc-win-r', '.cf-win']) assert.ok(dnCss.includes(rule), rule + ' is painted')
    // the gate is lit by night through the same token the day uses for a dark gate; the guard checks it against the wall
    const lum = hex => parseInt(hex.slice(1, 3), 16) + parseInt(hex.slice(3, 5), 16) + parseInt(hex.slice(5, 7), 16)
    const gate = [...stripComments(tokensText).matchAll(/--color-castle-gate:\s*(#[0-9a-fA-F]{6})/g)].map(m => lum(m[1]))
    assert.strictEqual(gate.length, 3)
    assert.ok(gate[1] > gate[0] + 300 && gate[2] === gate[1], 'the gate token is dark by day and lit by night')
    assert.ok(/class="cc-p cc-gate-door"/.test(renderCitadel(castleGraph(REACHED, CEN, 100, true), CEN)), 'the citadel gate of a built wall is drawn with the gate token')
  })

  test('E92_S13_T04: reduced motion: every castle movement is declared inside prefers-reduced-motion: no-preference for a root without data-motion="off"; the base drawing is the final, readable state', () => {
    const blocks = topLevel(dnCss)
    const motion = /(^|[\s;{])(animation|transition)(-[a-z-]+)?\s*:/
    const guard = blocks.filter(b => /^@media\s*\(prefers-reduced-motion:\s*no-preference\)$/.test(b.head))
    assert.strictEqual(guard.length, 1, 'one guard')
    const names = new Set()
    let rules = 0
    for (const rule of guard[0].body.split('}').map(r => r.trim()).filter(Boolean)) {
      const [sel, decl] = rule.split('{')
      for (const one of sel.split(',')) assert.ok(one.trim().startsWith(':root:not([data-motion="off"]) .dep-tree '), 'gated by data-motion and scoped to the tree: ' + one.trim())
      const m = decl.match(/animation:\s*([a-z-]+)/)
      if (m) names.add(m[1])
      rules++
    }
    assert.deepStrictEqual([...names].sort(), ['dn-drift', 'dn-flap', 'dt-twinkle'], 'birds flap and drift, the stars reuse dt-twinkle')
    assert.ok(rules >= 8)
    for (const b of blocks) if (b !== guard[0]) assert.ok(!motion.test(b.body), 'movement outside the guard: ' + b.head)
    // no second twinkle: one keyframes rule with that word, the existing dt-twinkle, and the section's keyframes are the two bird ones
    assert.strictEqual(count(css, /@keyframes\s+[a-z-]*twinkle/g), 1, 'one twinkle keyframes rule')
    assert.ok(/@keyframes dt-twinkle \{/.test(css.slice(0, DN_START)), 'the twinkle is the existing one, declared before the section')
    assert.deepStrictEqual([...dnCss.matchAll(/@keyframes\s+([a-z-]+)/g)].map(m => m[1]).sort(), ['dn-drift', 'dn-flap'])
    // the still state: the base rules do not hide anything and set no opacity of zero or of a keyframe's start
    const base = blocks.filter(b => !b.head.startsWith('@'))
    for (const b of base) assert.ok(!/(^|[;\s])opacity\s*:\s*0(\.\d+)?\s*(;|$)/.test(b.body), 'a base rule hides an element: ' + b.head)
    assert.ok(/\.dn-bird \{[^}]*stroke: var\(--dn-bird\)/.test(dnCss) && /\.dn-star \{[^}]*fill: var\(--dn-twinkle\)/.test(dnCss), 'birds and stars are painted in the still state')
    assert.ok(!/@media[^{]*prefers-reduced-motion:\s*reduce/.test(dnCss), 'no reduce-only branch: the base state is the final state')
    for (const [f, src] of DN_SRC) assert.ok(!/animation|<animate|setInterval|requestAnimationFrame|style=/.test(src), f + ': nothing moves in the markup')
  })

  test('E92_S13_T04: every new colour is a token for light and dark, no component has a colour literal or a word, and the old star-disc shimmer is out of the castle goals', () => {
    const tok = stripComments(tokensText)
    const sky = ['sky-top', 'sky-bottom', 'sky-sun', 'sky-sun-ray', 'sky-moon', 'sky-star', 'sky-twinkle', 'sky-bird', 'castle-win-l', 'castle-win-r']
    for (const t of sky) assert.strictEqual(count(tok, new RegExp('--color-' + t + '\\s*:', 'g')), 3, `--color-${t} defined for light and dark (two blocks)`)
    for (const [f, src] of DN_SRC) {
      assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(src) && !/\b(rgb|rgba|hsl|hsla|oklch|color-mix)\(/.test(src), f + ': no colour literal')
      const text = [...src.matchAll(/<[A-Za-z][^<>]*>([^<>{}\n]*[A-Za-z][^<>{}\n]*)<\//g)].map(x => x[1].trim()).filter(Boolean)
      assert.deepStrictEqual(text, [], f + ': hard-coded JSX text')
      assert.ok(!/<canvas|<foreignObject|<image|<script|<img/.test(src), f + ': pure SVG')
    }
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(stripComments(dnCss)) && !/\b(rgb|rgba|hsl|hsla|oklch|color-mix)\(/.test(dnCss), 'no colour literal in the section')
    const used = [...new Set([...stripComments(dnCss).matchAll(/var\((--[a-z0-9-]+)/g)].map(m => m[1]))]
    assert.ok(used.every(u => u.startsWith('--dn-') || u.startsWith('--cc-') || ['--theme-day-display', '--theme-night-display', '--color-sky-top', '--color-sky-bottom', '--color-sky-sun', '--color-sky-sun-ray', '--color-sky-moon', '--color-sky-star', '--color-sky-twinkle', '--color-sky-bird'].includes(u)), 'only the two hooks and the theme tokens: ' + used.join(' '))
    // the star design keeps its own shimmer (it is the star-disc goal and still a selectable design); neither castle uses it
    assert.ok(/\.dt-shimmer \{/.test(css) && /dt-shimmer 3\.4s/.test(css) && StarGoalSource().includes('dt-shimmer'), 'the shimmer is still the star design\'s')
    for (const design of ['citadel', 'facade']) assert.ok(!goalHtml(designHtml[design](castleGraph(REACHED, CEN, 100, true), CEN)).includes('dt-shimmer'), design + ': no shimmer sweep in the goal')
    for (const [f, src] of DN_SRC) assert.ok(!src.includes('dt-shimmer'), f)
  })

  test('E92_S13_T04: the theme reading, the token palette hook and the reduced-motion rules are one shared piece a third design reuses: both castles use it, it names no castle class, and no tree colour is added', () => {
    const cit = goalHtml(renderCitadel(castleGraph(MIXED, CEN, 61), CEN))
    const fac = goalHtml(renderFacade(castleGraph(FMIX, CEN, 61), CEN))
    for (const html of [cit, fac]) assert.ok(html.includes('dn-scene') && html.includes('class="dn-sky') && html.includes('class="dn-sun"'))
    for (const [f, src] of DN_SRC.slice(1)) assert.ok(/from '\.\/DayNightScene'/.test(src) && /DaySky/.test(src) && /DayNightEffects/.test(src), f + ' draws the shared scene')
    const shared = dnCss.slice(0, dnCss.indexOf("/* the castle's lit windows"))
    assert.ok(shared.length > 1500 && !/castle|cc-|cf-/.test(stripComments(shared)), 'the shared rules name no castle class')
    const hook = shared.slice(shared.indexOf('.dep-tree .dn-scene {'), shared.indexOf('}', shared.indexOf('.dep-tree .dn-scene {')))
    const defined = [...hook.matchAll(/(--dn-[a-z-]+):\s*var\((--color-sky-[a-z-]+)\)/g)]
    const usedHook = new Set([...stripComments(dnCss).matchAll(/var\((--dn-[a-z-]+)\)/g)].map(m => m[1]))
    assert.ok(defined.length === 8 && [...usedHook].every(u => defined.some(d => d[1] === u)), 'every --dn-* in use is defined once, from a --color-sky-* token, in the hook')
    // E92_S13_T07 added the --color-tree-* tokens to tokens.css (its own section, its own stylesheet); what stays true is that the SHARED
    // day and night section carries no tree colour and no tree rule, which is why the tree reuses it instead of editing it
    assert.ok(!/tree|season|foliage/i.test(stripComments(dnCss).replace(/\.dep-tree|dep-tree|dependency tree|the tree|seasons tree/gi, '')), 'no tree colour or tree rule in the shared section')
    assert.ok(/\.dn-line \.dn-sun-core/.test(dnCss), 'the drawing-board variant is a modifier of the same classes')
  })

  // ===================== E92_S13_T07: the seasons tree, the third goal design =====================
  // The tree has a stylesheet of its own (seasons-tree.css, loaded by TreeGoal.jsx), so no section of dependency-tree.css the tests
  // above slice to the end of the file is touched; these tests read that stylesheet.
  const treeCss = fs.readFileSync(path.join(compDir, 'seasons-tree.css'), 'utf8')
  const treeSrc = stripComments(fs.readFileSync(path.join(compDir, 'TreeGoal.jsx'), 'utf8'))
  const treeLayoutSrc = fs.readFileSync(path.join(compDir, 'treeLayout.js'), 'utf8')
  const withTreeChoice = fn => {
    const was = globalThis.window
    try {
      globalThis.window = { localStorage: { getItem: () => 'tree', setItem() {} } }
      return fn()
    } finally {
      if (was === undefined) delete globalThis.window
      else globalThis.window = was
    }
  }
  const TEN = { ...CEN, tree_stage_sprout: 'Sprout', tree_stage_seedling: 'Seedling', tree_stage_sapling: 'Sapling', tree_stage_young: 'Young tree', tree_stage_mature: 'Mature tree', tree_stage_majestic: 'Majestic tree', tree_stage_track: 'Growth stage: %s' }
  const renderTree = (g, labels = TEN) => withTreeChoice(() => renderToStaticMarkup(React.createElement(CitadelTree, { model: citadelModel(g, labels), labels })))
  const treeModelOf = g => unfoldGroups(citadelModel(g, TEN), new Set(), { goalArea: 'tree' })
  const attrCount = (html, re) => (html.match(re) || []).length
  const TMIX = [
    { states: [D, D, D] },
    { states: [D, P, R, R], deps: [1] },
    { states: [D, F, R, X], deps: [1] },
    { states: [R, R], deps: [2, 3] },
    { undec: true, deps: [1] },
    { states: [D, D], deps: [1] },
  ]

  test('E92_S13_T08: the citadel paints no sky backdrop panel, yet keeps the sun, the moon and the stars; the seasons tree keeps its own backdrop', () => {
    for (const reached of [false, true]) {
      const cit = goalHtml(renderCitadel(castleGraph(reached ? REACHED : MIXED, CEN, reached ? 100 : 61, reached), CEN))
      assert.ok(!cit.includes('dn-backdrop') && !cit.includes('dn-sky-top') && !/<linearGradient id="dt-sky-/.test(cit), 'no sky panel in the citadel (reached ' + reached + ')')
      assert.ok(cit.includes('class="dn-sky') && cit.includes('class="dn-sun"') && cit.includes('class="dn-moon"') && cit.includes('class="dn-night"'), 'the sun and the moon are still drawn')
    }
    assert.ok(goalHtml(renderCitadel(castleGraph(REACHED, CEN, 100, true), CEN)).includes('data-effect="birds"'), 'the birds still fly at goal reached')
    assert.ok(goalHtml(renderTree(castleGraph(TMIX, TEN, 61))).includes('dn-backdrop'), 'the seasons tree keeps its sky panel')
    assert.ok(!/<DaySky[^>]*\bbackdrop\b/.test(fs.readFileSync(path.join(__dirname, '..', 'src', 'components', 'progress', 'CitadelGoal.jsx'), 'utf8')), 'the citadel source passes no backdrop prop')
  })

  test('E92_S13_T07: the seasons tree is one more entry of the goal design list: registered, offered by the selector, drawn when chosen, never by default; the star, the citadel and the facade stay', () => {
    assert.ok('tree' in GOAL_RENDERERS && GOAL_RENDERERS.tree.goalArea === 'tree' && GOAL_RENDERERS.star && GOAL_RENDERERS.citadel && GOAL_RENDERERS.facade)
    assert.strictEqual(Object.keys(GOAL_RENDERERS).filter(k => k === 'tree').length, 1, 'one entry')
    assert.ok(renderCitadel(castleGraph(TMIX, TEN, 61), TEN).includes('data-castle="citadel"'), 'the citadel is still the default')
    const html = renderTree(castleGraph(TMIX, TEN, 61))
    const goal = goalHtml(html)
    assert.ok(goal.includes('data-goal-design="tree"') && goal.includes('data-castle="tree"') && !goal.includes('data-castle="citadel"') && !goal.includes('data-castle="facade"'))
    for (const x of ['dt-star-outline', 'dt-goal-ring', 'dt-goal-disc', 'dt-halo', 'dt-shimmer', 'dt-spark', 'cc-table', 'cc-wall-block', 'cc-tower', 'cf-tower']) assert.ok(!goal.includes(x), x)
    assert.ok(/data-testid="dt-goal-design"/.test(html) && html.includes('data-goal-design="tree"'), 'the selector offers it')
    assert.ok(!/<canvas|<foreignObject|<image|<script|<img/.test(html), 'pure SVG')
  })

  test('E92_S13_T07: the text under the node is unchanged and not duplicated inside the drawing; the edges to the goal end at the tree, spread over several points', () => {
    const html = renderTree(castleGraph(TMIX, TEN, 61))
    const goal = goalHtml(html)
    assert.ok(goal.includes('>Goal<') && goal.includes('>Goal epic<') && /class="dt-goal-count"[^>]*>\d+ \/ \d+ done · 61 %</.test(goal) && /dt-goal-decomposed"[^>]*>5\/6 stories decomposed</.test(goal), 'the text lines are unchanged')
    const drawing = goal.slice(goal.indexOf('class="dt-tree dn-scene"'), goal.indexOf('class="dt-goal-name"'))
    assert.ok(!drawing.includes('Goal epic') && !drawing.includes('stories decomposed') && !/ done · 61 %/.test(drawing), 'the goal text is not inside the drawing')
    assert.strictEqual(attrCount(goal, /class="dt-goal-(name|title|count)"/g), 3, 'the three text lines once each')
    const m = treeModelOf(castleGraph(TMIX, TEN, 61))
    const y = c => Number(goal.match(new RegExp(`class="${c}"[^>]* y="([\\d.]+)"`))[1])
    const top = m.castle.tree.text.top
    assert.deepStrictEqual([y('dt-goal-name'), y('dt-goal-title'), y('dt-goal-count')], [top, top + 18, top + 36])
    assert.ok(top >= m.castle.tree.box.bottom, 'the text starts under the tree')
    // goal edges: one end per end task, none on top of another, all on the left of the goal and inside its area
    const goalEdges = [...html.matchAll(/<path class="dt-edge[^"]*dt-edge-goal[^"]*"[^>]*\sd="([^"]+)"/g)].map(x => x[1])
    assert.ok(goalEdges.length >= 2, 'the tree has several end stories: ' + goalEdges.length)
    const last = d => d.split(/[ ,]/).filter(Boolean).slice(-2).map(Number)
    const stops = goalEdges.map(last)
    assert.strictEqual(new Set(stops.map(p => p.join())).size, stops.length, 'each edge ends at its own point')
    assert.ok(stops.every(p => p[0] < m.goal.x), 'the edges end on the left of the goal')
  })

  test('E92_S13_T07: the worked example (16 tasks, 12 done, 11 stories, 9 decomposed) is drawn as 11 branches, 2 stubs, 12 done clumps; every state has its own shape and a branch its own aria label', () => {
    const WORKED = [
      { states: [D, D] }, { states: [D, D], deps: [1] }, { states: [D, D], deps: [1] }, { states: [D, D], deps: [2] }, { states: [D, D], deps: [3] },
      { states: [D, D], deps: [1] }, { states: [P, R], deps: [4] }, { states: [R], deps: [5] }, { states: [R], deps: [6] }, { undec: true, deps: [7] }, { undec: true, deps: [8] },
    ]
    const html = renderTree(castleGraph(WORKED, TEN, 61))
    const goal = goalHtml(html)
    assert.strictEqual(attrCount(goal, /class="tr-branch[^"]*" data-branch="/g), 11)
    assert.strictEqual(attrCount(goal, /data-stub="/g), 2)
    assert.strictEqual(attrCount(goal, /data-state="done"/g), 12)
    assert.strictEqual(attrCount(goal, /data-state="in_progress"/g), 1)
    assert.strictEqual(attrCount(goal, /data-state="pending"/g), 3)
    assert.strictEqual(attrCount(goal, /data-undecomposed="true"/g), 2)
    assert.ok(goal.includes('aria-label="E01_S01: 2 of 2 done"') && goal.includes('aria-label="E01_S10 Story 10: not broken down yet"'), 'the castle tower words, per branch: ' + (goal.match(/aria-label="E01_S1?[01][^"]*"/g) || []).join(' | '))
    assert.ok(attrCount(goal, /data-ribbon="/g) === 11, 'a status ribbon on every branch base')
  })

  test('E92_S13_T07: shapes, not colour alone: blossom and flowers for in progress, a bare snowy twig for to do, a withered clump with fallen leaves for failed, a "?" pill and a dashed stub for a story not broken down, snow along a branch that has not started, a vine and lantern for a finished leaf', () => {
    const html = renderTree(castleGraph(TMIX, TEN, 61))
    const goal = goalHtml(html)
    const wip = goal.slice(goal.indexOf('data-state="in_progress"'), goal.indexOf('data-state="pending"'))
    assert.ok(wip.includes('tr-tone-bloom') || goal.includes('class="tr-wip tr-tone-bloom"'), 'blossom')
    assert.ok(attrCount(goal, /class="tr-flower"/g) >= 5, 'flowers on the blossom clump')
    const twig = goal.slice(goal.indexOf('data-state="pending"'))
    assert.ok(twig.includes('class="tr-twig"') && twig.includes('class="tr-snow"'), 'a twig with snow')
    const failed = goal.slice(goal.indexOf('class="tr-failed'))
    assert.ok(failed.includes('tr-tone-dead') && failed.includes('class="tr-crack"') && failed.includes('tr-fallen'), 'a withered clump shedding dead leaves')
    assert.ok(goal.includes('data-stub="E01_S05"') && goal.includes('class="tr-stub-ring"') && goal.includes('>E01_S05 ?<'), 'a stub and the "?"')
    assert.ok(goal.includes('class="tr-branch tr-droop"') && goal.includes('data-branch="E01_S03"'), 'a failed story\'s branch droops')
    assert.ok(/class="tr-snow-line" data-snow="E01_S04"/.test(goal), 'snow along the branch where nothing has started')
    assert.ok(!goal.includes('data-snow="E01_S01"') && !goal.includes('data-snow="E01_S02"'), 'but not on a started one')
    const vined = renderTree(castleGraph([{ states: [D, D, D] }, { states: [D, D], deps: [1] }, { states: [D, P], deps: [1] }], TEN, 61))
    assert.ok(/data-vine="E01_S02"/.test(vined) && !/data-vine="E01_S01"|data-vine="E01_S03"/.test(vined), 'a vine on the finished story nothing depends on')
    assert.ok(/class="tr-lantern-glow dn-night"/.test(vined) && /class="tr-lantern"/.test(vined), 'the lantern is lit by night (its glow is a night element)')
    assert.ok(goal.includes('class="tr-mass"') && goal.includes('class="tr-contour"') && goal.includes('class="tr-line-c tr-edge"') && goal.includes('class="tr-leaf"'), 'a detailed crown body: contour lines, light edges, leaves, shade')
    assert.ok(goal.includes('tr-shade'), 'with shade')
    assert.ok(goal.includes('class="tr-pill"') && goal.includes('class="tr-dot tr-st-'), 'labels are pills with a status dot')
  })

  test('E92_S13_T07: the stage track shows the six stages and names the current one from the labels (Sprout 0, Seedling 10, Sapling 25, Young tree 45, Mature tree 70, Majestic tree only at goal reached)', () => {
    const stageAt = (percent, reached) => { const g = castleGraph(TMIX.slice(0, 2), TEN, percent, reached); const goal = goalHtml(renderTree(g)); return [goal.match(/class="tr-track" data-stage="(\w+)"/)[1], goal.match(/class="tr-stage-name"[^>]*>([^<]+)</)[1], attrCount(goal, /class="tr-stage-dot/g)] }
    assert.deepStrictEqual(stageAt(0, false), ['sprout', 'Sprout', 6])
    assert.deepStrictEqual(stageAt(10, false).slice(0, 2), ['seedling', 'Seedling'])
    assert.deepStrictEqual(stageAt(25, false).slice(0, 2), ['sapling', 'Sapling'])
    assert.deepStrictEqual(stageAt(45, false).slice(0, 2), ['young', 'Young tree'])
    assert.deepStrictEqual(stageAt(70, false).slice(0, 2), ['mature', 'Mature tree'])
    assert.deepStrictEqual(stageAt(99, false).slice(0, 2), ['mature', 'Mature tree'])
    assert.deepStrictEqual(stageAt(100, true).slice(0, 2), ['majestic', 'Majestic tree'])
    const sv = renderTree(castleGraph(TMIX.slice(0, 2), { ...TEN, tree_stage_young: 'Ungt träd' }, 45), { ...TEN, tree_stage_young: 'Ungt träd' })
    assert.ok(sv.includes('>Ungt träd<'), 'the stage names come from the labels payload')
    const bare = renderTree(castleGraph(TMIX.slice(0, 2), EN, 45), EN)
    assert.ok(bare.includes('>Young tree<'), 'and fall back to English when the payload lacks them')
  })

  test('E92_S13_T07: the surroundings read the percent only: stones lift out at 24/25, 44/45, 64/65 and 84/85 percent, mushrooms from 55, the same for any tree', () => {
    const stones = pct => attrCount(goalHtml(renderTree(castleGraph(TMIX, TEN, pct))), /class="tr-stone"/g)
    assert.deepStrictEqual([0, 24, 25, 44, 45, 64, 65, 84, 85, 99].map(stones), [0, 0, 1, 1, 2, 2, 3, 3, 4, 4])
    const mush = pct => attrCount(goalHtml(renderTree(castleGraph(TMIX, TEN, pct))), /data-mushroom=/g)
    assert.deepStrictEqual([54, 55].map(mush), [0, 2])
    const other = pct => attrCount(goalHtml(renderTree(castleGraph([{ states: [D] }, { states: [R, R, R], deps: [1] }], TEN, pct))), /class="tr-stone"/g)
    assert.deepStrictEqual([24, 25, 44, 45, 64, 65, 84, 85].map(other), [0, 1, 1, 2, 2, 3, 3, 4], 'another tree, the same stones')
  })

  test('E92_S13_T07: goal reached: rays, motes, falling petals, a swing, two forest spirits, birds (day) and twinkling stars (night, the shared dt-twinkle); an epic with a failed or an undecomposed story shows none', () => {
    const reached = goalHtml(renderTree(castleGraph(REACHED, TEN, 100, true)))
    for (const e of ['data-effect="swing"', 'data-effect="petals"', 'data-effect="birds"', 'data-effect="stars"']) assert.ok(reached.includes(e), e)
    assert.strictEqual(attrCount(reached, /data-effect="spirit"/g), 2)
    assert.ok(attrCount(reached, /class="tr-mote"/g) > 10 && reached.includes('class="tr-rays dn-day"') && reached.includes('class="tr-rays dn-night"'))
    assert.ok(/class="tr-tone-0"|class="tr-done tr-tone-0"/.test(reached) && reached.includes('tr-tone-1'), 'each crown section has its own season tone')
    assert.ok(reached.includes('class="tr-tree tr-sway"'), 'the whole crown sways')
    for (const g of [castleGraph([{ states: [D, D] }, { states: [D, F], deps: [1] }], TEN, 99, false), castleGraph([{ states: [D, D] }, { undec: true, deps: [1] }], TEN, 99, false)]) {
      const html = goalHtml(renderTree(g))
      for (const e of ['data-effect="swing"', 'data-effect="petals"', 'data-effect="birds"', 'data-effect="stars"', 'data-effect="spirit"', 'tr-sway']) assert.ok(!html.includes(e), 'not reached: ' + e)
      assert.ok(!/class="tr-tone-[1-6]"/.test(html), 'not an all-seasons tree')
    }
    assert.ok(attrCount(goalHtml(renderTree(castleGraph(TMIX, TEN, 20))), /class="tr-mote"/g) < attrCount(reached, /class="tr-mote"/g), 'the motes strengthen with the percent')
  })

  test('E92_S13_T07: day and night are the theme, through the shared scene: both halves in the markup, the tree adds tokens of its own, no colour literal, no word, no movement in the component, every tree colour is a token for light and dark', () => {
    const goal = goalHtml(renderTree(castleGraph(TMIX, TEN, 61)))
    assert.ok(goal.includes('class="dt-tree dn-scene"') && goal.includes('class="dn-sky') && goal.includes('class="dn-sun"') && goal.includes('class="dn-night"'), 'the shared day and night scene')
    assert.ok(!/data-theme|prefers-color-scheme|matchMedia/.test(goal) && !/<button|role="switch"/.test(goal), 'no separate control')
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(treeSrc) && !/\b(rgb|rgba|hsl|hsla|oklch|color-mix)\(/.test(treeSrc), 'no colour literal in the component')
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(treeLayoutSrc.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')), 'none in the layout either')
    const words = [...treeSrc.matchAll(/<[A-Za-z][^<>]*>([^<>{}\n]*[A-Za-z][^<>{}\n]*)<\//g)].map(x => x[1].trim()).filter(Boolean)
    assert.deepStrictEqual(words, [], 'no hard-coded JSX text')
    assert.ok(!/animation|<animate|setInterval|requestAnimationFrame/.test(treeSrc), 'nothing moves in the component')
    assert.ok(/from '\.\/DayNightScene'/.test(treeSrc) && /DaySky/.test(treeSrc) && /DayNightEffects/.test(treeSrc), 'it draws the shared scene')
    const tok = stripComments(tokensText)
    const names = [...new Set([...tok.matchAll(/--color-tree-([a-z-]+)\s*:/g)].map(m => m[1]))]
    assert.ok(names.length > 60)
    for (const n of names) assert.strictEqual(count(tok, new RegExp('--color-tree-' + n + '\\s*:', 'g')), 3, `--color-tree-${n}: light, dark media block, dark attribute block`)
    const usedCss = [...new Set([...stripComments(treeCss).matchAll(/var\((--[a-z0-9-]+)/g)].map(m => m[1]))]
    for (const u of usedCss) assert.ok(u.startsWith('--tr-') || u.startsWith('--color-tree-') || u.startsWith('--color-progress-'), 'only tree and E92 tokens in the stylesheet: ' + u)
    for (const u of usedCss.filter(x => x.startsWith('--color-'))) assert.ok(count(tok, new RegExp(u + '\\s*:', 'g')) === 3, u + ' is defined for light and dark')
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(stripComments(treeCss)) && !/\b(rgb|rgba|hsl|hsla|oklch|color-mix)\(/.test(treeCss), 'no colour literal in the stylesheet')
    assert.ok(/--dn-sky-top:\s*var\(--color-tree-sky-top\)/.test(treeCss), 'the shared sky takes the tree\'s own sky tokens')
    assert.ok(treeSrc.includes("import './seasons-tree.css'"), 'the component loads its stylesheet')
    const ribbon = ['done', 'in-progress', 'failed', 'pending']
    for (const r of ribbon) assert.ok(treeCss.includes(`var(--color-progress-${r})`), 'the status ribbon keeps the E92 colour ' + r)
  })

  test('E92_S13_T07: every movement is stopped by :root[data-motion="off"] and by prefers-reduced-motion: reduce; the goal-reached state rests visible; the twinkle is the existing dt-twinkle', () => {
    const text = stripComments(treeCss)
    const blocks = []
    let depth = 0, start = 0, head = ''
    for (let i = 0; i < text.length; i++) {
      const c = text[i]
      if (c === '{') { if (depth === 0) { head = text.slice(start, i).trim(); start = i + 1 } depth++ }
      else if (c === '}') { depth--; if (depth === 0) { blocks.push({ head, body: text.slice(start, i) }); start = i + 1 } }
    }
    const MOTION = /(^|[\s;{])(animation|transition)(-[a-z-]+)?\s*:/
    for (const b of blocks) {
      if (/^@media\s*\(prefers-reduced-motion:\s*no-preference\)$/.test(b.head) || b.head.startsWith('@keyframes')) continue
      assert.ok(!MOTION.test(b.body), 'motion outside the guard: ' + b.head)
    }
    const guard = blocks.find(b => /^@media\s*\(prefers-reduced-motion:\s*no-preference\)$/.test(b.head))
    assert.ok(guard, 'one no-preference block')
    const rules = guard.body.split('}').map(r => r.trim()).filter(Boolean).map(r => r.split('{'))
    assert.ok(rules.length >= 7 && rules.every(([sel]) => sel.startsWith(':root:not([data-motion="off"]) .dep-tree ')), 'every animated rule says it is off with the toggle: ' + rules.map(r => r[0]).join(' | '))
    const names = new Set(rules.map(([, d]) => (d.match(/animation:\s*([a-z-]+)/) || [])[1]))
    for (const k of ['tr-sway', 'tr-swing', 'tr-fall', 'tr-mote', 'tr-drip', 'tr-bob']) assert.ok(names.has(k) && new RegExp('@keyframes\\s+' + k + '\\b').test(treeCss), k)
    assert.ok(!/@media[^{]*prefers-reduced-motion:\s*reduce/.test(treeCss), 'no reduce-only branch: the base state is the final state')
    // reduced motion shows the goal-reached state: the effects are in the markup whatever the preference, and nothing is hidden at rest
    const rest = text.replace(guard.body, '')
    assert.ok(!/\.tr-(fall|mote|drip|stone|swing|sway|vine)[^{]*\{[^}]*(display:\s*none|opacity:\s*0(?![.\d])|visibility:\s*hidden)/.test(rest), 'what moves is visible at rest')
    assert.ok(goalHtml(renderTree(castleGraph(REACHED, TEN, 100, true))).includes('data-effect="spirit"'), 'the goal-reached condition draws its effects with no script and no preference')
    // the twinkle is the shared one (dt-twinkle), the flap the shared dn-flap; the tree declares neither
    assert.ok(!/@keyframes\s+(tr-twinkle|tr-flap|dt-twinkle|dn-flap)/.test(treeCss), 'no second twinkle or flap')
    assert.ok(/\.dn-star \{ animation: dt-twinkle/.test(css.replace(/:root:not\(\[data-motion="off"\]\) \.dep-tree /g, '')), 'the stars of the shared scene use dt-twinkle')
  })

  test('E92_S13_T07: the tree\'s stylesheet is separate and the files that tests slice to the end are untouched: the tree section is bounded and dependency-tree.css has no tree rule', () => {
    assert.ok(!/\.dt-tree|\.tr-|--color-tree/.test(css), 'dependency-tree.css holds no tree rule')
    assert.ok(/\/\* end E92_S13_T07 \*\/\s*$/.test(treeCss), 'the stylesheet ends at its marker')
    const imports = [...fs.readFileSync(path.join(compDir, 'TreeGoal.jsx'), 'utf8').matchAll(/^import '([^']+\.css)'/gm)].map(m => m[1])
    assert.deepStrictEqual(imports, ['./seasons-tree.css'])
  })

  console.log(`\n${n} tests passed`)

})().catch(e => { console.error(e); process.exit(1) })
