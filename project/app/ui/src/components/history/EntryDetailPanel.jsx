import { useEffect, useRef } from 'react'
import { marked } from 'marked'
import DOMPurify from 'dompurify'
import './history.css'

function formatDate(iso) {
  if (!iso) return '—'
  return new Intl.DateTimeFormat(undefined, {
    year: 'numeric',
    month: 'long',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(iso))
}

function renderMarkdown(md) {
  if (!md) return ''
  return DOMPurify.sanitize(marked.parse(md))
}

// E06_S07_T01 — board-item overlay. Board entries are wrapped as
// `{ type: 'board_item', kind: 'epic' | 'story' | 'task', ...item }` by
// BoardView.jsx's onSelect handler, where `...item` is the raw epic/story/task
// object returned by GET /v1/board (including its `_content` markdown body).
const BOARD_KIND_LABELS = {
  epic: 'Epic',
  story: 'Story',
  task: 'Task',
}

// E58_S01_T06 — generic "markdown library" entry overlay, consumed by E58_S02 (Rapports) and
// E58_S03 (Documentation). Raw entries from `readRapportsFull()`/`readDocumentation()` are shaped
// `{ file, data, content, category, date }` with no `type` field of their own — the consuming tab
// wraps the selected entry before handing it here, mirroring this file's existing `board_item`
// precedent from `BoardView.jsx`:
//   onSelect={entry => setSelected({ type: 'library_entry', ...entry })}
// See `../shared/EntryListItem.jsx` for the full entry-shape contract.

export default function EntryDetailPanel({ entry, onClose }) {
  const panelRef = useRef(null)

  useEffect(() => {
    if (!entry) return
    const onKey = e => { if (e.key === 'Escape') onClose() }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [entry, onClose])

  if (!entry) return null

  return (
    <>
      <div className="panel-backdrop" onClick={onClose} aria-hidden="true" />
      <aside className="detail-panel" ref={panelRef} aria-label="Entry details">
        <button className="panel-close" onClick={onClose} aria-label="Close">✕</button>

        {entry.type === 'git_commit' && (
          <>
            <h3 className="panel-title">Commit</h3>
            <dl className="panel-meta">
              <dt>SHA</dt>
              <dd><code>{entry.sha}</code></dd>
              <dt>Author</dt>
              <dd>{entry.author || '—'}</dd>
              <dt>Date</dt>
              <dd>{formatDate(entry.date)}</dd>
            </dl>
            <h4>Subject</h4>
            <p className="panel-subject">{entry.subject}</p>
            {entry.body && (
              <>
                <h4>Message</h4>
                <pre className="panel-body">{entry.body}</pre>
              </>
            )}
          </>
        )}

        {entry.type === 'rapport' && (
          <>
            <h3 className="panel-title">Rapport</h3>
            <dl className="panel-meta">
              <dt>File</dt>
              <dd>{entry.filename || '—'}</dd>
              <dt>Date</dt>
              <dd>{formatDate(entry.date)}</dd>
            </dl>
            {entry.content_summary ? (
              <div
                className="markdown-body"
                dangerouslySetInnerHTML={{ __html: renderMarkdown(entry.content_summary) }}
              />
            ) : (
              <p className="panel-empty">No content available.</p>
            )}
          </>
        )}

        {entry.type === 'board_item' && (
          <>
            <h3 className="panel-title">{BOARD_KIND_LABELS[entry.kind] || entry.kind}</h3>
            <dl className="panel-meta">
              <dt>ID</dt>
              <dd><code>{entry.id}</code></dd>
              <dt>Status</dt>
              <dd>{entry.status || '—'}</dd>
            </dl>
            <h4>{entry.title}</h4>
            {entry._content ? (
              <div
                className="markdown-body"
                dangerouslySetInnerHTML={{ __html: renderMarkdown(entry._content) }}
              />
            ) : (
              <p className="panel-empty">No content available.</p>
            )}
          </>
        )}

        {entry.type === 'library_entry' && (
          <>
            <h3 className="panel-title">{entry.category || 'Entry'}</h3>
            <dl className="panel-meta">
              <dt>File</dt>
              <dd>{entry.file || '—'}</dd>
              <dt>Category</dt>
              <dd>{entry.category || '—'}</dd>
              <dt>Date</dt>
              <dd>{formatDate(entry.date)}</dd>
            </dl>
            {entry.content ? (
              <div
                className="markdown-body"
                dangerouslySetInnerHTML={{ __html: renderMarkdown(entry.content) }}
              />
            ) : (
              <p className="panel-empty">No content available.</p>
            )}
          </>
        )}
      </aside>
    </>
  )
}
