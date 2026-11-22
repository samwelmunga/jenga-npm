#!/usr/bin/env node
'use strict'
// E47_S07_T01: WCAG contrast check for the colour tokens in src/tokens.css.
// E47_S08_T01: also fails on any colour literal (named keyword such as `white`, hex, rgb()/hsl()) used as a
// colour value in a stylesheet other than tokens.css, so a card cannot pin itself to one theme.
// E92_S03_T03: also guards the five --color-progress-* tokens (see PROGRESS_* below).
// E92_S13_T04: also guards the day and night tokens of the goal designs (see DAY_NIGHT_* below).
// E92_S13_T07: also guards the seasons tree's --color-tree-* tokens (see TREE_* below).
// Zero dependencies. Exits non-zero if any checked pair is below 4.5:1, a progress token is not distinct or below
// 3:1 on the card surface, or a colour literal is found.
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

// ---- WCAG contrast (shared by the text-pair checks and the progress-token check) ----
const lum = hex => {
  const c = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map(v => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)))
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}
const ratio = (a, b) => {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p)
  return (x + 0.05) / (y + 0.05)
}

// ---- progress tokens (E92_S03_T03) ----
// The pies and the pipeline diagram colour a slice by status using these five tokens and nothing else
// (E92 decisions 2 and 3: green done, yellow in-progress, red Failed/Blocked, grey pending, muted blue-grey
// Rejected, which must never read as any of the other four).
//
// Distinctness metric: CIE76 colour difference, delta E*ab = Euclidean distance between the two colours in
// CIE L*a*b* (sRGB -> linear -> XYZ with the D65 white point -> L*a*b*). Every pair of the five tokens, in each
// theme, must be at least PROGRESS_MIN_DELTA_E apart. A delta E of about 2.3 is one just-noticeable difference, so
// 20 is a clear, categorical difference (adjacent slices and legend swatches cannot be mistaken for each other),
// while still being reachable for a muted blue-grey next to a neutral grey. Contrast metric: WCAG 2.x relative
// luminance ratio of each token against --color-surface (the card the pie sits on), at least PROGRESS_MIN_CONTRAST
// (3:1, the WCAG non-text contrast level for graphical objects).
const PROGRESS_TOKENS = ['done', 'in-progress', 'failed', 'pending', 'rejected'].map(n => `--color-progress-${n}`)
const PROGRESS_MIN_DELTA_E = 20
const PROGRESS_MIN_CONTRAST = 3

function hexToLab(hex) {
  const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map(v => (v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)))
  const x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
  const y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
  const z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
  const f = t => (t > 216 / 24389 ? Math.cbrt(t) : (24389 / 27 * t + 16) / 116)
  const [fx, fy, fz] = [f(x), f(y), f(z)]
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
}
function deltaE76(hexA, hexB) {
  const a = hexToLab(hexA), b = hexToLab(hexB)
  return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2])
}

// Returns [{ok, kind, message}] for one theme's token map (token name -> #rrggbb).
function checkProgressTokens(theme, themeName) {
  const out = []
  const surface = theme['--color-surface']
  const present = PROGRESS_TOKENS.filter(tk => {
    if (theme[tk]) return true
    out.push({ ok: false, kind: 'missing', message: `${themeName}: missing ${tk}` })
    return false
  })
  if (!surface) out.push({ ok: false, kind: 'missing', message: `${themeName}: missing --color-surface` })
  else for (const tk of present) {
    const r = ratio(theme[tk], surface)
    out.push({ ok: r >= PROGRESS_MIN_CONTRAST, kind: 'contrast',
      message: `${themeName.padEnd(5)} ${tk} on --color-surface: ${r.toFixed(2)}:1 (min ${PROGRESS_MIN_CONTRAST}:1)` })
  }
  for (let i = 0; i < present.length; i++)
    for (let j = i + 1; j < present.length; j++) {
      const d = deltaE76(theme[present[i]], theme[present[j]])
      out.push({ ok: d >= PROGRESS_MIN_DELTA_E, kind: 'distinct',
        message: `${themeName.padEnd(5)} ${present[i]} vs ${present[j]}: delta E76 ${d.toFixed(1)} (min ${PROGRESS_MIN_DELTA_E})` })
    }
  return out
}

// ---- day and night tokens (E92_S13_T04) ----
// Day is the light theme and night the dark one. Every goal design that has a sky (the citadel, the facade and, in
// E92_S13_T07, the seasons tree) draws its sun, moon, stars, birds and lit windows from these tokens and shows the day half or the
// night half with the two display tokens, so a token missing from a theme, or a display token the wrong way round, would draw a
// sun at night or no stars. Three guards: (1) every token below is defined in the light block, the dark block and the media block
// (the dark/media parity above then keeps those two equal); (2) the display tokens are inline/none in the light theme and
// none/inline in the dark one; (3) what is drawn against another colour keeps 3:1 (WCAG non-text contrast) in the theme it is
// shown in: the bird on the day sky, the stars and moon on the night sky, the lit window on the night wood and the lit gate on
// the night wall (and the dark gate on the day wall). A later design appends its own tokens to DAY_NIGHT_TOKENS and its own
// pairs to DAY_NIGHT_PAIRS; it never copies the checks.
const DAY_NIGHT_TOKENS = ['--color-castle-win-l', '--color-castle-win-r', '--color-sky-top', '--color-sky-bottom', '--color-sky-sun',
  '--color-sky-sun-ray', '--color-sky-moon', '--color-sky-star', '--color-sky-twinkle', '--color-sky-bird']
const DAY_NIGHT_DISPLAY = { light: { day: 'inline', night: 'none' }, dark: { day: 'none', night: 'inline' } }
const DAY_NIGHT_MIN_CONTRAST = 3
// [theme it is shown in, foreground token, background token]
const DAY_NIGHT_PAIRS = [
  ['light', '--color-sky-bird', '--color-sky-bottom'],
  ['light', '--color-castle-gate', '--color-castle-wall-l'],
  ['dark', '--color-sky-star', '--color-sky-top'],
  ['dark', '--color-sky-twinkle', '--color-sky-top'],
  ['dark', '--color-sky-moon', '--color-sky-top'],
  ['dark', '--color-castle-win-l', '--color-castle-end-l'],
  ['dark', '--color-castle-win-r', '--color-castle-end-r'],
  ['dark', '--color-castle-gate', '--color-castle-wall-l'],
]

// `blocks` is { light, dark, mediaDark }: each the token map of that block ({ '--x': '#rrggbb' }); `display` is the same shape
// for the display tokens ({ '--theme-day-display': 'inline' }). Returns [{ ok, kind, message }].
function checkDayNightTokens(blocks, display) {
  const out = []
  for (const [name, t] of Object.entries(blocks)) {
    const missing = DAY_NIGHT_TOKENS.filter(k => !t[k])
    out.push({ ok: missing.length === 0, kind: 'defined', message: `${name.padEnd(9)} day and night tokens defined` + (missing.length ? ` (missing: ${missing.join(' ')})` : ` (${DAY_NIGHT_TOKENS.length})`) })
  }
  for (const [theme, want] of Object.entries(DAY_NIGHT_DISPLAY)) {
    const d = (display && display[theme]) || {}
    const ok = d['--theme-day-display'] === want.day && d['--theme-night-display'] === want.night
    out.push({ ok, kind: 'display', message: `${theme.padEnd(5)} --theme-day-display ${d['--theme-day-display']}, --theme-night-display ${d['--theme-night-display']} (want ${want.day} / ${want.night})` })
  }
  for (const [theme, fg, bg] of DAY_NIGHT_PAIRS) {
    const t = blocks[theme] || {}
    if (!t[fg] || !t[bg]) { out.push({ ok: false, kind: 'contrast', message: `${theme.padEnd(5)} missing ${fg} or ${bg}` }); continue }
    const r = ratio(t[fg], t[bg])
    out.push({ ok: r >= DAY_NIGHT_MIN_CONTRAST, kind: 'contrast', message: `${theme.padEnd(5)} ${fg} on ${bg}: ${r.toFixed(2)}:1 (min ${DAY_NIGHT_MIN_CONTRAST}:1)` })
  }
  return out
}

// ---- the seasons tree's tokens (E92_S13_T07) ----
// The tree has about 70 `--color-tree-*` tokens of its own (sky, forest, pool, island, bark, snow, seven season tones, blossom,
// withered, flowers, label pill). Two guards: (1) the set of names is the same in the light block, the dark block and the media
// block (a token missing from a theme draws nothing in it, the same way a missing sky token would); (2) the label text keeps 4.5:1
// on its pill in both themes (it is text), and the lit lantern keeps 3:1 on the night sky (non-text contrast).
// [theme it is shown in, foreground token, background token, minimum ratio]
const TREE_PAIRS = [
  ['light', '--color-tree-text', '--color-tree-pill', 4.5],
  ['dark', '--color-tree-text', '--color-tree-pill', 4.5],
  ['dark', '--color-tree-lantern', '--color-tree-sky-top', 3],
  ['dark', '--color-tree-mote', '--color-tree-sky-bottom', 3],
]
const TREE_PREFIX = '--color-tree-'
const TREE_MIN_TOKENS = 60

// `blocks` is { light, dark, mediaDark }: each the token map of that block. Returns [{ ok, kind, message }].
function checkTreeTokens(blocks) {
  const out = []
  const names = t => Object.keys(t || {}).filter(k => k.startsWith(TREE_PREFIX)).sort()
  const light = names(blocks.light)
  out.push({ ok: light.length >= TREE_MIN_TOKENS, kind: 'defined', message: `light     ${light.length} tree tokens defined (min ${TREE_MIN_TOKENS})` })
  for (const [name, t] of Object.entries(blocks)) {
    if (name === 'light') continue
    const have = new Set(names(t))
    const missing = light.filter(k => !have.has(k))
    const extra = [...have].filter(k => !light.includes(k))
    out.push({ ok: missing.length === 0 && extra.length === 0, kind: 'defined', message: `${name.padEnd(9)} tree tokens match the light block` + (missing.length ? ` (missing: ${missing.join(' ')})` : '') + (extra.length ? ` (extra: ${extra.join(' ')})` : '') })
  }
  for (const [theme, fg, bg, min] of TREE_PAIRS) {
    const t = blocks[theme] || {}
    if (!t[fg] || !t[bg]) { out.push({ ok: false, kind: 'contrast', message: `${theme.padEnd(5)} missing ${fg} or ${bg}` }); continue }
    const r = ratio(t[fg], t[bg])
    out.push({ ok: r >= min, kind: 'contrast', message: `${theme.padEnd(5)} ${fg} on ${bg}: ${r.toFixed(2)}:1 (min ${min}:1)` })
  }
  return out
}

module.exports = { findColourLiterals, cssFiles, hexToLab, deltaE76, ratio, checkProgressTokens,
  PROGRESS_TOKENS, PROGRESS_MIN_DELTA_E, PROGRESS_MIN_CONTRAST,
  checkDayNightTokens, DAY_NIGHT_TOKENS, DAY_NIGHT_DISPLAY, DAY_NIGHT_PAIRS, DAY_NIGHT_MIN_CONTRAST,
  checkTreeTokens, TREE_PAIRS, TREE_MIN_TOKENS }

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
  for (const [name, t] of [['light', light], ['dark', dark]])
    for (const res of checkProgressTokens(t, name)) {
      if (!res.ok) failed = true
      console.log(`${res.ok ? 'ok  ' : 'FAIL'}  ${res.message}`)
    }

  // the display tokens are not colours: read them from the same three blocks
  const displayOf = re => {
    const m = css.match(re)
    if (!m) throw new Error('token block not found: ' + re)
    const out = {}
    for (const d of m[1].matchAll(/(--theme-(?:day|night)-display)\s*:\s*([a-z]+)\s*;/g)) out[d[1]] = d[2]
    return out
  }
  const display = {
    light: displayOf(/:root\s*\{\s*color-scheme:\s*light;([\s\S]*?)\n\}/),
    dark: displayOf(/:root\[data-theme="dark"\]\s*\{([\s\S]*?)\n\}/),
  }
  const displayMedia = displayOf(/prefers-color-scheme:\s*dark\)\s*\{\s*:root:not\(\[data-theme="light"\]\)\s*\{([\s\S]*?)\n  \}/)
  if (JSON.stringify(display.dark) !== JSON.stringify(displayMedia)) {
    console.log('FAIL  media-query dark block and [data-theme="dark"] block differ in the --theme-*-display tokens')
    failed = true
  }
  for (const res of checkDayNightTokens({ light, dark, 'dark(media)': mediaDark }, display)) {
    if (!res.ok) failed = true
    console.log(`${res.ok ? 'ok  ' : 'FAIL'}  ${res.message}`)
  }

  for (const res of checkTreeTokens({ light, dark, 'dark(media)': mediaDark })) {
    if (!res.ok) failed = true
    console.log(`${res.ok ? 'ok  ' : 'FAIL'}  ${res.message}`)
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
