import './audits-panel.css'

/**
 * AuditsPanel — E85_S03_T05.
 *
 * Renders the `audits` object of `GET /v1/security` (shape documented in the header of
 * `project/app/api/parsers/security.js`):
 *   { state: 'recorded'|'never-audited'|'error', config, targets[], history[], error }
 * Every field may be null; `audits` itself may be null/undefined (treated like never-audited).
 * Every number, date, path and status label shown comes from the payload; only the static field
 * labels (Low, Threshold, ...) live here.
 *
 * History decision: the whole `history` (newest first, already capped by the API) is listed in a
 * collapsed <details>, including each directory's newest result that its target row also shows,
 * so the audit trail is never filtered.
 */

// status -> CSS modifier. Unknown statuses fall back to `unknown` and still show their own label.
const STATUS_CLASSES = {
  clean: 'audits-badge-clean',
  findings: 'audits-badge-findings',
  unavailable: 'audits-badge-unavailable',
  disabled: 'audits-badge-disabled',
}

const SEVERITIES = [
  ['low', 'Low'],
  ['moderate', 'Moderate'],
  ['high', 'High'],
  ['critical', 'Critical'],
  ['total', 'Total'],
]

const show = value => (value === null || value === undefined || value === '' ? '—' : String(value))

function StatusBadge({ status }) {
  const cls = STATUS_CLASSES[status] ?? 'audits-badge-unknown'
  return <span className={`audits-badge ${cls}`}>{show(status)}</span>
}

function Counts({ counts }) {
  return (
    <dl className="audits-counts">
      {SEVERITIES.map(([key, label]) => (
        <div key={key} className="audits-count">
          <dt>{label}</dt>
          <dd>{show(counts?.[key])}</dd>
        </div>
      ))}
    </dl>
  )
}

function ConfigLine({ config }) {
  if (!config) {
    return <p className="audits-config audits-note">No audit-config.json exists for this project.</p>
  }
  return (
    <p className="audits-config">
      <span>Mode: <strong>{show(config.mode)}</strong></span>
      <span>Severity threshold: <strong>{show(config.severity_threshold)}</strong></span>
      <span>Offline behavior: <strong>{show(config.offline_behavior)}</strong></span>
      <span>Production only: <strong>{show(config.production_only)}</strong></span>
    </p>
  )
}

function TargetRow({ target }) {
  return (
    <li className="audits-target" data-testid="audits-target">
      <div className="audits-target-head">
        <span className="audits-dir">{show(target.scanned_dir)}</span>
        <StatusBadge status={target.status} />
      </div>
      <Counts counts={target.counts} />
      <dl className="audits-meta">
        <div><dt>Threshold</dt><dd>{show(target.threshold)}</dd></div>
        <div><dt>Consent basis</dt><dd>{show(target.consent_basis)}</dd></div>
        <div><dt>Last consent</dt><dd>{show(target.last_consent_date)}</dd></div>
        <div><dt>Timestamp</dt><dd>{show(target.date)}</dd></div>
        {target.rapport && <div><dt>Rapport</dt><dd className="audits-path">{target.rapport}</dd></div>}
      </dl>
    </li>
  )
}

function History({ history }) {
  if (!history.length) return null
  return (
    <details className="audits-history" data-testid="audits-history">
      <summary>History ({history.length})</summary>
      <ul className="audits-history-list">
        {history.map((h, i) => (
          <li key={`${h.date}-${h.scanned_dir}-${i}`} className="audits-history-item">
            <span className="audits-history-date">{show(h.date)}</span>
            <span className="audits-dir">{show(h.scanned_dir)}</span>
            <StatusBadge status={h.status} />
            <span className="audits-history-total">Total: {show(h.counts?.total)}</span>
          </li>
        ))}
      </ul>
    </details>
  )
}

export default function AuditsPanel({ audits }) {
  const targets = Array.isArray(audits?.targets) ? audits.targets : []
  const history = Array.isArray(audits?.history) ? audits.history : []
  const state = audits?.state ?? 'never-audited'

  return (
    <div className="audits-panel" data-testid="audits-panel" data-state={state}>
      {audits && <ConfigLine config={audits.config} />}
      {state === 'error' && (
        <p className="audits-error" role="alert">
          Dependency audit data could not be read completely: {show(audits?.error)}
        </p>
      )}
      {state !== 'error' && (!audits || state === 'never-audited') && (
        <p className="audits-note" data-testid="audits-never">
          No dependency audit has been recorded yet. Audits are opt-in; see{' '}
          <code>project/documentation/security-audits.md</code>.
        </p>
      )}
      {targets.length > 0 && (
        <ul className="audits-targets">
          {targets.map((t, i) => (
            <TargetRow key={`${t.scanned_dir}-${i}`} target={t} />
          ))}
        </ul>
      )}
      <History history={history} />
    </div>
  )
}
