import StatusBadge from './StatusBadge'
import TaskCard from './TaskCard'

export default function StoryCard({ story }) {
  return (
    <div className="story-card">
      <div className="story-header">
        <h4 className="story-title">{story.title}</h4>
        <span className="story-id">{story.id}</span>
        <StatusBadge status={story.status} />
      </div>
      {story.tasks && story.tasks.length > 0 && (
        <div className="tasks-list">
          {story.tasks.map(task => (
            <TaskCard key={task.id} task={task} />
          ))}
        </div>
      )}
    </div>
  )
}
