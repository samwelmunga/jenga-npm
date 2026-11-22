#!/usr/bin/env node
'use strict'
// E92_S13_T05: render test for the goal design selector and the goal slot of DependencyTree. Zero test framework and no
// DOM, the technique of dependency-tree.test.cjs: the sources are bundled with esbuild (CSS import stubbed) twice. Once
// with real React and react-dom/server (static render), once with `react` swapped, for the component sources only, for a
// tiny hook runtime so a pick can be driven through the handler the component really sets and the result rendered again.
// The real registry holds the star, (E92_S13_T02) the citadel and (E92_S13_T03) the facade; every other design here is a FAKE renderer handed to the
// tree through its `renderers` prop (and a fifth list entry through its `designs` prop); that is what proves the selector,
// the default, the stored choice and the fifth entry before the facade and the seasons tree exist. A renderer without a
// `goalArea` (the star, every fake) is laid out in the star's fixed disc area, so the models here are built for that area.
// Run: node project/app/ui/scripts/goal-design-selector.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const compDir = path.join(uiDir, 'src', 'components', 'progress')
const esbuild = require('esbuild')
const read = f => fs.readFileSync(path.join(compDir, f), 'utf8')
const css = read('dependency-tree.css')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'goal-design-selector-'))
const nodePaths = [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')]
const entry = `
  import React from 'react'
  import { renderToStaticMarkup } from 'react-dom/server'
  export { default as DependencyTree } from './src/components/progress/DependencyTree.jsx'
  export { default as GoalDesignSelector } from './src/components/progress/GoalDesignSelector.jsx'
  export { default as StarGoal } from './src/components/progress/StarGoal.jsx'
  export { GOAL_RENDERERS } from './src/components/progress/goalDesigns.js'
  export { GOAL_DESIGNS, GOAL_DESIGN_STORAGE_KEY, DEFAULT_GOAL_DESIGN } from './src/components/progress/goalDesignModel.js'
  export { buildDependencyTreeModel, unfoldGroups } from './src/components/progress/dependencyTreeModel.js'
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
const real = require(outReal)
const { React, renderToStaticMarkup, DependencyTree, GoalDesignSelector, GOAL_RENDERERS, GOAL_DESIGNS, GOAL_DESIGN_STORAGE_KEY } = real
const buildCastleModel = real.buildDependencyTreeModel // the default (castle) goal area
const buildDependencyTreeModel = (g, id, l, o) => real.buildDependencyTreeModel(g, id, l, { goalArea: 'disc', ...o })
let hook // set once the hook bundle is built

/** Minimal hook runtime (the technique of dependency-tree.test.cjs): one instance, state slots, a setter re-renders. */
function mount(Comp, props) {
  const slots = []
  let i = 0
  let output
  globalThis.__h = {
    useState(init) {
      const k = i++
      if (!(k in slots)) slots[k] = typeof init === 'function' ? init() : init
      return [slots[k], v => { slots[k] = v; render() }]
    },
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
  return {
    html: () => renderToStaticMarkup(output),
    find: pred => all(output, pred)[0],
  }
}

const EN = {
  goal: 'Goal', ready_to_take: 'Ready to take', nothing_ready: 'Nothing ready', tree_empty: 'No tasks to show',
  state_done: 'Done', state_ready: 'Ready', state_locked: 'Locked', state_failed: 'Failed', state_rejected: 'Rejected', in_progress: 'In progress',
  gate_waiting: 'Waiting for a dependency (locked)', gate_open: 'Dependency done (unlocked)', group_tasks: '%d tasks',
  show_all: 'Show all %d', collapse: 'Collapse', goal_reached: 'Goal reached!', goal_progress: '%d / %d done · %d %%', epic_decomposed: '%d/%d stories decomposed',
  tip_depends_on: 'Depends on', tip_unlocks: 'Unlocks', tip_goal_direct: 'Leads straight to the goal',
  goal_design_group: 'Goal design', goal_design_star: 'Star', goal_design_citadel: 'Citadel', goal_design_facade: 'Facade', goal_design_tree: 'Seasons tree',
}
const SV = {
  ...EN, goal: 'Mål', goal_design_group: 'Måldesign', goal_design_star: 'Stjärna', goal_design_citadel: 'Citadell', goal_design_facade: 'Fasad', goal_design_tree: 'Årstidsträd',
}
const T = (id, story, state, deps) => ({
  id, story_id: story, epic_id: 'E01', title: 'Title ' + id, status: 'x',
  bucket: { done: 'done', in_progress: 'in_progress', ready: 'pending', locked: 'pending', failed: 'failed', rejected: 'rejected' }[state],
  state, depends_on: deps || [], blocked_by: [], unlocked_by: null,
})
const S1 = 'E01_S01'
const graphOf = (labels, reached) => ({
  schema_version: 1, labels, epics: [{ id: 'E01', title: 'Goal epic', epic_progress: { stories: 1, decomposed: 1, tasks_done: reached ? 2 : 1, tasks_denominator: 2, percent: reached ? 100 : 50, goal_reached: !!reached } }],
  stories: [{ id: S1, epic_id: 'E01', title: 'First' }],
  tasks: [T('E01_S01_T01', S1, 'done', []), T('E01_S01_T02', S1, reached ? 'done' : 'ready', ['E01_S01_T01'])],
  external: null,
})
const modelOf = (labels, reached) => buildDependencyTreeModel(graphOf(labels, reached), 'E01', labels)

/** A fake renderer: a marker drawing carrying its own id, an edge inset of its own, optionally its own defs and style. */
const fake = (id, inset) => ({
  edgeInset: inset,
  Defs: ({ gid }) => React.createElement('linearGradient', { id: `fake-${id}-${gid}` }),
  Drawing: ({ goal }) => React.createElement('circle', { className: `fake-drawing fake-${id}`, 'data-reached': String(goal.reached), r: '20' }),
  rootStyle: () => ({ '--fake-var': id }),
})
const unfoldOf = model => real.unfoldGroups(model, new Set(), { goalArea: 'disc' })
const registryOf = (...ids) => Object.fromEntries(ids.map((id, k) => [id, fake(id, 10 + k)]))

/** A localStorage stand-in installed as window.localStorage for the duration of fn. */
function withStorage(store, fn) {
  Object.defineProperty(globalThis, 'window', { configurable: true, value: store === 'throws' ? { get localStorage() { throw new Error('SecurityError') } } : { localStorage: store } })
  try { return fn() } finally { delete globalThis.window }
}
const fakeStore = initial => {
  const m = new Map(Object.entries(initial || {}))
  return { map: m, getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => { m.set(k, String(v)) } }
}
const throwingStore = () => ({ getItem() { throw new Error('SecurityError') }, setItem() { throw new Error('QuotaExceededError') } })

const renderTree = (labels, renderers, reached, designs) =>
  renderToStaticMarkup(React.createElement(DependencyTree, { model: modelOf(labels, reached), labels, renderers, designs }))
const count = (s, re) => (s.match(re) || []).length
const stripComments = s => s.replace(/\/\*[\s\S]*?\*\//g, '')
/** The selector's markup: from its group to the end of that div. */
const selectorOf = html => {
  const at = html.indexOf('data-testid="dt-goal-design"')
  if (at < 0) return ''
  const start = html.lastIndexOf('<div', at)
  return html.slice(start, html.indexOf('</div>', at) + 6)
}
const buttonsOf = html => [...selectorOf(html).matchAll(/<button\b([^>]*)>([\s\S]*?)<\/button>/g)].map(m => ({
  id: (m[1].match(/data-goal-design="([^"]+)"/) || [])[1],
  pressed: (m[1].match(/aria-pressed="([^"]+)"/) || [])[1],
  text: m[2].replace(/<span class="dt-gd-check"[^>]*>[^<]*<\/span>/, '').replace(/<[^>]+>/g, ''),
  check: m[2].includes('dt-gd-check'),
  attrs: m[1],
}))
/** The design drawn in the goal slot, by the marker on the goal group. */
const goalGroupDrawn = html => (html.match(/class="dt-node dt-goal[^>]*data-goal-design="([^"]+)"/) || [])[1]

;(async () => {
  await hookBuilt
  hook = require(outHook)
  let n = 0
  const test = (name, fn) => { fn(); n++; console.log('ok  ' + name) }

  // E92_S13_T09: the public build leaves the seasons tree out. vite.config.js points ./seasonsTreeEntry at a stub unless
  // JENGA_UI_SEASONS_TREE=1; the same substitution is made here with an esbuild plugin, so the stub build is exercised for real.
  const outOff = path.join(tmp, 'off.cjs')
  await esbuild.build({
    stdin: { contents: entry, resolveDir: uiDir, loader: 'jsx' },
    outfile: outOff, bundle: true, platform: 'node', format: 'cjs', jsx: 'automatic', nodePaths, loader: { '.css': 'empty' }, logLevel: 'silent',
    plugins: [{ name: 'seasons-tree-off', setup(b) { b.onResolve({ filter: /^\.\/seasonsTreeEntry$/ }, () => ({ path: path.join(compDir, 'seasonsTreeEntry.off.js') })) } }],
  })
  const OFF = require(outOff)

  test('E92_S13_T09: without the seasons tree built in, the registry holds three designs and the selector offers three; with it, four', () => {
    assert.deepStrictEqual(Object.keys(OFF.GOAL_RENDERERS), ['star', 'citadel', 'facade'], 'tree is not registered')
    assert.ok(!('tree' in OFF.GOAL_RENDERERS))
    const m = OFF.buildDependencyTreeModel(graphOf(EN, true), 'E01', EN)
    const html = withStorage(fakeStore(), () => OFF.renderToStaticMarkup(OFF.React.createElement(OFF.DependencyTree, { model: m, labels: EN })))
    assert.deepStrictEqual(buttonsOf(html).map(x => x.id), ['star', 'citadel', 'facade'])
    // a stored choice of the tree, from a browser that saw it before, falls back to the default
    const stored = withStorage(fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: 'tree' }), () => OFF.renderToStaticMarkup(OFF.React.createElement(OFF.DependencyTree, { model: m, labels: EN })))
    assert.strictEqual(goalGroupDrawn(stored), 'citadel')
    assert.ok(!html.includes('tr-backdrop') && !stored.includes('tr-backdrop'))
    // the real files still register it (the Node tests bundle them as they are)
    assert.deepStrictEqual(Object.keys(GOAL_RENDERERS), ['star', 'citadel', 'facade', 'tree'])
  })

  test('E92_S13_T09: vite.config.js gates the substitution on JENGA_UI_SEASONS_TREE=1, and the stub holds no renderer and no import', () => {
    const cfg = fs.readFileSync(path.join(uiDir, 'vite.config.js'), 'utf8')
    assert.ok(/process\.env\.JENGA_UI_SEASONS_TREE === '1'/.test(cfg), 'the flag is read from the environment')
    assert.ok(/seasonsTreeIn \? \[\] : \[\{ find: \/\^\\\.\\\/seasonsTreeEntry\$\/, replacement: seasonsTreeOff \}\]/.test(cfg), 'the alias is set only when the flag is not "1"')
    const stub = stripComments(read('seasonsTreeEntry.off.js'))
    assert.ok(/export default null/.test(stub) && !/\bimport\b/.test(stub), 'the stub is a bare null')
    const entryReal = stripComments(read('seasonsTreeEntry.js'))
    assert.ok(/export \{ default \} from '\.\/TreeGoal'/.test(entryReal))
    const designs = stripComments(read('goalDesigns.js'))
    assert.ok(!/from '\.\/TreeGoal'/.test(designs) && /from '\.\/seasonsTreeEntry'/.test(designs), 'goalDesigns.js reaches the tree only through the entry')
  })

  test('the real registry holds the star and the citadel: the citadel is drawn by default, the selector offers both, the star is still drawn when chosen (E92_S13_T02)', () => {
    assert.deepStrictEqual(Object.keys(GOAL_RENDERERS), ['star', 'citadel', 'facade', 'tree']) // E92_S13_T03 registered the facade, E92_S13_T07 the seasons tree
    const castleModel = buildCastleModel(graphOf(EN, true), 'E01', EN)
    const html = withStorage(fakeStore(), () => renderToStaticMarkup(React.createElement(DependencyTree, { model: castleModel, labels: EN })))
    assert.strictEqual(goalGroupDrawn(html), 'citadel', 'no stored choice: the default, the citadel')
    assert.ok(html.includes('data-castle="citadel"') && !html.includes('dt-star-outline') && !html.includes('dt-goal-ring') && !html.includes('dt-halo-grad'), 'the castle, not the star in a disc')
    assert.ok(html.includes('data-testid="dt-goal-design"') && buttonsOf(html).map(x => x.id).join() === 'star,citadel,facade,tree', 'four registered designs: the selector is shown, in list order')
    const star = withStorage(fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: 'star' }), () => renderToStaticMarkup(React.createElement(DependencyTree, { model: castleModel, labels: EN })))
    assert.strictEqual(goalGroupDrawn(star), 'star')
    assert.ok(star.includes('dt-star-outline') && star.includes('dt-goal-ring') && star.includes('dt-halo-grad dt-complete'), 'the existing star in a disc with its ring and halo')
    assert.strictEqual(count(star, /class="dt-spark"/g), 5, 'five sparks at the goal')
    assert.strictEqual(count(star, /class="dt-shimmer"/g), 1)
    assert.ok(star.includes('--goal-halo-opacity:') && star.includes('--goal-halo-scale:'), 'the halo custom properties are still on the goal group')
    // a star laid out from a castle model gets the star's own fixed area, not the castle's
    const disc = unfoldOf(castleModel)
    assert.strictEqual(disc.layout.goalAreaW, 260)
    assert.strictEqual(disc.goal.x - disc.layout.goalOffsetX, castleModel.layout.goalX)
    const d = star.match(/data-from="E01_S01_T02" data-to="goal"[^>]* d="([^"]+)"/)[1].trim().split(/\s+/).slice(-2).map(Number)
    assert.deepStrictEqual(d, [disc.goal.x - 46, disc.goal.y], 'the star edge ends at its inset')
  })

  test('the star renderer is the former Goal node: its edge inset is 46, the ring radius 50 less 4', () => {
    assert.strictEqual(GOAL_RENDERERS.star.edgeInset, 46)
    const m = modelOf(EN, false)
    const html = withStorage(fakeStore(), () => renderToStaticMarkup(React.createElement(DependencyTree, { model: m, labels: EN, renderers: { star: GOAL_RENDERERS.star } })))
    const d = html.match(/data-from="E01_S01_T02" data-to="goal"[^>]* d="([^"]+)"/)[1]
    const end = d.trim().split(/\s+/).slice(-2).map(Number)
    assert.deepStrictEqual(end, [m.goal.x - 46, m.goal.y])
  })

  test('with the citadel registered it is the default, the selector appears, and the list order is the display order', () => {
    const html = withStorage(fakeStore(), () => renderTree(EN, registryOf('star', 'citadel')))
    assert.strictEqual(goalGroupDrawn(html), 'citadel', 'the citadel is drawn: it is the default, not the first entry')
    assert.ok(html.includes('fake-citadel') && !html.includes('fake-star'))
    const b = buttonsOf(html)
    assert.deepStrictEqual(b.map(x => x.id), ['star', 'citadel'])
    assert.deepStrictEqual(b.map(x => x.text), ['Star', 'Citadel'])
    assert.deepStrictEqual(b.map(x => x.pressed), ['false', 'true'])
  })

  test('registered in any order, shown in list order; only registered designs appear (no facade, no tree, until they register)', () => {
    const html = withStorage(fakeStore(), () => renderTree(EN, registryOf('facade', 'star')))
    assert.deepStrictEqual(buttonsOf(html).map(x => x.id), ['star', 'facade'])
    assert.strictEqual(goalGroupDrawn(html), 'star', 'no citadel yet: the default is the first registered design, the star')
    assert.deepStrictEqual(buttonsOf(html).map(x => x.pressed), ['true', 'false'])
  })

  test('all four designs: four buttons in the order star, citadel, facade, seasons tree, with the labels payload words', () => {
    const reg = registryOf('star', 'citadel', 'facade', 'tree')
    const en = buttonsOf(withStorage(fakeStore(), () => renderTree(EN, reg)))
    assert.deepStrictEqual(en.map(x => x.id), ['star', 'citadel', 'facade', 'tree'])
    assert.deepStrictEqual(en.map(x => x.text), ['Star', 'Citadel', 'Facade', 'Seasons tree'])
    const sv = buttonsOf(withStorage(fakeStore(), () => renderTree(SV, reg)))
    assert.deepStrictEqual(sv.map(x => x.text), ['Stjärna', 'Citadell', 'Fasad', 'Årstidsträd'])
    assert.ok(selectorOf(withStorage(fakeStore(), () => renderTree(SV, reg))).includes('aria-label="Måldesign"'))
    assert.ok(selectorOf(withStorage(fakeStore(), () => renderTree(EN, reg))).includes('aria-label="Goal design"'))
  })

  test('a fifth fake entry is one more entry of the list: it appears in the selector and is selectable, with the control untouched', () => {
    const FIFTH = { id: 'moon', labelKey: 'goal_design_moon' }
    const five = [...GOAL_DESIGNS, FIFTH]
    const labels = { ...EN, goal_design_moon: 'Moon' }
    const reg = registryOf('star', 'citadel', 'facade', 'tree', 'moon')
    // the control alone: any number of items
    const items = five.map(d => ({ id: d.id, text: labels[d.labelKey] }))
    const picked = []
    const alone = renderToStaticMarkup(React.createElement(GoalDesignSelector, { items, value: 'citadel', groupText: 'Goal design', onSelect: id => picked.push(id) }))
    assert.strictEqual(count(alone, /<button\b/g), 5, 'five buttons')
    assert.deepStrictEqual([...alone.matchAll(/data-goal-design="([^"]+)"/g)].map(m => m[1]), ['star', 'citadel', 'facade', 'tree', 'moon'])
    // the whole path: the list, the goal slot, the control and the stored choice
    const html = withStorage(fakeStore(), () => renderTree(labels, reg, false, five))
    assert.deepStrictEqual(buttonsOf(html).map(x => x.id), ['star', 'citadel', 'facade', 'tree', 'moon'])
    assert.deepStrictEqual(buttonsOf(html).map(x => x.text), ['Star', 'Citadel', 'Facade', 'Seasons tree', 'Moon'])
    assert.strictEqual(goalGroupDrawn(html), 'citadel', 'a fifth entry does not move the default')
    const store = fakeStore()
    withStorage(store, () => {
      const m = mount(hook.DependencyTree, { model: modelOf(labels, false), labels, renderers: reg, designs: five })
      m.find(el => el.type === hook.GoalDesignSelector).props.onSelect('moon')
      const after = m.html()
      assert.strictEqual(goalGroupDrawn(after), 'moon', 'the fifth design is drawn')
      assert.ok(after.includes('fake-moon') && buttonsOf(after).find(x => x.pressed === 'true').id === 'moon')
      assert.strictEqual(store.map.get(GOAL_DESIGN_STORAGE_KEY), 'moon', 'and stored')
      const again = mount(hook.DependencyTree, { model: modelOf(labels, false), labels, renderers: reg, designs: five })
      assert.strictEqual(goalGroupDrawn(again.html()), 'moon', 'and read back')
    })
    // a fifth id that is registered but not in the list is never shown
    const ignored = withStorage(fakeStore(), () => renderTree(EN, reg, false))
    assert.deepStrictEqual(buttonsOf(ignored).map(x => x.id), ['star', 'citadel', 'facade', 'tree'])
  })

  test('the selector is hidden with fewer than two items and renders nothing', () => {
    const one = renderToStaticMarkup(React.createElement(GoalDesignSelector, { items: [{ id: 'star', text: 'Star' }], value: 'star', groupText: 'g', onSelect() {} }))
    assert.strictEqual(one, '')
    assert.strictEqual(renderToStaticMarkup(React.createElement(GoalDesignSelector, { items: [], value: null, groupText: 'g', onSelect() {} })), '')
    assert.strictEqual(renderToStaticMarkup(React.createElement(GoalDesignSelector, { value: null, groupText: 'g', onSelect() {} })), '')
  })

  test('accessible: a group of real buttons with aria-pressed, a check mark and no tabindex that removes one from the Tab order', () => {
    const html = withStorage(fakeStore(), () => renderTree(EN, registryOf('star', 'citadel', 'facade', 'tree')))
    const sel = selectorOf(html)
    assert.ok(/role="group"/.test(sel) && /aria-label="Goal design"/.test(sel), 'a named group')
    const b = buttonsOf(html)
    assert.strictEqual(b.length, 4)
    for (const x of b) {
      assert.ok(/type="button"/.test(x.attrs), 'a real button that does not submit')
      assert.ok(x.pressed === 'true' || x.pressed === 'false', 'aria-pressed on every button')
      assert.ok(!/tabindex/i.test(x.attrs), 'in the Tab order')
    }
    assert.strictEqual(b.filter(x => x.pressed === 'true').length, 1, 'exactly one is pressed')
    assert.deepStrictEqual(b.map(x => x.check), b.map(x => x.pressed === 'true'), 'the chosen one, and only it, has the check mark (not colour alone)')
    assert.ok(/<span class="dt-gd-check" aria-hidden="true">/.test(sel), 'the check mark is decoration; aria-pressed carries the state')
  })

  test('css: a visible focus ring, a pressed style that is not colour alone, wrapping at a narrow overlay, tokens only, no motion', () => {
    const plain = stripComments(css)
    assert.ok(/\.dep-tree \.dt-gd-btn:focus-visible\s*\{[^}]*outline:\s*2px solid var\(--color-accent\)/.test(plain), 'focus ring like the zoom buttons')
    const pressed = plain.match(/\.dt-gd-btn\[aria-pressed="true"\]\s*\{([^}]*)\}/)
    assert.ok(pressed && /border-color/.test(pressed[1]) && /font-weight:\s*700/.test(pressed[1]) && /box-shadow:\s*inset/.test(pressed[1]), 'heavier weight and border, not colour alone')
    const group = plain.match(/\.dep-tree \.dt-gd\s*\{([^}]*)\}/)[1]
    assert.ok(/flex-wrap:\s*wrap/.test(group) && /max-width:\s*calc\(100% - 16px\)/.test(group), 'wraps and never wider than the overlay')
    // the selector's own rules: from `.dep-tree .dt-gd {` to the next section comment (the citadel's), not to the end of the file, so
    // that the later sections (the day and night section of E92_S13_T04 declares the castle goal's animations) are not read as the selector's
    const plainOwn = stripComments(css.slice(0, css.indexOf('/* goal: the citadel')))
    assert.ok(css.indexOf('/* goal: the citadel') > css.indexOf('.dep-tree .dt-gd {'), 'the citadel section follows the selector rules')
    const mine = plainOwn.slice(plainOwn.indexOf('.dep-tree .dt-gd {'))
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(mine) && !/\b(rgb|rgba|hsl|hsla)\(/.test(mine), 'no colour literal')
    assert.ok(!/\b(animation|transition)\b/.test(mine), 'no motion in the selector')
  })

  test('the selector sits next to the zoom controls, inside the zoom frame that the large view enlarges, so every layout shows it', () => {
    const html = withStorage(fakeStore(), () => renderTree(EN, registryOf('star', 'citadel')))
    const frame = html.indexOf('data-testid="dt-zoom"')
    const controls = html.indexOf('data-testid="dt-zoom-controls"')
    const selector = html.indexOf('data-testid="dt-goal-design"')
    const ready = html.indexOf('data-testid="dt-ready"')
    assert.ok(frame >= 0 && frame < controls && controls < selector && selector < ready, 'zoom frame, then zoom controls, then the selector, before the ready list')
    assert.ok(html.indexOf('data-testid="dt-fs-toggle"') < selector, 'the large view button stays the first focusable control')
    assert.ok(/^<section class="dep-tree"/.test(html), 'the selector is a descendant of the one root that the large view enlarges (never re-parented)')
  })

  test('stored choice: a stored id of a registered design is drawn; unknown or throwing storage draws the default', () => {
    const reg = registryOf('star', 'citadel', 'facade', 'tree')
    for (const id of ['star', 'citadel', 'facade', 'tree']) {
      assert.strictEqual(goalGroupDrawn(withStorage(fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: id }), () => renderTree(EN, reg))), id, id)
    }
    assert.strictEqual(goalGroupDrawn(withStorage(fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: 'bogus' }), () => renderTree(EN, reg))), 'citadel', 'unknown value')
    assert.strictEqual(goalGroupDrawn(withStorage(throwingStore(), () => renderTree(EN, reg))), 'citadel', 'getItem throws')
    assert.strictEqual(goalGroupDrawn(withStorage('throws', () => renderTree(EN, reg))), 'citadel', 'reaching localStorage throws')
    assert.strictEqual(goalGroupDrawn(renderTree(EN, reg)), 'citadel', 'no window at all (a static render)')
    assert.strictEqual(goalGroupDrawn(withStorage(fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: 'facade' }), () => renderTree(EN, registryOf('star')))), 'star', 'a stored design that is not registered: the first registered')
  })

  test('picking a design switches the drawing of the goal without a reload, and stores the id under the one key', () => {
    const store = fakeStore()
    withStorage(store, () => {
      const m = mount(hook.DependencyTree, { model: modelOf(EN, false), labels: EN, renderers: registryOf('star', 'citadel', 'facade') })
      assert.strictEqual(goalGroupDrawn(m.html()), 'citadel')
      const sel = () => m.find(el => el.type === hook.GoalDesignSelector)
      assert.ok(sel(), 'the selector element is in the tree')
      sel().props.onSelect('facade')
      let html = m.html()
      assert.strictEqual(goalGroupDrawn(html), 'facade', 'the goal drawing changed')
      assert.ok(html.includes('fake-facade') && !html.includes('fake-citadel'))
      assert.deepStrictEqual(buttonsOf(html).map(x => x.pressed), ['false', 'false', 'true'])
      assert.strictEqual(store.map.get(GOAL_DESIGN_STORAGE_KEY), 'facade', 'stored under the documented key')
      sel().props.onSelect('star')
      html = m.html()
      assert.strictEqual(goalGroupDrawn(html), 'star')
      assert.ok(/fake-star/.test(html))
      assert.strictEqual(store.map.get(GOAL_DESIGN_STORAGE_KEY), 'star')
    })
  })

  test('the design persists across a remount (a reload) under that key, and is read back', () => {
    const store = fakeStore()
    withStorage(store, () => {
      const reg = registryOf('star', 'citadel', 'facade')
      const first = mount(hook.DependencyTree, { model: modelOf(EN, false), labels: EN, renderers: reg })
      first.find(el => el.type === hook.GoalDesignSelector).props.onSelect('star')
      const second = mount(hook.DependencyTree, { model: modelOf(EN, false), labels: EN, renderers: reg })
      assert.strictEqual(goalGroupDrawn(second.html()), 'star')
    })
  })

  test('with storage unavailable or throwing a pick still switches between all designs for the page and nothing throws', () => {
    for (const mk of [() => throwingStore(), () => 'throws', () => null]) {
      withStorage(mk(), () => {
        const m = mount(hook.DependencyTree, { model: modelOf(EN, false), labels: EN, renderers: registryOf('star', 'citadel', 'facade', 'tree') })
        assert.strictEqual(goalGroupDrawn(m.html()), 'citadel', 'the citadel is shown')
        for (const id of ['tree', 'star', 'facade', 'citadel']) {
          assert.doesNotThrow(() => m.find(el => el.type === hook.GoalDesignSelector).props.onSelect(id))
          assert.strictEqual(goalGroupDrawn(m.html()), id, `switched to ${id}`)
          assert.strictEqual(buttonsOf(m.html()).find(x => x.pressed === 'true').id, id)
        }
      })
    }
  })

  test('the goal slot uses the chosen renderer: its defs, its drawing, its edge inset and its custom properties', () => {
    const reg = registryOf('star', 'citadel')
    const m = modelOf(EN, true)
    const render = stored => withStorage(fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: stored }), () => renderToStaticMarkup(React.createElement(DependencyTree, { model: m, labels: EN, renderers: reg })))
    const cit = render('citadel')
    assert.ok(cit.includes('fake-citadel-') && cit.includes('data-reached="true"'), 'its defs and its drawing, with the goal-reached state')
    assert.ok(cit.includes('--fake-var:citadel'))
    assert.ok(!cit.includes('dt-star-outline'), 'the star is not drawn when the citadel is')
    const endOf = html => html.match(/data-from="E01_S01_T02" data-to="goal"[^>]* d="([^"]+)"/)[1].trim().split(/\s+/).slice(-2).map(Number)
    assert.deepStrictEqual(endOf(cit), [m.goal.x - 11, m.goal.y], 'the citadel fake has inset 11')
    assert.deepStrictEqual(endOf(render('star')), [m.goal.x - 10, m.goal.y], 'the star fake has inset 10')
    // the text under the node is drawn for every design and is not duplicated inside the drawing
    for (const html of [cit, render('star')]) {
      assert.ok(html.includes('>Goal reached!<') && html.includes('>2 / 2 done · 100 %<') && html.includes('>Goal epic<'))
      assert.strictEqual(count(html, />Goal reached!</g), 1)
    }
  })

  test('no registered design draws no goal drawing but keeps the goal text and does not throw', () => {
    const html = withStorage(fakeStore(), () => renderTree(EN, {}))
    assert.ok(!html.includes('data-goal-design') && !html.includes('dt-star-outline') && !html.includes('data-testid="dt-goal-design"'))
    assert.ok(html.includes('>Goal epic<'))
  })

  test('every label key of the list, and the group key, has a JSX fallback word and an entry in the labels payload test fixtures', () => {
    const jsx = read('DependencyTree.jsx')
    const fallback = jsx.split('const FALLBACK = {')[1].split('\n}')[0]
    for (const d of GOAL_DESIGNS) assert.ok(new RegExp(`\\b${d.labelKey}: '[^']+',`).test(fallback), `fallback for ${d.labelKey}`)
    assert.ok(/\bgoal_design_group: 'Goal design',/.test(fallback))
    assert.ok(/goal_design_star: 'Star',/.test(fallback) && /goal_design_citadel: 'Citadel',/.test(fallback) && /goal_design_facade: 'Facade',/.test(fallback) && /goal_design_tree: 'Seasons tree',/.test(fallback))
    // a payload without the keys falls back to those English words
    const bare = { ...EN }
    for (const k of Object.keys(bare)) if (k.startsWith('goal_design_')) delete bare[k]
    const html = withStorage(fakeStore(), () => renderTree(bare, registryOf('star', 'citadel', 'facade', 'tree')))
    assert.deepStrictEqual(buttonsOf(html).map(x => x.text), ['Star', 'Citadel', 'Facade', 'Seasons tree'])
    assert.ok(selectorOf(html).includes('aria-label="Goal design"'))
  })

  test('no word is hard-coded and no colour literal sits in the new component sources', () => {
    for (const f of ['GoalDesignSelector.jsx', 'StarGoal.jsx', 'goalDesigns.js']) {
      const src = stripComments(read(f))
      const text = [...src.matchAll(/<[A-Za-z][^<>]*>([^<>{}\n]*[A-Za-z][^<>{}\n]*)<\//g)].map(m => m[1].trim()).filter(Boolean)
      assert.deepStrictEqual(text, [], `${f}: hard-coded JSX text ${text.join(' | ')}`)
      assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(src) && !/\b(rgb|rgba|hsl|hsla|oklch|color-mix)\(/.test(src), `${f}: colour literal`)
    }
  })

  test('the star was moved, not copied: DependencyTree.jsx no longer holds its path, sparks or ring, and StarGoal.jsx does', () => {
    const tree = stripComments(read('DependencyTree.jsx'))
    const star = stripComments(read('StarGoal.jsx'))
    assert.ok(!tree.includes('M0 -22 L6.5 -7') && !tree.includes('dt-star-outline') && !tree.includes('dt-spark') && !tree.includes('GOAL_EDGE_INSET'))
    assert.ok(star.includes('M0 -22 L6.5 -7') && star.includes('dt-star-outline') && star.includes('dt-spark') && star.includes('GOAL_EDGE_INSET = 46'))
  })

  console.log(`\n${n} tests passed`)
})().catch(e => { console.error(e); process.exit(1) })
