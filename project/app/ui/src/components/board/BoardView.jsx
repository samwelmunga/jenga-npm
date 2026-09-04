import { useState } from 'react'
import EpicCard from './EpicCard'
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

export default function BoardView({ epics }) {
  const [selectedStatuses, setSelectedStatuses] = useState(() => new Set())

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

  const visibleEpics = filterEpics(epics, selectedStatuses)

  return (
    <div className="board-view">
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
        visibleEpics.map(epic => <EpicCard key={epic.id} epic={epic} />)
      )}
    </div>
  )
}
