#!/usr/bin/env node
'use strict'
// E47_S07_T01: WCAG contrast check for the colour tokens in src/tokens.css.
// Zero dependencies. Exits non-zero if any checked pair is below 4.5:1.
const fs = require('fs')
const path = require('path')

const css = fs.readFileSync(path.join(__dirname, '..', 'src', 'tokens.css'), 'utf8')

// Extract the declarations of the light default (:root with color-scheme: light) and the
// explicit dark block (:root[data-theme="dark"]). The media-query block is asserted equal.
function block(re) {
  const m = css.match(re)
  if (!m) throw new Error('token block not found: ' + re)
  const out = {}
  for (const d of m[1].matchAll(/(--color-[a-z-]+)\s*:\s*(#[0-9a-fA-F]{6})\s*;/g)) out[d[1]] = d[2]
  return out
}
const light = block(/:root\s*\{\s*color-scheme:\s*light;([\s\S]*?)\n\}/)
const dark = block(/:root\[data-theme="dark"\]\s*\{([\s\S]*?)\n\}/)
const mediaDark = block(/prefers-color-scheme:\s*dark\)\s*\{\s*:root:not\(\[data-theme="light"\]\)\s*\{([\s\S]*?)\n  \}/)

function lum(hex) {
  const c = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map(v => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)))
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}
function ratio(a, b) {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p)
  return (x + 0.05) / (y + 0.05)
}

let failed = false
if (JSON.stringify(dark) !== JSON.stringify(mediaDark)) {
  console.log('FAIL  media-query dark block and [data-theme="dark"] block differ')
  failed = true
}
for (const [name, t] of [['light', light], ['dark', dark]]) {
  const pairs = []
  for (const fg of ['--color-text', '--color-text-muted'])
    for (const bg of ['--color-bg', '--color-surface', '--color-surface-alt']) pairs.push([fg, bg])
  for (const s of ['success', 'warning', 'danger', 'info', 'purple']) pairs.push([`--color-${s}`, `--color-${s}-bg`])
  pairs.push(['--color-accent-contrast', '--color-accent'])
  for (const [fg, bg] of pairs) {
    if (!t[fg] || !t[bg]) { console.log(`FAIL  ${name}: missing ${fg} or ${bg}`); failed = true; continue }
    const r = ratio(t[fg], t[bg])
    const ok = r >= 4.5
    if (!ok) failed = true
    console.log(`${ok ? 'ok  ' : 'FAIL'}  ${name.padEnd(5)} ${fg} on ${bg}: ${r.toFixed(2)}:1`)
  }
}
process.exit(failed ? 1 : 0)
