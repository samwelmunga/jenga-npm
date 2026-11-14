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
const { React, renderToStaticMarkup, DependencyTree, buildDependencyTreeModel, FOLD_THRESHOLD, LAYOUT } = require(outReal)
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
  goal: 'Goal', ready_to_take: 'Ready to take', nothing_ready: 'Nothing ready', tree_empty: 'No dependencies to show',
  unlocked_by: '%s unlocked by %s', state_done: 'Done', state_ready: 'Ready', state_locked: 'Locked',
  state_failed: 'Failed', state_rejected: 'Rejected', in_progress: 'In progress',
  gate_waiting: 'Waiting for a dependency (locked)', gate_open: 'Dependency done (unlocked)', group_tasks: '%d tasks',
  show_all: 'Show all %d', collapse: 'Collapse', goal_reached: 'Goal reached!', goal_progress: '%d / %d done · %d %%',
  tip_depends_on: 'Depends on', tip_unlocks: 'Unlocks', tip_goal_direct: 'Leads straight to the goal',
}
const SV = {
  goal: 'Mål', ready_to_take: 'Redo att ta', nothing_ready: 'Inget redo', tree_empty: 'Inga beroenden att visa',
  unlocked_by: '%s låstes upp av %s', state_done: 'Klar', state_ready: 'Redo', state_locked: 'Låst',
  state_failed: 'Misslyckad', state_rejected: 'Avvisad', in_progress: 'Pågår',
  gate_waiting: 'Väntar på beroende (låst)', gate_open: 'Beroendet är klart (upplåst)', group_tasks: '%d uppgifter',
  show_all: 'Visa alla %d', collapse: 'Fäll ihop', goal_reached: 'Mål nått!', goal_progress: '%d / %d klara · %d %%',
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
    assert.strictEqual(FOLD_THRESHOLD, 5)
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
  const pct = (done, total) => {
    const tasks = [T('E01_S01_T01', S1, done >= 1 ? 'done' : 'ready', [])]
    for (let i = 2; i <= total; i++) tasks.push(T('E01_S01_T0' + i, S1, i <= done ? 'done' : 'ready', ['E01_S01_T01']))
    const html = render(graph(tasks, EN), EN)
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
    const sv = renderToStaticMarkup(React.createElement(DependencyTree, { model: model(graph([T('E01_S01_T01', S1, 'done', []), T('E01_S01_T02', S1, 'done', ['E01_S01_T01'])], SV), SV), labels: SV }))
    assert.ok(sv.includes('Mål nått!') && sv.includes('2 / 2 klara · 100 %'))
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

  test('empty model renders tree_empty only; nothing_ready renders its label and no list', () => {
    const html = render(graph([T('E01_S01_T01', S1, 'done', [])], EN), EN)
    assert.ok(html.includes('No dependencies to show') && !html.includes('<svg'))
    assert.ok(renderToStaticMarkup(React.createElement(DependencyTree, { model: null, labels: SV })).includes('Inga beroenden att visa'))
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
    assert.ok(html.includes('6 tasks') && html.includes('Show all 6') && html.includes('Waiting') === false)
    assert.ok(!/>(group_tasks|show_all|collapse|goal_progress|gate_open|gate_waiting)</.test(html))
    m.fire(m.node(GROUP), 'onClick')
    assert.ok(m.html().includes('Collapse'))
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
