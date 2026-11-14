#!/usr/bin/env node
'use strict'
// E92_S07_T04: tests for useFocusContain.js, the focus trap of the large view of the epic progress map. Zero test
// framework and no browser. React is not resolvable from every checkout (a task worktree has no node_modules), so the
// hook source is read, its two imports are rewritten (react to a tiny stub whose useEffect runs the effect at once and
// records the cleanup; ./fullscreenModel to its absolute file URL), written to a temp .mjs and loaded with import().
// The DOM is a small fake: a root with several children, a document with a focus owner, and EventTarget-like objects
// that count their add/remove calls.
//   1. focusableIn: the usual set, disabled / hidden / tabindex -1 skipped, queried again every time.
//   2. Initial focus: first control, unless focus is already inside.
//   3. Tab and Shift+Tab: wrap last to first and first to last, middle left to the browser, list re-queried each time.
//   4. focusin outside the root returns focus inside; inside is left alone.
//   5. Listeners: none while inactive, added when active, removed on deactivation and unmount.
//   6. Keys: Enter and Space never default-prevented; no inert written; nothing done to focus on deactivation.
//   7. Source rules: no hex literal, no inert, no preventDefault on Enter/Space, no zoomPan imports.
// Run: node project/app/ui/scripts/fullscreen-focus.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { pathToFileURL } = require('url')

const compDir = path.join(__dirname, '..', 'src', 'components', 'progress')
const hookFile = path.join(compDir, 'useFocusContain.js')
const modelFile = path.join(compDir, 'fullscreenModel.js')
const hookSrc = fs.readFileSync(hookFile, 'utf8')

let n = 0
const test = async (name, fn) => { await fn(); n++; console.log('ok  ' + name) }

// ---------- the fake DOM ----------
function makeDoc() {
  const listeners = {}
  const doc = {
    activeElement: null,
    adds: 0,
    removes: 0,
    listeners,
    addEventListener(type, fn) { doc.adds++; (listeners[type] = listeners[type] || new Set()).add(fn) },
    removeEventListener(type, fn) { doc.removes++; if (listeners[type]) listeners[type].delete(fn) },
    count(type) { return listeners[type] ? listeners[type].size : 0 },
    dispatch(type, ev) { for (const fn of [...(listeners[type] || [])]) fn(ev) },
  }
  return doc
}

function makeEl(doc, name, attrs = {}) {
  const el = {
    name,
    attrs: { ...attrs },
    disabled: !!attrs.disabled,
    hidden: false,
    type: attrs.type,
    parent: null,
    focusCalls: 0,
    hasAttribute(a) { return a in el.attrs },
    getAttribute(a) { return a in el.attrs ? String(el.attrs[a]) : null },
    closest(sel) {
      if (sel !== '[hidden]') return null
      for (let p = el; p; p = p.parent) if ('hidden' in p.attrs) return p
      return null
    },
    focus() { el.focusCalls++; doc.activeElement = el; doc.dispatch('focusin', { target: el }) },
  }
  return el
}

function makeRoot(doc) {
  const root = {
    ownerDocument: doc,
    children: [],
    adds: 0,
    removes: 0,
    listeners: {},
    addEventListener(type, fn) { root.adds++; (root.listeners[type] = root.listeners[type] || new Set()).add(fn) },
    removeEventListener(type, fn) { root.removes++; if (root.listeners[type]) root.listeners[type].delete(fn) },
    count(type) { return root.listeners[type] ? root.listeners[type].size : 0 },
    contains(el) { return root.children.includes(el) },
    queries: 0,
    querySelectorAll() { root.queries++; return root.children.slice() }, // the selector is not evaluated: the hook filters
    add(el) { el.parent = root; root.children.push(el); return el },
    key(ev) { for (const fn of [...(root.listeners.keydown || [])]) fn(ev) },
  }
  return root
}

function keyEvent(key, extra = {}) {
  const ev = { key, shiftKey: false, ctrlKey: false, altKey: false, metaKey: false, prevented: 0, ...extra }
  ev.preventDefault = () => { ev.prevented++ }
  return ev
}

// A root with: close (button), zoomOut (button), hiddenBtn (hidden), off (disabled), skip (tabindex -1), card (tabindex 0), last (button).
function scene() {
  const doc = makeDoc()
  const root = makeRoot(doc)
  const close = root.add(makeEl(doc, 'close'))
  const zoomOut = root.add(makeEl(doc, 'zoomOut'))
  const off = root.add(makeEl(doc, 'off', { disabled: '' }))
  const skip = root.add(makeEl(doc, 'skip', { tabindex: '-1' }))
  const hid = root.add(makeEl(doc, 'hid', { hidden: '' }))
  const card = root.add(makeEl(doc, 'card', { tabindex: '0' }))
  const last = root.add(makeEl(doc, 'last'))
  const outside = makeEl(doc, 'outside')
  return { doc, root, close, zoomOut, off, skip, hid, card, last, outside }
}

;(async () => {
  // ---------- load the hook with the react stub ----------
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fullscreen-focus-'))
  fs.writeFileSync(path.join(tmp, 'react-stub.mjs'),
    "export function useEffect(fn, deps) { globalThis.__fcRuns = globalThis.__fcRuns || []; globalThis.__fcRuns.push({ cleanup: fn(), deps }) }\n")
  const reactImport = /import\s*\{\s*useEffect\s*\}\s*from\s*'react'/
  const modelImport = /import\s*\{\s*nextTabTarget\s*\}\s*from\s*'\.\/fullscreenModel'/
  assert.ok(reactImport.test(hookSrc), 'the hook imports useEffect from react')
  assert.ok(modelImport.test(hookSrc), 'the hook imports nextTabTarget from ./fullscreenModel')
  const rewritten = hookSrc
    .replace(reactImport, `import { useEffect } from ${JSON.stringify(pathToFileURL(path.join(tmp, 'react-stub.mjs')).href)}`)
    .replace(modelImport, `import { nextTabTarget } from ${JSON.stringify(pathToFileURL(modelFile).href)}`)
  const hookCopy = path.join(tmp, 'useFocusContain.mjs')
  fs.writeFileSync(hookCopy, rewritten)
  const H = await import(pathToFileURL(hookCopy).href)
  const useFocusContain = H.default
  const resetRuns = () => { globalThis.__fcRuns = [] }
  const lastRun = () => globalThis.__fcRuns[globalThis.__fcRuns.length - 1]
  process.on('exit', () => { try { fs.rmSync(tmp, { recursive: true, force: true }) } catch (e) { /* temp only */ } })

  // ---------- 1. focusableIn ----------
  await test('exports: default hook, focusableIn, containFocus', () => {
    assert.strictEqual(typeof useFocusContain, 'function')
    assert.strictEqual(typeof H.focusableIn, 'function')
    assert.strictEqual(typeof H.containFocus, 'function')
  })
  await test('focusableIn: skips disabled, hidden and tabindex -1; keeps buttons and tabindex 0', () => {
    const s = scene()
    assert.deepStrictEqual(H.focusableIn(s.root).map(e => e.name), ['close', 'zoomOut', 'card', 'last'])
  })
  await test('focusableIn: skips input type=hidden, a hidden ancestor and tabindex below -1', () => {
    const s = scene()
    s.root.add(makeEl(s.doc, 'hiddenInput', { type: 'hidden' }))
    s.root.add(makeEl(s.doc, 'neg', { tabindex: '-5' }))
    const wrapper = { attrs: { hidden: '' }, parent: s.root }
    const inside = makeEl(s.doc, 'inHidden'); inside.parent = wrapper; s.root.children.push(inside)
    assert.deepStrictEqual(H.focusableIn(s.root).map(e => e.name), ['close', 'zoomOut', 'card', 'last'])
  })
  await test('focusableIn: a missing root, or one that throws, gives an empty list', () => {
    assert.deepStrictEqual(H.focusableIn(null), [])
    assert.deepStrictEqual(H.focusableIn({}), [])
    assert.deepStrictEqual(H.focusableIn({ querySelectorAll() { throw new Error('detached') } }), [])
  })
  await test('focusableIn: queries the root every call (no cache)', () => {
    const s = scene()
    const before = s.root.queries
    H.focusableIn(s.root); H.focusableIn(s.root)
    assert.strictEqual(s.root.queries, before + 2)
    s.root.add(makeEl(s.doc, 'extra'))
    assert.strictEqual(H.focusableIn(s.root).length, 5)
  })

  // ---------- 2. initial focus ----------
  await test('containFocus: focuses the first focusable control when focus is elsewhere', () => {
    const s = scene()
    s.doc.activeElement = s.outside
    const off = H.containFocus(s.root)
    assert.strictEqual(s.doc.activeElement, s.close)
    assert.strictEqual(s.close.focusCalls, 1)
    off()
  })
  await test('containFocus: focus already inside the root is left where it is', () => {
    const s = scene()
    s.doc.activeElement = s.card
    const off = H.containFocus(s.root)
    assert.strictEqual(s.doc.activeElement, s.card)
    assert.strictEqual(s.close.focusCalls, 0)
    off()
  })
  await test('containFocus: an empty root takes no focus and does not throw', () => {
    const doc = makeDoc(); const root = makeRoot(doc)
    const off = H.containFocus(root)
    assert.strictEqual(doc.activeElement, null)
    off()
  })

  // ---------- 3. Tab and Shift+Tab ----------
  await test('Tab from the last control goes to the first', () => {
    const s = scene(); s.doc.activeElement = s.last
    const off = H.containFocus(s.root)
    const ev = keyEvent('Tab')
    s.root.key(ev)
    assert.strictEqual(s.doc.activeElement, s.close)
    assert.strictEqual(ev.prevented, 1)
    off()
  })
  await test('Shift+Tab from the first control goes to the last', () => {
    const s = scene(); s.doc.activeElement = s.close
    const off = H.containFocus(s.root)
    const ev = keyEvent('Tab', { shiftKey: true })
    s.root.key(ev)
    assert.strictEqual(s.doc.activeElement, s.last)
    assert.strictEqual(ev.prevented, 1)
    off()
  })
  await test('Tab and Shift+Tab never land on the disabled, hidden or tabindex -1 elements', () => {
    const s = scene(); s.doc.activeElement = s.last
    const off = H.containFocus(s.root)
    const seen = []
    for (let i = 0; i < 6; i++) {
      s.root.key(keyEvent('Tab'))
      seen.push(s.doc.activeElement.name)
    }
    for (const bad of ['off', 'skip', 'hid']) assert.ok(!seen.includes(bad), bad)
    assert.strictEqual(seen[0], 'close')
    off()
  })
  await test('Tab in the middle of the list is left to the browser (not default-prevented, no focus call)', () => {
    const s = scene(); s.doc.activeElement = s.zoomOut
    const off = H.containFocus(s.root)
    const ev = keyEvent('Tab'); s.root.key(ev)
    assert.strictEqual(ev.prevented, 0)
    assert.strictEqual(s.doc.activeElement, s.zoomOut)
    const back = keyEvent('Tab', { shiftKey: true }); s.root.key(back)
    assert.strictEqual(back.prevented, 0)
    off()
  })
  await test('Tab with focus on a non-tabbable element inside the root goes to the first (Shift+Tab to the last)', () => {
    const s = scene(); s.doc.activeElement = s.skip
    const off = H.containFocus(s.root)
    s.root.key(keyEvent('Tab'))
    assert.strictEqual(s.doc.activeElement, s.close)
    s.doc.activeElement = s.skip
    s.root.key(keyEvent('Tab', { shiftKey: true }))
    assert.strictEqual(s.doc.activeElement, s.last)
    off()
  })
  await test('the list is re-queried on every Tab: a control added or removed changes the wrap target', () => {
    const s = scene(); s.doc.activeElement = s.last
    const off = H.containFocus(s.root)
    const q0 = s.root.queries
    const extra = s.root.add(makeEl(s.doc, 'extra')) // an expanded group adds a card after `last`
    s.doc.activeElement = extra
    s.root.key(keyEvent('Tab'))
    assert.strictEqual(s.doc.activeElement, s.close) // wrapped from the new last
    assert.ok(s.root.queries > q0)
    s.root.children.splice(s.root.children.indexOf(extra), 1) // the group collapses again
    s.doc.activeElement = s.last
    s.root.key(keyEvent('Tab'))
    assert.strictEqual(s.doc.activeElement, s.close)
    s.doc.activeElement = s.close
    s.root.key(keyEvent('Tab', { shiftKey: true }))
    assert.strictEqual(s.doc.activeElement, s.last)
    off()
  })
  await test('Tab with no focusable control keeps focus put (default-prevented); other keys and modified Tab are ignored', () => {
    const doc = makeDoc(); const root = makeRoot(doc)
    const off = H.containFocus(root)
    const ev = keyEvent('Tab'); root.key(ev)
    assert.strictEqual(ev.prevented, 1)
    const s = scene(); s.doc.activeElement = s.last
    const off2 = H.containFocus(s.root)
    for (const ev2 of [keyEvent('Tab', { ctrlKey: true }), keyEvent('Tab', { altKey: true }), keyEvent('Tab', { metaKey: true }), keyEvent('a'), keyEvent('Escape')]) {
      s.root.key(ev2)
      assert.strictEqual(ev2.prevented, 0, ev2.key)
    }
    assert.strictEqual(s.doc.activeElement, s.last)
    off(); off2()
  })

  // ---------- 4. focusin ----------
  await test('focusin on an element outside the root returns focus into the root', () => {
    const s = scene(); s.doc.activeElement = s.card
    const off = H.containFocus(s.root)
    s.outside.focus() // the document's focusin listener fires and sends focus back
    assert.strictEqual(s.doc.activeElement, s.close)
    off()
  })
  await test('focusin inside the root is left alone, and focusin with no target does nothing', () => {
    const s = scene(); s.doc.activeElement = s.card
    const off = H.containFocus(s.root)
    const calls = s.close.focusCalls
    s.zoomOut.focus()
    assert.strictEqual(s.doc.activeElement, s.zoomOut)
    assert.strictEqual(s.close.focusCalls, calls)
    s.doc.dispatch('focusin', {}); s.doc.dispatch('focusin', null)
    assert.strictEqual(s.doc.activeElement, s.zoomOut)
    off()
  })
  await test('focusin redirect does not loop and does nothing when the root has no control', () => {
    const doc = makeDoc(); const root = makeRoot(doc); const out = makeEl(doc, 'out')
    const off = H.containFocus(root)
    out.focus() // nothing to redirect to: the focus stays where it landed, no recursion
    assert.strictEqual(doc.activeElement, out)
    off()
  })

  // ---------- 5. listeners ----------
  await test('hook with active false: no listener is added and no effect cleanup exists', () => {
    const s = scene(); resetRuns()
    useFocusContain({ rootRef: { current: s.root }, active: false })
    assert.strictEqual(lastRun().cleanup, undefined)
    assert.strictEqual(s.root.adds, 0); assert.strictEqual(s.doc.adds, 0)
    assert.strictEqual(s.root.count('keydown'), 0); assert.strictEqual(s.doc.count('focusin'), 0)
  })
  await test('hook with active true: one keydown on the root, one focusin on the document; cleanup removes both', () => {
    const s = scene(); resetRuns(); s.doc.activeElement = s.outside
    useFocusContain({ rootRef: { current: s.root }, active: true })
    assert.strictEqual(s.root.count('keydown'), 1)
    assert.strictEqual(s.doc.count('focusin'), 1)
    assert.strictEqual(s.root.adds, 1); assert.strictEqual(s.doc.adds, 1)
    assert.strictEqual(s.doc.activeElement, s.close) // the initial focus
    lastRun().cleanup() // deactivation or unmount
    assert.strictEqual(s.root.count('keydown'), 0)
    assert.strictEqual(s.doc.count('focusin'), 0)
    assert.strictEqual(s.root.removes, 1); assert.strictEqual(s.doc.removes, 1)
  })
  await test('hook effect depends on rootRef and active only; a missing ref or root does nothing', () => {
    const s = scene(); const ref = { current: s.root }; resetRuns()
    useFocusContain({ rootRef: ref, active: true })
    assert.deepStrictEqual(lastRun().deps, [ref, true])
    lastRun().cleanup()
    resetRuns()
    useFocusContain({ rootRef: { current: null }, active: true })
    assert.strictEqual(lastRun().cleanup, undefined)
    resetRuns(); useFocusContain({ active: true }); assert.strictEqual(lastRun().cleanup, undefined)
    resetRuns(); useFocusContain(); assert.strictEqual(lastRun().cleanup, undefined)
  })
  await test('after cleanup the trap is gone: Tab and focusin no longer move focus', () => {
    const s = scene(); s.doc.activeElement = s.last
    const off = H.containFocus(s.root)
    off()
    const ev = keyEvent('Tab'); s.root.key(ev)
    s.outside.focus()
    assert.strictEqual(ev.prevented, 0)
    assert.strictEqual(s.doc.activeElement, s.outside)
  })
  await test('a root that cannot take listeners gives a no-op cleanup; a throwing listener API never throws out', () => {
    assert.doesNotThrow(() => H.containFocus(null)())
    assert.doesNotThrow(() => H.containFocus({})())
    const s = scene()
    s.root.addEventListener = () => { throw new Error('nope') }
    s.root.removeEventListener = () => { throw new Error('nope') }
    assert.doesNotThrow(() => H.containFocus(s.root)())
  })

  // ---------- 6. keys, inert, deactivation ----------
  await test('Enter and Space are never default-prevented, on any control', () => {
    const s = scene()
    const off = H.containFocus(s.root)
    for (const el of s.root.children) {
      s.doc.activeElement = el
      for (const key of ['Enter', ' ', 'Spacebar', 'Space']) {
        const ev = keyEvent(key); s.root.key(ev)
        assert.strictEqual(ev.prevented, 0, `${el.name} ${JSON.stringify(key)}`)
      }
    }
    off()
  })
  await test('no inert (or any other) attribute is written to any element', () => {
    const s = scene(); s.doc.activeElement = s.outside
    const before = JSON.stringify([...s.root.children, s.outside].map(e => e.attrs))
    const off = H.containFocus(s.root)
    s.root.key(keyEvent('Tab')); s.outside.focus()
    off()
    assert.strictEqual(JSON.stringify([...s.root.children, s.outside].map(e => e.attrs)), before)
    for (const el of [...s.root.children, s.outside]) assert.ok(!('inert' in el.attrs) && !('inert' in el), el.name)
  })
  await test('deactivation does nothing to focus', () => {
    const s = scene(); s.doc.activeElement = s.card
    const off = H.containFocus(s.root)
    const calls = s.root.children.reduce((a, e) => a + e.focusCalls, 0) + s.outside.focusCalls
    off()
    assert.strictEqual(s.doc.activeElement, s.card)
    assert.strictEqual(s.root.children.reduce((a, e) => a + e.focusCalls, 0) + s.outside.focusCalls, calls)
  })

  // ---------- 7. source rules ----------
  const code = hookSrc.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
  await test('source: no hex colour literal, no inert, no zoomPanModel or useZoomPan import', () => {
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(code), 'hex literal')
    assert.ok(!/\binert\b/i.test(code), 'inert')
    assert.ok(!/zoomPanModel|useZoomPan/.test(code), 'zoom pan import')
    const imports = code.match(/^import .*$/gm) || []
    assert.deepStrictEqual(imports.map(l => l.match(/from '([^']+)'/)[1]).sort(), ['./fullscreenModel', 'react'])
  })
  await test('source: preventDefault is reached only after the Tab check; no Enter or Space key handling', () => {
    assert.ok(!/['"`]Enter['"`]/.test(code), 'Enter')
    assert.ok(!/['"`] ['"`]|['"`]Space(bar)?['"`]/.test(code), 'Space')
    const guardIdx = code.indexOf("e.key !== 'Tab'")
    assert.ok(guardIdx > 0, 'Tab guard')
    const first = code.indexOf('preventDefault')
    assert.ok(first > guardIdx, 'every preventDefault sits after the Tab-only early return')
  })
  await test('source: the hook file is the only listener site and adds listeners on root and document only', () => {
    const adds = code.match(/\.addEventListener\([^)]*\)/g) || []
    assert.deepStrictEqual(adds.map(a => a.match(/'(\w+)'/)[1]).sort(), ['focusin', 'keydown'])
    assert.ok(!/setAttribute|removeAttribute|\.style\b|dataset/.test(code), 'writes no attribute or style')
  })

  console.log(`\n${n} tests passed`)
})().catch(e => { console.error(e); process.exit(1) })
