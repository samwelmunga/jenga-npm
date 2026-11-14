#!/usr/bin/env node
'use strict'
// E92_S07_T03: tests for useFullscreen.js, the event wiring of the large view of the epic progress map. Zero test
// framework and no browser: the hook is bundled with esbuild against a hand-rolled hook runtime (technique of
// tree-zoom-pan.test.cjs and epic-overlay-tree.test.cjs) and driven through a fake document, window and elements.
//   1. native: requestFullscreen on the root, the state follows the reported change, no keydown listener.
//   2. refusal: unsupported, throwing, rejected, resolved-but-not-fullscreen and fullscreenerror all end in the fallback layer.
//   3. fullscreenchange: leaving real fullscreen closes the view, a change on a closed view changes nothing.
//   4. Esc in the fallback: the capture listener closes only the large view and a stand-in overlay listener is not called.
//   5. every way of closing returns focus to the opener and removes the attributes and listeners; unmount too.
//   6. guards: throwing getters, missing or throwing exitFullscreen, missing document or window, a missing root.
//   7. Source rules: the hook reads fullscreenModel only, no colour literal, nothing from the mirrors.
// fullscreen-model.test.cjs and the zoom/pan tests are separate files and are not touched.
// Run: node project/app/ui/scripts/fullscreen-hook.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const compDir = path.join(uiDir, 'src', 'components', 'progress')
const hookFile = path.join(compDir, 'useFullscreen.js')
const esbuild = require('esbuild')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fullscreen-hook-'))
const nodePaths = [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')]

// The hook imports react; inside src/ it is replaced by a shim that forwards to the hand-rolled runtime below.
const shim = path.join(tmp, 'react-shim.js')
fs.writeFileSync(shim, `
  const h = () => globalThis.__h
  export const useState = init => h().useState(init)
  export const useRef = init => h().useRef(init)
  export const useEffect = (fn, deps) => h().useEffect(fn, deps)
  export default {}
`)
const hookOut = path.join(tmp, 'hook.cjs')
const buildHook = () => esbuild.build({
  bundle: true, platform: 'node', format: 'cjs', jsx: 'automatic', nodePaths, loader: { '.css': 'empty' }, logLevel: 'silent', outfile: hookOut,
  stdin: { contents: `export { default as useFullscreen } from './src/components/progress/useFullscreen.js'`, resolveDir: uiDir, loader: 'js' },
  plugins: [{ name: 'react-hook-shim', setup(b) { b.onResolve({ filter: /^react$/ }, a => (a.importer.includes(path.sep + 'src' + path.sep) ? { path: shim } : null)) } }],
})

let n = 0
const test = async (name, fn) => { await fn(); n++; console.log('ok  ' + name) }
const tick = () => new Promise(resolve => setImmediate(resolve)) // lets every pending promise settle

/**
 * Hook runtime: state and ref slots, effects run after each render when their deps changed, in order, cleanups run on
 * unmount. A state setter re-renders; after unmount a setter is only counted (`lateSets`), so a state update on an
 * unmounted component is caught.
 */
function mountHook(hook, props) {
  let slots = [], deps = [], cleanups = [], i, effects, result, rendering = false, dirty = false, unmounted = false
  const probe = { renders: 0, lateSets: 0 }
  globalThis.__h = {
    useState(init) {
      const k = i++
      if (!(k in slots)) slots[k] = typeof init === 'function' ? init() : init
      return [slots[k], v => {
        if (unmounted) { probe.lateSets++; return }
        slots[k] = v
        flush()
      }]
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
  function flush() {
    if (rendering) { dirty = true; return }
    rendering = true
    do {
      dirty = false
      i = 0; effects = []
      result = hook(props)
      probe.renders++
      const run = effects; effects = []
      run.forEach(f => f())
    } while (dirty)
    rendering = false
  }
  flush()
  return {
    get z() { return result },
    probe,
    unmount() {
      unmounted = true
      cleanups.forEach(c => { if (c) c() })
      cleanups = []
    },
  }
}

/**
 * A fake page. `o.fullscreenEnabled`: true (default), false, 'missing', 'throws'. `o.request` is what root.requestFullscreen
 * does: 'ok' (the browser reports the change, then the promise resolves), 'throws', 'rejects', 'notfs' (resolves without
 * being fullscreen), 'silent' (fullscreen with no event, promise resolves), 'nopromise' (returns nothing, waits for events),
 * 'hang' (a promise that `release()` resolves, with the change event first), 'missing'. `o.exit`: 'ok', 'missing', 'throws',
 * 'rejects'. `o.raf`: false removes requestAnimationFrame.
 */
function makeWorld(o = {}) {
  const W = { focusLog: [], requestCalls: 0, requestThis: null, exitCalls: 0, listeners: [], frameQueue: [] }
  const el = name => ({
    name, attrs: {}, isConnected: true,
    setAttribute(k, v) { this.attrs[k] = String(v) },
    removeAttribute(k) { delete this.attrs[k] },
    focus() { W.focusLog.push(name); doc.activeElement = this },
  })
  const html = el('html'), root = el('root'), opener = el('opener'), other = el('other')
  const doc = {
    documentElement: html, activeElement: opener, fullscreenElement: null, listeners: {},
    addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f) },
    removeEventListener(t, f) { const a = this.listeners[t] || []; const k = a.indexOf(f); if (k >= 0) a.splice(k, 1) },
  }
  const fe = o.fullscreenEnabled === undefined ? true : o.fullscreenEnabled
  if (fe === 'throws') Object.defineProperty(doc, 'fullscreenEnabled', { get() { throw new Error('blocked by permissions policy') } })
  else if (fe !== 'missing') doc.fullscreenEnabled = fe
  const fire = type => (doc.listeners[type] || []).slice().forEach(f => f({ type }))
  let release = null
  const enterFullscreen = () => { doc.fullscreenElement = root; fire('fullscreenchange') }
  const request = o.request || 'ok'
  if (request !== 'missing') {
    root.requestFullscreen = function () {
      W.requestCalls++
      W.requestThis = this
      switch (request) {
        case 'throws': throw new Error('Fullscreen request denied')
        case 'rejects': return Promise.reject(new Error('Fullscreen request denied'))
        case 'notfs': return Promise.resolve()
        case 'silent': doc.fullscreenElement = root; return Promise.resolve()
        case 'nopromise': return undefined
        case 'hang': return new Promise(resolve => { release = () => { enterFullscreen(); resolve() } })
        default: return Promise.resolve().then(enterFullscreen)
      }
    }
  }
  const exit = o.exit || 'ok'
  if (exit !== 'missing') {
    doc.exitFullscreen = function () {
      W.exitCalls++
      doc.fullscreenElement = null // a real browser fires fullscreenchange after this; the tests fire it themselves
      if (exit === 'throws') throw new Error('Document not active')
      return exit === 'rejects' ? Promise.reject(new Error('Document not active')) : Promise.resolve()
    }
  }
  const win = {
    addEventListener(type, fn, capture) { W.listeners.push({ type, fn, capture: capture === true || !!(capture && capture.capture) }) },
    removeEventListener(type, fn, capture) {
      const c = capture === true || !!(capture && capture.capture)
      const k = W.listeners.findIndex(l => l.type === type && l.fn === fn && l.capture === c)
      if (k >= 0) W.listeners.splice(k, 1)
    },
  }
  if (o.raf !== false) win.requestAnimationFrame = cb => { W.frameQueue.push(cb); return W.frameQueue.length }
  Object.assign(W, {
    doc, win, html, root, opener, other,
    rootRef: { current: root },
    fire,
    release: () => release(),
    frames() { const q = W.frameQueue.splice(0); q.forEach(f => f()) },
    keydownListeners: () => W.listeners.filter(l => l.type === 'keydown'),
    changeListeners: () => (doc.listeners.fullscreenchange || []).length,
    // An Escape (or other) keydown the way the browser orders it: window capture listeners first, and a stopPropagation
    // there keeps it from the document-level listeners that follow (the stand-in for the epic overlay's own handler).
    key(k) {
      const ev = { key: k, stopCalls: 0, preventCalls: 0, stopped: false,
        stopPropagation() { this.stopCalls++; this.stopped = true }, preventDefault() { this.preventCalls++ } }
      W.listeners.filter(l => l.type === 'keydown' && l.capture).forEach(l => { if (!ev.stopped) l.fn(ev) })
      if (!ev.stopped) (doc.listeners.keydown || []).slice().forEach(f => f(ev))
      return ev
    },
  })
  return W
}

let useFullscreen
const install = W => { globalThis.document = W.doc; globalThis.window = W.win }
const uninstall = () => { delete globalThis.document; delete globalThis.window }
/** A world, installed, with the hook mounted; `run` gets `{ W, m }` and the globals are removed afterwards. */
async function withHook(o, run) {
  const W = makeWorld(o)
  install(W)
  try {
    const m = mountHook(useFullscreen, { rootRef: o && o.rootRef ? o.rootRef : W.rootRef })
    await run({ W, m })
  } finally {
    uninstall()
  }
}
/** The end state shared by every way of closing. */
const assertClosed = (W, m, label) => {
  assert.strictEqual(m.z.mode, 'closed', label + ': mode')
  assert.strictEqual(m.z.open, false, label + ': open')
  assert.strictEqual(W.root.attrs['data-fullscreen'], undefined, label + ': root attribute gone')
  assert.strictEqual(W.html.attrs['data-dt-fullscreen'], undefined, label + ': html attribute gone')
  assert.strictEqual(W.keydownListeners().length, 0, label + ': no keydown listener left')
}

;(async () => {
  await buildHook()
  ;({ useFullscreen } = require(hookOut))

  // ---------- 1. native ----------
  await test('native: toggle() calls requestFullscreen on the root and the state becomes native after the reported change', () => withHook({}, async ({ W, m }) => {
    assert.strictEqual(m.z.mode, 'closed')
    assert.strictEqual(m.z.open, false)
    m.z.toggle(W.opener)
    assert.strictEqual(W.requestCalls, 1)
    assert.strictEqual(W.requestThis, W.root, 'requestFullscreen is called on the tree root')
    assert.strictEqual(m.z.mode, 'closed', 'not believed fullscreen before the browser says so')
    assert.strictEqual(W.root.attrs['data-fullscreen'], undefined)
    await tick()
    assert.strictEqual(m.z.mode, 'native')
    assert.strictEqual(m.z.open, true)
    assert.strictEqual(W.root.attrs['data-fullscreen'], 'native')
    assert.strictEqual(W.html.attrs['data-dt-fullscreen'], undefined, 'no page scroll lock in native')
  }))

  await test('native: a resolved request that is fullscreen on the root enters even when no change event arrives', () => withHook({ request: 'silent' }, async ({ W, m }) => {
    m.z.toggle()
    await tick()
    assert.strictEqual(m.z.mode, 'native')
    assert.strictEqual(W.root.attrs['data-fullscreen'], 'native')
  }))

  await test('native: a request without a promise waits for the change event, and a change of another element is ignored', () => withHook({ request: 'nopromise' }, async ({ W, m }) => {
    m.z.toggle()
    await tick()
    assert.strictEqual(m.z.mode, 'closed')
    W.doc.fullscreenElement = W.other
    W.fire('fullscreenchange')
    assert.strictEqual(m.z.mode, 'closed', 'another element going fullscreen is not the root')
    W.doc.fullscreenElement = W.root
    W.fire('fullscreenchange')
    assert.strictEqual(m.z.mode, 'native')
  }))

  await test('native: the webkit prefixed pair and event are used when the unprefixed API is missing', () => withHook({ fullscreenEnabled: 'missing', request: 'missing' }, async ({ W, m }) => {
    W.doc.webkitFullscreenEnabled = true
    let called = 0
    W.root.webkitRequestFullscreen = function () { called++; W.doc.webkitFullscreenElement = W.root; W.fire('webkitfullscreenchange') }
    m.z.toggle()
    assert.strictEqual(called, 1)
    assert.strictEqual(m.z.mode, 'native')
    W.doc.webkitFullscreenElement = null
    W.fire('webkitfullscreenchange')
    assertClosed(W, m, 'webkit change')
  }))

  await test('native: the hook registers no keydown listener at any point', () => withHook({}, async ({ W, m }) => {
    assert.strictEqual(W.keydownListeners().length, 0, 'closed')
    m.z.toggle()
    assert.strictEqual(W.keydownListeners().length, 0, 'request in flight')
    await tick()
    assert.strictEqual(m.z.mode, 'native')
    assert.strictEqual(W.keydownListeners().length, 0, 'open in native')
    const seen = []
    W.doc.addEventListener('keydown', e => seen.push(e.key))
    W.key('Escape')
    assert.deepStrictEqual(seen, ['Escape'], 'Esc is left to the browser and to the overlay')
    assert.strictEqual(m.z.mode, 'native', 'a keydown does not close a native view; fullscreenchange does')
  }))

  // ---------- 2. refusal: the fallback layer ----------
  const assertFallback = (W, m, label) => {
    assert.strictEqual(m.z.mode, 'fallback', label + ': mode')
    assert.strictEqual(m.z.open, true, label + ': open')
    assert.strictEqual(W.root.attrs['data-fullscreen'], 'fallback', label + ': root attribute')
    assert.strictEqual(W.html.attrs['data-dt-fullscreen'], 'fallback', label + ': html attribute')
  }

  await test('fallback: an unsupported document (fullscreenEnabled false or missing, no requestFullscreen) opens the layer at once', async () => {
    for (const o of [{ fullscreenEnabled: false }, { fullscreenEnabled: 'missing' }, { request: 'missing' }]) {
      await withHook(o, async ({ W, m }) => {
        m.z.toggle(W.opener)
        assertFallback(W, m, JSON.stringify(o))
        assert.strictEqual(W.requestCalls, 0, 'nothing is requested')
        assert.strictEqual(W.keydownListeners().length, 1, 'the Esc listener is registered')
      })
    }
  })

  await test('fallback: a requestFullscreen that throws synchronously opens the layer', () => withHook({ request: 'throws' }, async ({ W, m }) => {
    assert.doesNotThrow(() => m.z.toggle(W.opener))
    assert.strictEqual(W.requestCalls, 1)
    assertFallback(W, m, 'throwing request')
  }))

  await test('fallback: a rejected promise opens the layer, without an unhandled rejection', () => withHook({ request: 'rejects' }, async ({ W, m }) => {
    m.z.toggle(W.opener)
    assert.strictEqual(m.z.mode, 'closed', 'not yet decided')
    await tick()
    assertFallback(W, m, 'rejected request')
    assert.strictEqual(W.keydownListeners().length, 1)
  }))

  await test('fallback: a request that resolves without the root being fullscreen opens the layer', () => withHook({ request: 'notfs' }, async ({ W, m }) => {
    m.z.toggle(W.opener)
    await tick()
    assertFallback(W, m, 'resolved but not fullscreen')
  }))

  await test('fallback: fullscreenerror during a request opens the layer; a fullscreenerror at any other time changes nothing', () => withHook({ request: 'nopromise' }, async ({ W, m }) => {
    W.fire('fullscreenerror')
    assert.strictEqual(m.z.mode, 'closed')
    m.z.toggle(W.opener)
    W.fire('fullscreenerror')
    assertFallback(W, m, 'fullscreenerror')
    W.fire('fullscreenerror')
    assertFallback(W, m, 'second fullscreenerror')
  }))

  await test('fallback: a throwing fullscreenEnabled getter opens the layer', () => withHook({ fullscreenEnabled: 'throws' }, async ({ W, m }) => {
    assert.doesNotThrow(() => m.z.toggle(W.opener))
    assertFallback(W, m, 'throwing getter')
    assert.strictEqual(W.requestCalls, 0)
  }))

  // ---------- 3. fullscreenchange ----------
  await test('fullscreenchange: leaving real fullscreen closes the view, removes the attributes and returns focus to the opener', () => withHook({}, async ({ W, m }) => {
    m.z.toggle(W.opener)
    await tick()
    assert.strictEqual(m.z.mode, 'native')
    W.doc.fullscreenElement = null // Esc or the browser UI
    W.fire('fullscreenchange')
    assertClosed(W, m, 'fullscreenchange')
    assert.strictEqual(W.exitCalls, 0, 'the browser already left fullscreen; exitFullscreen is not called')
    assert.deepStrictEqual(W.focusLog, [], 'focus goes back on the next frame, not before')
    W.frames()
    assert.deepStrictEqual(W.focusLog, ['opener'])
  }))

  await test('fullscreenchange: after an already closed view it changes nothing and throws nothing', () => withHook({}, async ({ W, m }) => {
    m.z.toggle(W.opener)
    await tick()
    m.z.exit() // the close button
    W.fire('fullscreenchange') // the change the browser reports for that exit
    W.frames()
    const renders = m.probe.renders
    assertClosed(W, m, 'close button')
    assert.strictEqual(W.exitCalls, 1)
    assert.deepStrictEqual(W.focusLog, ['opener'])
    assert.doesNotThrow(() => { W.fire('fullscreenchange'); W.fire('webkitfullscreenchange') })
    W.frames()
    assertClosed(W, m, 'late changes')
    assert.strictEqual(W.exitCalls, 1, 'no second exit')
    assert.deepStrictEqual(W.focusLog, ['opener'], 'focus is returned once')
    assert.strictEqual(m.probe.renders, renders, 'no render for a no-op')
    // a never opened view too
    await withHook({}, async ({ W: W2, m: m2 }) => {
      assert.doesNotThrow(() => W2.fire('fullscreenchange'))
      assertClosed(W2, m2, 'never opened')
      assert.strictEqual(W2.exitCalls, 0)
    })
  }))

  await test('fullscreenchange: a change in the fallback layer (the root is not fullscreen) leaves the layer open', () => withHook({ fullscreenEnabled: false }, async ({ W, m }) => {
    m.z.toggle(W.opener)
    W.fire('fullscreenchange')
    assertFallback(W, m, 'unrelated change')
    assert.strictEqual(W.exitCalls, 0)
  }))

  // ---------- 4. Esc in the fallback ----------
  await test('Esc in the fallback: the capture listener closes only the large view, the overlay listener is not called', () => withHook({ fullscreenEnabled: false }, async ({ W, m }) => {
    let overlayCalls = 0
    W.doc.addEventListener('keydown', () => { overlayCalls++ }) // stands in for EntryDetailPanel's document-level Escape
    m.z.toggle(W.opener)
    const listeners = W.keydownListeners()
    assert.strictEqual(listeners.length, 1)
    assert.strictEqual(listeners[0].capture, true, 'a capture-phase listener on the window')
    const ev = W.key('Escape')
    assert.strictEqual(overlayCalls, 0, 'the overlay did not see the Escape')
    assert.strictEqual(ev.stopCalls, 1, 'stopPropagation')
    assert.strictEqual(ev.preventCalls, 1, 'preventDefault')
    assertClosed(W, m, 'Escape')
    W.frames()
    assert.deepStrictEqual(W.focusLog, ['opener'])
    // with the large view closed, the next Escape belongs to the overlay again
    const again = W.key('Escape')
    assert.strictEqual(overlayCalls, 1, 'the overlay closes on the next Escape')
    assert.strictEqual(again.stopCalls, 0)
  }))

  await test('Esc in the fallback: other keys are left alone and the layer stays open', () => withHook({ fullscreenEnabled: false }, async ({ W, m }) => {
    let overlayCalls = 0
    W.doc.addEventListener('keydown', () => { overlayCalls++ })
    m.z.toggle(W.opener)
    const ev = W.key('a')
    assert.strictEqual(ev.stopCalls, 0)
    assert.strictEqual(ev.preventCalls, 0)
    assert.strictEqual(overlayCalls, 1)
    assertFallback(W, m, 'after another key')
    // the legacy key name is Escape too
    W.key('Esc')
    assertClosed(W, m, 'Esc')
  }))

  await test('Esc in the fallback after a refused native request closes only the large view too', () => withHook({ request: 'rejects' }, async ({ W, m }) => {
    let overlayCalls = 0
    W.doc.addEventListener('keydown', () => { overlayCalls++ })
    m.z.toggle(W.opener)
    await tick()
    assertFallback(W, m, 'refused')
    W.key('Escape')
    assert.strictEqual(overlayCalls, 0)
    assertClosed(W, m, 'Escape after refusal')
  }))

  // ---------- 5. every way of closing ----------
  await test('close button in the fallback: attributes and Esc listener gone, focus back on the opener', () => withHook({ fullscreenEnabled: false }, async ({ W, m }) => {
    m.z.toggle(W.opener)
    assertFallback(W, m, 'open')
    m.z.toggle() // the toggle control pressed again
    assertClosed(W, m, 'toggle')
    W.frames()
    assert.deepStrictEqual(W.focusLog, ['opener'])
    m.z.toggle(W.opener)
    assertFallback(W, m, 'reopened')
    m.z.exit()
    assertClosed(W, m, 'exit()')
    W.frames()
    assert.deepStrictEqual(W.focusLog, ['opener', 'opener'])
  }))

  await test('close button in native: exitFullscreen is called once, the later change is a no-op, focus returns once', () => withHook({}, async ({ W, m }) => {
    m.z.toggle(W.opener)
    await tick()
    m.z.exit()
    assert.strictEqual(W.exitCalls, 1)
    assertClosed(W, m, 'exit()')
    W.fire('fullscreenchange')
    m.z.exit() // re-entrant
    m.z.toggle(W.opener) // reopens: a new request
    assert.strictEqual(W.requestCalls, 2)
    await tick()
    assert.strictEqual(m.z.mode, 'native')
    W.doc.fullscreenElement = null
    W.fire('fullscreenchange')
    W.frames()
    assert.deepStrictEqual(W.focusLog, ['opener', 'opener'], 'once per close')
    assert.strictEqual(W.exitCalls, 1, 'the browser-initiated close did not call exitFullscreen')
  }))

  await test('re-entrant exit is a no-op: nothing changes, nothing renders, nothing is called', () => withHook({ fullscreenEnabled: false }, async ({ W, m }) => {
    m.z.exit() // never opened
    assert.strictEqual(m.probe.renders, 1)
    m.z.toggle(W.opener)
    m.z.exit()
    W.frames()
    const renders = m.probe.renders
    m.z.exit()
    m.z.exit()
    W.frames()
    assert.strictEqual(m.probe.renders, renders)
    assert.deepStrictEqual(W.focusLog, ['opener'])
  }))

  await test('unmount in the fallback: listener, attributes and the document listeners are removed, focus returns, no state update', () => withHook({ fullscreenEnabled: false }, async ({ W, m }) => {
    m.z.toggle(W.opener)
    assertFallback(W, m, 'open')
    assert.ok(W.changeListeners() > 0)
    m.unmount()
    assert.strictEqual(W.keydownListeners().length, 0, 'Esc listener removed')
    assert.strictEqual(W.root.attrs['data-fullscreen'], undefined)
    assert.strictEqual(W.html.attrs['data-dt-fullscreen'], undefined)
    assert.strictEqual(W.changeListeners(), 0)
    assert.strictEqual(m.probe.lateSets, 0, 'no setState after unmount')
    W.frames()
    assert.deepStrictEqual(W.focusLog, ['opener'])
  }))

  await test('unmount in native: exitFullscreen is called while the root is fullscreen, attributes removed, focus returns', () => withHook({}, async ({ W, m }) => {
    m.z.toggle(W.opener)
    await tick()
    W.rootRef.current = null // React clears the ref before the cleanup of an unmounting component runs
    m.unmount()
    assert.strictEqual(W.exitCalls, 1)
    assert.strictEqual(W.html.attrs['data-dt-fullscreen'], undefined)
    assert.strictEqual(W.root.attrs['data-fullscreen'], undefined)
    assert.strictEqual(W.changeListeners(), 0)
    assert.strictEqual(m.probe.lateSets, 0)
    W.frames()
    assert.deepStrictEqual(W.focusLog, ['opener'])
  }))

  await test('unmount of a closed view removes the document listeners and does nothing else', () => withHook({}, async ({ W, m }) => {
    assert.ok(W.changeListeners() > 0)
    m.unmount()
    assert.strictEqual(W.changeListeners(), 0)
    assert.strictEqual(W.exitCalls, 0)
    W.frames()
    assert.deepStrictEqual(W.focusLog, [])
  }))

  await test('unmount while a request is in flight: a fullscreen the browser grants afterwards is left again', () => withHook({ request: 'hang' }, async ({ W, m }) => {
    m.z.toggle(W.opener)
    m.unmount()
    W.release() // the browser answers late
    await tick()
    assert.strictEqual(W.exitCalls, 1)
    assert.strictEqual(m.probe.lateSets, 0)
    assert.strictEqual(W.root.attrs['data-fullscreen'], undefined)
  }))

  await test('exit while a request is in flight cancels it: the late fullscreen is left, the view stays closed', () => withHook({ request: 'hang' }, async ({ W, m }) => {
    m.z.toggle(W.opener)
    m.z.toggle(W.opener) // a second press while pending does not send a second request
    assert.strictEqual(W.requestCalls, 1)
    m.z.exit()
    W.release()
    await tick()
    assert.strictEqual(W.exitCalls, 1)
    assertClosed(W, m, 'cancelled request')
    W.frames()
    assert.deepStrictEqual(W.focusLog, [], 'nothing was opened, so there is no focus to return')
  }))

  await test('opener: an element passed to toggle, an event currentTarget, or the focused element is the one that gets focus back', () => withHook({ fullscreenEnabled: false }, async ({ W, m }) => {
    W.doc.activeElement = W.other
    m.z.toggle(W.opener) // an explicit element wins over the focused one
    m.z.exit(); W.frames()
    m.z.toggle({ currentTarget: W.other, type: 'click' }) // what a React onClick={fs.toggle} passes
    m.z.exit(); W.frames()
    W.doc.activeElement = W.opener
    m.z.toggle() // no argument: the focused element
    m.z.exit(); W.frames()
    assert.deepStrictEqual(W.focusLog, ['opener', 'other', 'opener'])
  }))

  await test('focus return is guarded: an opener that is gone, one whose focus throws, no opener at all, and no requestAnimationFrame', () => withHook({ fullscreenEnabled: false }, async ({ W, m }) => {
    m.z.toggle(W.opener)
    W.opener.isConnected = false
    m.z.exit(); W.frames()
    assert.deepStrictEqual(W.focusLog, [], 'a disconnected opener is skipped')
    W.opener.isConnected = true
    const broken = { focus() { throw new Error('cannot focus') } }
    m.z.toggle(broken)
    m.z.exit()
    assert.doesNotThrow(() => W.frames())
    W.doc.activeElement = null
    m.z.toggle()
    m.z.exit()
    assert.doesNotThrow(() => W.frames())
    assert.deepStrictEqual(W.focusLog, [])
  }))

  await test('focus return without requestAnimationFrame happens at once', () => withHook({ fullscreenEnabled: false, raf: false }, async ({ W, m }) => {
    m.z.toggle(W.opener)
    m.z.exit()
    assert.deepStrictEqual(W.focusLog, ['opener'])
  }))

  // ---------- 6. guards ----------
  await test('guard: a missing exitFullscreen never throws on close', () => withHook({ exit: 'missing' }, async ({ W, m }) => {
    m.z.toggle(W.opener)
    await tick()
    assert.strictEqual(m.z.mode, 'native')
    assert.doesNotThrow(() => m.z.exit())
    assertClosed(W, m, 'no exitFullscreen')
  }))

  await test('guard: an exitFullscreen that throws, or rejects, never propagates', async () => {
    for (const exit of ['throws', 'rejects']) {
      await withHook({ exit }, async ({ W, m }) => {
        m.z.toggle(W.opener)
        await tick()
        assert.doesNotThrow(() => m.z.exit())
        await tick() // an unhandled rejection would end the process here
        assertClosed(W, m, 'exit ' + exit)
      })
    }
  })

  await test('guard: a requestFullscreen that throws synchronously never propagates, even with a throwing webkit pair', () => withHook({ request: 'throws' }, async ({ W, m }) => {
    assert.doesNotThrow(() => m.z.toggle(W.opener))
    assertFallback(W, m, 'sync throw')
  }))

  await test('guard: a thenable whose then throws is a refusal', () => withHook({ request: 'missing' }, async ({ W, m }) => {
    W.doc.fullscreenEnabled = true
    W.root.requestFullscreen = () => ({ then() { throw new Error('broken thenable') } })
    assert.doesNotThrow(() => m.z.toggle(W.opener))
    assertFallback(W, m, 'broken thenable')
  }))

  await test('guard: no document and no window at all still opens and closes the layer', async () => {
    const W = makeWorld({})
    uninstall()
    const m = mountHook(useFullscreen, { rootRef: W.rootRef })
    assert.doesNotThrow(() => m.z.toggle())
    assert.strictEqual(m.z.mode, 'fallback')
    assert.strictEqual(W.root.attrs['data-fullscreen'], 'fallback')
    assert.doesNotThrow(() => m.z.exit())
    assert.strictEqual(m.z.mode, 'closed')
    assert.strictEqual(W.root.attrs['data-fullscreen'], undefined)
    assert.doesNotThrow(() => m.unmount())
  })

  await test('guard: listeners, attributes and focus that throw never propagate', async () => {
    const W = makeWorld({ fullscreenEnabled: false })
    W.win.addEventListener = () => { throw new Error('no window listeners') }
    W.win.removeEventListener = () => { throw new Error('no window listeners') }
    W.doc.addEventListener = () => { throw new Error('no document listeners') }
    W.doc.removeEventListener = () => { throw new Error('no document listeners') }
    W.html.setAttribute = () => { throw new Error('read-only') }
    W.root.setAttribute = () => { throw new Error('read-only') }
    W.root.removeAttribute = () => { throw new Error('read-only') }
    install(W)
    try {
      let m
      assert.doesNotThrow(() => { m = mountHook(useFullscreen, { rootRef: W.rootRef }) })
      assert.doesNotThrow(() => m.z.toggle(W.opener))
      assert.strictEqual(m.z.mode, 'fallback', 'the layer still opens')
      assert.doesNotThrow(() => m.z.exit())
      assert.strictEqual(m.z.mode, 'closed')
      assert.doesNotThrow(() => m.unmount())
    } finally {
      uninstall()
    }
  })

  await test('guard: a document whose property reads throw never propagates', async () => {
    const W = makeWorld({})
    const hostile = new Proxy({}, { get() { throw new Error('SecurityError') }, set() { throw new Error('SecurityError') } })
    globalThis.document = hostile
    globalThis.window = W.win
    try {
      let m
      assert.doesNotThrow(() => { m = mountHook(useFullscreen, { rootRef: W.rootRef }) })
      assert.doesNotThrow(() => m.z.toggle())
      await tick()
      assert.strictEqual(m.z.mode, 'fallback')
      assert.doesNotThrow(() => m.z.exit())
      assert.doesNotThrow(() => m.unmount())
    } finally {
      uninstall()
    }
  })

  await test('guard: a missing root (ref not attached yet, or no ref) opens nothing', async () => {
    await withHook({ rootRef: { current: null } }, async ({ W, m }) => {
      assert.doesNotThrow(() => m.z.toggle(W.opener))
      assert.strictEqual(m.z.mode, 'closed')
      assert.strictEqual(W.html.attrs['data-dt-fullscreen'], undefined)
      assert.strictEqual(W.keydownListeners().length, 0)
    })
    install(makeWorld({}))
    try {
      const m = mountHook(useFullscreen, undefined)
      assert.doesNotThrow(() => m.z.toggle())
      assert.strictEqual(m.z.mode, 'closed')
      assert.doesNotThrow(() => m.unmount())
    } finally {
      uninstall()
    }
  })

  // ---------- 7. source rules ----------
  await test('source: the hook reads fullscreenModel only, no colour literal, no mirror path, no zoom/pan import', () => {
    const src = fs.readFileSync(hookFile, 'utf8')
    assert.ok(/from '\.\/fullscreenModel'/.test(src), 'imports the model')
    const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '') // the header comment may name the module it mirrors
    assert.ok(!/zoomPanModel|useZoomPan/.test(code), 'does not import or call the zoom/pan modules')
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(src), 'no hex colour literal')
    assert.ok(!/\.claude|\.agents/.test(src), 'nothing from the mirrors')
    assert.ok(!/\bsetTimeout\b|\bsetInterval\b/.test(src), 'no timers')
  })

  console.log(`\n${n} tests passed`)
  fs.rmSync(tmp, { recursive: true, force: true })
})().catch(err => {
  console.error(err)
  process.exit(1)
})
