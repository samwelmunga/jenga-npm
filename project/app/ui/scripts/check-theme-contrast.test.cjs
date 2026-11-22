#!/usr/bin/env node
'use strict'
// E47_S08_T01: the theme check must fail when a colour keyword (or hex/rgb/hsl literal) is reintroduced
// in a stylesheet, and must not flag tokens, transparent, or white-space.
// E92_S03_T03: the progress-token check must fail when two of the five tokens are too close (for example
// rejected equal to pending) or a token is below 3:1 on --color-surface. Zero dependencies.
// E92_S13_T04: the day and night guard fails when a token is missing from a theme, a display token is the wrong way round, or
// a bird, star, window or gate is below 3:1 against what it is drawn on.
// Run: node project/app/ui/scripts/check-theme-contrast.test.cjs
const assert = require('assert')
const { findColourLiterals, deltaE76, checkProgressTokens, PROGRESS_TOKENS, PROGRESS_MIN_DELTA_E, checkDayNightTokens, DAY_NIGHT_TOKENS, DAY_NIGHT_DISPLAY, checkTreeTokens, TREE_MIN_TOKENS } = require('./check-theme-contrast.cjs')

const hits = css => findColourLiterals(css).map(h => h.prop + ':' + h.value)

for (const bad of ['background: white;', 'background-color: Black;', 'color: red;', 'border: 1px solid gray;',
  'background: #fff;', 'color: rgb(0, 0, 0);', 'box-shadow: 0 1px 2px rgba(0,0,0,.2);', 'fill: hsl(10 10% 10%);'])
  assert.strictEqual(findColourLiterals('.x {\n  ' + bad + '\n}').length, 1, 'should flag: ' + bad)

for (const good of ['background: var(--color-surface);', 'color: inherit;', 'background: transparent;',
  'border: 1px solid var(--color-border);', 'white-space: nowrap;', 'color: var(--color-white-ish);',
  'box-shadow: 0 1px 2px var(--color-shadow);', 'background: url(red.png);'])
  assert.deepStrictEqual(hits('.x {\n  ' + good + '\n}'), [], 'should not flag: ' + good)

assert.deepStrictEqual(hits('/* background: white; */\n.x { color: var(--color-text); }'), [], 'comments are ignored')
assert.strictEqual(findColourLiterals('.a {\n}\n.b {\n  background: white;\n}')[0].line, 4, 'reports the line')
// ---- progress tokens (E92_S03_T03) ----
const failures = res => res.filter(r => !r.ok)
const palette = (surface, over) => Object.assign({ '--color-surface': surface }, over)
const lightGood = palette('#ffffff', { '--color-progress-done': '#15803d', '--color-progress-in-progress': '#b88200',
  '--color-progress-failed': '#b91c1c', '--color-progress-pending': '#6b7280', '--color-progress-rejected': '#5b8fc7' })
const darkGood = palette('#1a1d23', { '--color-progress-done': '#4ade80', '--color-progress-in-progress': '#facc15',
  '--color-progress-failed': '#f87171', '--color-progress-pending': '#9ca3af', '--color-progress-rejected': '#7ba3d6' })

assert.strictEqual(PROGRESS_TOKENS.length, 5, 'five progress tokens')
assert.strictEqual(deltaE76('#336699', '#336699'), 0, 'identical colours are 0 apart')
assert.ok(Math.abs(deltaE76('#000000', '#ffffff') - 100) < 0.1, 'black vs white is about 100')
assert.deepStrictEqual(failures(checkProgressTokens(lightGood, 'light')), [], 'a distinct light palette passes')
assert.deepStrictEqual(failures(checkProgressTokens(darkGood, 'dark')), [], 'a distinct dark palette passes')
// 5 contrast results + 10 pairs
assert.strictEqual(checkProgressTokens(lightGood, 'light').length, 15, 'checks 5 contrasts and all 10 pairs')

// The deliberate mutation: rejected equal to pending must fail, in both themes.
for (const [good, name, pend] of [[lightGood, 'light', '#6b7280'], [darkGood, 'dark', '#9ca3af']]) {
  const bad = Object.assign({}, good, { '--color-progress-rejected': pend })
  const f = failures(checkProgressTokens(bad, name))
  assert.ok(f.some(r => r.kind === 'distinct' && /pending vs .*rejected|rejected vs .*pending/.test(r.message)),
    name + ': rejected == pending must fail the distinctness check')
}
// A rejected that is only a slightly bluer grey is still too close.
assert.ok(deltaE76('#6b7280', '#64748b') < PROGRESS_MIN_DELTA_E, 'slate grey is within the threshold of the neutral grey')
assert.ok(failures(checkProgressTokens(Object.assign({}, lightGood, { '--color-progress-rejected': '#64748b' }), 'light'))
  .some(r => r.kind === 'distinct'), 'a near-grey rejected fails')

// 3:1 on the surface: a pale token on a white card fails.
assert.ok(failures(checkProgressTokens(Object.assign({}, lightGood, { '--color-progress-in-progress': '#fde68a' }), 'light'))
  .some(r => r.kind === 'contrast' && /in-progress/.test(r.message)), 'a pale token fails the 3:1 check')

// A missing token or surface is a failure, not a silent pass.
const noRej = Object.assign({}, lightGood); delete noRej['--color-progress-rejected']
assert.ok(failures(checkProgressTokens(noRej, 'light')).some(r => r.kind === 'missing'), 'a missing token fails')
const noSurface = Object.assign({}, lightGood); delete noSurface['--color-surface']
assert.ok(failures(checkProgressTokens(noSurface, 'light')).some(r => r.kind === 'missing'), 'a missing surface fails')
// ---- day and night tokens (E92_S13_T04) ----
const dnLight = {}
const dnDark = {}
for (const t of DAY_NIGHT_TOKENS) { dnLight[t] = '#808080'; dnDark[t] = '#808080' }
Object.assign(dnLight, { '--color-sky-bird': '#39414e', '--color-sky-bottom': '#f6f0e2', '--color-castle-gate': '#3d2b1c', '--color-castle-wall-l': '#e8c283' })
Object.assign(dnDark, { '--color-sky-top': '#0e1424', '--color-sky-star': '#cfd6e6', '--color-sky-twinkle': '#ffd27a', '--color-sky-moon': '#e9e4cf',
  '--color-castle-win-l': '#ffd27a', '--color-castle-end-l': '#575d72', '--color-castle-win-r': '#efb25a', '--color-castle-end-r': '#41475a',
  '--color-castle-gate': '#ffcc66', '--color-castle-wall-l': '#646b80' })
const dnDisplay = { light: { '--theme-day-display': 'inline', '--theme-night-display': 'none' }, dark: { '--theme-day-display': 'none', '--theme-night-display': 'inline' } }
const dnRun = (light, dark, display) => checkDayNightTokens({ light, dark, 'dark(media)': dark }, display)
assert.deepStrictEqual(failures(dnRun(dnLight, dnDark, dnDisplay)), [], 'a good day and night palette passes')
assert.deepStrictEqual(DAY_NIGHT_DISPLAY.light, { day: 'inline', night: 'none' })
// a token missing from one theme fails, and so does a missing one in the media block
const dnLess = Object.assign({}, dnDark); delete dnLess['--color-sky-star']
assert.ok(failures(dnRun(dnLight, dnLess, dnDisplay)).some(r => r.kind === 'defined' && /sky-star/.test(r.message)), 'a missing star colour fails')
// display tokens the wrong way round (a sun at night) fail
assert.ok(failures(dnRun(dnLight, dnDark, { light: dnDisplay.dark, dark: dnDisplay.light })).filter(r => r.kind === 'display').length === 2, 'swapped display tokens fail in both themes')
assert.ok(failures(dnRun(dnLight, dnDark, {})).some(r => r.kind === 'display'), 'absent display tokens fail')
// a bird that is the sky colour, a star as dark as the night sky, a window as dark as its wall fail
assert.ok(failures(dnRun(Object.assign({}, dnLight, { '--color-sky-bird': '#f0e8d8' }), dnDark, dnDisplay)).some(r => r.kind === 'contrast' && /sky-bird/.test(r.message)), 'an invisible bird fails')
assert.ok(failures(dnRun(dnLight, Object.assign({}, dnDark, { '--color-sky-star': '#101828' }), dnDisplay)).some(r => r.kind === 'contrast' && /sky-star/.test(r.message)), 'an invisible star fails')
assert.ok(failures(dnRun(dnLight, Object.assign({}, dnDark, { '--color-castle-win-l': '#5a6076' }), dnDisplay)).some(r => r.kind === 'contrast' && /win-l/.test(r.message)), 'a window that does not light up fails')
assert.ok(failures(dnRun(dnLight, Object.assign({}, dnDark, { '--color-castle-gate': '#646b80' }), dnDisplay)).some(r => r.kind === 'contrast' && /gate/.test(r.message)), 'an unlit gate fails')
// ---- the seasons tree's tokens (E92_S13_T07) ----
const treeBase = {}
for (let i = 0; i < TREE_MIN_TOKENS; i++) treeBase['--color-tree-t' + String.fromCharCode(97 + (i % 26)) + String.fromCharCode(97 + Math.floor(i / 26))] = '#808080'
const treeLight = Object.assign({}, treeBase, { '--color-tree-text': '#22302c', '--color-tree-pill': '#ffffff' })
const treeDark = Object.assign({}, treeBase, { '--color-tree-text': '#e6f2ee', '--color-tree-pill': '#0c1d26', '--color-tree-lantern': '#ffcf5a', '--color-tree-sky-top': '#0c1d26', '--color-tree-mote': '#d8ff8a', '--color-tree-sky-bottom': '#163a40' })
Object.assign(treeLight, { '--color-tree-lantern': '#ffcf5a', '--color-tree-sky-top': '#e6f5ee', '--color-tree-mote': '#ffe58a', '--color-tree-sky-bottom': '#a9dccb' })
const treeRun = (light, dark, media) => checkTreeTokens({ light, dark, 'dark(media)': media || dark })
assert.deepStrictEqual(failures(treeRun(treeLight, treeDark)), [], 'a good tree palette passes')
const treeLess = Object.assign({}, treeDark); delete treeLess['--color-tree-tta']
assert.ok(failures(treeRun(treeLight, treeLess)).some(r => r.kind === 'defined' && /missing/.test(r.message)), 'a tree token missing from the dark theme fails')
assert.ok(failures(treeRun(treeLight, treeDark, treeLess)).some(r => r.kind === 'defined'), 'and one missing from the media block')
assert.ok(failures(treeRun({ '--color-tree-text': '#fff' }, treeDark)).length > 0, 'too few tree tokens fail')
assert.ok(failures(treeRun(treeLight, Object.assign({}, treeDark, { '--color-tree-text': '#3a5a66' }))).some(r => r.kind === 'contrast' && /tree-text/.test(r.message)), 'label text that does not read on its pill fails')
assert.ok(failures(treeRun(treeLight, Object.assign({}, treeDark, { '--color-tree-lantern': '#17303a' }))).some(r => r.kind === 'contrast' && /lantern/.test(r.message)), 'an unlit lantern fails')
console.log('check-theme-contrast.test: ok')
