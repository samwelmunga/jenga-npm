#!/usr/bin/env node
'use strict'
// E92_S07_T06: CSS-text test for the large view of the dependency tree (the block headed E92_S07_T06 appended to
// dependency-tree.css). Zero test framework and no DOM: the stylesheet is read as text, the block is cut out and asserted on,
// in the technique of tree-zoom-pan.test.cjs and motion-toggle.test.cjs.
//   1. the fallback layer: position fixed, inset 0, z-index above the epic overlay (101) and not above the leave guard (1000),
//      an opaque token background, and the page scroll lock on <html>
//   2. real fullscreen: :fullscreen and :-webkit-full-screen, each in a rule of its own, with the surface background
//   3. the large-view layout: column root, the drawing fills the height, the lists are a strip of their own
//   4. .dt-fs-btn and .dt-fs-hint, the focus ring with --color-accent, the 32px target
//   5. colours: no hex, no functional colour, no colour name, every colour a var(--color-*) token that tokens.css defines
//   6. motion: every transition and animation of the block is inside prefers-reduced-motion: no-preference and starts at
//      :root:not([data-motion="off"]); the base rules have none; the block adds no keyframes
//   7. the overlay's own rules are still there and are not the ones the large view relies on (override by specificity)
// Run: node project/app/ui/scripts/fullscreen-css.test.cjs
const assert = require('assert')
const fs = require('fs')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const cssPath = path.join(uiDir, 'src', 'components', 'progress', 'dependency-tree.css')
const css = fs.readFileSync(cssPath, 'utf8')
const tokens = fs.readFileSync(path.join(uiDir, 'src', 'tokens.css'), 'utf8')

let n = 0
const test = (name, fn) => { fn(); n++; console.log('ok  ' + name) }
const strip = t => t.replace(/\/\*[\s\S]*?\*\//g, '')

/** Top-level blocks of a stylesheet, tracking brace depth: [{ head, body }]. */
function topLevel(text) {
  const out = []
  let depth = 0, start = 0, head = ''
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c === '{') { if (depth === 0) { head = text.slice(start, i).trim(); start = i + 1 } depth++ }
    else if (c === '}') { depth--; if (depth === 0) { out.push({ head, body: text.slice(start, i) }); start = i + 1 } }
  }
  return out
}
/** Flat rules of a block body: [{ sel, decl }] (a body that itself holds nested rules, like a media block, is split once). */
const rulesOf = body => body.split('}').map(r => r.trim()).filter(Boolean).map(r => { const i = r.indexOf('{'); return { sel: r.slice(0, i).trim(), decl: r.slice(i + 1).trim() } })

// the block: from the comment headed E92_S07_T06 to the comment that closes it (a later task may append after it)
const MARK = '/* E92_S07_T06'
const END = '/* end E92_S07_T06 */'
const at = css.indexOf(MARK)
assert.ok(at > 0, 'the stylesheet carries a block headed E92_S07_T06')
assert.strictEqual(css.indexOf(MARK, at + 1), -1, 'exactly one block headed E92_S07_T06')
const endAt = css.indexOf(END)
assert.ok(endAt > at, 'the block is closed by the end comment')
const blockRaw = css.slice(at, endAt)
const block = strip(blockRaw)
const before = strip(css.slice(0, at))
const blocks = topLevel(block)
const plain = blocks.filter(b => !b.head.startsWith('@'))
const media = blocks.filter(b => b.head.startsWith('@media'))
/** The declarations of the one plain rule whose selector text is exactly `sel`. */
const rule = sel => {
  const hits = plain.filter(b => b.head.split(',').map(s => s.trim()).includes(sel))
  assert.ok(hits.length >= 1, 'rule for ' + sel)
  return hits.map(h => h.body).join(';')
}
const alone = sel => plain.find(b => b.head === sel)

// ---------- 1. the fallback layer ----------
test('block: the fallback layer is position: fixed with inset: 0 and a z-index above the panel (101) and not above the leave guard (1000)', () => {
  const d = rule('.dep-tree[data-fullscreen="fallback"]')
  assert.ok(/position:\s*fixed\b/.test(d), 'position fixed')
  assert.ok(/inset:\s*0\s*(;|$)/.test(d), 'inset 0')
  const z = Number((d.match(/z-index:\s*(\d+)/) || [])[1])
  assert.ok(z > 101 && z <= 1000, 'z-index ' + z + ' is above 101 and not above 1000')
  // the real numbers the layer is measured against are still the ones in the stylesheets
  const history = fs.readFileSync(path.join(uiDir, 'src', 'components', 'history', 'history.css'), 'utf8')
  assert.ok(/\.detail-panel\s*\{[^}]*z-index:\s*101\b/.test(history), 'the overlay panel is still 101')
  const guard = fs.readFileSync(path.join(uiDir, 'src', 'components', 'leave-guard-modal.css'), 'utf8')
  assert.ok(/z-index:\s*1000\b/.test(guard), 'the leave guard is still 1000')
})

test('block: the fallback layer is opaque, on the surface token, with padding', () => {
  const d = rule('.dep-tree[data-fullscreen="fallback"]')
  assert.deepStrictEqual(d.match(/background[a-z-]*:\s*[^;]+/g), ['background: var(--color-surface)'], 'the one background is the surface token')
  assert.ok(!/opacity\s*:/.test(d), 'no opacity on the layer')
  assert.ok(!/background[^;]*(transparent|none|rgba?\()/.test(d), 'not transparent')
  assert.ok(/padding:\s*[\d.]+rem/.test(d), 'padding')
})

test('block: html[data-dt-fullscreen] locks the page scroll', () => {
  assert.ok(/overflow:\s*hidden/.test(rule('html[data-dt-fullscreen]')))
})

// ---------- 2. real fullscreen ----------
test('block: :fullscreen and :-webkit-full-screen each have a rule of their own with the surface background and padding', () => {
  for (const sel of ['.dep-tree:fullscreen', '.dep-tree:-webkit-full-screen']) {
    const own = plain.filter(b => b.head === sel)
    assert.strictEqual(own.length, 1, sel + ' is alone in its selector list, so an unknown pseudo does not drop the other')
    assert.ok(/background:\s*var\(--color-surface\)/.test(own[0].body), sel + ' surface background')
    assert.ok(/padding:\s*[\d.]+rem/.test(own[0].body), sel + ' padding')
  }
})

// ---------- 3. layout ----------
test('block: the large view is a column and the drawing fills the height (both modes, keyed to [data-fullscreen])', () => {
  const root = rule('.dep-tree[data-fullscreen]')
  assert.ok(/display:\s*flex/.test(root) && /flex-direction:\s*column/.test(root), 'column flex root')
  const zoom = rule('.dep-tree[data-fullscreen] .dt-zoom')
  assert.ok(/flex:\s*1\b/.test(zoom) && /min-height:\s*0/.test(zoom), 'the zoom box takes the room that is left')
  const vp = rule('.dep-tree[data-fullscreen] .dt-viewport')
  assert.ok(/flex:\s*1\b/.test(vp) && /height:\s*auto/.test(vp), 'the viewport fills instead of the overlay clamp()')
  assert.ok(!/clamp\(/.test(block), 'the overlay height is overridden, not repeated')
})

test('block: the ready list and the unlocked list are a compact strip that scrolls on its own and takes no room from the drawing by overlap', () => {
  for (const sel of ['.dep-tree[data-fullscreen] .dt-ready', '.dep-tree[data-fullscreen] .dt-unlocked']) {
    const d = rule(sel)
    assert.ok(/flex:\s*0 0 auto/.test(d), sel + ' keeps its own size')
    assert.ok(/max-height:/.test(d) && /overflow:\s*auto/.test(d), sel + ' is capped and scrolls')
    assert.ok(!/position:\s*(absolute|fixed)/.test(d), sel + ' stays in flow, so it cannot sit over the drawing')
  }
  assert.ok(!/\.dt-(ready|unlocked)[^{]*\{[^}]*position:\s*(absolute|fixed)/.test(block))
})

test('block: the controls and the tooltip keep their layer: no z-index on them is touched', () => {
  for (const b of plain) if (/z-index/.test(b.body)) assert.ok(/\[data-fullscreen="fallback"\]/.test(b.head), 'the only z-index of the block is the fallback layer: ' + b.head)
  assert.ok(/\.dt-zoom-controls\s*\{[^}]*z-index:\s*6/.test(before) && /\.dt-tip\s*\{[^}]*z-index:\s*5/.test(before))
})

// ---------- 4. the button and the hint ----------
test('block: .dt-fs-btn and .dt-fs-hint exist; the button is at least 32px, hovers like .dt-zbtn and has a 2px accent focus ring', () => {
  const btn = rule('.dep-tree .dt-fs-btn')
  assert.ok(/min-width:\s*32px/.test(btn) && /min-height:\s*32px/.test(btn), '32px target')
  assert.ok(/cursor:\s*pointer/.test(btn))
  const hover = rule('.dep-tree .dt-fs-btn:hover')
  const zoomHover = (before.match(/\.dt-zbtn:hover\s*\{([^}]*)\}/) || [])[1]
  assert.ok(zoomHover, '.dt-zbtn:hover exists')
  const norm = s => s.split(';').map(x => x.trim().replace(/\s+/g, ' ')).filter(Boolean).sort().join(';')
  assert.strictEqual(norm(hover), norm(zoomHover), 'hover is the zoom button hover')
  const ring = rule('.dep-tree .dt-fs-btn:focus-visible')
  assert.ok(/outline:\s*2px solid var\(--color-accent\)/.test(ring), 'focus ring is 2px of --color-accent')
  assert.ok(/outline-offset:\s*2px/.test(ring), 'offset 2px')
  assert.ok(!/outline:\s*(none|0)/.test(block), 'no rule removes an outline')
  assert.ok(plain.some(b => b.head.split(',').map(s => s.trim()).includes('.dep-tree .dt-fs-hint')), '.dt-fs-hint exists')
  assert.ok(/color:\s*var\(--color-text-muted\)/.test(rule('.dep-tree .dt-fs-hint')))
})

// ---------- 5. colours ----------
test('block: no hex, no functional colour and no colour name', () => {
  assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(block), 'hex literal')
  assert.ok(!/\b(rgb|rgba|hsl|hsla|hwb|lab|lch|oklab|oklch|color-mix|color)\(/.test(block), 'functional colour')
  assert.ok(!/\b(white|black|red|green|blue|gray|grey|yellow|orange|purple|currentcolor|transparent)\b\s*[;}]/i.test(block), 'colour name')
})

test('block: every colour value is a var(--color-*) token that tokens.css defines for the light and the dark theme', () => {
  const COLOUR_PROPS = /(^|[;\s])(color|background|background-color|border|border-color|border-top|border-right|border-bottom|border-left|outline|outline-color|fill|stroke|box-shadow|text-shadow|caret-color|accent-color)\s*:\s*([^;]*)/g
  let seen = 0
  for (const b of plain) {
    for (const m of b.body.matchAll(COLOUR_PROPS)) {
      const value = m[3].trim()
      if (/^(none|0|inherit|initial|unset)$/.test(value)) continue
      assert.ok(/var\(--color-[a-z-]+\)/.test(value), `${b.head} { ${m[2]}: ${value} } is not a colour token`)
      seen++
    }
  }
  assert.ok(seen >= 8, 'colour declarations found: ' + seen)
  const used = [...new Set([...block.matchAll(/var\((--[a-z0-9-]+)/g)].map(m => m[1]))]
  assert.ok(used.length >= 5 && used.every(t => t.startsWith('--color-')), 'the block uses colour tokens only: ' + used.join(' '))
  const t = strip(tokens)
  const tb = topLevel(t)
  const light = tb.filter(b => b.head === ':root').map(b => b.body).join('\n')
  const dark = tb.filter(b => /prefers-color-scheme:\s*dark/.test(b.head) || /data-theme="dark"/.test(b.head)).map(b => b.body).join('\n')
  for (const tok of used) {
    assert.ok(new RegExp(tok + '\\s*:').test(light), tok + ' defined for light')
    assert.ok(new RegExp(tok + '\\s*:').test(dark), tok + ' defined for dark')
  }
})

// ---------- 6. motion ----------
const MOTION = /(^|[\s;{])(animation|transition)(-[a-z-]+)?\s*:/
test('block: every transition and animation is inside prefers-reduced-motion: no-preference and starts at :root:not([data-motion="off"])', () => {
  const guard = media.filter(b => /^@media\s*\(prefers-reduced-motion:\s*no-preference\)$/.test(b.head))
  assert.strictEqual(guard.length, 1, 'one reduced-motion guard in the block')
  let guarded = 0
  for (const r of rulesOf(guard[0].body)) {
    if (!MOTION.test(r.decl)) continue
    for (const one of r.sel.split(',')) assert.ok(one.trim().startsWith(':root:not([data-motion="off"])'), 'not gated by data-motion: ' + one.trim())
    guarded++
  }
  assert.ok(guarded >= 1, 'the button hover transition is declared in the guard')
  for (const b of blocks) {
    if (guard.includes(b)) continue
    assert.ok(!MOTION.test(b.body), 'motion declaration outside the guard: ' + b.head)
  }
})

test('block: the base rules carry no transition or animation, and the block adds no keyframes', () => {
  for (const b of plain) assert.ok(!/\b(transition|animation)/.test(b.body), 'base rule with motion: ' + b.head)
  assert.ok(!/@keyframes/.test(block), 'no keyframes added')
  assert.ok(!/@media[^{]*prefers-reduced-motion:\s*reduce/.test(block), 'no reduce-only branch needed: the base state is the final state')
})

// ---------- 7. the overlay is untouched ----------
test('stylesheet: the overlay rules the large view overrides are still in place, before the block', () => {
  assert.ok(/\.dt-viewport\s*\{[^}]*height:\s*clamp\(18rem, 55vh, 40rem\)[^}]*touch-action:\s*none/.test(before), 'overlay viewport rule unchanged')
  assert.ok(/\.dt-ready\s*\{\s*margin-top:\s*12px/.test(before), 'overlay ready rule unchanged')
  assert.ok(/\.dt-unlocked\s*\{[^}]*margin-top:\s*8px/.test(before), 'overlay unlocked rule unchanged')
  assert.ok(before.indexOf('@keyframes dt-twinkle') > 0, 'the six keyframes are before the block')
  assert.ok(before.length > 5000, 'the block is appended, not a replacement')
})

console.log(`\n${n} passed`)
