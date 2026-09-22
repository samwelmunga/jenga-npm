import { useState } from 'react'
import EpicCard from './EpicCard'
import EntryDetailPanel from '../history/EntryDetailPanel'
import './board.css'

// Canonical status values per templates/SCRUM_BOARD_SCHEMA.md's Status Values
// table. `Running` is deliberately excluded — it is not schema-valid (see
// E06_S05's same exclusion note).
const STATUS_OPTIONS = [
  'Pending',
  'In Progress',
  'Passed',
  'Passed with remarks',
  'Failed',
  'Rejected',
  'Blocked',
  'Backlog',
  'Done',
  'Merged',
  'Publicized',
  'Privatized',
  'Deployed to Stage',
  'Deployed to Prod',
]

function matches(status, selected) {
  return selected.size === 0 || selected.has(status)
}

function filterTasks(tasks, selected) {
  return (tasks || []).filter(task => matches(task.status, selected))
}

function filterStories(stories, selected) {
  return (stories || [])
    .map(story => {
      const tasks = filterTasks(story.tasks, selected)
      if (matches(story.status, selected) || tasks.length > 0) {
        return { ...story, tasks }
      }
      return null
    })
    .filter(Boolean)
}

function filterEpics(epics, selected) {
  if (selected.size === 0) return epics
  return epics
    .map(epic => {
      const stories = filterStories(epic.stories, selected)
      if (matches(epic.status, selected) || stories.length > 0) {
        return { ...epic, stories }
      }
      return null
    })
    .filter(Boolean)
}

// E06_S08_T01 — epic-range filter. `from`/`to` are epic ids ('' = unset, meaning
// unbounded in that direction). Ordering is on the numeric part of the id
// (`E06` -> 6); an id that doesn't parse has no position in the range and is
// always kept, so a malformed epic can never be silently hidden by the filter.
function epicOrder(id) {
  const match = /\d+/.exec(id || '')
  return match ? Number(match[0]) : null
}

function filterEpicRange(epics, from, to) {
  if (!from && !to) return epics
  const fromOrder = from ? epicOrder(from) : null
  const toOrder = to ? epicOrder(to) : null
  return epics.filter(epic => {
    const order = epicOrder(epic.id)
    if (order === null) return true
    if (fromOrder !== null && order < fromOrder) return false
    if (toOrder !== null && order > toOrder) return false
    return true
  })
}

export default function BoardView({ epics }) {
  const [selectedStatuses, setSelectedStatuses] = useState(() => new Set())
  const [fromEpic, setFromEpic] = useState('')
  const [toEpic, setToEpic] = useState('')
  // E06_S07_T01 — lifted selection state for the content overlay, mirroring
  // HistoryTab.jsx's lifted `selected` useState pattern. `kind` distinguishes
  // epic/story/task so EntryDetailPanel can render the right label/meta.
  const [selected, setSelected] = useState(null)

  function onSelect(kind, item) {
    setSelected({ type: 'board_item', kind, ...item })
  }

  if (!epics || epics.length === 0) {
    return <div className="empty-state">No board data available.</div>
  }

  function toggleStatus(status) {
    setSelectedStatuses(prev => {
      const next = new Set(prev)
      if (next.has(status)) {
        next.delete(status)
      } else {
        next.add(status)
      }
      return next
    })
  }

  // Range and status filters compose with AND — the range bounds which epics are
  // in play, then the status filter narrows what's shown within them.
  const epicOptions = epics.map(epic => epic.id).filter(Boolean)
  const visibleEpics = filterEpics(filterEpicRange(epics, fromEpic, toEpic), selectedStatuses)

  return (
    <div className="board-view">
      <div className="epic-range-filter">
        <label className="epic-range-option">
          From epic
          <select value={fromEpic} onChange={e => setFromEpic(e.target.value)}>
            <option value="">All</option>
            {epicOptions.map(id => (
              <option key={id} value={id}>{id}</option>
            ))}
          </select>
        </label>
        <label className="epic-range-option">
          To epic
          <select value={toEpic} onChange={e => setToEpic(e.target.value)}>
            <option value="">All</option>
            {epicOptions.map(id => (
              <option key={id} value={id}>{id}</option>
            ))}
          </select>
        </label>
      </div>
      <div className="status-filter">
        {STATUS_OPTIONS.map(status => (
          <label key={status} className="status-filter-option">
            <input
              type="checkbox"
              checked={selectedStatuses.has(status)}
              onChange={() => toggleStatus(status)}
            />
            {status}
          </label>
        ))}
      </div>
      {visibleEpics.length === 0 ? (
        <div className="empty-state">No items match the selected filters.</div>
      ) : (
        visibleEpics.map(epic => <EpicCard key={epic.id} epic={epic} onSelect={onSelect} />)
      )}
      <EntryDetailPanel entry={selected} onClose={() => setSelected(null)} />
    </div>
  )
}
