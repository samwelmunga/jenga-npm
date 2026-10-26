#!/usr/bin/env node
'use strict'
// E85_S03_T06: server-render test for FindingsTable. Zero test framework: bundles the component with
// esbuild (CSS import stubbed), renders it with react-dom/server and asserts on the HTML.
// Fixtures mirror the credential_findings shape in project/app/api/parsers/security.js.
// Run: node project/app/ui/scripts/findings-table.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'findings-table-')), 'bundle.cjs')
esbuild.buildSync({
  // The component uses hooks, so React and the renderer must come from the same bundle as the component
  // (a separately required React would be a second copy and break useState): re-export all three together.
  stdin: {
    contents: `
      import React from 'react'
      import { renderToStaticMarkup } from 'react-dom/server'
      export { default, filterFindings, sortFindings } from './src/components/security/FindingsTable.jsx'
      export { React, renderToStaticMarkup }
    `,
    resolveDir: uiDir,
    loader: 'jsx',
  },
  outfile: out,
  bundle: true,
  platform: 'node',
  format: 'cjs',
  jsx: 'automatic',
  nodePaths: [path.join(uiDir, 'node_modules')],
  loader: { '.css': 'empty' },
  logLevel: 'silent',
})
const mod = require(out)
const { React, renderToStaticMarkup } = mod
const FindingsTable = mod.default
const render = (data, initialFilter) => renderToStaticMarkup(React.createElement(FindingsTable, { data, initialFilter }))
const count = (html, needle) => html.split(needle).length - 1

const f = (skill, file, line, cls, verdict, reason, action, scope) =>
  ({ skill, file, line, class: cls, text: 'x', scope, verdict, reason, action })
const findings = [
  f('alpha', 'skills/alpha/SKILL.md', 12, 'dotenv-read', 'benign mention', 'documents the rule only', 'none', 'flagged'),
  f(null, 'scripts/tool.sh', 34, 'env-token', 'true read', 'reads the token value', 'reword', 'other'),
  f('beta', 'skills/beta/SKILL.md', 56, 'cat-secret', 'benign mention', 'prose mention', 'allow-list', 'flagged'),
  f('alpha', 'skills/alpha/scripts/run.sh', 7, 'env-token', 'true read', 'captures the value', 'reword', 'flagged'),
]
const data = {
  state: 'recorded', scan_date: '2026-10-24', command: 'scripts/scan-credential-patterns.sh --json', error: null,
  summary: { total: 4, by_skill: { alpha: 2, beta: 1 } },
  findings,
}

// Mixed fixture: every row renders with file, line, class, verdict, reason, action; summary equals row count.
{
  const html = render(data)
  assert.strictEqual(count(html, 'data-testid="findings-row"'), 4)
  for (const s of [
    'skills/alpha/SKILL.md', 'scripts/tool.sh', 'skills/beta/SKILL.md', 'skills/alpha/scripts/run.sh',
    '>12<', '>34<', '>56<', '>7<', 'dotenv-read', 'env-token', 'cat-secret',
    'documents the rule only', 'reads the token value', 'prose mention', 'captures the value',
    'reword', 'allow-list', '2026-10-24', 'scripts/scan-credential-patterns.sh --json',
  ]) assert.ok(html.includes(s), 'missing ' + s)
  assert.ok(html.includes('Total: <strong>4</strong>'))
  assert.ok(html.includes('<code>alpha</code>: 2') && html.includes('<code>beta</code>: 1'))
  assert.ok(html.includes('4 of 4 shown'))
  // by_skill counts add up to the rows that carry a skill; null-skill row has a blank skill cell.
  assert.ok(html.includes('<td class="findings-cell-skill"></td>'))
  assert.ok(!html.includes('>null<') && !html.includes('undefined'))
}

// true read rows are distinguishable (badge text AND row class) and listed first; order otherwise stable.
{
  const html = render(data)
  const verdicts = [...html.matchAll(/data-verdict="([^"]+)"/g)].map(m => m[1])
  assert.deepStrictEqual(verdicts, ['true read', 'true read', 'benign mention', 'benign mention'])
  assert.ok(/findings-badge-true-read">true read</.test(html))
  assert.ok(/findings-badge-benign">benign mention</.test(html))
  assert.strictEqual(count(html, 'findings-row-true-read'), 2)
  assert.ok(html.indexOf('scripts/tool.sh') < html.indexOf('skills/alpha/scripts/run.sh'))
  assert.ok(html.indexOf('skills/alpha/scripts/run.sh') < html.indexOf('skills/alpha/SKILL.md'))
  assert.ok(html.indexOf('skills/alpha/SKILL.md') < html.indexOf('skills/beta/SKILL.md'))
}

// Filter narrowing (pure helpers plus first-render initial state).
{
  assert.strictEqual(mod.filterFindings(findings, 'all').length, 4)
  assert.strictEqual(mod.filterFindings(findings, 'flagged').length, 3)
  assert.strictEqual(mod.filterFindings(findings, 'true-read').length, 2)
  const flagged = render(data, 'flagged')
  assert.strictEqual(count(flagged, 'data-testid="findings-row"'), 3)
  assert.ok(!flagged.includes('scripts/tool.sh') && flagged.includes('3 of 4 shown'))
  const reads = render(data, 'true-read')
  assert.strictEqual(count(reads, 'data-testid="findings-row"'), 2)
  assert.ok(!reads.includes('skills/beta/SKILL.md'))
  // The control carries static labels.
  assert.ok(reads.includes('All findings') && reads.includes('Flagged skills only') && reads.includes('True reads only'))
}

// Empty filter result and empty findings: explanatory sentence, no rows.
{
  const benignOnly = { ...data, findings: [findings[0]], summary: { total: 1, by_skill: { alpha: 1 } } }
  const html = render(benignOnly, 'true-read')
  assert.ok(html.includes('data-testid="findings-no-match"') && html.includes('No findings match this filter.'))
  assert.strictEqual(count(html, 'data-testid="findings-row"'), 0)
  const none = render({ ...data, findings: [], summary: { total: 0, by_skill: {} } })
  assert.ok(none.includes('No findings match this filter.') && none.includes('0 of 0 shown'))
}

// Never scanned (and null/undefined data): sentence naming the producing script, no table.
for (const d of [{ state: 'never-scanned', scan_date: null, command: null, summary: { total: 0, by_skill: {} }, findings: [], error: null }, null, undefined]) {
  const html = render(d)
  assert.ok(html.includes('data-testid="findings-never"'))
  assert.ok(html.includes('scripts/scan-credential-patterns.sh'))
  assert.strictEqual(count(html, '<table'), 0)
}

// Error state: message shown, role=alert, no never-scanned text.
{
  const html = render({ state: 'error', findings: [], summary: null, error: 'cannot parse credential-findings.json: Unexpected token' })
  assert.ok(html.includes('role="alert"') && html.includes('cannot parse credential-findings.json: Unexpected token'))
  assert.ok(!html.includes('data-testid="findings-never"'))
}

// Unknown verdict / action degrade to neutral badges with their own labels.
{
  const html = render({ ...data, findings: [f('a', 'x.md', 1, 'c', 'weird', 'r', 'odd', 'flagged')] })
  assert.ok(/findings-badge-unknown">weird</.test(html) && /findings-action-unknown">odd</.test(html))
}

// Optional note / outside_patterns is rendered when the payload carries one, absent otherwise.
{
  assert.ok(!render(data).includes('findings-note'))
  assert.ok(render({ ...data, note: 'three sites outside the pattern set' }).includes('three sites outside the pattern set'))
  assert.ok(render({ ...data, outside_patterns: ['site one', 'site two'] }).includes('site two'))
}

// Stylesheet: no hex / rgb / hsl / colour-keyword literal in findings-table.css.
{
  const css = fs.readFileSync(path.join(uiDir, 'src/components/security/findings-table.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
  assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(css), 'hex colour found')
  assert.ok(!/\b(rgb|rgba|hsl|hsla)\(/.test(css), 'rgb/hsl colour found')
  assert.ok(!/\b(white|black|red|green|blue|yellow|orange|gray|grey|purple|pink|silver|navy|teal|maroon|cyan|magenta)\b/i.test(css), 'colour keyword found')
}

console.log('findings-table.test.cjs: all assertions passed')
