import { useState } from 'react'
import StatusBadge from './StatusBadge'
import TaskCard from './TaskCard'

export default function StoryCard({ story, onSelect }) {
  // E06_S04_T01 — in-memory only, starts collapsed; see EpicCard.jsx.
  const [expanded, setExpanded] = useState(false)
  const hasTasks = Boolean(story.tasks && story.tasks.length > 0)

  function toggle() {
    setExpanded(prev => !prev)
  }

  return (
    <div className="story-card">
      <div className={`story-header${expanded && hasTasks ? ' is-expanded' : ''}`}>
        <span
          className={`collapse-toggle${hasTasks ? '' : ' is-empty'}`}
          role="button"
          tabIndex={hasTasks ? 0 : -1}
          aria-expanded={hasTasks ? expanded : undefined}
          aria-disabled={hasTasks ? undefined : true}
          aria-label={`${expanded ? 'Collapse' : 'Expand'} tasks of ${story.id}`}
          onClick={hasTasks ? toggle : undefined}
          onKeyDown={e => {
            if (!hasTasks) return
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              toggle()
            }
          }}
        />
        <h4
          className="story-title"
          role="button"
          tabIndex={0}
          onClick={() => onSelect('story', story)}
          onKeyDown={e => (e.key === 'Enter' || e.key === ' ') && onSelect('story', story)}
        >
          {story.title}
        </h4>
        <span className="story-id">{story.id}</span>
        <StatusBadge status={story.status} />
      </div>
      {hasTasks && expanded && (
        <div className="tasks-list">
          {story.tasks.map(task => (
            <TaskCard key={task.id} task={task} onSelect={onSelect} />
          ))}
        </div>
      )}
    </div>
  )
}
