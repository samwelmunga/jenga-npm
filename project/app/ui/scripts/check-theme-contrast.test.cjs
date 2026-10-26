#!/usr/bin/env node
'use strict'
// E47_S08_T01: the theme check must fail when a colour keyword (or hex/rgb/hsl literal) is reintroduced
// in a stylesheet, and must not flag tokens, transparent, or white-space. Zero dependencies.
// Run: node project/app/ui/scripts/check-theme-contrast.test.cjs
const assert = require('assert')
const { findColourLiterals } = require('./check-theme-contrast.cjs')

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
console.log('check-theme-contrast.test: ok')
