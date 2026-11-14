#!/usr/bin/env node
'use strict'
// E47_S08_T01: the theme check must fail when a colour keyword (or hex/rgb/hsl literal) is reintroduced
// in a stylesheet, and must not flag tokens, transparent, or white-space.
// E92_S03_T03: the progress-token check must fail when two of the five tokens are too close (for example
// rejected equal to pending) or a token is below 3:1 on --color-surface. Zero dependencies.
// Run: node project/app/ui/scripts/check-theme-contrast.test.cjs
const assert = require('assert')
const { findColourLiterals, deltaE76, checkProgressTokens, PROGRESS_TOKENS, PROGRESS_MIN_DELTA_E } = require('./check-theme-contrast.cjs')

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
console.log('check-theme-contrast.test: ok')
