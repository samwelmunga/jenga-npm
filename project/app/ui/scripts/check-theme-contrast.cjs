#!/usr/bin/env node
'use strict'
// E47_S07_T01: WCAG contrast check for the colour tokens in src/tokens.css.
// E47_S08_T01: also fails on any colour literal (named keyword such as `white`, hex, rgb()/hsl()) used as a
// colour value in a stylesheet other than tokens.css, so a card cannot pin itself to one theme.
// Zero dependencies. Exits non-zero if any checked pair is below 4.5:1 or a colour literal is found.
const fs = require('fs')
const path = require('path')

// ---- colour-literal scan (E47_S08_T01) ----
// Every colour-bearing declaration outside tokens.css must use var(--color-*), transparent, inherit,
// currentColor, none and the like. A named colour, hex, rgb()/hsl() literal pins one theme.
const NAMED = ('aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown ' +
  'burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod ' +
  'darkgray darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen ' +
  'darkslateblue darkslategray darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue ' +
  'firebrick floralwhite forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray green greenyellow grey honeydew ' +
  'hotpink indianred indigo ivory khaki lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan ' +
  'lightgoldenrodyellow lightgray lightgreen lightgrey lightpink lightsalmon lightseagreen lightskyblue lightslategray ' +
  'lightslategrey lightsteelblue lightyellow lime limegreen linen magenta maroon mediumaquamarine mediumblue mediumorchid ' +
  'mediumpurple mediumseagreen mediumslateblue mediumspringgreen mediumturquoise mediumvioletred midnightblue mintcream ' +
  'mistyrose moccasin navajowhite navy oldlace olive olivedrab orange orangered orchid palegoldenrod palegreen paleturquoise ' +
  'palevioletred papayawhip peachpuff peru pink plum powderblue purple rebeccapurple red rosybrown royalblue saddlebrown ' +
  'salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray slategrey snow springgreen steelblue tan ' +
  'teal thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen').split(' ')
const COLOR_PROP = new RegExp('^(background(-color|-image)?|color|border(-(top|right|bottom|left))?(-color)?|' +
  'outline(-color)?|fill|stroke|box-shadow|text-shadow|caret-color|accent-color|text-decoration(-color)?|' +
  'column-rule(-color)?|scrollbar-color)$')
const LITERAL = new RegExp('#[0-9a-fA-F]{3,8}\\b|\\b(rgba?|hsla?|hwb|lab|lch|oklab|oklch)\\(|(^|[^\\w-])(' +
  NAMED.join('|') + ')(?![\\w-])', 'i')

function cssFiles(dir) {
  const out = []
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name)
    if (e.isDirectory()) out.push(...cssFiles(full))
    else if (e.name.endsWith('.css') && e.name !== 'tokens.css') out.push(full)
  }
  return out
}

// Returns [{line, prop, value}] for each colour-literal declaration in a stylesheet's text.
function findColourLiterals(text) {
  const found = []
  // Blank comments out (keeping newlines) so prose in a comment cannot match and line numbers stay right.
  const stripped = text.replace(/\/\*[\s\S]*?\*\//g, m => m.replace(/[^\n]/g, ' '))
  stripped.split('\n').forEach((ln, i) => {
    for (const d of ln.matchAll(/([a-z-]+)\s*:\s*([^;{}]+)/gi)) {
      if (!COLOR_PROP.test(d[1].toLowerCase())) continue
      // Drop var(...) and url(...) bodies so a token or path name containing a colour word cannot match.
      const value = d[2].replace(/var\([^)]*\)/g, '').replace(/url\([^)]*\)/g, '')
      if (LITERAL.test(value)) found.push({ line: i + 1, prop: d[1], value: d[2].trim() })
    }
  })
  return found
}

module.exports = { findColourLiterals, cssFiles }

if (require.main === module) {
  const srcDir = path.join(__dirname, '..', 'src')
  const css = fs.readFileSync(path.join(srcDir, 'tokens.css'), 'utf8')

  // Extract the declarations of the light default (:root with color-scheme: light) and the
  // explicit dark block (:root[data-theme="dark"]). The media-query block is asserted equal.
  const block = re => {
    const m = css.match(re)
    if (!m) throw new Error('token block not found: ' + re)
    const out = {}
    for (const d of m[1].matchAll(/(--color-[a-z-]+)\s*:\s*(#[0-9a-fA-F]{6})\s*;/g)) out[d[1]] = d[2]
    return out
  }
  const light = block(/:root\s*\{\s*color-scheme:\s*light;([\s\S]*?)\n\}/)
  const dark = block(/:root\[data-theme="dark"\]\s*\{([\s\S]*?)\n\}/)
  const mediaDark = block(/prefers-color-scheme:\s*dark\)\s*\{\s*:root:not\(\[data-theme="light"\]\)\s*\{([\s\S]*?)\n  \}/)

  const lum = hex => {
    const c = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
      .map(v => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)))
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
  }
  const ratio = (a, b) => {
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
    // Status/accent text printed straight onto a card surface (board, kanban and spike cards).
    for (const s of ['success', 'warning', 'danger', 'info', 'purple', 'teal']) pairs.push([`--color-${s}`, '--color-surface'])
    for (const [fg, bg] of pairs) {
      if (!t[fg] || !t[bg]) { console.log(`FAIL  ${name}: missing ${fg} or ${bg}`); failed = true; continue }
      const r = ratio(t[fg], t[bg])
      const ok = r >= 4.5
      if (!ok) failed = true
      console.log(`${ok ? 'ok  ' : 'FAIL'}  ${name.padEnd(5)} ${fg} on ${bg}: ${r.toFixed(2)}:1`)
    }
  }

  let literals = 0
  for (const f of cssFiles(srcDir))
    for (const hit of findColourLiterals(fs.readFileSync(f, 'utf8'))) {
      console.log(`FAIL  colour literal in ${path.relative(srcDir, f)}:${hit.line}  ${hit.prop}: ${hit.value} (use a var(--color-*) token)`)
      literals++
    }
  if (literals) failed = true
  else console.log('ok    no colour literals outside tokens.css')

  process.exit(failed ? 1 : 0)
}
