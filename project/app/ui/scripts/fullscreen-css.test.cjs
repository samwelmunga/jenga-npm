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

// ---------- 8. E92_S13_T04: day and night for the castle designs hold in every place the tree is shown ----------
// The overlay, the large view (native fullscreen and the fixed fallback layer) and the --snapshot file all show the SAME root,
// .dep-tree (the large view only flips data-fullscreen on it), and the snapshot inlines this stylesheet and tokens.css with no
// script. So the day and night section works in all four exactly when it is rooted at .dep-tree, never keys off the large view,
// names no script, and keeps every movement in the one guard that data-motion="off" and reduce both close.
const DN_MARK = '/* day and night (E92_S13_T04)'
const DN_END_MARK = '/* end E92_S13_T04 */'
const dnAt = css.indexOf(DN_MARK)
const dnSection = strip(css.slice(dnAt, css.indexOf(DN_END_MARK)))
const dnBlocks = topLevel(dnSection)

test('day and night: the section is after the large-view block, closed by its end comment, and rooted at .dep-tree so the overlay, both large views and the snapshot all get it', () => {
  assert.ok(dnAt > endAt, 'the section follows the E92_S07_T06 block')
  assert.ok(css.indexOf(DN_END_MARK) > dnAt && css.indexOf(DN_MARK, dnAt + 1) === -1, 'one section, closed')
  const selectors = []
  for (const b of dnBlocks) {
    if (b.head.startsWith('@media')) for (const r of rulesOf(b.body)) selectors.push(...r.sel.split(','))
    else if (!b.head.startsWith('@')) selectors.push(...b.head.split(','))
  }
  assert.ok(selectors.length >= 30, 'rules found: ' + selectors.length)
  for (const sel of selectors.map(x => x.trim())) {
    assert.ok(/^(:root:not\(\[data-motion="off"\]\) )?\.dep-tree\b/.test(sel), 'rooted at the tree: ' + sel)
    assert.ok(!/data-fullscreen|data-dt-fullscreen|:fullscreen|:-webkit-full-screen/.test(sel), 'does not depend on the large view: ' + sel)
  }
  assert.ok(!/@import|url\(|<script|javascript:/.test(dnSection), 'no import, no url, no script: the snapshot needs nothing else')
})

test('day and night: the large view neither overrides nor repeats the scene: nothing in its block touches the scene classes', () => {
  assert.ok(!/\.dn-|\.dt-castle|\.cc-|\.cf-/.test(block), 'the E92_S07_T06 block leaves the scene alone')
  assert.ok(!/display\s*:\s*var\(--theme-/.test(block))
})

test('day and night: every movement of the castle goal is in one no-preference guard for a root without data-motion="off", for birds, flocks and twinkling stars', () => {
  const guard = dnBlocks.filter(b => /^@media\s*\(prefers-reduced-motion:\s*no-preference\)$/.test(b.head))
  assert.strictEqual(guard.length, 1)
  const moving = rulesOf(guard[0].body).filter(r => MOTION.test(r.decl))
  assert.ok(moving.length >= 8)
  for (const r of moving) for (const one of r.sel.split(',')) assert.ok(one.trim().startsWith(':root:not([data-motion="off"])'), 'gated: ' + one.trim())
  const all = rulesOf(guard[0].body).map(r => r.sel + '{' + r.decl).join('\n')
  for (const cls of ['.dn-bird', '.dn-flock', '.dn-star']) assert.ok(all.includes(cls + ' {') || all.includes(cls + '{') || all.includes(cls + ':'), cls + ' moves only in the guard')
  for (const b of dnBlocks) if (b !== guard[0]) assert.ok(!MOTION.test(b.body), 'movement outside the guard: ' + b.head)
  assert.ok(/animation:\s*dt-twinkle\b/.test(all), 'the stars use the existing dt-twinkle')
  assert.ok(!/@keyframes\s+[a-z-]*twinkle/.test(dnSection), 'no second twinkle keyframes')
})

test('day and night: the goal-reached birds and stars are drawn still when nothing moves: their base rules paint them and none hides them', () => {
  const base = dnBlocks.filter(b => !b.head.startsWith('@'))
  const decl = sel => base.filter(b => b.head.split(',').map(x => x.trim()).includes(sel)).map(b => b.body).join(';')
  assert.ok(/stroke:\s*var\(--dn-bird\)/.test(decl('.dep-tree .dn-bird')) && !/display:\s*none/.test(decl('.dep-tree .dn-bird')))
  assert.ok(/fill:\s*var\(--dn-twinkle\)/.test(decl('.dep-tree .dn-star')) && /fill-opacity:\s*0\.9/.test(decl('.dep-tree .dn-star')))
  for (const b of base) assert.ok(!/(^|[;\s])opacity\s*:\s*0(\.\d+)?\s*(;|$)/.test(b.body), 'no base rule fades anything out: ' + b.head)
  const tk = strip(tokens)
  for (const t of ['--theme-day-display', '--theme-night-display']) assert.strictEqual((tk.match(new RegExp(t + '\\s*:', 'g')) || []).length, 3, t + ' in the light block and both dark blocks')
})

// ---------- 9. E92_S13_T07: the seasons tree holds in every place the tree is shown, with its own stylesheet ----------
// The tree's rules are in seasons-tree.css (loaded by TreeGoal.jsx, bundled into the build and inlined by the --snapshot export), not
// appended to dependency-tree.css, so the sections of that file the tests above slice (the large view's block, the day and night
// section) are not touched. The tree is drawn inside the same .dep-tree root as everything else, so the overlay, both large views and
// the snapshot all show it; its rules are rooted there, key off no large-view attribute, name no script, and keep every movement in the
// one guard that data-motion="off" and reduce both close.
const treeCssRaw = fs.readFileSync(path.join(uiDir, 'src', 'components', 'progress', 'seasons-tree.css'), 'utf8')
const treeCss = strip(treeCssRaw)
const treeBlocks = topLevel(treeCss)

test('seasons tree: every rule is rooted at .dep-tree, none depends on the large view, none reads a script, import or url', () => {
  const selectors = []
  for (const b of treeBlocks) {
    if (b.head.startsWith('@media')) for (const r of rulesOf(b.body)) selectors.push(...r.sel.split(','))
    else if (!b.head.startsWith('@')) selectors.push(...b.head.split(','))
  }
  assert.ok(selectors.length >= 80, 'rules found: ' + selectors.length)
  for (const sel of selectors.map(x => x.trim())) {
    assert.ok(/^(:root:not\(\[data-motion="off"\]\) )?\.dep-tree\b/.test(sel), 'rooted at the tree: ' + sel)
    assert.ok(!/data-fullscreen|data-dt-fullscreen|:fullscreen|:-webkit-full-screen/.test(sel), 'does not depend on the large view: ' + sel)
  }
  assert.ok(!/@import|url\(|<script|javascript:/.test(treeCss), 'nothing else is needed in the snapshot')
  assert.ok(/\/\* end E92_S13_T07 \*\/\s*$/.test(treeCssRaw))
  assert.ok(!/\.tr-|\.dt-tree|--color-tree/.test(css), 'dependency-tree.css holds no tree rule: the slices of the tests above are unchanged')
})

test('seasons tree: every movement is in one no-preference guard for a root without data-motion="off"; nothing else moves; the goal-reached effects rest visible', () => {
  const guard = treeBlocks.filter(b => /^@media\s*\(prefers-reduced-motion:\s*no-preference\)$/.test(b.head))
  assert.strictEqual(guard.length, 1)
  const moving = rulesOf(guard[0].body).filter(r => MOTION.test(r.decl))
  assert.ok(moving.length >= 7)
  for (const r of moving) for (const one of r.sel.split(',')) assert.ok(one.trim().startsWith(':root:not([data-motion="off"])'), 'gated: ' + one.trim())
  for (const b of treeBlocks) if (b !== guard[0] && !b.head.startsWith('@keyframes')) assert.ok(!MOTION.test(b.body), 'movement outside the guard: ' + b.head)
  assert.ok(!/@media[^{]*prefers-reduced-motion:\s*reduce/.test(treeCss), 'no reduce-only branch needed: the base state is the final state')
  // reduced motion and the Animations toggle both leave the petals, motes, swing and spirits where they stand: no base rule hides them
  for (const b of treeBlocks.filter(x => !x.head.startsWith('@'))) {
    assert.ok(!/(^|[;\s])opacity\s*:\s*0(\.0+)?\s*(;|$)/.test(b.body) && !/display\s*:\s*none/.test(b.body) && !/visibility\s*:\s*hidden/.test(b.body), 'a base rule hides something: ' + b.head)
  }
  // the twinkle of the stars at goal reached is the shared dt-twinkle, the flap of the birds the shared one; the tree adds no second
  assert.ok(!/@keyframes\s+[a-z-]*(twinkle|flap)/.test(treeCss))
  assert.ok(/animation:\s*dt-twinkle\b/.test(strip(css)))
})

test('seasons tree: every tree colour is a token defined for light and dark, no colour literal in the stylesheet; the status ribbons use the E92 tokens', () => {
  assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(treeCss) && !/\b(rgb|rgba|hsl|hsla|hwb|lab|lch|oklab|oklch|color-mix)\(/.test(treeCss))
  const tk = strip(tokens)
  const used = [...new Set([...treeCss.matchAll(/var\((--color-[a-z-]+)\)/g)].map(m => m[1]))]
  assert.ok(used.length > 50, 'tokens in use: ' + used.length)
  for (const u of used) assert.strictEqual((tk.match(new RegExp(u + '\\s*:', 'g')) || []).length, 3, u + ': light, dark media block, dark attribute block')
  for (const r of ['done', 'in-progress', 'failed', 'pending']) assert.ok(used.includes('--color-progress-' + r), 'the E92 colour ' + r)
})

console.log(`\n${n} passed`)
