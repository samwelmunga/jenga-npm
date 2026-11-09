import './architecture.css'
import { coverageRows, coverageSummaryText, coverageEmptyText } from './coverageOverlay.js'

// E83_S03_T04: read-only text view of the test coverage overlay. `nodes` and `coverage` come from
// `data.sad_map`. Locations are plain `file:line` text: no link, no click handler, no filter control.
export default function TestCoverageTable({ nodes, coverage }) {
  const covered = coverage && Number.isFinite(coverage.testCovered) ? coverage.testCovered : 0
  const rows = covered > 0 ? coverageRows(nodes) : []

  if (rows.length === 0) {
    return <p className="arch-empty">{coverageEmptyText(coverage)}</p>
  }

  const summary = coverageSummaryText(coverage)
  return (
    <div className="test-cov">
      {summary && <p className="test-cov-summary">{summary}</p>}
      <div className="dep-table-wrap">
        <table className="dep-table test-cov-table">
          <thead>
            <tr>
              <th>Node</th>
              <th>Type</th>
              <th>Test</th>
              <th>Location</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row, i) => (
              <tr key={`${row.nodeId}|${row.file}|${row.line}|${row.name}|${i}`}>
                <td>{row.nodeLabel}</td>
                <td className="test-cov-type">{row.type}</td>
                <td>{row.name}</td>
                <td className="test-cov-location">{`${row.file}:${row.line}`}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
