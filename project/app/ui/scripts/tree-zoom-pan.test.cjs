#!/usr/bin/env node
'use strict'
// E92_S06_T21: tests for the zoom and pan of the overlay dependency tree. Zero test framework and no DOM.
//   1. zoomPanModel.js, the pure maths: wheel zoom about the cursor, ctrl faster, clamp 0.25-3, pinch from two pointers,
//      the drag threshold, Fit, and when Fit runs.
//   2. useZoomPan.js driven through a hand-rolled hook runtime (technique of epic-overlay-tree.test.cjs) with a fake
//      element, a fake ResizeObserver and hand-made pointer and wheel events: fit on first render and on an epic change
//      but not on a data refresh, wheel, drag vs click, pinch, the four buttons.
//   3. DependencyTree rendered with react-dom/server: the controls, their words from the labels, none without labels.
//   4. Source rules: no colour literal, no leftover min-width on the drawing.
// Run: node project/app/ui/scripts/tree-zoom-pan.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { pathToFileURL } = require('url')

const uiDir = path.join(__dirname, '..')
const compDir = path.join(uiDir, 'src', 'components', 'progress')
const esbuild = require('esbuild')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tree-zoom-pan-'))
const nodePaths = [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')]

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
const hookOut = path.join(tmp, 'hook.cjs')
const realOut = path.join(tmp, 'real.cjs')
const hookEntry = `export { default as useZoomPan } from './src/components/progress/useZoomPan.js'`
const realEntry = `
  import { createElement as ce } from 'react'
  import { renderToStaticMarkup } from 'react-dom/server'
  export { default as DependencyTree } from './src/components/progress/DependencyTree.jsx'
  export { buildDependencyTreeModel } from './src/components/progress/dependencyTreeModel.js'
  export { ce, renderToStaticMarkup }
`
const common = { bundle: true, platform: 'node', format: 'cjs', jsx: 'automatic', nodePaths, loader: { '.css': 'empty' }, logLevel: 'silent' }
// the hook bundle uses a plugin, and esbuild refuses plugins in buildSync, so both builds run async inside the main function
const buildAll = async () => {
  await esbuild.build({ ...common, stdin: { contents: hookEntry, resolveDir: uiDir, loader: 'js' }, outfile: hookOut,
    plugins: [{ name: 'react-hook-shim', setup(b) { b.onResolve({ filter: /^react$/ }, a => (a.importer.includes(path.sep + 'src' + path.sep) ? { path: shim } : null)) } }] })
  await esbuild.build({ ...common, stdin: { contents: realEntry, resolveDir: uiDir, loader: 'jsx' }, outfile: realOut })
}
let useZoomPan, DependencyTree, buildDependencyTreeModel, ce, renderToStaticMarkup

let n = 0
const test = async (name, fn) => { await fn(); n++; console.log('ok  ' + name) }
const near = (a, b, msg, eps = 1e-9) => assert.ok(Math.abs(a - b) < eps, `${msg || ''} ${a} !~ ${b}`)

;(async () => {
  await buildAll()
  ;({ useZoomPan } = require(hookOut))
  ;({ DependencyTree, buildDependencyTreeModel, ce, renderToStaticMarkup } = require(realOut))
  const M = await import(pathToFileURL(path.join(compDir, 'zoomPanModel.js')).href)
  const world = (v, sx, sy) => ({ x: (sx - v.x) / v.k, y: (sy - v.y) / v.k }) // the drawing point under a viewport point

  // ---------- 1. the pure maths ----------
  await test('wheel zoom keeps the drawing point under the cursor fixed', () => {
    const v0 = { k: 1, x: 40, y: -25 }
    for (const [cx, cy, dy] of [[300, 200, -120], [10, 490, -120], [650, 40, 90], [0, 0, -300]]) {
      const v1 = M.wheelZoom(v0, { deltaY: dy, ctrlKey: false, deltaMode: 0 }, cx, cy)
      assert.notStrictEqual(v1.k, v0.k, 'the scale changed')
      const a = world(v0, cx, cy), b = world(v1, cx, cy)
      near(a.x, b.x, 'x fixed'); near(a.y, b.y, 'y fixed')
    }
  })

  await test('wheel direction: up (negative deltaY) zooms in, down zooms out; zero changes nothing', () => {
    const v = { k: 1, x: 0, y: 0 }
    assert.ok(M.wheelZoom(v, { deltaY: -100 }, 5, 5).k > 1)
    assert.ok(M.wheelZoom(v, { deltaY: 100 }, 5, 5).k < 1)
    assert.strictEqual(M.wheelZoom(v, { deltaY: 0 }, 5, 5), v)
  })

  await test('ctrl-wheel zooms faster than a plain wheel, by the documented rates', () => {
    const v = { k: 1, x: 0, y: 0 }
    const plain = M.wheelZoom(v, { deltaY: -10, ctrlKey: false }, 0, 0).k
    const ctrl = M.wheelZoom(v, { deltaY: -10, ctrlKey: true }, 0, 0).k
    assert.ok(ctrl > plain && plain > 1)
    near(Math.log(plain), 10 * M.WHEEL_RATE, 'plain rate'); near(Math.log(ctrl), 10 * M.WHEEL_RATE_CTRL, 'ctrl rate')
    assert.ok(M.WHEEL_RATE_CTRL > M.WHEEL_RATE)
    // a wheel that reports lines instead of pixels is scaled
    assert.ok(M.wheelZoom(v, { deltaY: -1, deltaMode: 1 }, 0, 0).k > M.wheelZoom(v, { deltaY: -1, deltaMode: 0 }, 0, 0).k)
  })

  await test('the scale is clamped to 0.25-3 at both ends, and the fixed point survives the clamp', () => {
    assert.strictEqual(M.MIN_SCALE, 0.25)
    assert.strictEqual(M.MAX_SCALE, 3)
    let v = { k: 1, x: 12, y: 7 }
    for (let i = 0; i < 40; i++) v = M.wheelZoom(v, { deltaY: -500, ctrlKey: true }, 321, 123)
    assert.strictEqual(v.k, 3)
    near(world(v, 321, 123).x, world({ k: 1, x: 12, y: 7 }, 321, 123).x, 'fixed at the top')
    for (let i = 0; i < 80; i++) v = M.wheelZoom(v, { deltaY: 500, ctrlKey: true }, 321, 123)
    assert.strictEqual(v.k, 0.25)
    assert.strictEqual(M.clampScale(99), 3); assert.strictEqual(M.clampScale(0.001), 0.25); assert.strictEqual(M.clampScale(NaN), 1)
    // at the limit a further zoom changes nothing at all
    assert.strictEqual(M.zoomAbout(v, 0.5, 1, 1), v)
  })

  await test('buttons: plus and minus zoom about the centre, 100 % is scale 1, percent is a whole number', () => {
    const size = { w: 800, h: 400 }
    const v0 = { k: 0.5, x: 30, y: 10 }
    const up = M.stepZoom(v0, M.BUTTON_STEP, size)
    near(up.k, 0.625)
    near(world(up, 400, 200).x, world(v0, 400, 200).x); near(world(up, 400, 200).y, world(v0, 400, 200).y)
    assert.ok(M.stepZoom(v0, 1 / M.BUTTON_STEP, size).k < 0.5)
    const one = M.actualSize(v0, size)
    assert.strictEqual(one.k, 1)
    near(world(one, 400, 200).x, world(v0, 400, 200).x)
    assert.strictEqual(M.percentOf({ k: 1.256 }), 126)
    assert.strictEqual(M.percentOf(one), 100)
  })

  await test('pinch: the scale follows the distance of two pointers, the midpoint keeps its drawing point', () => {
    const v0 = { k: 1, x: 20, y: 30 }
    const a0 = { x: 200, y: 200 }, b0 = { x: 300, y: 200 }
    const start = M.pinchStart(v0, a0, b0)
    assert.strictEqual(start.d0, 100)
    // spread to twice the distance around the same midpoint
    const v1 = M.pinchView(start, { x: 150, y: 200 }, { x: 350, y: 200 })
    near(v1.k, 2)
    const m0 = world(v0, 250, 200), m1 = world(v1, 250, 200)
    near(m0.x, m1.x); near(m0.y, m1.y)
    // pinch inwards
    near(M.pinchView(start, { x: 225, y: 200 }, { x: 275, y: 200 }).k, 0.5)
    // the same distance but moved: pure pan, scale unchanged
    const moved = M.pinchView(start, { x: 230, y: 240 }, { x: 330, y: 240 })
    near(moved.k, 1); near(moved.x, v0.x + 30); near(moved.y, v0.y + 40)
    // clamped, and a zero starting distance is the starting view
    assert.strictEqual(M.pinchView(start, { x: 0, y: 0 }, { x: 5000, y: 0 }).k, 3)
    const degenerate = M.pinchStart(v0, a0, a0)
    assert.strictEqual(M.pinchView(degenerate, a0, b0), v0)
  })

  await test('drag threshold: a pointer within a few pixels is a click, beyond it a drag', () => {
    assert.ok(M.DRAG_THRESHOLD >= 3 && M.DRAG_THRESHOLD <= 6)
    assert.strictEqual(M.isDrag(100, 100, 100, 100), false)
    assert.strictEqual(M.isDrag(100, 100, 102, 102), false)
    assert.strictEqual(M.isDrag(100, 100, 104, 100), false) // exactly the threshold is still a click
    assert.strictEqual(M.isDrag(100, 100, 105, 100), true)
    assert.strictEqual(M.isDrag(100, 100, 100, 94), true)
    assert.deepStrictEqual(M.panBy({ k: 2, x: 10, y: 10 }, -4, 6), { k: 2, x: 6, y: 16 })
  })

  await test('Fit: the drawing inside the viewport and centred, never past the limits, top-left when it cannot fit', () => {
    const box = { x: -10, y: -10, w: 1000, h: 400 }
    const v = M.fitView(box, { w: 520, h: 360 }, 10)
    near(v.k, 0.5)
    const left = box.x * v.k + v.x, right = (box.x + box.w) * v.k + v.x
    near(left, 10, 'left air'); near(right, 510, 'right air')
    const top = box.y * v.k + v.y, bottom = (box.y + box.h) * v.k + v.y
    near(top + (360 - bottom), 360 - 400 * v.k, 'centred vertically')
    // a small drawing is not blown up past the maximum
    assert.strictEqual(M.fitView({ x: 0, y: 0, w: 10, h: 10 }, { w: 800, h: 600 }).k, 3)
    // a huge one stops at the minimum and starts at the top-left corner instead of being cut off on both sides
    const big = M.fitView({ x: 0, y: 0, w: 5000, h: 3000 }, { w: 500, h: 300 }, 16)
    assert.strictEqual(big.k, 0.25)
    near(big.x, 16); near(big.y, 16)
  })

  await test('fitPlan: first render and a changed epic fit, a refresh of the same epic does not, a resize fits only an untouched view', () => {
    assert.strictEqual(M.fitPlan(null, 'E01', false), true, 'first render')
    assert.strictEqual(M.fitPlan('E01', 'E02', true), true, 'epic changed, even after the user zoomed')
    assert.strictEqual(M.fitPlan('E01', 'E01', true), false, 'same epic, user zoomed: leave it')
    assert.strictEqual(M.fitPlan('E01', 'E01', false), true, 'same epic, never touched (a resize): fit again')
    assert.strictEqual(M.fitPlan(null, null, false), false, 'nothing drawn')
  })

  await test('transformOf is a rounded translate-scale', () => {
    assert.strictEqual(M.transformOf({ k: 0.5, x: 10.12345, y: -3 }), 'translate(10.123 -3) scale(0.5)')
  })

  // ---------- 2. the hook, driven through fake events ----------
  /**
   * Hook runtime: state and ref slots, effects run after each render when their deps changed, in order. A state setter
   * queues one more pass that runs after the current effects (as React batches), so an effect's closure is the one of the
   * render it was created in. `el`, when given, is what the hook's ref points at before the first effects run (the way a
   * committed DOM node is), `null` leaves the viewport unmounted.
   */
  function mount(hook, initialProps, el = null) {
    let props = initialProps, slots = [], deps = [], cleanups = [], i, effects, result, rendering = false, dirty = false
    globalThis.__h = {
      useState(init) {
        const k = i++
        if (!(k in slots)) slots[k] = typeof init === 'function' ? init() : init
        return [slots[k], v => { slots[k] = v; flush() }]
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
        if (el) result.stageRef.current = el
        const run = effects; effects = []
        run.forEach(f => f())
      } while (dirty)
      rendering = false
    }
    flush()
    return {
      get z() { return result },
      setProps(p) { props = { ...props, ...p }; flush() },
    }
  }

  function fakeStage(w = 800, h = 500, left = 100, top = 50) {
    const el = {
      listeners: {}, captured: [], released: [], size: { w, h },
      getBoundingClientRect() { return { left, top, width: this.size.w, height: this.size.h } },
      addEventListener(t, f) { this.listeners[t] = f },
      removeEventListener(t) { delete this.listeners[t] },
      setPointerCapture(id) { this.captured.push(id) },
      releasePointerCapture(id) { this.released.push(id) },
    }
    return el
  }
  let observers = []
  globalThis.ResizeObserver = class { constructor(cb) { this.cb = cb; this.live = true; observers.push(this) } observe() {} disconnect() { this.live = false } }

  const BOX = { x: -10, y: -10, w: 2000, h: 900 }
  function ready(props = { box: BOX, fitKey: 'E01' }) {
    observers = []
    const el = fakeStage()
    return { m: mount(useZoomPan, props, el), el }
  }
  const ptr = (el, id, x, y, extra) => ({ pointerId: id, pointerType: 'mouse', button: 0, clientX: x, clientY: y, currentTarget: el, ...extra })

  await test('hook: nothing is fitted before the viewport is measured (the SVG fits itself), then Fit runs once', () => {
    const before = mount(useZoomPan, { box: BOX, fitKey: 'E01' })
    assert.strictEqual(before.z.view, null)
    assert.strictEqual(before.z.percent, null)
    const { m } = ready()
    assert.deepStrictEqual(m.z.size, { w: 800, h: 500 })
    assert.deepStrictEqual(m.z.view, M.fitView(BOX, { w: 800, h: 500 }))
    assert.strictEqual(m.z.percent, M.percentOf(m.z.view))
    assert.strictEqual(typeof m.z.handlers.onPointerDown, 'function')
  })

  await test('hook: no box (nothing drawn) attaches nothing and never fits', () => {
    const el = fakeStage()
    const m = mount(useZoomPan, { box: null, fitKey: null }, el)
    assert.strictEqual(m.z.view, null)
    assert.deepStrictEqual(el.listeners, {})
  })

  await test('hook: a data refresh of the same epic does not fit again, a different epic does', () => {
    const { m } = ready()
    m.z.zoomIn()
    const zoomed = m.z.view
    assert.ok(zoomed.k > M.fitView(BOX, { w: 800, h: 500 }).k)
    m.setProps({ box: { ...BOX, w: 2600, h: 1200 }, fitKey: 'E01' }) // new data, same epic, new layout size
    assert.strictEqual(m.z.view, zoomed, 'the zoomed view is untouched by a refresh')
    m.setProps({ box: BOX, fitKey: 'E01' })
    assert.strictEqual(m.z.view, zoomed)
    m.setProps({ box: { ...BOX, w: 800 }, fitKey: 'E02' })
    assert.deepStrictEqual(m.z.view, M.fitView({ ...BOX, w: 800 }, { w: 800, h: 500 }), 'a new epic is fitted to its own box')
  })

  await test('hook: a resize refits a view nobody touched and leaves a view the user changed', () => {
    const { m, el } = ready()
    el.size = { w: 1000, h: 600 }
    observers[0].cb()
    assert.deepStrictEqual(m.z.view, M.fitView(BOX, { w: 1000, h: 600 }))
    m.z.zoomIn()
    const kept = m.z.view
    el.size = { w: 500, h: 500 }
    observers[0].cb()
    assert.strictEqual(m.z.view, kept)
    assert.deepStrictEqual(m.z.size, { w: 500, h: 500 })
    m.z.fit() // Fit hands control back to the layout
    assert.deepStrictEqual(m.z.view, M.fitView(BOX, { w: 500, h: 500 }))
    el.size = { w: 640, h: 500 }
    observers[0].cb()
    assert.deepStrictEqual(m.z.view, M.fitView(BOX, { w: 640, h: 500 }))
  })

  await test('hook: a native non-passive wheel listener zooms about the cursor and stops the page scroll', () => {
    const { m, el } = ready()
    assert.ok(el.listeners.wheel, 'wheel listener attached')
    const v0 = m.z.view
    let prevented = 0
    el.listeners.wheel({ deltaY: -150, ctrlKey: false, clientX: 100 + 300, clientY: 50 + 200, preventDefault() { prevented++ } })
    assert.strictEqual(prevented, 1)
    const v1 = m.z.view
    assert.ok(v1.k > v0.k)
    near(world(v0, 300, 200).x, world(v1, 300, 200).x); near(world(v0, 300, 200).y, world(v1, 300, 200).y)
    el.listeners.wheel({ deltaY: -150, ctrlKey: true, clientX: 400, clientY: 250, preventDefault() {} })
    assert.ok(Math.log(m.z.view.k / v1.k) > Math.log(v1.k / v0.k), 'the ctrl step is bigger')
  })

  await test('hook: the listener and the observer are removed on unmount-style cleanup (effect cleanup runs)', () => {
    const { m, el } = ready()
    assert.ok(observers[0].live)
    // changing hasStage reruns the effect, which cleans the previous one up
    m.setProps({ box: null, fitKey: null })
    assert.strictEqual(el.listeners.wheel, undefined)
    assert.strictEqual(observers[0].live, false)
  })

  await test('hook: drag pans by exactly the pointer movement, takes the pointer capture only once the drag begins', () => {
    const { m, el } = ready()
    const v0 = m.z.view
    const h = m.z.handlers
    h.onPointerDown(ptr(el, 1, 400, 300))
    assert.deepStrictEqual(el.captured, [], 'no capture on pointer down, so a plain click still reaches the card')
    h.onPointerMove(ptr(el, 1, 402, 301)) // inside the threshold
    assert.strictEqual(m.z.view, v0)
    assert.strictEqual(m.z.dragging, false)
    h.onPointerMove(ptr(el, 1, 430, 340))
    assert.deepStrictEqual(el.captured, [1])
    assert.strictEqual(m.z.dragging, true)
    near(m.z.view.x, v0.x + 30); near(m.z.view.y, v0.y + 40); assert.strictEqual(m.z.view.k, v0.k)
    h.onPointerMove(ptr(el, 1, 420, 340))
    near(m.z.view.x, v0.x + 20); near(m.z.view.y, v0.y + 40)
    h.onPointerUp(ptr(el, 1, 420, 340))
    assert.strictEqual(m.z.dragging, false)
    assert.deepStrictEqual(el.released, [1])
  })

  await test('hook: the click that ends a drag is swallowed, a plain click is not, and a drag does not poison the next click', () => {
    const { m, el } = ready()
    const h = m.z.handlers
    const click = () => { const e = { stopped: 0, prevented: 0, stopPropagation() { this.stopped++ }, preventDefault() { this.prevented++ } }; h.onClickCapture(e); return e }
    // plain click: down, up, click
    h.onPointerDown(ptr(el, 1, 400, 300)); h.onPointerMove(ptr(el, 1, 401, 301)); h.onPointerUp(ptr(el, 1, 401, 301))
    assert.strictEqual(click().stopped, 0, 'a plain click reaches the group card and expands it')
    // drag then click
    h.onPointerDown(ptr(el, 1, 400, 300)); h.onPointerMove(ptr(el, 1, 460, 300)); h.onPointerUp(ptr(el, 1, 460, 300))
    const swallowed = click()
    assert.strictEqual(swallowed.stopped, 1); assert.strictEqual(swallowed.prevented, 1)
    assert.strictEqual(click().stopped, 0, 'the swallow is for one click only')
    // drag, no click arrives (released elsewhere), then a plain click: the new pointer down resets it
    h.onPointerDown(ptr(el, 1, 400, 300)); h.onPointerMove(ptr(el, 1, 460, 300)); h.onPointerUp(ptr(el, 1, 460, 300))
    h.onPointerDown(ptr(el, 1, 200, 200)); h.onPointerUp(ptr(el, 1, 200, 200))
    assert.strictEqual(click().stopped, 0)
  })

  await test('hook: only the primary mouse button pans; a move with no button pressed does nothing', () => {
    const { m, el } = ready()
    const v0 = m.z.view, h = m.z.handlers
    h.onPointerDown(ptr(el, 1, 400, 300, { button: 2 }))
    h.onPointerMove(ptr(el, 1, 500, 300))
    assert.strictEqual(m.z.view, v0)
    h.onPointerMove(ptr(el, 7, 500, 300))
    assert.strictEqual(m.z.view, v0)
  })

  await test('hook: two pointers pinch (scale from the distance), and one finger left afterwards pans', () => {
    const { m, el } = ready()
    const h = m.z.handlers
    const v0 = m.z.view
    h.onPointerDown(ptr(el, 1, 300, 250, { pointerType: 'touch' }))
    h.onPointerDown(ptr(el, 2, 400, 250, { pointerType: 'touch' }))
    h.onPointerMove(ptr(el, 2, 500, 250, { pointerType: 'touch' })) // distance 100 -> 200
    near(m.z.view.k, v0.k * 2)
    // the starting midpoint was at viewport x 250, the pointers' midpoint is now at viewport x 300
    near(world(v0, 250, 200).x, world(m.z.view, 300, 200).x, 'the point under the starting midpoint follows the midpoint', 1e-6)
    h.onPointerUp(ptr(el, 2, 500, 250, { pointerType: 'touch' }))
    const afterPinch = m.z.view
    h.onPointerMove(ptr(el, 1, 320, 250, { pointerType: 'touch' }))
    near(m.z.view.x, afterPinch.x + 20)
    assert.strictEqual(m.z.view.k, afterPinch.k)
    h.onPointerUp(ptr(el, 1, 320, 250, { pointerType: 'touch' }))
    assert.strictEqual(m.z.dragging, false)
  })

  await test('hook: plus, minus, 100 % and Fit change the view and the percent readout; both ends stay inside 25-300 %', () => {
    const { m } = ready()
    const fit = m.z.view
    m.z.zoomIn()
    assert.ok(m.z.percent > M.percentOf(fit) || M.percentOf(fit) === 25)
    m.z.actual()
    assert.strictEqual(m.z.percent, 100)
    m.z.zoomOut()
    assert.strictEqual(m.z.percent, 80)
    for (let i = 0; i < 30; i++) m.z.zoomIn()
    assert.strictEqual(m.z.percent, 300)
    for (let i = 0; i < 60; i++) m.z.zoomOut()
    assert.strictEqual(m.z.percent, 25)
    m.z.fit()
    assert.deepStrictEqual(m.z.view, fit)
  })

  await test('hook: a browser scroll of the clipping viewport (a focused card out of view) is undone', () => {
    const { m } = ready()
    const target = { scrollLeft: 120, scrollTop: 30 }
    m.z.handlers.onScroll({ currentTarget: target })
    assert.deepStrictEqual(target, { scrollLeft: 0, scrollTop: 0 })
  })

  await test('hook: buttons and events before the first fit are harmless no-ops', () => {
    const m = mount(useZoomPan, { box: BOX, fitKey: 'E01' })
    m.z.zoomIn(); m.z.zoomOut(); m.z.fit(); m.z.actual()
    m.z.handlers.onPointerDown(ptr(fakeStage(), 1, 1, 1)); m.z.handlers.onPointerMove(ptr(fakeStage(), 1, 50, 50))
    assert.strictEqual(m.z.view, null)
  })

  // ---------- 3. DependencyTree with the controls ----------
  const T = (id, story, state, deps) => ({
    id, story_id: story, epic_id: 'E01', title: 'Title ' + id, status: 'x', bucket: state === 'ready' || state === 'locked' ? 'pending' : state, state,
    depends_on: deps || [], blocked_by: [], unlocked_by: null,
  })
  const graph = labels => ({
    schema_version: 1, labels, epics: [{ id: 'E01', title: 'Goal epic' }], stories: [{ id: 'E01_S01', epic_id: 'E01', title: 'First' }],
    tasks: [T('E01_S01_T01', 'E01_S01', 'done'), T('E01_S01_T02', 'E01_S01', 'ready', ['E01_S01_T01'])], external: null,
  })
  const EN = { zoom_group: 'Zoom', zoom_out: 'Zoom out', zoom_in: 'Zoom in', zoom_fit: 'Fit', zoom_actual: 'Actual size', zoom_percent: '%d %%', zoom_hint: 'Scroll or pinch to zoom · drag to pan' }
  const SV = { zoom_group: 'Zoom', zoom_out: 'Zooma ut', zoom_in: 'Zooma in', zoom_fit: 'Anpassa', zoom_actual: 'Verklig storlek', zoom_percent: '%d %%', zoom_hint: 'Scrolla eller nyp för att zooma · dra för att panorera' }
  const render = labels => { const g = graph(labels); return renderToStaticMarkup(ce(DependencyTree, { model: buildDependencyTreeModel(g, 'E01'), labels })) }

  await test('DependencyTree: the four buttons, the readout and the hint carry their words from the labels (English and Swedish)', () => {
    const en = render(EN)
    for (const w of ['aria-label="Zoom out"', 'aria-label="Zoom in"', 'aria-label="Fit"', 'aria-label="Actual size"', 'aria-label="Zoom"', 'Scroll or pinch to zoom']) assert.ok(en.includes(w), w)
    for (const z of ['out', 'in', 'fit', 'actual', 'percent']) assert.ok(en.includes(`data-zoom="${z}"`), z)
    assert.ok(en.includes('>100 %</button>'), 'the 100 % button caption is the formatted number')
    const sv = render(SV)
    for (const w of ['aria-label="Zooma ut"', 'aria-label="Zooma in"', 'aria-label="Anpassa"', 'aria-label="Verklig storlek"', 'Scrolla eller nyp']) assert.ok(sv.includes(w), w)
    assert.ok(!sv.includes('Zoom out') && !sv.includes('Scroll or pinch'))
  })

  await test('DependencyTree: without labels the controls show symbols only, carry no word and no key name, and the 100 % caption is still a number', () => {
    const html = render({})
    assert.ok(html.includes('data-zoom="actual"') && html.includes('100 %'))
    const controls = html.slice(html.indexOf('dt-zoom-controls'), html.indexOf('</div>', html.indexOf('dt-zoom-controls')))
    assert.ok(!/aria-label=|title=/.test(controls), 'no accessible name without labels: ' + controls)
    assert.ok(!/zoom_(out|in|fit|actual|group|hint)/.test(html), 'a label key is never shown as text')
    assert.ok(!html.includes('dt-zoom-hint'))
    assert.ok(controls.includes('⤢') && controls.includes('−') && controls.includes('+'))
  })

  await test('DependencyTree: until the first fit the SVG fits the drawing itself (viewBox, no transform), so nothing is blank', () => {
    const html = render(EN)
    assert.ok(/<svg[^>]*viewBox="/.test(html))
    assert.ok(!/class="dt-root"[^>]*transform=/.test(html))
    assert.ok(html.includes('class="dt-stage dt-viewport"'))
    assert.ok(!html.includes('data-fitted'))
  })

  // ---------- 4. source rules ----------
  await test('source: no colour literal in the new or changed UI files, and no leftover minimum width on the drawing', () => {
    const strip = t => t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
    const files = [
      path.join(compDir, 'zoomPanModel.js'), path.join(compDir, 'useZoomPan.js'), path.join(compDir, 'ZoomControls.jsx'),
      path.join(compDir, 'DependencyTree.jsx'), path.join(compDir, 'dependency-tree.css'),
      path.join(uiDir, 'src', 'App.css'), path.join(uiDir, 'src', 'App.jsx'),
    ]
    for (const f of files) {
      const t = strip(fs.readFileSync(f, 'utf8'))
      assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(t), 'hex literal in ' + path.basename(f))
      assert.ok(!/\b(rgb|rgba|hsl|hsla|oklch|color-mix)\(/.test(t), 'functional colour in ' + path.basename(f))
    }
    const history = fs.readFileSync(path.join(uiDir, 'src', 'components', 'history', 'history.css'), 'utf8')
    assert.ok(!/\.dt-svg\s*\{[^}]*min-width/.test(strip(history)), 'the overlay no longer forces a minimum width on the drawing')
    const css = fs.readFileSync(path.join(compDir, 'dependency-tree.css'), 'utf8')
    assert.ok(/\.dt-viewport\s*\{[^}]*touch-action:\s*none/.test(css) && /overflow:\s*hidden/.test(css))
  })

  await test('source: the hook takes a pointer capture lazily and the wheel listener is non-passive', () => {
    const src = fs.readFileSync(path.join(compDir, 'useZoomPan.js'), 'utf8')
    assert.ok(/addEventListener\('wheel', onWheel, \{ passive: false \}\)/.test(src))
    const down = src.slice(src.indexOf('onPointerDown(e)'), src.indexOf('onPointerMove(e)'))
    assert.ok(!/setPointerCapture|capture\(/.test(down), 'no capture on pointer down')
  })

  // ---------- 5. keepCentreOnResize (E92_S07_T05): opt-in, a touched view keeps its centre when the container changes size ----------
  const FM = await import(pathToFileURL(path.join(compDir, 'fullscreenModel.js')).href)
  const centreOf = (v, size) => world(v, size.w / 2, size.h / 2)
  const resizeTo = (el, w, h) => { el.size = { w, h }; observers[0].cb() }
  const KEEP = { box: BOX, fitKey: 'E01', keepCentreOnResize: true }

  await test('keepCentreOnResize: the first measurement only fits, it is not an adjustment', () => {
    const { m } = ready(KEEP)
    assert.deepStrictEqual(m.z.view, M.fitView(BOX, { w: 800, h: 500 }))
  })

  for (const [name, w, h] of [['bigger', 1400, 900], ['smaller', 500, 320]]) {
    await test(`keepCentreOnResize: a touched view in a ${name} container keeps its scale and its centre point, and stays touched`, () => {
      const { m, el } = ready(KEEP)
      m.z.zoomIn()
      m.z.zoomIn()
      const before = m.z.view
      const was = centreOf(before, { w: 800, h: 500 })
      resizeTo(el, w, h)
      const after = m.z.view
      assert.notStrictEqual(after, before, 'the view was replaced')
      assert.strictEqual(after.k, before.k, 'the scale is kept')
      const now = centreOf(after, { w, h })
      near(now.x, was.x, 'the point that was at the centre is at the new centre (x)')
      near(now.y, was.y, 'the point that was at the centre is at the new centre (y)')
      assert.deepStrictEqual(after, FM.keepCentre(before, { w: 800, h: 500 }, { w, h }), 'the view is keepCentre of the old view')
      assert.deepStrictEqual(m.z.size, { w, h })
      // still touched: the adjustment is no user touch, so a further resize adjusts again and does not refit
      resizeTo(el, 900, 700)
      assert.strictEqual(m.z.view.k, before.k, 'still not refitted after a second resize')
      const again = centreOf(m.z.view, { w: 900, h: 700 })
      near(again.x, was.x, 'centre point kept again (x)')
      near(again.y, was.y, 'centre point kept again (y)')
    })
  }

  await test('keepCentreOnResize: a panned view keeps its centre point, and going bigger and back gives the view back', () => {
    const { m, el } = ready(KEEP)
    const sx = 400, sy = 250
    m.z.handlers.onPointerDown(ptr(el, 1, sx, sy))
    m.z.handlers.onPointerMove(ptr(el, 1, sx + 90, sy - 40))
    m.z.handlers.onPointerUp(ptr(el, 1, sx + 90, sy - 40))
    const panned = m.z.view
    assert.notDeepStrictEqual(panned, M.fitView(BOX, { w: 800, h: 500 }), 'the pan moved the view')
    const was = centreOf(panned, { w: 800, h: 500 })
    resizeTo(el, 1600, 1000)
    const big = centreOf(m.z.view, { w: 1600, h: 1000 })
    near(big.x, was.x); near(big.y, was.y)
    resizeTo(el, 800, 500)
    near(m.z.view.k, panned.k); near(m.z.view.x, panned.x); near(m.z.view.y, panned.y)
  })

  await test('keepCentreOnResize: a data refresh of the same epic never refits and never recentres', () => {
    const { m } = ready(KEEP)
    m.z.zoomIn()
    const zoomed = m.z.view
    m.setProps({ box: { ...BOX, w: 2600, h: 1200 }, fitKey: 'E01' })
    assert.strictEqual(m.z.view, zoomed, 'the zoomed view is the same object after a refresh')
    m.setProps({ box: BOX, fitKey: 'E01' })
    assert.strictEqual(m.z.view, zoomed)
  })

  await test('keepCentreOnResize: an untouched view is refitted on a resize exactly as before', () => {
    const { m, el } = ready(KEEP)
    resizeTo(el, 1400, 900)
    assert.deepStrictEqual(m.z.view, M.fitView(BOX, { w: 1400, h: 900 }))
    resizeTo(el, 500, 320)
    assert.deepStrictEqual(m.z.view, M.fitView(BOX, { w: 500, h: 320 }))
  })

  await test('keepCentreOnResize: Fit still measures the current container and hands control back to the layout; a different epic still refits', () => {
    const { m, el } = ready(KEEP)
    m.z.zoomIn()
    resizeTo(el, 1400, 900)
    m.z.fit()
    assert.deepStrictEqual(m.z.view, M.fitView(BOX, { w: 1400, h: 900 }))
    resizeTo(el, 700, 450)
    assert.deepStrictEqual(m.z.view, M.fitView(BOX, { w: 700, h: 450 }), 'after Fit the view is untouched again, so a resize refits')
    m.z.zoomIn()
    resizeTo(el, 900, 600)
    m.setProps({ box: { ...BOX, w: 800 }, fitKey: 'E02' })
    assert.deepStrictEqual(m.z.view, M.fitView({ ...BOX, w: 800 }, { w: 900, h: 600 }), 'a new epic is fitted to its own box')
  })

  for (const [label, props] of [['false', { box: BOX, fitKey: 'E01', keepCentreOnResize: false }], ['absent', { box: BOX, fitKey: 'E01' }]]) {
    await test(`keepCentreOnResize ${label}: a resize of a touched view leaves the view alone, as before`, () => {
      const { m, el } = ready(props)
      m.z.zoomIn()
      const kept = m.z.view
      resizeTo(el, 1400, 900)
      assert.strictEqual(m.z.view, kept, 'bigger container: same view object')
      resizeTo(el, 500, 320)
      assert.strictEqual(m.z.view, kept, 'smaller container: same view object')
      assert.deepStrictEqual(m.z.size, { w: 500, h: 320 })
    })
  }

  await test('source: useZoomPan keepCentreOnResize defaults to false, uses keepCentre, and commits it without a touch; the Fit rule lines are unchanged', () => {
    const src = fs.readFileSync(path.join(compDir, 'useZoomPan.js'), 'utf8')
    assert.ok(/keepCentreOnResize = false/.test(src), 'default false')
    assert.ok(/import \{ keepCentre \} from '\.\/fullscreenModel/.test(src))
    assert.ok(/commit\(keepCentre\(L\.view, previous, L\.size\), false\)/.test(src), 'no user touch')
    assert.ok(src.includes('if (!fitPlan(L.lastFitKey, L.fitKey, L.touched)) return'), 'the Fit effect condition')
    assert.ok(src.includes('commit(fitView(L.box, size), false)') && src.includes('}, [size, fitKey])'))
  })

  console.log(`\n${n} passed`)
})().catch(e => { console.error(e); process.exit(1) })
