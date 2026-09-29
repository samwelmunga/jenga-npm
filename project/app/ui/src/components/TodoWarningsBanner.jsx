import { useState, useEffect } from 'react'
import { get } from '../api/client'
import './components.css'

// Fetched once at the app shell level (mirrors App.jsx's own /v1/health fetch) rather than per-tab,
// since a malformed project/todo.md line is project-wide context, not specific to the Board or
// Active Sprint tab it happens to affect. A network/parse failure here is swallowed silently —
// this is an informational nice-to-have, never something that should block or error the dashboard.
export default function TodoWarningsBanner() {
  const [entries, setEntries] = useState([])

  useEffect(() => {
    get('/v1/todo-warnings')
      .then(data => setEntries(Array.isArray(data) ? data : []))
      .catch(() => {})
  }, [])

  if (entries.length === 0) return null

  return (
    <div className="todo-warnings-banner">
      <div className="todo-warnings-banner-title">
        ⚠ {entries.length} project/todo.md line{entries.length === 1 ? '' : 's'} won't be recognized as queued
      </div>
      <ul className="todo-warnings-banner-list">
        {entries.map(entry => (
          <li key={entry.line}>
            <span className="todo-warnings-banner-line">line {entry.line}:</span> {entry.text}
          </li>
        ))}
      </ul>
      <div className="todo-warnings-banner-hint">
        Expected shape: <code>&lt;mission title&gt;: &lt;E##_S##_T##&gt;</code> — the ref must be the
        last thing on the line, colon-preceded.
      </div>
    </div>
  )
}
