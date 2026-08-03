import StatusBadge from './StatusBadge'

export default function TaskCard({ task }) {
  return (
    <div className="task-card">
      <span className="task-title">{task.title}</span>
      <span className="task-id">{task.id}</span>
      {task.assigned_to && (
        <span className="task-assigned">@{task.assigned_to}</span>
      )}
      <StatusBadge status={task.status} />
    </div>
  )
}
