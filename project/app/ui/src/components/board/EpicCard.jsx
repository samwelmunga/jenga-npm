import StatusBadge from './StatusBadge'
import StoryCard from './StoryCard'

export default function EpicCard({ epic, onSelect }) {
  return (
    <div className="epic-card">
      <div className="epic-header">
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
      {epic.stories && epic.stories.length > 0 && (
        <div className="stories-list">
          {epic.stories.map(story => (
            <StoryCard key={story.id} story={story} onSelect={onSelect} />
          ))}
        </div>
      )}
    </div>
  )
}
