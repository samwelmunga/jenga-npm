import StatusBadge from './StatusBadge'
import StoryCard from './StoryCard'

export default function EpicCard({ epic }) {
  return (
    <div className="epic-card">
      <div className="epic-header">
        <h3 className="epic-title">{epic.title}</h3>
        <span className="epic-id">{epic.id}</span>
        <StatusBadge status={epic.status} />
      </div>
      {epic.stories && epic.stories.length > 0 && (
        <div className="stories-list">
          {epic.stories.map(story => (
            <StoryCard key={story.id} story={story} />
          ))}
        </div>
      )}
    </div>
  )
}
