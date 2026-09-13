import StatusBadge from './StatusBadge'

export default function TaskCard({ task, onSelect }) {
  return (
    <div className="task-card">
      <span
        className="task-title"
        role="button"
        tabIndex={0}
        onClick={() => onSelect('task', task)}
        onKeyDown={e => (e.key === 'Enter' || e.key === ' ') && onSelect('task', task)}
      >
        {task.title}
      </span>
      <span className="task-id">{task.id}</span>
      {task.assigned_to && (
        <span className="task-assigned">@{task.assigned_to}</span>
      )}
      <StatusBadge status={task.status} />
    </div>
  )
}
