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
      </aside>
    </>
  )
}
