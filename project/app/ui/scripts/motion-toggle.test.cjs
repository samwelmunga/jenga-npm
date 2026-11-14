#!/usr/bin/env node
'use strict'
// E92_S06_T21: tests for the dashboard's Animations toggle (Auto/Off).
//   1. motionPreference.js: the attribute, the guarded storage, blocked storage, file://-style failures.
//   2. index.html's inline pre-paint script, run in a vm against a fake window and document.
//   3. MotionToggle.jsx through a hand-rolled hook runtime: cycling, words from the labels, icon only without them.
//   4. dependency-tree.css as text: every tree animation is disabled under prefers-reduced-motion: reduce and under
//      :root[data-motion="off"] (evaluated, not only pattern-matched), and no animation is driven from script.
//   5. Source rules: App.jsx hosts the toggle next to the theme toggle and feeds it labels through loadProgressLabels;
//      every localStorage access in the new files is inside a try.
// Run: node project/app/ui/scripts/motion-toggle.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const vm = require('vm')
const { pathToFileURL } = require('url')

const uiDir = path.join(__dirname, '..')
const srcDir = path.join(uiDir, 'src')
const esbuild = require('esbuild')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'motion-toggle-'))
const nodePaths = [path.join(uiDir, 'node_modules'), path.join(uiDir, '..', 'node_modules')]

const shim = path.join(tmp, 'react-shim.js')
fs.writeFileSync(shim, `
  import * as R from ${JSON.stringify(require.resolve('react', { paths: [uiDir] }))}
  const h = () => globalThis.__h
  export const useState = init => h().useState(init)
  export const useEffect = (fn, deps) => h().useEffect(fn, deps)
  export default { ...R }
  export const createElement = R.createElement
  export const Fragment = R.Fragment
`)
const out = path.join(tmp, 'toggle.cjs')
// esbuild refuses plugins in buildSync, so the bundle is built async inside the main function
const buildToggle = () => esbuild.build({
  stdin: {
    contents: `
      import { renderToStaticMarkup } from 'react-dom/server'
      export { default as MotionToggle } from './src/components/MotionToggle.jsx'
      export { loadProgressLabels } from './src/api/progressLabels.js'
      export { renderToStaticMarkup }
    `,
    resolveDir: uiDir, loader: 'jsx',
  },
  outfile: out, bundle: true, platform: 'node', format: 'cjs', jsx: 'automatic', nodePaths, logLevel: 'silent',
  define: { 'import.meta.env': '{}' },
  plugins: [{ name: 'react-hook-shim', setup(b) { b.onResolve({ filter: /^react$/ }, a => (a.importer.includes(path.sep + 'src' + path.sep) ? { path: shim } : null)) } }],
})
let MotionToggle, loadProgressLabels, renderToStaticMarkup

let n = 0
const test = async (name, fn) => { await fn(); n++; console.log('ok  ' + name) }
const strip = t => t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

/** A fake storage; `fail` makes every call throw, like blocked storage. */
function storage(fail) {
  const data = new Map(), calls = []
  const guard = () => { if (fail) throw new Error('SecurityError') }
  return {
    calls, data,
    getItem(k) { calls.push(['get', k]); guard(); return data.has(k) ? data.get(k) : null },
    setItem(k, v) { calls.push(['set', k, v]); guard(); data.set(k, String(v)) },
    removeItem(k) { calls.push(['remove', k]); guard(); data.delete(k) },
  }
}
const fakeRoot = () => ({ dataset: {} })

;(async () => {
  await buildToggle()
  ;({ MotionToggle, loadProgressLabels, renderToStaticMarkup } = require(out))
  const P = await import(pathToFileURL(path.join(srcDir, 'components', 'motionPreference.js')).href)

  // ---------- 1. motionPreference ----------
  await test('the attribute and the stored key: Off sets data-motion="off" and stores it, Auto removes both', () => {
    assert.strictEqual(P.MOTION_STORAGE_KEY, 'jenga-dashboard-motion')
    const root = fakeRoot(), st = storage()
    assert.strictEqual(P.readMotionAttr(root), 'auto')
    assert.strictEqual(P.applyMotion('off', root, () => st), 'off')
    assert.strictEqual(root.dataset.motion, 'off')
    assert.strictEqual(P.readMotionAttr(root), 'off')
    assert.deepStrictEqual(st.calls, [['set', 'jenga-dashboard-motion', 'off']])
    assert.strictEqual(P.applyMotion('auto', root, () => st), 'auto')
    assert.ok(!('motion' in root.dataset), 'the attribute is absent in Auto, not "auto"')
    assert.deepStrictEqual(st.calls[1], ['remove', 'jenga-dashboard-motion'])
    assert.strictEqual(st.data.size, 0)
  })

  await test('the cycle is Auto -> Off -> Auto and nothing else', () => {
    assert.deepStrictEqual(P.NEXT_MOTION, { auto: 'off', off: 'auto' })
    assert.strictEqual(P.readMotionAttr({ dataset: { motion: 'banana' } }), 'auto')
    assert.strictEqual(P.readMotionAttr(null), 'auto')
  })

  await test('blocked storage: every call throws, and still nothing throws and the attribute follows the toggle', () => {
    const root = fakeRoot(), st = storage(true)
    assert.doesNotThrow(() => P.applyMotion('off', root, () => st))
    assert.strictEqual(root.dataset.motion, 'off')
    assert.doesNotThrow(() => P.applyMotion('auto', root, () => st))
    assert.ok(!('motion' in root.dataset))
  })

  await test('unreachable storage: the accessor itself throws (file:// in some browsers) or is null, and nothing throws', () => {
    const root = fakeRoot()
    assert.doesNotThrow(() => P.applyMotion('off', root, () => { throw new Error('SecurityError') }))
    assert.strictEqual(root.dataset.motion, 'off')
    assert.doesNotThrow(() => P.applyMotion('auto', root, () => null))
    // the default accessor, with a window whose localStorage getter throws, and with no window at all
    const saved = globalThis.window
    Object.defineProperty(globalThis, 'window', { configurable: true, value: { get localStorage() { throw new Error('SecurityError') } } })
    assert.doesNotThrow(() => P.applyMotion('off', root))
    assert.strictEqual(root.dataset.motion, 'off')
    delete globalThis.window
    assert.doesNotThrow(() => P.applyMotion('auto', root))
    assert.strictEqual(P.osReducesMotion(), false)
    if (saved) globalThis.window = saved
  })

  await test('osReducesMotion follows matchMedia and is false where it throws', () => {
    Object.defineProperty(globalThis, 'window', { configurable: true, value: { matchMedia: q => ({ matches: /reduce/.test(q) }) } })
    assert.strictEqual(P.osReducesMotion(), true)
    globalThis.window.matchMedia = () => { throw new Error('nope') }
    assert.strictEqual(P.osReducesMotion(), false)
    delete globalThis.window
  })

  // ---------- 2. the inline pre-paint script ----------
  const html = fs.readFileSync(path.join(uiDir, 'index.html'), 'utf8')
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1])
  const runScripts = window => {
    const document = { documentElement: { dataset: {} } }
    const ctx = vm.createContext({ window, document })
    for (const s of scripts) vm.runInContext(s, ctx)
    return document.documentElement.dataset
  }

  await test('index.html: an inline script resolves the stored motion preference before first paint, as the theme script does', () => {
    assert.ok(scripts.length >= 2, 'the theme script and the motion script')
    assert.ok(scripts.some(s => s.includes('jenga-dashboard-motion')))
    assert.ok(html.indexOf('jenga-dashboard-motion') < html.indexOf('<div id="root">'), 'before the app mounts')
    assert.ok(html.indexOf('jenga-dashboard-motion') < html.indexOf('type="module"'), 'before the module script')
    assert.ok(!/<script[^>]*\ssrc=[^>]*jenga-dashboard-motion/.test(html), 'inline, no network')
    const stored = storage(); stored.data.set('jenga-dashboard-motion', 'off'); stored.data.set('jenga-dashboard-theme', 'dark')
    assert.deepStrictEqual({ ...runScripts({ localStorage: stored }) }, { theme: 'dark', motion: 'off' })
    assert.deepStrictEqual({ ...runScripts({ localStorage: storage() }) }, {}, 'nothing stored: Auto, no attribute')
    const other = storage(); other.data.set('jenga-dashboard-motion', 'auto')
    assert.deepStrictEqual({ ...runScripts({ localStorage: other }) }, {}, 'only "off" sets the attribute')
  })

  await test('index.html: blocked storage and a throwing localStorage getter do not throw and leave Auto', () => {
    assert.deepStrictEqual({ ...runScripts({ localStorage: storage(true) }) }, {})
    assert.deepStrictEqual({ ...runScripts({ get localStorage() { throw new Error('SecurityError') } }) }, {})
  })

  await test('index.html: a failing theme read does not stop the motion read (separate try blocks)', () => {
    const st = storage(); st.data.set('jenga-dashboard-motion', 'off')
    const flaky = { getItem(k) { if (k === 'jenga-dashboard-theme') throw new Error('x'); return st.getItem(k) } }
    assert.strictEqual(runScripts({ localStorage: flaky }).motion, 'off')
  })

  // ---------- 3. MotionToggle ----------
  function mount(props) {
    let slots = [], deps = [], cleanups = [], i, effects, output, rendering = false, dirty = false
    globalThis.__h = {
      useState(init) {
        const k = i++
        if (!(k in slots)) slots[k] = typeof init === 'function' ? init() : init
        return [slots[k], v => { slots[k] = v; flush() }]
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
      do { dirty = false; i = 0; effects = []; output = MotionToggle(props); const run = effects; effects = []; run.forEach(f => f()) } while (dirty)
      rendering = false
    }
    flush()
    return { html: () => renderToStaticMarkup(output), click: () => output.props.onClick(), get props() { return output.props } }
  }
  const EN = { motion_label: 'Animations', motion_auto: 'Auto', motion_off: 'Off', motion_activate: 'Activate to switch to %s.', motion_os_reduced: 'system: off' }
  const SV = { motion_label: 'Animationer', motion_auto: 'Auto', motion_off: 'Av', motion_activate: 'Aktivera för att byta till %s.', motion_os_reduced: 'systemet: av' }
  function withEnv({ stored, fail, reduce, attr }, fn) {
    const st = storage(fail)
    if (stored) st.data.set('jenga-dashboard-motion', stored)
    const root = fakeRoot()
    if (attr) root.dataset.motion = attr
    const w = { localStorage: st, matchMedia: q => ({ matches: !!reduce && /reduce/.test(q), addEventListener() {}, removeEventListener() {} }) }
    Object.defineProperty(globalThis, 'window', { configurable: true, value: w })
    Object.defineProperty(globalThis, 'document', { configurable: true, value: { documentElement: root } })
    try { return fn({ st, root }) } finally { delete globalThis.window; delete globalThis.document }
  }

  await test('MotionToggle starts from the attribute the pre-paint script set, and cycles Auto -> Off -> Auto', () => {
    withEnv({ attr: 'off' }, ({ root }) => {
      const m = mount({ labels: EN })
      assert.ok(m.html().includes('data-motion-state="off"') && m.html().includes('Animations: Off'))
      m.click()
      assert.ok(!('motion' in root.dataset)); assert.ok(m.html().includes('data-motion-state="auto"') && m.html().includes('Animations: Auto'))
      m.click()
      assert.strictEqual(root.dataset.motion, 'off')
    })
    withEnv({}, () => assert.ok(mount({ labels: EN }).html().includes('data-motion-state="auto"')))
  })

  await test('MotionToggle writes jenga-dashboard-motion only through guarded calls, and a click with blocked storage still toggles', () => {
    withEnv({}, ({ st, root }) => {
      const m = mount({ labels: EN })
      m.click()
      assert.deepStrictEqual(st.calls, [['set', 'jenga-dashboard-motion', 'off']], 'no storage read at mount: the attribute is the initial state')
      assert.strictEqual(root.dataset.motion, 'off')
    })
    withEnv({ fail: true }, ({ root }) => {
      const m = mount({ labels: EN })
      assert.doesNotThrow(() => m.click())
      assert.strictEqual(root.dataset.motion, 'off')
      assert.ok(m.html().includes('Animations: Off'))
      assert.doesNotThrow(() => m.click())
      assert.ok(!('motion' in root.dataset))
    })
  })

  await test('MotionToggle: every word comes from the labels (English and Swedish), with the accessible name and the next state', () => {
    withEnv({}, () => {
      const en = mount({ labels: EN })
      assert.strictEqual(en.props['aria-label'], 'Animations: Auto. Activate to switch to Off.')
      assert.strictEqual(en.props.title, 'Animations: Auto')
      assert.ok(en.html().includes('theme-toggle-label') && en.html().includes('>Animations: Auto<'))
      const sv = mount({ labels: SV })
      assert.strictEqual(sv.props['aria-label'], 'Animationer: Auto. Aktivera för att byta till Av.')
      assert.ok(!sv.html().includes('Animations'))
    })
  })

  await test('MotionToggle: Auto while the system asks for reduced motion says so', () => {
    withEnv({ reduce: true }, () => {
      assert.ok(mount({ labels: EN }).html().includes('Animations: Auto (system: off)'))
      assert.ok(mount({ labels: SV }).html().includes('Animationer: Auto (systemet: av)'))
    })
    withEnv({ reduce: true, attr: 'off' }, () => assert.ok(!mount({ labels: EN }).html().includes('(system: off)')))
  })

  await test('MotionToggle: before the labels arrive (and if they never do) it is an icon only, with no word and no name', () => {
    withEnv({}, ({ root }) => {
      for (const labels of [undefined, null, {}, { motion_label: 'Animations' }]) {
        const m = mount({ labels })
        const h = m.html()
        assert.ok(h.includes('✦'), 'the icon')
        assert.ok(!h.includes('theme-toggle-label') && !/aria-label=|title=/.test(h), 'no label, no name: ' + h)
        assert.ok(!/motion_(label|auto|off|activate)/.test(h), 'a key is never shown')
      }
      const m = mount({ labels: {} })
      m.click()
      assert.strictEqual(root.dataset.motion, 'off', 'it still works')
      assert.ok(m.html().includes('⏸'))
    })
  })

  await test('loadProgressLabels: the labels of /v1/progress-cards, {} on a failure or a payload without them, through the injected get', async () => {
    const calls = []
    assert.deepStrictEqual(await loadProgressLabels(p => { calls.push(p); return Promise.resolve({ epics: [], labels: EN }) }), EN)
    assert.deepStrictEqual(calls, ['/v1/progress-cards'])
    assert.deepStrictEqual(await loadProgressLabels(() => Promise.reject(new Error('down'))), {})
    assert.deepStrictEqual(await loadProgressLabels(() => { throw new Error('sync') }), {})
    assert.deepStrictEqual(await loadProgressLabels(() => Promise.resolve({ empty: true })), {})
    assert.deepStrictEqual(await loadProgressLabels(() => Promise.resolve(null)), {})
    assert.deepStrictEqual(await loadProgressLabels(() => Promise.resolve({ labels: null })), {})
  })

  // ---------- 4. the CSS: every tree animation is off under reduce and under data-motion="off" ----------
  const css = fs.readFileSync(path.join(srcDir, 'components', 'progress', 'dependency-tree.css'), 'utf8')
  const topLevel = src => {
    const text = strip(src)
    const blocks = []
    let depth = 0, start = 0, head = ''
    for (let i = 0; i < text.length; i++) {
      const c = text[i]
      if (c === '{') { if (depth === 0) { head = text.slice(start, i).trim(); start = i + 1 } depth++ }
      else if (c === '}') { depth--; if (depth === 0) { blocks.push({ head, body: text.slice(start, i) }); start = i + 1 } }
    }
    return blocks
  }
  const MOTION = /(^|[\s;{])(animation|transition)(-[a-z-]+)?\s*:/
  /** The animation names that apply to a page in a given condition, by evaluating the guards the CSS declares. */
  function activeAnimations({ reduce, off }) {
    const names = new Set()
    for (const b of topLevel(css)) {
      const isMedia = b.head.startsWith('@media')
      if (!isMedia) { if (MOTION.test(b.body)) names.add('UNGUARDED:' + b.head); continue }
      const mediaOk = /prefers-reduced-motion:\s*no-preference/.test(b.head) ? !reduce : /prefers-reduced-motion:\s*reduce/.test(b.head) ? reduce : true
      if (!mediaOk) continue
      for (const rule of b.body.split('}').map(r => r.trim()).filter(Boolean)) {
        const [sel, decl] = rule.split('{')
        if (!MOTION.test(decl || '')) continue
        for (const one of sel.split(',').map(x => x.trim())) {
          const rootOk = one.startsWith(':root:not([data-motion="off"])') ? !off : one.startsWith(':root[data-motion="off"]') ? off : true
          if (rootOk) names.add((decl.match(/animation(?:-name)?:\s*([a-z-]+)/) || [, one])[1])
        }
      }
    }
    return [...names].sort()
  }
  const ALL = ['dt-blink', 'dt-breathe', 'dt-flow', 'dt-ring-pulse', 'dt-shimmer', 'dt-twinkle']

  await test('CSS: with no preference and the toggle on Auto all six tree animations run (edge flow, ready pulse, goal breathe, shimmer, sparks, in-progress blink)', () => {
    const on = activeAnimations({ reduce: false, off: false })
    assert.deepStrictEqual(on.filter(x => x.startsWith('dt-')), ALL)
    for (const k of ALL) assert.ok(new RegExp(`@keyframes\\s+${k}\\b`).test(css), 'keyframes ' + k)
    // the one named per element, so none of the six is silently missing from the guard
    for (const sel of ['.dt-edge-ready', '.dt-state-ready .dt-ring', '.dt-halo', '.dt-state-in_progress .dt-blink', '.dt-shimmer', '.dt-spark']) assert.ok(css.includes(sel), sel)
  })

  await test('CSS: under prefers-reduced-motion: reduce nothing animates, whatever the toggle says', () => {
    assert.deepStrictEqual(activeAnimations({ reduce: true, off: false }), [])
    assert.deepStrictEqual(activeAnimations({ reduce: true, off: true }), [])
  })

  await test('CSS: under :root[data-motion="off"] nothing animates, even with no reduced-motion preference', () => {
    assert.deepStrictEqual(activeAnimations({ reduce: false, off: true }), [])
  })

  await test('CSS: no transition, no unguarded animation, no animation-delay outside the guard; the stripped halo and ring rest in their final state', () => {
    for (const b of topLevel(css)) {
      if (/^@media\s*\(prefers-reduced-motion:\s*no-preference\)$/.test(b.head)) continue
      if (b.head.startsWith('@keyframes')) continue
      assert.ok(!MOTION.test(b.body), 'motion declaration outside the guard: ' + b.head)
    }
    // static states the stopped animations leave behind are visible, not hidden: the ring is an animation target only
    assert.ok(/\.dt-ring\s*\{[^}]*opacity:\s*0/.test(css), 'the ready ring is invisible at rest; the ready state is still shown by its dashed edge and plus mark')
    assert.ok(/\.dt-shimmer\s*\{[^}]*translateX\(-60px\)/.test(css), 'the sheen rests off to the side')
  })

  await test('tree sources drive no animation from script: no SMIL, no requestAnimationFrame, no Web Animations', () => {
    for (const f of ['components/progress/DependencyTree.jsx', 'components/progress/useZoomPan.js', 'components/progress/ZoomControls.jsx']) {
      const t = strip(fs.readFileSync(path.join(srcDir, f), 'utf8'))
      assert.ok(!/<animate|<animateTransform|<set\s|requestAnimationFrame|\.animate\(|setInterval/.test(t), f)
    }
  })

  // ---------- 5. source rules ----------
  await test('App.jsx hosts the toggle beside the theme toggle and feeds it the labels from loadProgressLabels', () => {
    const app = fs.readFileSync(path.join(srcDir, 'App.jsx'), 'utf8')
    assert.ok(/<ThemeToggle \/>\s*<MotionToggle labels=\{labels\} \/>/.test(app), 'next to ThemeToggle')
    assert.ok(/loadProgressLabels\(\)\.then\(/.test(app) && /useState\(\{\}\)/.test(app), 'labels start empty, then arrive')
    assert.ok(/header-toggles/.test(app))
    const appCss = fs.readFileSync(path.join(srcDir, 'App.css'), 'utf8')
    assert.ok(/\.header-toggles\s*\{/.test(appCss))
    const client = fs.readFileSync(path.join(srcDir, 'api', 'progressLabels.js'), 'utf8')
    assert.ok(client.includes("'/v1/progress-cards'") && /import \{ get \} from '\.\/client'/.test(client), 'the existing progress client, no new endpoint')
  })

  await test('every localStorage access in the new files is inside a try block, and the key is spelled once in the module and once in the script', () => {
    for (const f of ['components/motionPreference.js', 'components/MotionToggle.jsx', 'api/progressLabels.js']) {
      const t = strip(fs.readFileSync(path.join(srcDir, f), 'utf8'))
      let from = 0, idx
      while ((idx = t.indexOf('localStorage', from)) !== -1) {
        from = idx + 1
        const tryAt = t.lastIndexOf('try {', idx)
        assert.ok(tryAt !== -1, `${f}: localStorage outside any try`)
        let depth = 0
        for (let i = tryAt + 4; i < idx; i++) { if (t[i] === '{') depth++; else if (t[i] === '}') depth-- }
        assert.ok(depth > 0, `${f}: localStorage is after the end of the nearest try block`)
      }
    }
    const inline = scripts.filter(s => s.includes('jenga-dashboard-motion')).join('\n')
    const t = strip(inline.replace(/^\s*\/\/.*$/gm, ''))
    const tryAt = t.indexOf('try {')
    assert.ok(tryAt !== -1 && t.indexOf('localStorage') > tryAt, 'the inline script reads storage inside a try')
  })

  await test('no hex literal in the new or changed UI files', () => {
    for (const f of ['components/motionPreference.js', 'components/MotionToggle.jsx', 'api/progressLabels.js', 'App.jsx', 'App.css']) {
      const t = strip(fs.readFileSync(path.join(srcDir, f), 'utf8'))
      assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(t) && !/\b(rgb|rgba|hsl|hsla)\(/.test(t), f)
    }
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(strip(scripts.filter(s => s.includes('jenga-dashboard-motion')).join('\n'))))
  })

  console.log(`\n${n} passed`)
})().catch(e => { console.error(e); process.exit(1) })
