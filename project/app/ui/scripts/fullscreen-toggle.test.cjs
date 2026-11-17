#!/usr/bin/env node
'use strict'
// E92_S07_T07 (tester): render test of the fullscreen toggle wired into DependencyTree. Small on purpose; the story's
// full test task is E92_S07_T08. Zero test framework and no DOM: the component is bundled with esbuild (CSS stubbed) with
// `react` swapped for a tiny hook runtime (technique of dependency-tree.test.cjs), a minimal fake document/root is
// provided so useFullscreen can enter its fallback layer, and the result is rendered to markup.
// Run: node project/app/ui/scripts/fullscreen-toggle.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const compDir = path.join(uiDir, 'src', 'components', 'progress')
const esbuild = require('esbuild')
const jsx = fs.readFileSync(path.join(compDir, 'DependencyTree.jsx'), 'utf8')
const toggleJsx = fs.readFileSync(path.join(compDir, 'FullscreenToggle.jsx'), 'utf8')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fullscreen-toggle-'))
const nodePaths = [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')]
const entry = `
  import { renderToStaticMarkup } from 'react-dom/server'
  export { default as DependencyTree } from './src/components/progress/DependencyTree.jsx'
  export { buildDependencyTreeModel } from './src/components/progress/dependencyTreeModel.js'
  export { renderToStaticMarkup }
`
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
const outfile = path.join(tmp, 'hook.cjs')
const built = esbuild.build({
  stdin: { contents: entry, resolveDir: uiDir, loader: 'jsx' },
  outfile, bundle: true, platform: 'node', format: 'cjs', jsx: 'automatic', nodePaths, loader: { '.css': 'empty' }, logLevel: 'silent',
  plugins: [{
    name: 'react-hook-shim',
    setup(b) { b.onResolve({ filter: /^react$/ }, a => (a.importer.includes(path.sep + 'src' + path.sep) ? { path: shim } : null)) },
  }],
})
let DependencyTree, buildDependencyTreeModel, renderToStaticMarkup

/** A fake element that records attributes, like the root and <html> of the page. */
const fakeEl = () => ({ a: {}, setAttribute(n, v) { this.a[n] = String(v) }, removeAttribute(n) { delete this.a[n] }, focus() {} })

/** One component instance with state slots; setters re-render. `props` is replaceable (labels). */
function mount(props) {
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
  function render() { i = 0; output = DependencyTree(props) }
  render()
  const all = (node, pred, acc = []) => {
    if (Array.isArray(node)) { node.forEach(c => all(c, pred, acc)); return acc }
    if (!node || typeof node !== 'object' || !node.props) return acc
    if (pred(node)) acc.push(node)
    all(node.props.children, pred, acc)
    return acc
  }
  return {
    out: () => output,
    html: () => renderToStaticMarkup(output),
    // FullscreenToggle is a function component: DependencyTree returns its element, which renders to the button on its own
    toggle: () => {
      const el = all(output, e => typeof e.type === 'function' && e.type.name === 'FullscreenToggle')[0]
      if (!el) return undefined
      const markup = renderToStaticMarkup(el)
      const attr = name => { const r = markup.match(new RegExp('<button[^>]* ' + name + '="([^"]*)"')); return r ? r[1] : undefined }
      return { el, markup, props: { 'aria-label': attr('aria-label'), title: attr('title'), 'aria-pressed': attr('aria-pressed'), type: attr('type'), className: attr('class') } }
    },
    byAttr: (name, value) => all(output, el => el.props && el.props[name] === value)[0],
    // FullscreenToggle is a component element: find it, and call its onClick through the rendered button
    click: () => {
      const comp = all(output, el => typeof el.type === 'function' && el.type.name === 'FullscreenToggle')[0]
      assert.ok(comp, 'FullscreenToggle element present')
      return comp.props.onToggle({ currentTarget: fakeEl() })
    },
  }
}

const EN = {
  goal: 'Goal', ready_to_take: 'Ready to take', nothing_ready: 'Nothing ready', tree_empty: 'No tasks to show',
  unlocked_by: '%s unlocked by %s', state_done: 'Done', state_ready: 'Ready', state_locked: 'Locked',
  state_failed: 'Failed', state_rejected: 'Rejected', in_progress: 'In progress',
  gate_waiting: 'W', gate_open: 'O', group_tasks: '%d tasks', show_all: 'Show all %d', collapse: 'Collapse',
  goal_reached: 'Goal reached!', goal_progress: '%d / %d done · %d %%', tip_depends_on: 'Depends on', tip_unlocks: 'Unlocks',
  tip_goal_direct: 'Direct',
  fullscreen_enter: 'Show full screen', fullscreen_exit: 'Exit full screen', fullscreen_hint: 'Press Esc to exit',
  fullscreen_layer: 'Dependency tree, full screen',
}
const BASE = { ...EN }
for (const k of ['fullscreen_enter', 'fullscreen_exit', 'fullscreen_hint', 'fullscreen_layer']) delete BASE[k]
const T = (id, story, state, deps) => ({
  id, story_id: story, epic_id: 'E01', title: 'Title ' + id, status: 'x', bucket: state === 'done' ? 'done' : 'pending', state,
  depends_on: deps || [], blocked_by: [], unlocked_by: null,
})
const g = labels => ({
  schema_version: 1, labels, epics: [{ id: 'E01', title: 'Goal epic' }],
  stories: [{ id: 'E01_S01', epic_id: 'E01', title: 'First' }],
  tasks: [T('E01_S01_T01', 'E01_S01', 'done', []), T('E01_S01_T02', 'E01_S01', 'ready', ['E01_S01_T01'])], external: null,
})
const props = labels => ({ model: buildDependencyTreeModel(g(labels), 'E01', labels), labels })

;(async () => {
  await built
  ;({ DependencyTree, buildDependencyTreeModel, renderToStaticMarkup } = require(outfile))
let n = 0
const test = (name, fn) => { fn(); n++; console.log('ok  ' + name) }
const savedDoc = globalThis.document
const html = fakeEl()
globalThis.document = { documentElement: html, activeElement: null }

test('closed: the toggle renders an icon button with aria-label and title from the labels, pressed false, no root attributes', () => {
  const m = mount(props(EN))
  const t = m.toggle()
  assert.ok(t, 'toggle button')
  assert.strictEqual(t.props.type, 'button')
  assert.strictEqual(t.props.className, 'dt-fs-btn')
  assert.strictEqual(t.props['aria-label'], 'Show full screen')
  assert.strictEqual(t.props.title, 'Show full screen')
  assert.strictEqual(t.props['aria-pressed'], 'false')
  const root = m.out()
  assert.strictEqual(root.type, 'section')
  assert.strictEqual(root.props['data-fullscreen'], undefined)
  assert.strictEqual(root.props.role, undefined)
  assert.strictEqual(root.props['aria-modal'], undefined)
  assert.strictEqual(root.props['aria-label'], undefined)
  const h = m.html()
  assert.ok(h.includes('data-testid="dt-fs-toggle"') && h.includes('<svg'), 'icon is rendered')
  assert.ok(!h.includes('dt-fs-hint'), 'no hint while closed')
  assert.ok(!/ data-fullscreen=/.test(h))
})

test('no labels: icon only, no aria-label or title, no hint, nothing thrown', () => {
  const m = mount(props(BASE))
  const t = m.toggle()
  assert.strictEqual(t.props['aria-label'], undefined)
  assert.strictEqual(t.props.title, undefined)
  m.out().ref.current = fakeEl()
  m.click()
  const root = m.out()
  assert.strictEqual(root.props['data-fullscreen'], 'fallback')
  assert.strictEqual(root.props.role, undefined, 'no dialog role without fullscreen_layer')
  assert.strictEqual(root.props['aria-label'], undefined)
  assert.ok(!m.html().includes('dt-fs-hint'), 'no hint without the label')
  assert.ok(m.html().includes('<svg'))
})

test('the empty tree shows no toggle and no ref', () => {
  const m = mount({ model: { empty: true }, labels: EN })
  assert.strictEqual(m.toggle(), undefined)
  assert.ok(!m.html().includes('dt-fs-toggle'))
})

test('open: same root node and ref, data-fullscreen fallback, dialog attributes, exit label, pressed true, hint; <html> flag set', () => {
  const m = mount(props(EN))
  const rootBefore = m.out()
  const ref = rootBefore.ref
  assert.ok(ref && 'current' in ref, 'root carries a ref')
  const root = fakeEl()
  ref.current = root
  m.click()
  const o = m.out()
  assert.strictEqual(o.type, 'section')
  assert.strictEqual(o.ref, ref, 'the same ref object (no remount, no new instance)')
  assert.strictEqual(o.props['data-fullscreen'], 'fallback')
  assert.strictEqual(o.props.role, 'dialog')
  assert.strictEqual(o.props['aria-modal'], 'true')
  assert.strictEqual(o.props['aria-label'], 'Dependency tree, full screen')
  assert.strictEqual(o.key, null)
  const t = m.toggle()
  assert.strictEqual(t.props['aria-label'], 'Exit full screen')
  assert.strictEqual(t.props.title, 'Exit full screen')
  assert.strictEqual(t.props['aria-pressed'], 'true')
  const h = m.html()
  assert.ok(h.includes('data-fullscreen="fallback"') && h.includes('role="dialog"') && h.includes('aria-modal="true"'))
  assert.ok(h.includes('dt-fs-hint') && h.includes('Press Esc to exit'))
  assert.strictEqual(root.a['data-fullscreen'], 'fallback', 'hook sets the attribute on the real root')
  assert.strictEqual(html.a['data-dt-fullscreen'], 'fallback', 'hook sets the page scroll lock on <html>')
  // closing through the same toggle
  m.click()
  const c = m.out()
  assert.strictEqual(c.ref, ref)
  assert.strictEqual(c.props['data-fullscreen'], undefined)
  assert.strictEqual(c.props.role, undefined)
  assert.strictEqual(m.toggle().props['aria-label'], 'Show full screen')
  assert.strictEqual(m.toggle().props['aria-pressed'], 'false')
  assert.strictEqual(root.a['data-fullscreen'], undefined, 'attribute removed on close')
  assert.strictEqual(html.a['data-dt-fullscreen'], undefined, '<html> flag removed on close')
  assert.ok(!m.html().includes('dt-fs-hint'))
})

test('the toggle is the first child of .dt-zoom, so it is the first focusable control in DOM order', () => {
  const h = mount(props(EN)).html()
  const zoom = h.slice(h.indexOf('data-testid="dt-zoom"'))
  assert.ok(zoom.indexOf('dt-fs-toggle') > 0)
  const at = zoom.indexOf('dt-fs-toggle')
  assert.ok(at < zoom.indexOf('<button', at + 1), 'toggle before any other button')
  const before = zoom.slice(0, zoom.lastIndexOf('<button', at))
  assert.ok(!before.includes('<button') && !before.includes('tabindex'), 'nothing focusable before the toggle')
})

test('source: only the allowed edits to the zoom call; no hex literal, no word, no .claude/.agents path, no second keydown listener', () => {
  const call = jsx.match(/useZoomPan\(\{[^\n]*\}\)/)[0]
  assert.strictEqual(call, "useZoomPan({ box: empty ? null : { x: vbX, y: vbY, w: vbW, h: vbH }, fitKey: empty ? null : model.goal.id, keepCentreOnResize: true })")
  for (const [name, s] of [['DependencyTree.jsx', jsx], ['FullscreenToggle.jsx', toggleJsx]]) {
    const code = s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(code), name + ': hex literal')
    assert.ok(!/\.claude\/|\.agents\//.test(code), name + ': mirror path')
    assert.ok(!/addEventListener|onKeyDown\s*=\s*\{[^}]*Escape/.test(code), name + ': no extra listener')
  }
  assert.ok(!/createPortal|\bkey=/.test(jsx.replace(/\/\*[\s\S]*?\*\//g, '').split('export default function DependencyTree')[1].split('<section')[0] + jsx.split('<section')[1].split('>')[0]), 'no portal, no key on the root')
  const code = toggleJsx.replace(/\/\*[\s\S]*?\*\//g, '')
  assert.ok(!/>\s*[A-Za-z][A-Za-z ]+\s*</.test(code.replace(/<svg[\s\S]*?<\/svg>/, '')), 'no text node (word) in FullscreenToggle')
  assert.ok(!/["'`](Show|Exit|Press|Visa|Avsluta|Tryck)/.test(code), 'no label word hard-coded')
})

globalThis.document = savedDoc
console.log(`${n} passed`)
})().catch(e => { console.error(e); process.exit(1) })
