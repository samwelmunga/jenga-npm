#!/usr/bin/env node
'use strict'
// E92_S06_T10 / E92_S06_T20: render test for DependencyTree (tree v2). Zero test framework and no DOM: the component is
// bundled with esbuild (CSS import stubbed) twice. Once with real React and react-dom/server (static render), once with
// `react` swapped, for the component sources only, for a tiny hook runtime (technique of epic-overlay-tree.test.cjs) so
// hover, focus, click and Enter can be driven through the handlers the component really sets, and the result is
// rendered to markup. The CSS and the JSX are parsed as text for the reduced-motion and no-colour-literal rules.
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
const { React, renderToStaticMarkup, DependencyTree, buildDependencyTreeModel, unfoldGroups, FOLD_THRESHOLD, LAYOUT } = require(outReal)
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
const mountTree = (g, labels) => mount(hook.DependencyTree, { model: hook.buildDependencyTreeModel(g, 'E01', labels), labels })
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
    assert.deepStrictEqual([...names].sort(), ['dt-blink', 'dt-breathe', 'dt-flow', 'dt-ring-pulse', 'dt-shimmer', 'dt-twinkle'])
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
    const used = [...new Set([...css.matchAll(/var\((--[a-z0-9-]+)/g)].map(m => m[1]))].filter(t => !local.has(t))
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

  console.log(`\n${n} tests passed`)

})().catch(e => { console.error(e); process.exit(1) })
