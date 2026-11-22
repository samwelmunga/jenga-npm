#!/usr/bin/env node
'use strict'
// E92_S13_T04: model test for the day and night scene geometry (dayNightModel.js). Zero test framework, plain node, like
// goal-design-model.test.cjs: the module is pure ESM with no import, so it is loaded with a dynamic import and no bundler or DOM
// is involved. It checks what the drawings rely on: the sun climbs with the percent and never leaves the box, the box of a scaled
// layout maps back to the natural frame, and every bird and star lies inside the box.
// Run: node project/app/ui/scripts/day-night-model.test.cjs
const assert = require('assert')
const path = require('path')
const { pathToFileURL } = require('url')

const modelPath = path.join(__dirname, '..', 'src', 'components', 'progress', 'dayNightModel.js')

async function main() {
  const M = await import(pathToFileURL(modelPath).href)
  let n = 0
  const test = (name, fn) => { fn(); n++; console.log('ok  ' + name) }
  const inside = (f, p) => p.x >= f.x && p.x <= f.x + f.w && p.y >= f.y && p.y <= f.y + f.h

  test('skyFrame turns the box of a layout (goal frame) back into the natural frame, and carries the size factor', () => {
    const layout = { scale: 0.5, shiftY: -20, box: { left: -100, right: 100, top: -80, bottom: 80, w: 200, h: 160 } }
    const f = M.skyFrame(layout)
    assert.deepStrictEqual([f.x, f.y, f.w, f.h], [-200, -120, 400, 320])
    // a point of the natural frame goes to the goal frame by x * scale, y * scale + shiftY: the corners land on the box
    assert.strictEqual(f.x * 0.5, -100)
    assert.strictEqual((f.y + f.h) * 0.5 - 20, 80)
    assert.strictEqual(f.k, Math.round(M.SCENE_UNIT / 0.5 * 100) / 100, 'a scaled-down castle gets a larger factor, so the sun and birds keep their size on screen')
    assert.strictEqual(M.skyFrame({ scale: 1, shiftY: 0, box: { left: -50, right: 50, top: -40, bottom: 40, w: 100, h: 80 } }).k, M.SCENE_UNIT)
  })

  test('skyFrame never fails: a missing or odd layout gives the plain default box', () => {
    for (const bad of [undefined, null, {}, { box: {} }, { box: { w: 'x', h: 1 } }, 'text', 7]) {
      const f = M.skyFrame(bad)
      assert.deepStrictEqual([f.w, f.h], [440, 420])
      assert.ok(f.k > 0)
    }
    assert.strictEqual(M.skyFrame({ scale: 0, shiftY: 'a', box: { left: -1, right: 1, top: -1, bottom: 1, w: 2, h: 2 } }).w, 2, 'a scale of zero is read as 1')
  })

  test('the sun climbs with the percent: strictly higher at every step, clamped to 0..100, always inside the box', () => {
    const f = { x: -220, y: -210, w: 440, h: 420, k: 1.2 }
    let last = Infinity
    for (const p of [0, 10, 25, 50, 75, 99, 100]) {
      const s = M.sunPosition(f, p)
      assert.ok(s.y < last, `${p} %: higher than the step before`)
      assert.ok(inside(f, s))
      last = s.y
    }
    assert.deepStrictEqual(M.sunPosition(f, -40), M.sunPosition(f, 0))
    assert.deepStrictEqual(M.sunPosition(f, 400), M.sunPosition(f, 100))
    for (const bad of [NaN, undefined, null, '50', Infinity]) assert.deepStrictEqual(M.sunPosition(f, bad), M.sunPosition(f, 0), String(bad) + ' is read as 0 %')
    assert.strictEqual(M.sunPosition(f, 0).x, M.sunPosition(f, 100).x, 'the sun rises straight up')
    assert.strictEqual(M.moonPosition(f).x > f.x + f.w / 2, true)
  })

  test('the sun has twelve rays of two lengths and the moon, star and bird shapes are plain path data', () => {
    const rays = M.sunRays()
    assert.strictEqual(rays.length, 12)
    const len = r => Math.round(Math.hypot(r.x2 - r.x1, r.y2 - r.y1) * 10) / 10
    assert.deepStrictEqual([...new Set(rays.map(len))].sort((a, b) => a - b), [6, 10])
    for (const d of [M.STAR_PATH, M.BIRD_PATH, M.MOON_PATH]) assert.ok(/^M[-\d. MLQAZ,]+$/.test(d), d)
  })

  test('every bird, twinkling star and dim star lies inside the box, at any scale, and the birds are three flocks of seven birds', () => {
    for (const k of [1.2, 2.4, 4]) {
      const f = { x: -300, y: -150, w: 600, h: 300, k }
      const birds = M.birdFlocks(f)
      assert.deepStrictEqual(birds.map(fl => fl.length), [3, 2, 2])
      for (const b of birds.flat()) { assert.ok(inside(f, b)); assert.ok(b.scale > 0) }
      assert.strictEqual(M.twinkleStars(f).length, 6)
      for (const s of M.twinkleStars(f)) assert.ok(inside(f, s))
      assert.strictEqual(M.nightStars(f).length, 12)
      for (const s of M.nightStars(f)) { assert.ok(inside(f, s)); assert.ok(s.r > 0) }
    }
    assert.deepStrictEqual(M.twinkleStars({ x: 0, y: 0, w: 100, h: 100, k: 1 }), M.twinkleStars({ x: 0, y: 0, w: 100, h: 100, k: 1 }), 'pure: the same frame, the same stars')
  })

  test('the sun and the birds keep clear of each other', () => {
    const f = { x: 0, y: 0, w: 680, h: 560, k: 1.2 }
    for (const p of [0, 100]) {
      const s = M.sunPosition(f, p)
      for (const b of M.birdFlocks(f).flat()) assert.ok(Math.hypot(b.x - s.x, b.y - s.y) > 60, `a bird sits on the sun at ${p} %`)
    }
  })

  console.log(`\n${n} tests passed`)
}

main().catch(e => { console.error(e); process.exit(1) })
