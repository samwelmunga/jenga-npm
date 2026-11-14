import { useEffect, useMemo, useState } from 'react'
import { get } from '../../api/client'
import useTodoSelection from '../../hooks/useTodoSelection'
import useTodoTags from '../../hooks/useTodoTags'
import { copyText } from './clipboard'
import { applyMark, flattenBoard, formatJengaCommand, groupOptions, joinTodo, tagsForRef } from './todoModel'

// E47_S10_T03 - body of the todo bubble panel. Mounted only while the panel is open, so the fetch happens on open.

// Pure view, so it can be rendered server-side in the test.
export function TodoListView({
  rows, ticks, onToggle, showTerminal, onShowTerminal, error, loading,
  tags = {}, group = '', onGroup = () => {}, onCreateTag = () => {}, tagMessage = '',
  mode = 'mark', onMode = () => {}, onApply = () => {}, onCopy = () => {}, copyState = '',
}) {
  if (error) return <p role="alert" className="todo-panel-note">Could not load the todo list.</p>
  if (loading) return <p className="todo-panel-note">Loading...</p>
  return (
    <div className="todo-panel">
      <label className="todo-panel-filter">
        <input type="checkbox" checked={showTerminal} onChange={e => onShowTerminal(e.target.checked)} />
        Show finished
      </label>
      <TagControls tags={tags} group={group} onGroup={onGroup} onCreateTag={onCreateTag} tagMessage={tagMessage} />
      <MarkControls mode={mode} onMode={onMode} onApply={onApply} onCopy={onCopy} copyState={copyState} canCopy={ticks.length > 0} />
      {rows.length === 0 ? (
        <p className="todo-panel-note">Nothing queued.</p>
      ) : (
        <ul className="todo-list">
          {rows.map(row => (
            <li key={row.ref} className={`todo-row${row.unresolved ? ' todo-row-unresolved' : ''}`}>
              <label className="todo-row-label">
                <input
                  type="checkbox"
                  checked={ticks.includes(row.ref)}
                  onChange={() => onToggle(row.ref)}
                  aria-label={`Select ${row.id}${row.title ? ': ' + row.title : ''}`}
                />
                <span className="todo-row-id">{row.id}</span>
                <span className="todo-row-title">{row.title}</span>
                <span className="todo-row-status">{row.status}</span>
                {tagsForRef(tags, row.ref).length > 0 && (
                  <span className="todo-row-tags">
                    {tagsForRef(tags, row.ref).map(t => <span key={t} className="todo-tag">{t}</span>)}
                  </span>
                )}
              </label>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export const COPY_LABELS = { copied: 'Copied', failed: 'Copy failed' }

function MarkControls({ mode, onMode, onApply, onCopy, copyState, canCopy }) {
  return (
    <div className="todo-mark">
      <select value={mode} onChange={e => onMode(e.target.value)} aria-label="Mark or unmark">
        <option value="mark">Mark</option>
        <option value="unmark">Unmark</option>
      </select>
      <button type="button" className="todo-tag-add" onClick={onApply}>Apply</button>
      <button
        type="button"
        className="todo-copy"
        onClick={onCopy}
        disabled={!canCopy}
        aria-label="Copy /jenga command for ticked rows"
        title="Copy /jenga command"
      >
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" strokeWidth="1.5">
          <rect x="5" y="5" width="8" height="9" rx="1" /><path d="M3 11V3a1 1 0 0 1 1-1h6" />
        </svg>
      </button>
      <span role="status" className={`todo-copy-status${copyState === 'failed' ? ' todo-copy-failed' : ''}`}>{COPY_LABELS[copyState] || ''}</span>
    </div>
  )
}

function TagControls({ tags, group, onGroup, onCreateTag, tagMessage }) {
  const [name, setName] = useState('')
  const submit = e => {
    e.preventDefault()
    if (onCreateTag(name)) setName('')
  }
  return (
    <div className="todo-tags">
      <form className="todo-tag-form" onSubmit={submit}>
        <input
          className="todo-tag-input"
          type="text"
          value={name}
          onChange={e => setName(e.target.value)}
          placeholder="New tag"
          aria-label="New tag name"
        />
        <button type="submit" className="todo-tag-add">Tag ticked</button>
      </form>
      {tagMessage && <p role="alert" className="todo-tag-message">{tagMessage}</p>}
      <label className="todo-group">
        Group
        <select value={group} onChange={e => onGroup(e.target.value)} aria-label="Group">
          {groupOptions(tags).map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
        </select>
      </label>
    </div>
  )
}

export default function TodoPanel() {
  const [entries, setEntries] = useState(null)
  const [board, setBoard] = useState(null)
  const [projectName, setProjectName] = useState(null)
  const [error, setError] = useState(false)
  const [showTerminal, setShowTerminal] = useState(false)

  useEffect(() => {
    let live = true
    Promise.all([get('/v1/todo'), get('/v1/board'), get('/v1/health').catch(() => null)])
      .then(([todo, epics, health]) => {
        if (!live) return
        setEntries(Array.isArray(todo) ? todo : [])
        setBoard(flattenBoard(epics))
        setProjectName(health && typeof health.projectName === 'string' ? health.projectName : null)
      })
      .catch(() => { if (live) setError(true) })
    return () => { live = false }
  }, [])

  const { ticks, toggle, setAll: toggleMany } = useTodoSelection(projectName, entries)
  const { tags, createTag } = useTodoTags(projectName, entries)
  const [group, setGroup] = useState('')
  const [tagMessage, setTagMessage] = useState('')
  // The group choice is a view of the tag set only; it never filters the list. Fall back to All if its tag is gone.
  const activeGroup = group in tags ? group : ''
  const onCreateTag = name => {
    const result = createTag(name, ticks)
    setTagMessage(result.ok ? '' : result.error)
    return result.ok
  }
  const [mode, setMode] = useState('mark')
  const [copyState, setCopyState] = useState('')
  const rows = useMemo(() => (entries && board ? joinTodo(entries, board, { showTerminal }) : []), [entries, board, showTerminal])
  const onApply = () => toggleMany(applyMark(ticks, mode, rows, tags, activeGroup))
  const onCopy = async () => {
    const text = formatJengaCommand(rows, ticks)
    if (!text) return
    const result = await copyText(text)
    setCopyState(result.ok ? 'copied' : 'failed')
    setTimeout(() => setCopyState(''), 2500)
  }

  return (
    <TodoListView
      rows={rows}
      ticks={ticks}
      onToggle={toggle}
      showTerminal={showTerminal}
      onShowTerminal={setShowTerminal}
      error={error}
      loading={!error && !(entries && board)}
      tags={tags}
      group={activeGroup}
      onGroup={setGroup}
      onCreateTag={onCreateTag}
      tagMessage={tagMessage}
      mode={mode}
      onMode={setMode}
      onApply={onApply}
      onCopy={onCopy}
      copyState={copyState}
    />
  )
}
