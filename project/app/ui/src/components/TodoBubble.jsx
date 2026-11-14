import { useEffect, useRef, useState } from 'react'
import { isEmbeddedSnapshot } from '../api/client'
import TodoPanel from './todo/TodoPanel'
import './todo-bubble.css'

// E47_S10_T02 - floating todo bubble. Shell only: the panel body is filled in by E47_S10_T03.

// Tab ids the bubble appears on (Backlog and Active Sprint).
export const BUBBLE_TABS = ['board', 'active-sprint']

// Visible on a bubble tab of the live dashboard only. A snapshot export (and so j.dashboard-share) has no server to
// read todos from, hence `snapshot` hides it.
export function shouldShowTodoBubble(activeTab, snapshot) {
  return BUBBLE_TABS.includes(activeTab) && !snapshot
}

// Esc closes the panel. An event something else already handled (e.g. the E47_S08 leave modal) is left alone.
export function handlePanelKeyDown(e, close) {
  if (e.key === 'Escape' && !e.defaultPrevented) {
    close()
    return true
  }
  return false
}

// Checklist glyph (rounded square, three checkmarks, three lines). Strokes use currentColor so it follows the bubble's
// colour token in light and dark themes.
export function ChecklistIcon() {
  return (
    <svg
      className="todo-bubble-icon"
      viewBox="0 0 24 24"
      width="24"
      height="24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <rect x="2.5" y="2.5" width="19" height="19" rx="3.5" />
      <path d="M6 8.2l1.3 1.3 2.2-2.6" />
      <path d="M6 12.7l1.3 1.3 2.2-2.6" />
      <path d="M6 17.2l1.3 1.3 2.2-2.6" />
      <path d="M12.5 8.5h5" />
      <path d="M12.5 13h5" />
      <path d="M12.5 17.5h3" />
    </svg>
  )
}

// Pure view, so it can be rendered server-side in the test.
export function TodoBubbleView({ open, onToggle, onClose, bubbleRef, closeRef, body }) {
  return (
    <>
      <button
        type="button"
        ref={bubbleRef}
        className="todo-bubble"
        aria-label="Open todo list"
        aria-expanded={open}
        aria-controls="todo-bubble-panel"
        onClick={onToggle}
      >
        <ChecklistIcon />
      </button>
      {open && (
        <div id="todo-bubble-panel" className="todo-bubble-panel" role="dialog" aria-label="Todo list">
          <div className="todo-bubble-header">
            <h2 className="todo-bubble-title">Todo</h2>
            <button type="button" ref={closeRef} className="todo-bubble-close" aria-label="Close todo list" onClick={onClose}>
              Close
            </button>
          </div>
          <div className="todo-bubble-body">{body}</div>
        </div>
      )}
    </>
  )
}

function TodoBubbleInner() {
  const [open, setOpen] = useState(false)
  const bubbleRef = useRef(null)
  const closeRef = useRef(null)
  const wasOpen = useRef(false)

  // Focus moves into the panel on open and back to the bubble on close.
  useEffect(() => {
    if (open) closeRef.current?.focus()
    else if (wasOpen.current) bubbleRef.current?.focus()
    wasOpen.current = open
  }, [open])

  useEffect(() => {
    if (!open) return undefined
    const onKeyDown = e => handlePanelKeyDown(e, () => setOpen(false))
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [open])

  return (
    <TodoBubbleView
      open={open}
      onToggle={() => setOpen(o => !o)}
      onClose={() => setOpen(false)}
      bubbleRef={bubbleRef}
      closeRef={closeRef}
      body={<TodoPanel />}
    />
  )
}

// `snapshot` is injectable for tests; the default asks the api client.
export default function TodoBubble({ activeTab, snapshot = isEmbeddedSnapshot() }) {
  if (!shouldShowTodoBubble(activeTab, snapshot)) return null
  return <TodoBubbleInner />
}
