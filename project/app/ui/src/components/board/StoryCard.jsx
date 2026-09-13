import StatusBadge from './StatusBadge'
import TaskCard from './TaskCard'

export default function StoryCard({ story, onSelect }) {
  return (
    <div className="story-card">
      <div className="story-header">
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
      {story.tasks && story.tasks.length > 0 && (
        <div className="tasks-list">
          {story.tasks.map(task => (
            <TaskCard key={task.id} task={task} onSelect={onSelect} />
          ))}
        </div>
      )}
    </div>
  )
}
