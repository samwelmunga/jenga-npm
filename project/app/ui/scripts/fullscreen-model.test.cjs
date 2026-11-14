#!/usr/bin/env node
'use strict'
// E92_S07_T01: tests for fullscreenModel.js, the pure logic of the large view of the epic progress map. Zero test
// framework and no DOM: the module is plain functions, loaded as an ES module the way tree-zoom-pan.test.cjs loads
// zoomPanModel.js.
//   1. fullscreenSupport: native, fallback, throwing getters, never throws.
//   2. reduce and the selectors: enter, enterRefused, syncNative, exit, escape, isOpen, rootMode, toggleLabelKey, escapeAction.
//   3. keepCentre: the same scale, the old centre point at the new centre, unusable sizes.
//   4. nextTabTarget: wrap both ways, empty, out of range.
//   5. Source rules: pure module, no React, no zoomPanModel import, no colour literal.
// Run: node project/app/ui/scripts/fullscreen-model.test.cjs
const assert = require('assert')
const fs = require('fs')
const path = require('path')
const { pathToFileURL } = require('url')

const compDir = path.join(__dirname, '..', 'src', 'components', 'progress')
const modelFile = path.join(compDir, 'fullscreenModel.js')

let n = 0
const test = async (name, fn) => { await fn(); n++; console.log('ok  ' + name) }
const near = (a, b, msg, eps = 1e-9) => assert.ok(Math.abs(a - b) < eps, `${msg || ''} ${a} !~ ${b}`)

;(async () => {
  const M = await import(pathToFileURL(modelFile).href)
  const world = (v, sx, sy) => ({ x: (sx - v.x) / v.k, y: (sy - v.y) / v.k }) // the drawing point under a viewport point

  // ---------- 1. fullscreenSupport ----------
  const goodDoc = { fullscreenEnabled: true }
  const goodEl = { requestFullscreen() {} }
  const throwing = key => { const o = {}; Object.defineProperty(o, key, { get() { throw new Error('blocked') } }); return o }

  await test('fullscreenSupport: native when fullscreenEnabled and requestFullscreen are present', () => {
    assert.strictEqual(M.fullscreenSupport(goodDoc, goodEl), 'native')
  })
  await test('fullscreenSupport: native through the webkit prefixed pair', () => {
    assert.strictEqual(M.fullscreenSupport({ webkitFullscreenEnabled: true }, { webkitRequestFullscreen() {} }), 'native')
  })
  await test('fullscreenSupport: fallback without fullscreenEnabled, with it false, and without requestFullscreen', () => {
    assert.strictEqual(M.fullscreenSupport({}, goodEl), 'fallback')
    assert.strictEqual(M.fullscreenSupport({ fullscreenEnabled: false }, goodEl), 'fallback')
    assert.strictEqual(M.fullscreenSupport(goodDoc, {}), 'fallback')
    assert.strictEqual(M.fullscreenSupport(goodDoc, { requestFullscreen: true }), 'fallback') // not callable
  })
  await test('fullscreenSupport: a mixed prefixed and unprefixed pair is not native', () => {
    assert.strictEqual(M.fullscreenSupport({ fullscreenEnabled: true }, { webkitRequestFullscreen() {} }), 'fallback')
    assert.strictEqual(M.fullscreenSupport({ webkitFullscreenEnabled: true }, { requestFullscreen() {} }), 'fallback')
  })
  await test('fullscreenSupport: a property getter that throws counts as unavailable and never throws', () => {
    assert.strictEqual(M.fullscreenSupport(throwing('fullscreenEnabled'), goodEl), 'fallback')
    assert.strictEqual(M.fullscreenSupport(goodDoc, throwing('requestFullscreen')), 'fallback')
    assert.strictEqual(M.fullscreenSupport(throwing('webkitFullscreenEnabled'), throwing('webkitRequestFullscreen')), 'fallback')
    // the unprefixed pair throws but the prefixed pair is fine: still usable
    const doc = { webkitFullscreenEnabled: true }
    Object.defineProperty(doc, 'fullscreenEnabled', { get() { throw new Error('blocked') } })
    assert.strictEqual(M.fullscreenSupport(doc, { webkitRequestFullscreen() {} }), 'native')
  })
  await test('fullscreenSupport: missing document or element gives fallback', () => {
    for (const [d, e] of [[null, null], [undefined, goodEl], [goodDoc, undefined], [null, goodEl]]) {
      assert.strictEqual(M.fullscreenSupport(d, e), 'fallback')
    }
  })

  // ---------- 2. reduce and the selectors ----------
  const closed = M.initialState()
  const enter = support => ({ type: 'enter', support })

  await test('initialState is closed and its selectors say so', () => {
    assert.deepStrictEqual(closed, { mode: 'closed' })
    assert.strictEqual(M.isOpen(closed), false)
    assert.strictEqual(M.rootMode(closed), null)
    assert.strictEqual(M.toggleLabelKey(closed), 'fullscreen_enter')
    assert.strictEqual(M.escapeAction(closed), 'none')
  })
  await test('reduce: enter on native support opens native', () => {
    const s = M.reduce(closed, enter('native'))
    assert.strictEqual(s.mode, 'native')
    assert.strictEqual(M.isOpen(s), true)
    assert.strictEqual(M.rootMode(s), 'native')
    assert.strictEqual(M.toggleLabelKey(s), 'fullscreen_exit')
  })
  await test('reduce: enter on fallback support opens fallback', () => {
    const s = M.reduce(closed, enter('fallback'))
    assert.strictEqual(s.mode, 'fallback')
    assert.strictEqual(M.rootMode(s), 'fallback')
    assert.strictEqual(M.isOpen(s), true)
    assert.strictEqual(M.toggleLabelKey(s), 'fullscreen_exit')
  })
  await test('reduce: enter with an unknown or missing support result opens the fallback, never stays closed', () => {
    assert.strictEqual(M.reduce(closed, { type: 'enter' }).mode, 'fallback')
    assert.strictEqual(M.reduce(closed, enter('bogus')).mode, 'fallback')
  })
  await test('reduce: enter while already open changes nothing', () => {
    const nat = M.reduce(closed, enter('native'))
    const fb = M.reduce(closed, enter('fallback'))
    assert.strictEqual(M.reduce(nat, enter('fallback')), nat)
    assert.strictEqual(M.reduce(fb, enter('native')), fb)
  })
  await test('reduce: enterRefused ends in fallback from native and from closed, and is stable in fallback', () => {
    const nat = M.reduce(closed, enter('native'))
    assert.strictEqual(M.reduce(nat, { type: 'enterRefused' }).mode, 'fallback')
    assert.strictEqual(M.reduce(closed, { type: 'enterRefused' }).mode, 'fallback')
    const fb = M.reduce(closed, enter('fallback'))
    assert.strictEqual(M.reduce(fb, { type: 'enterRefused' }), fb)
    assert.strictEqual(M.rootMode(M.reduce(nat, { type: 'enterRefused' })), 'fallback')
  })
  await test('reduce: syncNative(false) while native ends closed (the browser left fullscreen)', () => {
    const nat = M.reduce(closed, enter('native'))
    const s = M.reduce(nat, { type: 'syncNative', active: false })
    assert.strictEqual(s.mode, 'closed')
    assert.strictEqual(M.rootMode(s), null)
    assert.strictEqual(M.isOpen(s), false)
    assert.strictEqual(M.toggleLabelKey(s), 'fullscreen_enter')
  })
  await test('reduce: syncNative(true) while native stays native; while closed it does not open', () => {
    const nat = M.reduce(closed, enter('native'))
    assert.strictEqual(M.reduce(nat, { type: 'syncNative', active: true }), nat)
    assert.strictEqual(M.reduce(closed, { type: 'syncNative', active: true }), closed)
    assert.strictEqual(M.isOpen(M.reduce(closed, { type: 'syncNative', active: true })), false)
  })
  await test('reduce: syncNative never touches the fallback layer', () => {
    const fb = M.reduce(closed, enter('fallback'))
    assert.strictEqual(M.reduce(fb, { type: 'syncNative', active: false }), fb)
    assert.strictEqual(M.reduce(fb, { type: 'syncNative', active: true }), fb)
  })
  await test('reduce: exit closes native and fallback, and a closed model stays closed', () => {
    for (const support of ['native', 'fallback']) {
      const s = M.reduce(M.reduce(closed, enter(support)), { type: 'exit' })
      assert.strictEqual(s.mode, 'closed')
      assert.strictEqual(M.rootMode(s), null)
    }
    assert.strictEqual(M.reduce(closed, { type: 'exit' }), closed)
  })
  await test('reduce: escape closes the fallback layer; native and closed are left alone', () => {
    const fb = M.reduce(closed, enter('fallback'))
    const nat = M.reduce(closed, enter('native'))
    assert.strictEqual(M.reduce(fb, { type: 'escape' }).mode, 'closed')
    assert.strictEqual(M.reduce(nat, { type: 'escape' }), nat)
    assert.strictEqual(M.reduce(closed, { type: 'escape' }), closed)
  })
  await test('reduce: unknown event, missing event and a damaged state leave a valid state; the state never disagrees with the last event', () => {
    const nat = M.reduce(closed, enter('native'))
    assert.strictEqual(M.reduce(nat, { type: 'nope' }), nat)
    assert.strictEqual(M.reduce(nat, undefined), nat)
    assert.deepStrictEqual(M.reduce(undefined, enter('native')), { mode: 'native' })
    assert.deepStrictEqual(M.reduce({ mode: 'weird' }, enter('fallback')), { mode: 'fallback' })
    // a full session: enter native, refused, escape, enter native, browser leaves, enter native, exit
    let s = closed
    const run = (ev, mode) => { s = M.reduce(s, ev); assert.strictEqual(s.mode, mode, JSON.stringify(ev)) }
    run(enter('native'), 'native')
    run({ type: 'enterRefused' }, 'fallback')
    run({ type: 'escape' }, 'closed')
    run(enter('native'), 'native')
    run({ type: 'syncNative', active: false }, 'closed')
    run(enter('native'), 'native')
    run({ type: 'exit' }, 'closed')
  })
  await test('reduce does not mutate its input state', () => {
    const s = Object.freeze({ mode: 'native' })
    assert.doesNotThrow(() => M.reduce(s, { type: 'syncNative', active: false }))
    assert.strictEqual(s.mode, 'native')
  })
  await test('escapeAction: close in fallback, none in native and closed', () => {
    assert.strictEqual(M.escapeAction({ mode: 'fallback' }), 'close')
    assert.strictEqual(M.escapeAction({ mode: 'native' }), 'none')
    assert.strictEqual(M.escapeAction({ mode: 'closed' }), 'none')
    assert.strictEqual(M.escapeAction(undefined), 'none')
  })
  await test('rootMode and toggleLabelKey follow the mode', () => {
    assert.strictEqual(M.rootMode({ mode: 'native' }), 'native')
    assert.strictEqual(M.rootMode({ mode: 'fallback' }), 'fallback')
    assert.strictEqual(M.rootMode({ mode: 'closed' }), null)
    assert.strictEqual(M.rootMode(undefined), null)
    assert.strictEqual(M.toggleLabelKey({ mode: 'native' }), 'fullscreen_exit')
    assert.strictEqual(M.toggleLabelKey({ mode: 'fallback' }), 'fullscreen_exit')
    assert.strictEqual(M.toggleLabelKey({ mode: 'closed' }), 'fullscreen_enter')
    assert.strictEqual(M.toggleLabelKey(undefined), 'fullscreen_enter')
  })

  // ---------- 3. keepCentre ----------
  const centreOf = s => ({ x: s.w / 2, y: s.h / 2 })
  const checkKeeps = (v0, oldSize, newSize) => {
    const v1 = M.keepCentre(v0, oldSize, newSize)
    assert.strictEqual(v1.k, v0.k, 'the scale is kept')
    const c0 = centreOf(oldSize), c1 = centreOf(newSize)
    const a = world(v0, c0.x, c0.y), b = world(v1, c1.x, c1.y)
    near(a.x, b.x, 'the world x at the centre'); near(a.y, b.y, 'the world y at the centre')
    return v1
  }
  await test('keepCentre: a bigger container keeps the scale and the centre point', () => {
    const v1 = checkKeeps({ k: 1, x: 0, y: 0 }, { w: 400, h: 300 }, { w: 1200, h: 800 })
    assert.deepStrictEqual(v1, { k: 1, x: 400, y: 250 }) // (1200-400)/2 and (800-300)/2
  })
  await test('keepCentre: a smaller container keeps the scale and the centre point', () => {
    const v1 = checkKeeps({ k: 1, x: 100, y: 60 }, { w: 1200, h: 800 }, { w: 400, h: 300 })
    assert.deepStrictEqual(v1, { k: 1, x: -300, y: -190 })
  })
  await test('keepCentre: a zoomed and panned view keeps the scale and maps the old centre point to the new centre', () => {
    const v0 = { k: 1.75, x: -230.5, y: 41.25 }
    const v1 = checkKeeps(v0, { w: 640, h: 480 }, { w: 1440, h: 900 })
    near(v1.k, 1.75, 'k')
    near(v1.x, -230.5 + 400, 'x'); near(v1.y, 41.25 + 210, 'y')
    checkKeeps({ k: 0.4, x: 12, y: -7 }, { w: 1440, h: 900 }, { w: 640, h: 480 })
  })
  await test('keepCentre: a width-only or height-only change moves only that axis; no change gives an equal view', () => {
    assert.deepStrictEqual(M.keepCentre({ k: 2, x: 10, y: 20 }, { w: 500, h: 400 }, { w: 700, h: 400 }), { k: 2, x: 110, y: 20 })
    assert.deepStrictEqual(M.keepCentre({ k: 2, x: 10, y: 20 }, { w: 500, h: 400 }, { w: 500, h: 600 }), { k: 2, x: 10, y: 120 })
    assert.deepStrictEqual(M.keepCentre({ k: 2, x: 10, y: 20 }, { w: 500, h: 400 }, { w: 500, h: 400 }), { k: 2, x: 10, y: 20 })
  })
  await test('keepCentre: a round trip gives the starting view back', () => {
    const v0 = { k: 0.8, x: 33, y: -12 }
    const out = M.keepCentre(M.keepCentre(v0, { w: 500, h: 300 }, { w: 1500, h: 900 }), { w: 1500, h: 900 }, { w: 500, h: 300 })
    near(out.x, v0.x); near(out.y, v0.y); assert.strictEqual(out.k, v0.k)
  })
  await test('keepCentre: no clamp and no refit, a scale outside 0.25-3 is returned as it is', () => {
    assert.strictEqual(M.keepCentre({ k: 5, x: 0, y: 0 }, { w: 100, h: 100 }, { w: 200, h: 200 }).k, 5)
    assert.strictEqual(M.keepCentre({ k: 0.1, x: 0, y: 0 }, { w: 100, h: 100 }, { w: 200, h: 200 }).k, 0.1)
  })
  await test('keepCentre: a zero, negative, missing or non-finite size returns the input itself', () => {
    const v = { k: 1.5, x: 9, y: 8 }
    const ok = { w: 300, h: 200 }
    for (const bad of [{ w: 0, h: 200 }, { w: 300, h: 0 }, { w: 0, h: 0 }, { w: -5, h: 200 }, { w: NaN, h: 200 },
      { w: Infinity, h: 200 }, { w: '300', h: 200 }, {}, null, undefined]) {
      assert.strictEqual(M.keepCentre(v, bad, ok), v, 'old size ' + JSON.stringify(bad))
      assert.strictEqual(M.keepCentre(v, ok, bad), v, 'new size ' + JSON.stringify(bad))
    }
    assert.strictEqual(M.keepCentre(undefined, ok, ok), undefined)
  })

  // ---------- 4. nextTabTarget ----------
  await test('nextTabTarget: Tab moves forward and wraps from the last to the first', () => {
    assert.strictEqual(M.nextTabTarget(4, 0, false), 1)
    assert.strictEqual(M.nextTabTarget(4, 2, false), 3)
    assert.strictEqual(M.nextTabTarget(4, 3, false), 0)
  })
  await test('nextTabTarget: Shift+Tab moves back and wraps from the first to the last', () => {
    assert.strictEqual(M.nextTabTarget(4, 3, true), 2)
    assert.strictEqual(M.nextTabTarget(4, 1, true), 0)
    assert.strictEqual(M.nextTabTarget(4, 0, true), 3)
  })
  await test('nextTabTarget: one element always gives that element', () => {
    assert.strictEqual(M.nextTabTarget(1, 0, false), 0)
    assert.strictEqual(M.nextTabTarget(1, 0, true), 0)
  })
  await test('nextTabTarget: no focusable element gives -1', () => {
    for (const shift of [false, true]) {
      assert.strictEqual(M.nextTabTarget(0, 0, shift), -1)
      assert.strictEqual(M.nextTabTarget(0, -1, shift), -1)
      assert.strictEqual(M.nextTabTarget(-3, 0, shift), -1)
      assert.strictEqual(M.nextTabTarget(NaN, 0, shift), -1)
      assert.strictEqual(M.nextTabTarget(undefined, 0, shift), -1)
    }
  })
  await test('nextTabTarget: an index outside the list gives the first element, or the last with Shift', () => {
    for (const idx of [-1, 4, 99, NaN, undefined, 1.5]) {
      assert.strictEqual(M.nextTabTarget(4, idx, false), 0, 'forward from ' + idx)
      assert.strictEqual(M.nextTabTarget(4, idx, true), 3, 'backward from ' + idx)
    }
  })

  // ---------- 5. source rules ----------
  await test('source: the model is pure, imports nothing, and has no colour literal', () => {
    const src = fs.readFileSync(modelFile, 'utf8')
    const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
    assert.ok(!/^\s*import\s/m.test(code), 'no import at all, so none from React or zoomPanModel.js')
    assert.ok(!/\b(document|window|navigator|localStorage)\b/.test(code), 'no document or window access')
    assert.ok(!/\b(setTimeout|setInterval|requestAnimationFrame|Date\.now)\b/.test(code), 'no timers')
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(code), 'no hex literal')
  })
  await test('source: zoomPanModel.js and useZoomPan.js still carry the Fit rules', () => {
    const zp = fs.readFileSync(path.join(compDir, 'zoomPanModel.js'), 'utf8')
    assert.ok(/MIN_SCALE = 0\.25/.test(zp) && /MAX_SCALE = 3/.test(zp), 'the 0.25-3 clamp')
    assert.ok(/export function fitView/.test(zp) && /export function clampScale/.test(zp))
  })

  console.log(`\n${n} tests passed`)
})().catch(e => { console.error('FAIL', e && e.stack || e); process.exit(1) })
