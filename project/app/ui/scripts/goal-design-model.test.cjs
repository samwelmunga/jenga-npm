#!/usr/bin/env node
'use strict'
// E92_S13_T05: model test for the goal design list, the default and the stored choice. Zero test framework, plain node,
// like progress-model.test.cjs: goalDesignModel.js is pure ESM with no import, so it is loaded with a dynamic import and
// no bundler or DOM is involved.
// Run: node project/app/ui/scripts/goal-design-model.test.cjs
const assert = require('assert')
const fs = require('fs')
const path = require('path')
const { pathToFileURL } = require('url')

const modelPath = path.join(__dirname, '..', 'src', 'components', 'progress', 'goalDesignModel.js')

/** A Storage stand-in: a Map behind getItem and setItem, with the calls recorded. */
function fakeStore(initial) {
  const m = new Map(Object.entries(initial || {}))
  const calls = []
  return {
    calls,
    map: m,
    getItem(k) { calls.push(['get', k]); return m.has(k) ? m.get(k) : null },
    setItem(k, v) { calls.push(['set', k, v]); m.set(k, String(v)) },
  }
}
const throwingStore = () => ({
  getItem() { throw new Error('SecurityError: storage blocked') },
  setItem() { throw new Error('QuotaExceededError') },
})

async function main() {
  const M = await import(pathToFileURL(modelPath).href)
  const {
    GOAL_DESIGNS, DEFAULT_GOAL_DESIGN, GOAL_DESIGN_STORAGE_KEY, GOAL_DESIGN_GROUP_LABEL_KEY,
    registeredDesigns, selectorVisible, defaultDesignId, resolveGoalDesign, goalDesignStorage, readGoalDesign, writeGoalDesign,
  } = M
  const ids = list => list.map(d => d.id)
  // renderers are opaque to the model: a registry only has to hold something truthy under an id
  const registry = (...rs) => Object.fromEntries(rs.map(r => [r, { Drawing: () => null }]))
  const ALL = registry('star', 'citadel', 'facade', 'tree')
  const ALL_REGISTERED = registeredDesigns(ALL)
  let n = 0
  const test = (name, fn) => { fn(); n++; console.log('ok  ' + name) }

  test('the list order is star, citadel, facade, seasons tree, with a label key each', () => {
    assert.deepStrictEqual(ids(GOAL_DESIGNS), ['star', 'citadel', 'facade', 'tree'])
    assert.deepStrictEqual(GOAL_DESIGNS.map(d => d.labelKey), ['goal_design_star', 'goal_design_citadel', 'goal_design_facade', 'goal_design_tree'])
    assert.strictEqual(GOAL_DESIGN_GROUP_LABEL_KEY, 'goal_design_group')
    assert.ok(Object.isFrozen(GOAL_DESIGNS) && GOAL_DESIGNS.every(Object.isFrozen), 'the list is declared once and cannot be changed by a caller')
  })

  test('the default is the named constant "citadel", and it is not the first entry of the list', () => {
    assert.strictEqual(DEFAULT_GOAL_DESIGN, 'citadel')
    assert.notStrictEqual(GOAL_DESIGNS[0].id, DEFAULT_GOAL_DESIGN, 'the star is first and is not the default')
    assert.ok(ids(GOAL_DESIGNS).includes(DEFAULT_GOAL_DESIGN), 'the default is a design of the list')
    // independent of the list order: the citadel is still the default when it is not first and the list is reordered
    const reordered = [...GOAL_DESIGNS].reverse()
    assert.strictEqual(defaultDesignId(registeredDesigns(ALL, reordered)), 'citadel')
  })

  test('the storage key is one documented string', () => {
    assert.strictEqual(GOAL_DESIGN_STORAGE_KEY, 'jenga-dashboard-goal-design')
    const header = fs.readFileSync(modelPath, 'utf8').split('*/')[0]
    assert.ok(header.includes('GOAL_DESIGN_STORAGE_KEY') && /localStorage key/.test(header), 'the header documents the key')
  })

  test('registeredDesigns keeps list order whatever the registry key order is, and drops designs with no renderer', () => {
    assert.deepStrictEqual(ids(registeredDesigns(registry('tree', 'star', 'facade', 'citadel'))), ['star', 'citadel', 'facade', 'tree'])
    assert.deepStrictEqual(ids(registeredDesigns(registry('star'))), ['star'])
    assert.deepStrictEqual(ids(registeredDesigns(registry('star', 'facade'))), ['star', 'facade'])
    assert.deepStrictEqual(registeredDesigns({}), [])
    assert.deepStrictEqual(registeredDesigns(null), [])
    assert.deepStrictEqual(registeredDesigns(undefined), [])
    assert.deepStrictEqual(ids(registeredDesigns({ star: null, citadel: undefined, facade: false, tree: 0 })), [], 'a falsy renderer is not registered')
  })

  test('an inherited property or an id outside the list never registers a design', () => {
    assert.deepStrictEqual(registeredDesigns({ constructor: {}, toString: {}, hasOwnProperty: {} }), [])
    assert.deepStrictEqual(ids(registeredDesigns({ star: {}, moon: {} })), ['star'], 'an id that is not in the list is ignored')
  })

  test('the selector is visible only with two or more registered designs', () => {
    assert.strictEqual(selectorVisible(registeredDesigns(registry('star'))), false, 'only the star: hidden')
    assert.strictEqual(selectorVisible(registeredDesigns({})), false, 'none: hidden')
    assert.strictEqual(selectorVisible(registeredDesigns(registry('star', 'citadel'))), true)
    assert.strictEqual(selectorVisible(ALL_REGISTERED), true)
    assert.strictEqual(selectorVisible(null), false)
    assert.strictEqual(selectorVisible(undefined), false)
  })

  test('default: the citadel when registered, else the first registered design, else null', () => {
    assert.strictEqual(defaultDesignId(ALL_REGISTERED), 'citadel')
    assert.strictEqual(defaultDesignId(registeredDesigns(registry('star', 'citadel'))), 'citadel', 'not the first entry')
    assert.strictEqual(defaultDesignId(registeredDesigns(registry('star'))), 'star', 'only the star is registered')
    assert.strictEqual(defaultDesignId(registeredDesigns(registry('star', 'facade', 'tree'))), 'star', 'no citadel: the first registered')
    assert.strictEqual(defaultDesignId(registeredDesigns(registry('facade', 'tree'))), 'facade', 'no citadel, no star: the first registered')
    assert.strictEqual(defaultDesignId([]), null)
    assert.strictEqual(defaultDesignId(null), null)
  })

  test('readGoalDesign: nothing stored gives the default', () => {
    assert.strictEqual(readGoalDesign(ALL_REGISTERED, () => fakeStore()), 'citadel')
    assert.strictEqual(readGoalDesign(registeredDesigns(registry('star')), () => fakeStore()), 'star')
  })

  test('readGoalDesign: a stored star, citadel, facade or tree is returned', () => {
    for (const id of ['star', 'citadel', 'facade', 'tree']) {
      const store = fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: id })
      assert.strictEqual(readGoalDesign(ALL_REGISTERED, () => store), id, id)
      assert.deepStrictEqual(store.calls, [['get', GOAL_DESIGN_STORAGE_KEY]], 'one read, under the documented key')
    }
  })

  test('readGoalDesign: an unknown, empty or odd stored value gives the citadel', () => {
    for (const v of ['bogus', '', ' ', 'Citadel', 'STAR', 'moon', '{"id":"star"}', 'null', 'undefined', '__proto__', 'constructor', 'star ']) {
      assert.strictEqual(readGoalDesign(ALL_REGISTERED, () => fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: v })), 'citadel', JSON.stringify(v))
    }
  })

  test('readGoalDesign: a stored id that is in the list but not registered (not built yet) gives the default', () => {
    const onlyStar = registeredDesigns(registry('star'))
    assert.strictEqual(readGoalDesign(onlyStar, () => fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: 'facade' })), 'star')
    assert.strictEqual(readGoalDesign(onlyStar, () => fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: 'citadel' })), 'star', 'the default itself is not registered yet')
    const noTree = registeredDesigns(registry('star', 'citadel', 'facade'))
    assert.strictEqual(readGoalDesign(noTree, () => fakeStore({ [GOAL_DESIGN_STORAGE_KEY]: 'tree' })), 'citadel')
  })

  test('readGoalDesign: throwing, missing or null storage gives the default and never throws', () => {
    assert.strictEqual(readGoalDesign(ALL_REGISTERED, () => throwingStore()), 'citadel', 'getItem throws')
    assert.strictEqual(readGoalDesign(ALL_REGISTERED, () => { throw new Error('SecurityError') }), 'citadel', 'reaching storage throws')
    assert.strictEqual(readGoalDesign(ALL_REGISTERED, () => null), 'citadel', 'no storage')
    assert.strictEqual(readGoalDesign(ALL_REGISTERED, () => undefined), 'citadel')
    assert.strictEqual(readGoalDesign(ALL_REGISTERED, () => ({})), 'citadel', 'a store without getItem')
    assert.strictEqual(readGoalDesign(registeredDesigns(registry('star')), () => throwingStore()), 'star', 'only the star: the star')
  })

  test('with no window at all (Node, a static render) the default reading is the default design and nothing throws', () => {
    assert.strictEqual(typeof window, 'undefined')
    assert.strictEqual(goalDesignStorage(), null)
    assert.strictEqual(readGoalDesign(ALL_REGISTERED), 'citadel')
    assert.doesNotThrow(() => writeGoalDesign('star'))
  })

  test('a window whose localStorage getter throws (blocked site data, some file:// pages) is the default design', () => {
    Object.defineProperty(globalThis, 'window', { configurable: true, value: { get localStorage() { throw new Error('SecurityError') } } })
    try {
      assert.strictEqual(goalDesignStorage(), null)
      assert.strictEqual(readGoalDesign(ALL_REGISTERED), 'citadel')
      assert.doesNotThrow(() => writeGoalDesign('facade'))
    } finally {
      delete globalThis.window
    }
  })

  test('a window with a working localStorage round-trips through the default accessor', () => {
    const store = fakeStore()
    Object.defineProperty(globalThis, 'window', { configurable: true, value: { localStorage: store } })
    try {
      writeGoalDesign('facade')
      assert.strictEqual(store.map.get(GOAL_DESIGN_STORAGE_KEY), 'facade')
      assert.strictEqual(readGoalDesign(ALL_REGISTERED), 'facade')
    } finally {
      delete globalThis.window
    }
  })

  test('writeGoalDesign stores the id under the one key; throwing or missing storage is ignored', () => {
    const store = fakeStore()
    writeGoalDesign('tree', () => store)
    assert.deepStrictEqual(store.calls, [['set', GOAL_DESIGN_STORAGE_KEY, 'tree']])
    assert.doesNotThrow(() => writeGoalDesign('tree', () => throwingStore()))
    assert.doesNotThrow(() => writeGoalDesign('tree', () => null))
    assert.doesNotThrow(() => writeGoalDesign('tree', () => { throw new Error('SecurityError') }))
  })

  test('resolveGoalDesign: a registered id is kept, anything else is the default', () => {
    assert.strictEqual(resolveGoalDesign('facade', ALL_REGISTERED), 'facade')
    assert.strictEqual(resolveGoalDesign('star', ALL_REGISTERED), 'star')
    assert.strictEqual(resolveGoalDesign('moon', ALL_REGISTERED), 'citadel')
    assert.strictEqual(resolveGoalDesign(null, ALL_REGISTERED), 'citadel')
    assert.strictEqual(resolveGoalDesign(7, ALL_REGISTERED), 'citadel')
    assert.strictEqual(resolveGoalDesign('facade', registeredDesigns(registry('star'))), 'star', 'no longer registered')
    assert.strictEqual(resolveGoalDesign('star', []), null)
  })

  test('a fifth design is one more entry: it registers, is ordered, is stored and is read back, with no change to the functions', () => {
    const FIFTH = { id: 'moon', labelKey: 'goal_design_moon' }
    const five = [...GOAL_DESIGNS, FIFTH]
    const reg = { ...ALL, moon: { Drawing: () => null } }
    const registered = registeredDesigns(reg, five)
    assert.deepStrictEqual(ids(registered), ['star', 'citadel', 'facade', 'tree', 'moon'])
    assert.strictEqual(selectorVisible(registered), true)
    assert.strictEqual(defaultDesignId(registered), 'citadel', 'the new entry does not move the default')
    const store = fakeStore()
    writeGoalDesign('moon', () => store)
    assert.strictEqual(readGoalDesign(registered, () => store), 'moon')
    assert.strictEqual(readGoalDesign(ALL_REGISTERED, () => store), 'citadel', 'the same stored value is unknown to the four-entry list')
    // a fifth entry that is in the list but not registered stays absent
    assert.deepStrictEqual(ids(registeredDesigns(ALL, five)), ['star', 'citadel', 'facade', 'tree'])
  })

  test('the model has no import, no DOM, no React and no colour', () => {
    const src = fs.readFileSync(modelPath, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
    assert.ok(!/^\s*import\s/m.test(src), 'no import')
    assert.ok(!/\b(document|React|useState)\b/.test(src), 'no DOM and no React')
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(src), 'no colour literal')
  })

  console.log(`\n${n} tests passed`)
}

main().catch(e => { console.error(e); process.exit(1) })
