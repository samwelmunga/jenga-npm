#!/usr/bin/env node
'use strict'
// E85_S03_T05: server-render test for AuditsPanel. Zero test framework: bundles the component with
// esbuild (CSS import stubbed), renders it with react-dom/server and asserts on the HTML.
// Fixtures mirror project/app/api/parsers/security.test.js (same targets/history shape).
// Run: node project/app/ui/scripts/audits-panel.test.cjs
const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')

const uiDir = path.join(__dirname, '..')
const esbuild = require('esbuild')
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'audits-panel-')), 'bundle.cjs')
esbuild.buildSync({
  entryPoints: [path.join(uiDir, 'src/components/security/AuditsPanel.jsx')],
  outfile: out,
  bundle: true,
  platform: 'node',
  format: 'cjs',
  jsx: 'automatic',
  nodePaths: [path.join(uiDir, 'node_modules')],
  loader: { '.css': 'empty' },
  logLevel: 'silent',
})
const React = require(require.resolve('react', { paths: [uiDir] }))
const { renderToStaticMarkup } = require(require.resolve('react-dom/server', { paths: [uiDir] }))
const AuditsPanel = require(out).default
const render = audits => renderToStaticMarkup(React.createElement(AuditsPanel, { audits }))
const count = (html, needle) => html.split(needle).length - 1

const counts = (l, m, h, c) => ({ low: l, moderate: m, high: h, critical: c, total: l + m + h + c })
const config = { mode: 'ask', severity_threshold: 'high', offline_behavior: 'warn', production_only: false }
const aDirty = { scanned_dir: '/a', status: 'findings', threshold: 'high', counts: counts(1, 2, 3, 0), consent_basis: 'session-approval', date: '2026-10-20T10:05:00Z', rapport: '/r/audit-a.md', last_consent_date: '2026-10-20T10:00:00Z' }
const aClean = { scanned_dir: '/a', status: 'clean', threshold: 'high', counts: counts(0, 0, 0, 0), consent_basis: 'config-mode-on', date: '2026-10-22T10:05:00Z', rapport: null, last_consent_date: '2026-10-22T10:00:00Z' }
const bUnavail = { scanned_dir: '/b', status: 'unavailable', threshold: null, counts: counts(0, 0, 0, 0), consent_basis: null, date: '2026-10-21T09:00:00Z', rapport: null, last_consent_date: null }
const bDisabled = { ...bUnavail, status: 'disabled', date: '2026-10-23T09:00:00Z' }

// Recorded: one row per directory, with status, counts, threshold, consent basis, timestamp; then history.
{
  const html = render({
    state: 'recorded', config, error: null,
    targets: [bDisabled, aClean],
    history: [bDisabled, aClean, bUnavail, aDirty],
  })
  assert.strictEqual(count(html, 'data-testid="audits-target"'), 2)
  assert.ok(html.includes('data-state="recorded"'))
  for (const s of ['/a', '/b', 'clean', 'disabled', 'config-mode-on', '2026-10-22T10:05:00Z', '2026-10-23T09:00:00Z', 'high', '2026-10-22T10:00:00Z']) {
    assert.ok(html.includes(s), 'missing ' + s)
  }
  // Config header values come from the payload.
  assert.ok(html.includes('<strong>ask</strong>') && html.includes('<strong>warn</strong>') && html.includes('<strong>false</strong>'))
  // History present, below the targets, with every entry (4), including the older findings result and the rapport-bearing one.
  assert.ok(html.indexOf('audits-targets') < html.indexOf('data-testid="audits-history"'))
  assert.strictEqual(count(html, 'audits-history-item'), 4)
  assert.ok(html.includes('History (4)'))
  assert.ok(html.includes('2026-10-20T10:05:00Z') && html.includes('Total: 6'))
  // unavailable / disabled are their own label + class, never the clean class.
  assert.ok(/audits-badge-disabled">disabled</.test(html))
  assert.ok(/audits-badge-unavailable">unavailable</.test(html))
  assert.ok(/audits-badge-clean">clean</.test(html))
  // Missing values are a visible dash, not "null".
  assert.ok(!html.includes('>null<') && !html.includes('undefined'))
}

// findings target: counts and rapport path shown as plain text.
{
  const html = render({ state: 'recorded', config: null, error: null, targets: [aDirty], history: [aDirty] })
  assert.ok(/audits-badge-findings">findings</.test(html))
  assert.ok(html.includes('/r/audit-a.md') && !html.includes('href="/r/audit-a.md"'))
  assert.ok(html.includes('No audit-config.json exists'))
  assert.ok(html.includes('<dt>Critical</dt><dd>0</dd>') && html.includes('<dt>High</dt><dd>3</dd>') && html.includes('<dt>Total</dt><dd>6</dd>'))
}

// Never audited (and null/undefined audits): explanatory text, no rows.
for (const audits of [{ state: 'never-audited', config: null, targets: [], history: [], error: null }, null, undefined]) {
  const html = render(audits)
  assert.ok(html.includes('data-testid="audits-never"'))
  assert.ok(html.includes('opt-in') && html.includes('project/documentation/security-audits.md'))
  assert.strictEqual(count(html, 'data-testid="audits-target"'), 0)
}

// Error state: message shown, role=alert, rest of the data still rendered; no never-audited text.
{
  const html = render({ state: 'error', config: null, targets: [aClean], history: [aClean], error: 'Unexpected token } in audit-config.json' })
  assert.ok(html.includes('role="alert"') && html.includes('Unexpected token } in audit-config.json'))
  assert.ok(!html.includes('data-testid="audits-never"'))
  assert.strictEqual(count(html, 'data-testid="audits-target"'), 1)
}

// Unknown status degrades to a neutral badge with its own label.
{
  const html = render({ state: 'recorded', config: null, error: null, targets: [{ ...aClean, status: 'weird' }], history: [] })
  assert.ok(/audits-badge-unknown">weird</.test(html))
}

// Stylesheet: no hex / rgb / hsl / colour-keyword literal in audits-panel.css.
{
  const css = fs.readFileSync(path.join(uiDir, 'src/components/security/audits-panel.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
  assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(css), 'hex colour found')
  assert.ok(!/\b(rgb|rgba|hsl|hsla)\(/.test(css), 'rgb/hsl colour found')
  assert.ok(!/\b(white|black|red|green|blue|yellow|orange|gray|grey|purple|pink|silver|navy|teal|maroon|cyan|magenta)\b/i.test(css), 'colour keyword found')
}

console.log('audits-panel.test.cjs: all assertions passed')
