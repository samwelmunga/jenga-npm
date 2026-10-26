import { useState } from 'react'
import './findings-table.css'

/**
 * FindingsTable — E85_S03_T06.
 *
 * Renders the `credential_findings` object of `GET /v1/security` (shape documented in the header of
 * `project/app/api/parsers/security.js`):
 *   { state: 'recorded'|'never-scanned'|'error', scan_date, command, summary: { total, by_skill },
 *     findings: [{ skill, file, line, class, text, scope, verdict, reason, action }], error }
 * `credential_findings` itself may be null/undefined (treated like never-scanned). Every row, count,
 * date and command shown comes from the payload; only the static labels live here.
 *
 * Layout decision: the real data is ~50 rows (an estimated 60-120 at most), so a flat table in a
 * height-capped scroll box is used rather than PaginationControls / EntryList.
 * Ordering: `true read` rows first, otherwise the payload order (stable sort).
 * Optional extras: a string/array `note` or `outside_patterns` on the payload is rendered as a note.
 */

const SCANNER = 'scripts/scan-credential-patterns.sh'

const FILTERS = [
  ['all', 'All findings'],
  ['flagged', 'Flagged skills only'],
  ['true-read', 'True reads only'],
]

const VERDICT_CLASSES = {
  'true read': 'findings-badge-true-read',
  'benign mention': 'findings-badge-benign',
}

const ACTION_CLASSES = {
  reword: 'findings-action-reword',
  'allow-list': 'findings-action-allow-list',
  none: 'findings-action-none',
}

const show = value => (value === null || value === undefined || value === '' ? '—' : String(value))

const isTrueRead = f => f?.verdict === 'true read'

/** True reads first; otherwise keeps the payload order. */
export function sortFindings(findings) {
  return findings
    .map((f, i) => [f, i])
    .sort((a, b) => Number(isTrueRead(b[0])) - Number(isTrueRead(a[0])) || a[1] - b[1])
    .map(([f]) => f)
}

export function filterFindings(findings, mode) {
  if (mode === 'flagged') return findings.filter(f => f?.scope === 'flagged')
  if (mode === 'true-read') return findings.filter(isTrueRead)
  return findings
}

function Summary({ data, rows }) {
  const bySkill = Object.entries(data.summary?.by_skill ?? {})
  return (
    <div className="findings-summary" data-testid="findings-summary">
      <p className="findings-summary-line">
        <span>Scan date: <strong>{show(data.scan_date)}</strong></span>
        <span>Command: <code>{show(data.command)}</code></span>
        <span>Total: <strong>{show(data.summary?.total ?? rows)}</strong></span>
      </p>
      {bySkill.length > 0 && (
        <ul className="findings-by-skill" data-testid="findings-by-skill">
          {bySkill.map(([skill, n]) => (
            <li key={skill}><code>{skill}</code>: {show(n)}</li>
          ))}
        </ul>
      )}
    </div>
  )
}

function NoteLine({ data }) {
  const raw = data.note ?? data.outside_patterns
  const items = (Array.isArray(raw) ? raw : [raw]).filter(v => typeof v === 'string' && v !== '')
  if (items.length === 0) return null
  return (
    <ul className="findings-note" data-testid="findings-note">
      {items.map((n, i) => <li key={i}>{n}</li>)}
    </ul>
  )
}

function Row({ finding }) {
  const trueRead = isTrueRead(finding)
  const verdictCls = VERDICT_CLASSES[finding.verdict] ?? 'findings-badge-unknown'
  const actionCls = ACTION_CLASSES[finding.action] ?? 'findings-action-unknown'
  return (
    <tr
      className={`findings-row ${trueRead ? 'findings-row-true-read' : 'findings-row-benign'}`}
      data-testid="findings-row"
      data-verdict={show(finding.verdict)}
    >
      <td className="findings-cell-skill">{finding.skill ?? ''}</td>
      <td className="findings-cell-file">{show(finding.file)}</td>
      <td className="findings-cell-line">{show(finding.line)}</td>
      <td className="findings-cell-class">{show(finding.class)}</td>
      <td><span className={`findings-badge ${verdictCls}`}>{show(finding.verdict)}</span></td>
      <td className="findings-cell-reason">{show(finding.reason)}</td>
      <td><span className={`findings-action ${actionCls}`}>{show(finding.action)}</span></td>
    </tr>
  )
}

export default function FindingsTable({ data, initialFilter = 'all' }) {
  const [filter, setFilter] = useState(initialFilter)
  const state = data?.state ?? 'never-scanned'
  const findings = Array.isArray(data?.findings) ? data.findings : []

  if (state === 'error') {
    return (
      <div className="findings-panel" data-testid="findings-panel" data-state="error">
        <p className="findings-error" role="alert">
          Credential scan data could not be read: {show(data?.error)}
        </p>
      </div>
    )
  }
  if (!data || state === 'never-scanned') {
    return (
      <div className="findings-panel" data-testid="findings-panel" data-state="never-scanned">
        <p className="findings-empty" data-testid="findings-never">
          No credential scan is recorded yet. Run <code>{SCANNER}</code> to produce one.
        </p>
      </div>
    )
  }

  const rows = sortFindings(filterFindings(findings, filter))
  return (
    <div className="findings-panel" data-testid="findings-panel" data-state={state}>
      <Summary data={data} rows={findings.length} />
      <NoteLine data={data} />
      <div className="findings-controls">
        <label htmlFor="findings-filter">Show</label>
        <select
          id="findings-filter"
          data-testid="findings-filter"
          value={filter}
          onChange={e => setFilter(e.target.value)}
        >
          {FILTERS.map(([value, label]) => (
            <option key={value} value={value}>{label}</option>
          ))}
        </select>
        <span className="findings-shown" data-testid="findings-shown">
          {rows.length} of {findings.length} shown
        </span>
      </div>
      <div className="findings-scroll">
        <table className="findings-table" data-testid="findings-table">
          <thead>
            <tr>
              <th scope="col">Skill</th>
              <th scope="col">File</th>
              <th scope="col">Line</th>
              <th scope="col">Pattern class</th>
              <th scope="col">Verdict</th>
              <th scope="col">Reason</th>
              <th scope="col">Proposed action</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? (
              <tr>
                <td colSpan={7} className="findings-empty" data-testid="findings-no-match">
                  No findings match this filter.
                </td>
              </tr>
            ) : (
              rows.map((f, i) => <Row key={`${f.file}-${f.line}-${i}`} finding={f} />)
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
