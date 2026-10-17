import { useState } from 'react'
import StatusBadge from './StatusBadge'
import StoryCard from './StoryCard'

export default function EpicCard({ epic, onSelect }) {
  // E06_S04_T01 — plain in-memory state, deliberately not persisted anywhere
  // (no localStorage/sessionStorage/URL), so every reload starts collapsed.
  const [expanded, setExpanded] = useState(false)
  const hasStories = Boolean(epic.stories && epic.stories.length > 0)

  function toggle() {
    setExpanded(prev => !prev)
  }

  return (
    <div className="epic-card">
      <div className={`epic-header${expanded && hasStories ? ' is-expanded' : ''}`}>
        {/* Separate control from the title: the title keeps its E06_S07 overlay
            handler untouched, and this toggle never calls onSelect. */}
        <span
          className={`collapse-toggle${hasStories ? '' : ' is-empty'}`}
          role="button"
          tabIndex={hasStories ? 0 : -1}
          aria-expanded={hasStories ? expanded : undefined}
          aria-disabled={hasStories ? undefined : true}
          aria-label={`${expanded ? 'Collapse' : 'Expand'} stories of ${epic.id}`}
          onClick={hasStories ? toggle : undefined}
          onKeyDown={e => {
            if (!hasStories) return
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              toggle()
            }
          }}
        />
        <h3
          className="epic-title"
          role="button"
          tabIndex={0}
          onClick={() => onSelect('epic', epic)}
          onKeyDown={e => (e.key === 'Enter' || e.key === ' ') && onSelect('epic', epic)}
        >
          {epic.title}
        </h3>
        <span className="epic-id">{epic.id}</span>
        <StatusBadge status={epic.status} />
      </div>
      {hasStories && expanded && (
        <div className="stories-list">
          {epic.stories.map(story => (
            <StoryCard key={story.id} story={story} onSelect={onSelect} />
          ))}
        </div>
      )}
    </div>
  )
}
