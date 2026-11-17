#!/usr/bin/env node
'use strict'
// E92_S07_T08: UI test of the large view of the epic progress map (the story's "Tests" criterion). The unit logic is covered by
// fullscreen-model, fullscreen-hook, fullscreen-focus and tree-zoom-pan; this file tests what the user sees and does.
// Zero test framework and no DOM library: the real DependencyTree (with the real useFullscreen, useFocusContain and useZoomPan)
// is bundled with esbuild with `react` swapped for a hand-rolled hook runtime that also runs effects (technique of
// fullscreen-toggle.test.cjs and tree-zoom-pan.test.cjs), rendered to markup with react-dom/server, and driven through a
// fake page (document, window, ResizeObserver, root, stage, opener).
//   1. Button and labels: the toggle with its words from scripts/progress-labels-json.sh (English and Swedish), no words
//      without labels, no toggle on the empty tree, no word written in the sources.
//   2. Open state: data-fullscreen, aria-pressed, the exit label, the hint, role=dialog with the layer label.
//   3. Esc and focus return: Escape in the fallback closes only the large view (a stand-in overlay listener is not called)
//      and focus returns to the opener; leaving real fullscreen through fullscreenchange ends in the same state.
//   4. State is kept: scale, centre point, expanded groups, hover, the stored motion value; Fit did not run.
//   5. Fit regression guard: fitPlan, fitView and clampScale pinned to fixed values; zoomPanModel.js has no fullscreen code.
//   6. Source rules: no hex literal in FullscreenToggle.jsx.
// Run: node project/app/ui/scripts/fullscreen-view.test.cjs
const assert = require('assert')
const { execFileSync } = require('child_process')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { pathToFileURL } = require('url')

const uiDir = path.join(__dirname, '..')
const repoRoot = path.join(uiDir, '..', '..', '..')
const compDir = path.join(uiDir, 'src', 'components', 'progress')
const esbuild = require('esbuild')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fullscreen-view-'))
const nodePaths = [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')]

// ---------- the words: taken from the output of scripts/progress-labels-json.sh, never typed here ----------
const KEYS = ['fullscreen_enter', 'fullscreen_exit', 'fullscreen_hint', 'fullscreen_layer']
const requireKeys = (p, lang) => {
  for (const k of KEYS) assert.ok(p && p.labels && typeof p.labels[k] === 'string' && p.labels[k].length > 0, `${lang}: the labels payload is missing ${k}`)
  return p
}
function payload(lang) {
  const env = { ...process.env, JENGA_PROGRESS_LANG: lang }
  const out = execFileSync('bash', [path.join(repoRoot, 'scripts', 'progress-labels-json.sh')], { env, encoding: 'utf8', cwd: repoRoot })
  const p = JSON.parse(out)
  assert.strictEqual(p.lang, lang, 'the payload is in the requested language')
  return requireKeys(p, lang)
}
const without = (labels, keys) => { const c = { ...labels }; for (const k of keys) delete c[k]; return c }

// ---------- the bundle: the real DependencyTree, its hooks run by the runtime below ----------
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
const bundleOut = path.join(tmp, 'view.cjs')
const buildBundle = () => esbuild.build({
  stdin: {
    contents: `
      import { renderToStaticMarkup } from 'react-dom/server'
      export { default as DependencyTree } from './src/components/progress/DependencyTree.jsx'
      export { buildDependencyTreeModel, unfoldGroups } from './src/components/progress/dependencyTreeModel.js'
      export { renderToStaticMarkup }
    `,
    resolveDir: uiDir, loader: 'jsx',
  },
  outfile: bundleOut, bundle: true, platform: 'node', format: 'cjs', jsx: 'automatic', nodePaths, loader: { '.css': 'empty' }, logLevel: 'silent',
  plugins: [{ name: 'react-hook-shim', setup(b) { b.onResolve({ filter: /^react$/ }, a => (a.importer.includes(path.sep + 'src' + path.sep) ? { path: shim } : null)) } }],
})
let DependencyTree, buildDependencyTreeModel, unfoldGroups, renderToStaticMarkup
let ZP, FM, MP // zoomPanModel, fullscreenModel, motionPreference (pure ES modules)

// ---------- fake page ----------
const tick = () => new Promise(resolve => setImmediate(resolve)) // lets every pending promise settle

/**
 * A fake page. `o.native`: the Fullscreen API exists (requestFullscreen resolves after fullscreenchange, as a browser does);
 * otherwise the page has none and the fallback layer is used. `W.key` orders a keydown the way the browser does: window capture
 * listeners first (a stopPropagation there ends it), then the root, then the document (the stand-in for EntryDetailPanel).
 */
function makeWorld(o = {}) {
  const native = o.native === true
  const W = { focusLog: [], requestCalls: 0, exitCalls: 0, winListeners: [], frameQueue: [], observers: [], mounts: [] }
  const mkEl = name => ({
    name, attrs: {}, dataset: {}, setCalls: [], isConnected: true, listeners: {},
    setAttribute(k, v) { this.setCalls.push(k); this.attrs[k] = String(v) },
    removeAttribute(k) { this.setCalls.push(k); delete this.attrs[k] },
    focus() { W.focusLog.push(name); doc.activeElement = this },
    addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f) },
    removeEventListener(t, f) { const a = this.listeners[t] || []; const k = a.indexOf(f); if (k >= 0) a.splice(k, 1) },
    hasAttribute() { return false }, getAttribute() { return null }, closest() { return null },
  })
  const html = mkEl('html'), root = mkEl('root'), opener = mkEl('opener'), exitBtn = mkEl('exit'), zoomBtn = mkEl('zoom')
  root.querySelectorAll = () => [exitBtn, zoomBtn]
  root.contains = el => el === root || el === exitBtn || el === zoomBtn
  const doc = {
    documentElement: html, activeElement: opener, fullscreenEnabled: native, fullscreenElement: null, listeners: {},
    addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f) },
    removeEventListener(t, f) { const a = this.listeners[t] || []; const k = a.indexOf(f); if (k >= 0) a.splice(k, 1) },
    exitFullscreen() { W.exitCalls++; doc.fullscreenElement = null; return Promise.resolve() }, // the tests fire the change themselves
  }
  root.ownerDocument = doc
  const fire = type => (doc.listeners[type] || []).slice().forEach(f => f({ type }))
  if (native) {
    root.requestFullscreen = () => {
      W.requestCalls++
      return Promise.resolve().then(() => { doc.fullscreenElement = root; fire('fullscreenchange') })
    }
  }
  const win = {
    addEventListener(type, fn, capture) { W.winListeners.push({ type, fn, capture: capture === true || !!(capture && capture.capture) }) },
    removeEventListener(type, fn, capture) {
      const c = capture === true || !!(capture && capture.capture)
      const k = W.winListeners.findIndex(l => l.type === type && l.fn === fn && l.capture === c)
      if (k >= 0) W.winListeners.splice(k, 1)
    },
    requestAnimationFrame(cb) { W.frameQueue.push(cb); return W.frameQueue.length },
  }
  const stage = {
    listeners: {}, size: { w: 800, h: 500 },
    getBoundingClientRect() { return { left: 100, top: 50, width: this.size.w, height: this.size.h } },
    addEventListener(t, f) { this.listeners[t] = f },
    removeEventListener(t) { delete this.listeners[t] },
    setPointerCapture() {}, releasePointerCapture() {},
  }
  const storage = { data: new Map(), setItem(k, v) { this.data.set(k, String(v)) }, removeItem(k) { this.data.delete(k) } }
  Object.assign(W, {
    doc, win, html, root, opener, exitBtn, zoomBtn, stage, storage, fire,
    frames() { const q = W.frameQueue.splice(0); q.forEach(f => f()) },
    keydownListeners: () => W.winListeners.filter(l => l.type === 'keydown'),
    resize(w, h) { stage.size = { w, h }; W.observers.filter(ob => ob.live).forEach(ob => ob.cb()) },
    key(k) {
      const ev = { key: k, stopCalls: 0, preventCalls: 0, stopped: false,
        stopPropagation() { this.stopCalls++; this.stopped = true }, preventDefault() { this.preventCalls++ } }
      W.winListeners.filter(l => l.type === 'keydown' && l.capture).forEach(l => { if (!ev.stopped) l.fn(ev) })
      if (!ev.stopped) (root.listeners.keydown || []).slice().forEach(f => f(ev))
      if (!ev.stopped) (doc.listeners.keydown || []).slice().forEach(f => f(ev))
      return ev
    },
  })
  return W
}

const saved = {}
const GLOBALS = ['document', 'window', 'ResizeObserver']
function install(W) {
  for (const g of GLOBALS) saved[g] = Object.prototype.hasOwnProperty.call(globalThis, g) ? globalThis[g] : undefined
  globalThis.document = W.doc
  globalThis.window = W.win
  globalThis.ResizeObserver = class { constructor(cb) { this.cb = cb; this.live = true; W.observers.push(this) } observe() {} disconnect() { this.live = false } }
}
function uninstall() {
  for (const g of GLOBALS) { if (saved[g] === undefined) delete globalThis[g]; else globalThis[g] = saved[g] }
}
/** A page, installed; `run` gets it, every tree mounted on it is unmounted afterwards and the globals are removed. */
async function withWorld(o, run) {
  const W = makeWorld(o)
  install(W)
  try {
    await run(W)
  } finally {
    W.mounts.forEach(m => m.unmount())
    uninstall()
  }
}

// ---------- the tree, run by a hook runtime that also runs effects ----------
const walk = (node, pred, acc = []) => {
  if (Array.isArray(node)) { node.forEach(c => walk(c, pred, acc)); return acc }
  if (!node || typeof node !== 'object' || !node.props) return acc
  if (pred(node)) acc.push(node)
  walk(node.props.children, pred, acc)
  return acc
}

/** DependencyTree mounted on the page `W`: the fake root and stage are attached to their refs before the effects run. */
function mountTree(props, W) {
  let slots = [], deps = [], cleanups = [], i, effects, output, rendering = false, dirty = false, unmounted = false
  const runtime = {
    useState(init) {
      const k = i++
      if (!(k in slots)) slots[k] = typeof init === 'function' ? init() : init
      return [slots[k], v => { if (unmounted) return; slots[k] = v; flush() }]
    },
    useRef(init) {
      const k = i++
      if (!(k in slots)) slots[k] = { current: init }
      return slots[k]
    },
    useEffect(fn, d) {
      const k = i++
      const prev = deps[k]
      if (!prev || !d || d.length !== prev.length || d.some((x, j) => x !== prev[j])) {
        effects.push(() => { if (cleanups[k]) cleanups[k](); deps[k] = d; const c = fn(); cleanups[k] = typeof c === 'function' ? c : null })
      }
    },
  }
  function attach() {
    if (output && output.ref && !output.ref.current) output.ref.current = W.root
    const stageEl = walk(output, e => typeof e.props.className === 'string' && e.props.className.split(' ').includes('dt-stage'))[0]
    if (stageEl && stageEl.ref && !stageEl.ref.current) stageEl.ref.current = W.stage
  }
  function flush() {
    if (rendering) { dirty = true; return }
    rendering = true
    do {
      dirty = false
      globalThis.__h = runtime
      i = 0; effects = []
      output = DependencyTree(props)
      attach()
      const run = effects; effects = []
      run.forEach(f => f())
    } while (dirty)
    rendering = false
  }
  flush()
  const find = pred => walk(output, pred)[0]
  const toggleEl = () => find(e => typeof e.type === 'function' && e.type.name === 'FullscreenToggle')
  const m = {
    out: () => output,
    slots: () => slots,
    html: () => renderToStaticMarkup(output),
    find,
    toggleEl,
    /** The press of the toggle, with the opener as the event's currentTarget (what React hands the handler). */
    click(opener) {
      const el = toggleEl()
      assert.ok(el, 'FullscreenToggle element present')
      return el.props.onToggle({ currentTarget: opener || W.opener })
    },
    /** The view `{ k, x, y }` the drawing group is transformed by now, or null before the first fit. */
    view() {
      const g = find(e => e.type === 'g' && e.props.className === 'dt-root')
      const t = g && g.props.transform
      if (!t) return null
      const r = t.match(/^translate\(([-+\d.e]+) ([-+\d.e]+)\) scale\(([-+\d.e]+)\)$/)
      assert.ok(r, 'the transform has the documented shape: ' + t)
      return { k: Number(r[3]), x: Number(r[1]), y: Number(r[2]) }
    },
    unmount() {
      unmounted = true
      cleanups.forEach(c => { if (c) c() })
      cleanups = []
    },
  }
  W.mounts.push(m)
  return m
}

// ---------- fixtures and markup helpers ----------
const T = (id, story, state, deps) => ({
  id, story_id: story, epic_id: 'E01', title: 'Title ' + id, status: 'x', bucket: state === 'done' ? 'done' : 'pending', state,
  depends_on: deps || [], blocked_by: [], unlocked_by: null,
})
const S1 = 'E01_S01'
const SMALL = [T('E01_S01_T01', S1, 'done', []), T('E01_S01_T02', S1, 'ready', ['E01_S01_T01'])]
// more than FOLD_THRESHOLD (3 since E92_S11_T03) done tasks in one story and one column fold into one group card
const GROUPED = [...[1, 2, 3, 4, 5, 6, 7].map(n => T('E01_S01_T0' + n, S1, 'done', [])), T('E01_S01_T08', S1, 'ready', ['E01_S01_T01'])]
const graph = (labels, tasks) => ({
  schema_version: 1, labels, epics: [{ id: 'E01', title: 'Goal epic' }],
  stories: [{ id: S1, epic_id: 'E01', title: 'First' }], tasks, external: null,
})
const treeProps = (labels, tasks = SMALL) => ({ model: buildDependencyTreeModel(graph(labels, tasks), 'E01', labels), labels })

const unesc = s => s.replace(/&quot;/g, '"').replace(/&#x27;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&')
const attrOf = (tag, name) => { const r = tag.match(new RegExp(' ' + name + '="([^"]*)"')); return r ? unesc(r[1]) : undefined }
const rootTag = h => h.match(/^<section[^>]*>/)[0]
const toggleTag = h => { const r = h.match(/<button[^>]*data-testid="dt-fs-toggle"[^>]*>/); return r ? r[0] : undefined }
const hintOf = h => { const r = h.match(/<span[^>]*data-testid="dt-fs-hint"[^>]*>([^<]*)<\/span>/); return r ? unesc(r[1]) : undefined }

const near = (a, b, msg, eps = 1e-9) => assert.ok(Math.abs(a - b) < eps, `${msg || ''} ${a} !~ ${b}`)
const nearView = (a, b, msg, eps = 2e-3) => { near(a.k, b.k, (msg || '') + ' k', eps); near(a.x, b.x, (msg || '') + ' x', eps); near(a.y, b.y, (msg || '') + ' y', eps) }
const worldPoint = (v, sx, sy) => ({ x: (sx - v.x) / v.k, y: (sy - v.y) / v.k }) // the drawing point under a viewport point

let n = 0
const test = async (name, fn) => { await fn(); n++; console.log('ok  ' + name) }

;(async () => {
  await buildBundle()
  ;({ DependencyTree, buildDependencyTreeModel, unfoldGroups, renderToStaticMarkup } = require(bundleOut))
  ZP = await import(pathToFileURL(path.join(compDir, 'zoomPanModel.js')).href)
  FM = await import(pathToFileURL(path.join(compDir, 'fullscreenModel.js')).href)
  MP = await import(pathToFileURL(path.join(uiDir, 'src', 'components', 'motionPreference.js')).href)

  const EN = payload('en')
  const SV = payload('sv')
  const toggleSrc = fs.readFileSync(path.join(compDir, 'FullscreenToggle.jsx'), 'utf8')
  const treeSrc = fs.readFileSync(path.join(compDir, 'DependencyTree.jsx'), 'utf8')
  const stripComments = s => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

  // ---------- 1. button and labels ----------
  await test('1 labels: the payload of scripts/progress-labels-json.sh carries the four keys in both languages, and a missing key fails', () => {
    for (const k of KEYS) assert.notStrictEqual(EN.labels[k], SV.labels[k], k + ' differs between the languages (the language switch is live)')
    for (const k of KEYS) assert.throws(() => requireKeys({ labels: without(EN.labels, [k]) }, 'en'), new RegExp('missing ' + k))
    assert.throws(() => requireKeys({ labels: { ...EN.labels, fullscreen_hint: '' } }, 'en'), /missing fullscreen_hint/)
  })

  for (const [lang, P] of [['en', EN], ['sv', SV]]) {
    await test(`1 button (${lang}): the toggle has aria-label and title equal to fullscreen_enter, pressed false, an icon, no hint`, () => withWorld({}, async W => {
      const m = mountTree(treeProps(P.labels), W)
      const h = m.html()
      const tag = toggleTag(h)
      assert.ok(tag, 'the toggle button is rendered')
      assert.strictEqual(attrOf(tag, 'type'), 'button')
      assert.strictEqual(attrOf(tag, 'aria-label'), P.labels.fullscreen_enter)
      assert.strictEqual(attrOf(tag, 'title'), P.labels.fullscreen_enter)
      assert.strictEqual(attrOf(tag, 'aria-pressed'), 'false')
      assert.ok(h.slice(h.indexOf(tag)).includes('<svg'), 'the icon is rendered inside the button')
      assert.ok(!h.includes('dt-fs-hint'), 'no hint while closed')
      const section = rootTag(h)
      assert.strictEqual(attrOf(section, 'data-fullscreen'), undefined)
      assert.strictEqual(attrOf(section, 'role'), undefined)
    }))
  }

  for (const [name, labelsFor] of [
    ['the payload without the four keys', () => without(EN.labels, KEYS)],
    ['an empty labels object', () => ({})],
  ]) {
    await test(`1 no labels (${name}): icon only, no aria-label or title, no hint, no dialog role, open and close do not throw`, () => withWorld({}, async W => {
      const full = treeProps(EN.labels)
      const m = mountTree({ model: full.model, labels: labelsFor() }, W)
      const h = m.html()
      const tag = toggleTag(h)
      assert.ok(tag, 'the toggle is still there')
      assert.strictEqual(attrOf(tag, 'aria-label'), undefined)
      assert.strictEqual(attrOf(tag, 'title'), undefined)
      assert.ok(h.slice(h.indexOf(tag)).includes('<svg'), 'the icon is the only content')
      m.click()
      const open = m.html()
      assert.strictEqual(attrOf(rootTag(open), 'data-fullscreen'), 'fallback', 'it still opens')
      assert.strictEqual(attrOf(rootTag(open), 'role'), undefined, 'no dialog role without fullscreen_layer')
      assert.strictEqual(attrOf(rootTag(open), 'aria-label'), undefined)
      assert.strictEqual(attrOf(toggleTag(open), 'aria-label'), undefined, 'no exit word either')
      assert.strictEqual(attrOf(toggleTag(open), 'aria-pressed'), 'true')
      assert.ok(!open.includes('dt-fs-hint'), 'no hint without fullscreen_hint')
      m.click()
      assert.strictEqual(attrOf(rootTag(m.html()), 'data-fullscreen'), undefined)
    }))
  }

  await test('1 empty tree: no toggle, no ref, no listener on the page', () => withWorld({}, async W => {
    for (const model of [{ empty: true }, buildDependencyTreeModel(graph(EN.labels, []), 'E01', EN.labels)]) {
      assert.strictEqual(model.empty, true, 'the model is the empty one')
      const m = mountTree({ model, labels: EN.labels }, W)
      const h = m.html()
      assert.ok(!h.includes('dt-fs-toggle'), 'no toggle button')
      assert.ok(!h.includes('<button'), 'no button at all')
      assert.ok(!m.toggleEl(), 'no FullscreenToggle element')
      assert.strictEqual(m.out().ref, null, 'no ref on the empty root')
      assert.strictEqual(attrOf(rootTag(h), 'data-empty'), 'true')
    }
  }))

  await test('1 words: the eight words come from the payload only; neither FullscreenToggle.jsx nor DependencyTree.jsx contains any of them', () => {
    const words = [...KEYS.map(k => EN.labels[k]), ...KEYS.map(k => SV.labels[k])]
    assert.strictEqual(new Set(words).size, 8, 'eight different words')
    assert.ok(toggleSrc.includes('dt-fs-btn') && treeSrc.includes('useFullscreen'), 'the right sources were read')
    for (const [name, src] of [['FullscreenToggle.jsx', toggleSrc], ['DependencyTree.jsx', treeSrc]]) {
      for (const w of words) assert.ok(!src.includes(w), `${name} contains the word "${w}"`)
    }
  })

  // ---------- 2. open state ----------
  for (const mode of ['fallback', 'native']) {
    for (const [lang, P] of [['en', EN], ['sv', SV]]) {
      await test(`2 open (${mode}, ${lang}): data-fullscreen, aria-pressed true, the exit label, the hint and the dialog with the layer label`, () => withWorld({ native: mode === 'native' }, async W => {
        const m = mountTree(treeProps(P.labels), W)
        const rootBefore = m.out().ref
        m.click(W.opener)
        if (mode === 'native') {
          assert.strictEqual(attrOf(rootTag(m.html()), 'data-fullscreen'), undefined, 'not believed fullscreen before the browser says so')
          await tick()
        }
        const h = m.html()
        const section = rootTag(h)
        assert.strictEqual(attrOf(section, 'data-fullscreen'), mode)
        assert.strictEqual(attrOf(section, 'role'), 'dialog')
        assert.strictEqual(attrOf(section, 'aria-modal'), 'true')
        assert.strictEqual(attrOf(section, 'aria-label'), P.labels.fullscreen_layer)
        const tag = toggleTag(h)
        assert.strictEqual(attrOf(tag, 'aria-pressed'), 'true')
        assert.strictEqual(attrOf(tag, 'aria-label'), P.labels.fullscreen_exit)
        assert.strictEqual(attrOf(tag, 'title'), P.labels.fullscreen_exit)
        assert.strictEqual(hintOf(h), P.labels.fullscreen_hint)
        assert.strictEqual(m.out().ref, rootBefore, 'the same root ref: nothing was re-created')
        assert.strictEqual(W.root.attrs['data-fullscreen'], mode, 'the hook marks the real root too')
        assert.strictEqual(W.html.attrs['data-dt-fullscreen'], mode === 'fallback' ? 'fallback' : undefined, 'page scroll lock only in the fallback layer')
        // and it closes again to the closed markup
        m.click(W.opener)
        const closed = m.html()
        assert.strictEqual(attrOf(rootTag(closed), 'data-fullscreen'), undefined)
        assert.strictEqual(attrOf(rootTag(closed), 'role'), undefined)
        assert.strictEqual(attrOf(toggleTag(closed), 'aria-pressed'), 'false')
        assert.strictEqual(attrOf(toggleTag(closed), 'aria-label'), P.labels.fullscreen_enter)
        assert.strictEqual(hintOf(closed), undefined)
      }))
    }
  }

  // ---------- 3. Esc and focus return ----------
  /** The end state shared by every way of closing the large view. */
  const assertClosed = (W, m, P, label) => {
    const h = m.html()
    assert.strictEqual(m.out().props['data-fullscreen'], undefined, label + ': no data-fullscreen on the root element')
    assert.strictEqual(attrOf(rootTag(h), 'role'), undefined, label + ': no dialog role')
    assert.strictEqual(attrOf(toggleTag(h), 'aria-pressed'), 'false', label + ': toggle not pressed')
    assert.strictEqual(attrOf(toggleTag(h), 'aria-label'), P.labels.fullscreen_enter, label + ': enter label back')
    assert.strictEqual(hintOf(h), undefined, label + ': no hint')
    assert.strictEqual(W.root.attrs['data-fullscreen'], undefined, label + ': attribute removed from the real root')
    assert.strictEqual(W.html.attrs['data-dt-fullscreen'], undefined, label + ': <html> flag removed')
    assert.strictEqual(W.keydownListeners().length, 0, label + ': no window keydown listener left')
    W.frames() // focus goes back on the next frame
    assert.strictEqual(W.doc.activeElement, W.opener, label + ': focus is on the opener')
    assert.strictEqual(W.focusLog[W.focusLog.length - 1], 'opener', label + ': the opener was the last element focused')
  }

  await test('3 Esc in the fallback: closes only the large view (the overlay listener is not called) and focus returns to the opener', () => withWorld({}, async W => {
    const overlay = []
    W.doc.addEventListener('keydown', e => overlay.push(e.key)) // stands in for EntryDetailPanel's document-level Escape
    const m = mountTree(treeProps(EN.labels), W)
    m.click(W.opener)
    assert.strictEqual(m.out().props['data-fullscreen'], 'fallback')
    assert.strictEqual(W.keydownListeners().length, 1, 'one Esc listener while the fallback layer is open')
    assert.ok(W.keydownListeners()[0].capture, 'in the capture phase, ahead of the overlay')
    assert.strictEqual(W.doc.activeElement, W.exitBtn, 'focus moved into the large view (the exit button)')
    const ev = W.key('Escape')
    assert.strictEqual(overlay.length, 0, 'the overlay did not see the Escape')
    assert.ok(ev.stopCalls >= 1 && ev.preventCalls >= 1, 'the event was stopped and default-prevented')
    assertClosed(W, m, EN, 'Escape')
    // with the large view closed the next Escape belongs to the overlay again
    W.key('Escape')
    assert.deepStrictEqual(overlay, ['Escape'], 'the overlay closes on the next Escape')
  }))

  await test('3 fullscreenchange: leaving real fullscreen ends in the same closed state, the overlay untouched, focus on the opener', () => withWorld({ native: true }, async W => {
    const overlay = []
    W.doc.addEventListener('keydown', e => overlay.push(e.key))
    const m = mountTree(treeProps(EN.labels), W)
    m.click(W.opener)
    await tick()
    assert.strictEqual(W.requestCalls, 1, 'real fullscreen was requested on the root')
    assert.strictEqual(m.out().props['data-fullscreen'], 'native')
    assert.strictEqual(W.keydownListeners().length, 0, 'no app listener in native: the browser keeps Esc')
    assert.strictEqual(W.doc.activeElement, W.exitBtn)
    // the browser leaves fullscreen (Esc, or its own UI) and says so
    W.doc.fullscreenElement = null
    W.fire('fullscreenchange')
    assertClosed(W, m, EN, 'fullscreenchange')
    assert.strictEqual(W.exitCalls, 0, 'the browser had left already: the app does not ask again')
    assert.strictEqual(overlay.length, 0, 'the overlay was not touched')
  }))

  await test('3 close button: the toggle closes the fallback layer to the same state (and leaves real fullscreen in native)', () => withWorld({ native: true }, async W => {
    const m = mountTree(treeProps(EN.labels), W)
    m.click(W.opener)
    await tick()
    assert.strictEqual(m.out().props['data-fullscreen'], 'native')
    m.click(W.opener)
    assert.strictEqual(W.exitCalls, 1, 'real fullscreen is left through document.exitFullscreen')
    assertClosed(W, m, EN, 'toggle (native)')
  }))

  // ---------- 4. state is kept ----------
  const boxOf = (model, expanded) => {
    const v = unfoldGroups(model, expanded)
    return { x: -10, y: -10, w: v.layout.width + 20, h: Math.max(v.layout.height, 24) + 20 } // the component's own box (no boundary nodes)
  }
  const S0 = { w: 800, h: 500 }, BIG = { w: 1400, h: 900 }
  const KEY = MP.MOTION_STORAGE_KEY

  for (const mode of ['fallback', 'native']) {
    await test(`4 kept (${mode}): scale, centre point, expanded groups, hover, Animations value survive enter and exit, and Fit did not run`, () => withWorld({ native: mode === 'native' }, async W => {
      const props = treeProps(EN.labels, GROUPED)
      W.stage.size = S0
      MP.applyMotion('off', W.html, () => W.storage) // the Animations toggle is Off
      const motionBefore = { attr: W.html.dataset.motion, stored: W.storage.data.get(KEY) }
      assert.deepStrictEqual(motionBefore, { attr: 'off', stored: 'off' })
      const htmlCallsBefore = W.html.setCalls.length

      const m = mountTree(props, W)
      const rootRef = m.out().ref
      // the first measured render is fitted, exactly as before
      const box0 = boxOf(props.model, new Set())
      nearView(m.view(), ZP.fitView(box0, S0), 'first render is fitted (the box formula matches the component)')

      // expand the group, then hover a card
      const group = m.find(e => e.props['data-kind'] === 'group')
      assert.ok(group, 'the fixture has a folded group')
      group.props.onClick()
      const expanded = m.slots().find(s => s instanceof Set)
      assert.strictEqual(expanded.size, 1, 'the group is expanded')
      assert.ok(m.find(e => e.props['data-toggle']), 'the collapse header of the expanded group is drawn')
      const box1 = boxOf(props.model, expanded)
      const card = m.find(e => e.props['data-node'] && e.props['data-kind'] !== 'group')
      card.props.onPointerEnter()
      const hoverSlot = m.slots().findIndex(s => s === card.props['data-node'])
      assert.ok(hoverSlot >= 0, 'the hovered card id is held in a state slot')

      // the user zooms (wheel about the cursor)
      W.stage.listeners.wheel({ deltaY: -100, ctrlKey: true, clientX: 500, clientY: 300, preventDefault() {} })
      const before = m.view()
      assert.ok(before.k > ZP.fitView(box1, S0).k * 1.5, 'the view was zoomed in by the user')
      const fitBig = ZP.fitView(box1, BIG)
      assert.ok(Math.abs(before.k - fitBig.k) > 0.1, 'a fit of the bigger container would give a visibly different scale')

      // enter: the container gets bigger
      m.click(W.opener)
      if (mode === 'native') await tick()
      assert.strictEqual(m.out().props['data-fullscreen'], mode)
      nearView(m.view(), before, 'entering alone changes nothing')
      W.resize(BIG.w, BIG.h)
      const entered = m.view()
      assert.strictEqual(entered.k, before.k, 'the scale is kept in the large view')
      nearView(entered, FM.keepCentre(before, S0, BIG), 'the view is the keepCentre result, not a fit')
      const cBefore = worldPoint(before, S0.w / 2, S0.h / 2), cIn = worldPoint(entered, BIG.w / 2, BIG.h / 2)
      near(cIn.x, cBefore.x, 'the centre point is kept (x)', 1e-2); near(cIn.y, cBefore.y, 'the centre point is kept (y)', 1e-2)
      assert.ok(Math.abs(entered.k - fitBig.k) > 0.1 && Math.abs(entered.x - fitBig.x) > 1, 'it is not the fit of the large container')
      assert.strictEqual(m.slots().find(s => s instanceof Set), expanded, 'expanded groups: the same Set object')
      assert.strictEqual(m.slots()[hoverSlot], card.props['data-node'], 'hover: the same state')
      assert.strictEqual(m.out().ref, rootRef, 'the same root ref')
      assert.deepStrictEqual({ attr: W.html.dataset.motion, stored: W.storage.data.get(KEY) }, motionBefore, 'Animations value unchanged while open')

      // exit: the container is small again
      m.click(W.opener)
      assert.strictEqual(m.out().props['data-fullscreen'], undefined)
      W.resize(S0.w, S0.h)
      const left = m.view()
      assert.strictEqual(left.k, before.k, 'the scale is kept after leaving')
      nearView(left, FM.keepCentre(entered, BIG, S0), 'the view is the keepCentre result again')
      nearView(left, before, 'enter then exit gives the user\'s view back')
      assert.ok(Math.abs(left.k - ZP.fitView(box1, S0).k) > 0.1, 'it is not a fit')
      assert.strictEqual(m.slots().find(s => s instanceof Set), expanded, 'expanded groups: the same Set object after exit')
      assert.strictEqual(m.slots()[hoverSlot], card.props['data-node'], 'hover: the same state after exit')
      assert.strictEqual(m.out().ref, rootRef)
      assert.deepStrictEqual({ attr: W.html.dataset.motion, stored: W.storage.data.get(KEY) }, motionBefore, 'Animations value unchanged after exit')
      assert.ok(W.html.setCalls.slice(htmlCallsBefore).every(name => name === 'data-dt-fullscreen'), 'the only <html> attribute the large view touches is its own flag')
    }))
  }

  await test('4 kept: a view nobody touched still follows the container exactly as before (Fit rules unchanged inside the large view)', () => withWorld({}, async W => {
    const props = treeProps(EN.labels, GROUPED)
    const m = mountTree(props, W)
    const box = boxOf(props.model, new Set())
    nearView(m.view(), ZP.fitView(box, S0))
    m.click(W.opener)
    W.resize(BIG.w, BIG.h)
    nearView(m.view(), ZP.fitView(box, BIG), 'an untouched view is fitted to the bigger container')
    m.click(W.opener)
    W.resize(S0.w, S0.h)
    nearView(m.view(), ZP.fitView(box, S0), 'and back')
  }))

  // ---------- 5. Fit regression guard (user decision of 2026-11-13: Fit stays exactly as it is) ----------
  await test('5 fitPlan: first render, same key touched, new key (and the unchanged resize and no-key rules) are pinned', () => {
    assert.strictEqual(ZP.fitPlan(null, 'E01', false), true, 'first render fits')
    assert.strictEqual(ZP.fitPlan(null, 'E01', true), true, 'first render fits whatever the touch flag')
    assert.strictEqual(ZP.fitPlan('E01', 'E01', true), false, 'same key, touched: never fits')
    assert.strictEqual(ZP.fitPlan('E01', 'E01', false), true, 'same key, untouched: fits on a resize')
    assert.strictEqual(ZP.fitPlan('E01', 'E02', true), true, 'new key fits even when touched')
    assert.strictEqual(ZP.fitPlan('E01', 'E02', false), true)
    assert.strictEqual(ZP.fitPlan('E01', null, false), false, 'no key (nothing drawn) never fits')
  })

  await test('5 fitView: three fixed inputs give fixed views (centred, scaled up, clamped at the top-left)', () => {
    const wide = ZP.fitView({ x: -10, y: -10, w: 2000, h: 900 }, { w: 800, h: 500 })
    near(wide.k, 0.384); near(wide.x, 19.84); near(wide.y, 81.04)
    const small = ZP.fitView({ x: -10, y: -10, w: 400, h: 200 }, { w: 800, h: 500 })
    near(small.k, 1.92); near(small.x, 35.2); near(small.y, 77.2)
    const huge = ZP.fitView({ x: -10, y: -10, w: 20000, h: 9000 }, { w: 800, h: 500 })
    near(huge.k, 0.25); near(huge.x, 18.5); near(huge.y, 18.5)
    const bigger = ZP.fitView({ x: -10, y: -10, w: 2000, h: 900 }, { w: 1400, h: 900 })
    near(bigger.k, 0.684); near(bigger.x, 22.84); near(bigger.y, 149.04)
    assert.strictEqual(ZP.FIT_PAD, 16)
  })

  await test('5 clampScale: clamps to 0.25 and 3; MIN_SCALE and MAX_SCALE are 0.25 and 3', () => {
    assert.strictEqual(ZP.MIN_SCALE, 0.25)
    assert.strictEqual(ZP.MAX_SCALE, 3)
    for (const [input, expected] of [[0.001, 0.25], [0.2499, 0.25], [0.25, 0.25], [1, 1], [3, 3], [3.0001, 3], [99, 3], [NaN, 1], [0, 1], [-2, 1]]) {
      assert.strictEqual(ZP.clampScale(input), expected, `clampScale(${input})`)
    }
  })

  await test('5 zoomPanModel.js contains no fullscreen text and imports nothing', () => {
    const src = fs.readFileSync(path.join(compDir, 'zoomPanModel.js'), 'utf8')
    assert.ok(src.includes('export function fitView') && src.includes('export function fitPlan'), 'the right file was read')
    assert.ok(!/fullscreen/i.test(src), 'no "fullscreen" anywhere in zoomPanModel.js, comments included')
    assert.ok(!/^\s*import\s/m.test(src), 'zoomPanModel.js imports nothing')
  })

  // ---------- 6. source rules ----------
  await test('6 source: FullscreenToggle.jsx has no hex literal (tokens only)', () => {
    const HEX = /#[0-9a-fA-F]{3,8}\b/
    assert.ok(HEX.test('color: #fff') && HEX.test('fill="#12abEF"'), 'the pattern finds hex literals')
    const code = stripComments(toggleSrc)
    assert.ok(code.includes('currentColor'), 'the icon takes its colour from the button')
    assert.ok(!HEX.test(code), 'FullscreenToggle.jsx contains a hex literal')
  })

  console.log(`${n} passed`)
})().catch(e => { console.error(e); process.exit(1) })
