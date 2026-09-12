import StatusBadge from './StatusBadge'
import { KANBAN_COLUMNS, flattenBoardItems, bucketIntoColumns } from './kanbanColumns'
import './kanban.css'

const TYPE_LABELS = { epic: 'Epic', story: 'Story', task: 'Task' }

function KanbanCard({ item }) {
  return (
    <div className="kanban-card">
      <div className="kanban-card-header">
        <span className="kanban-card-type">{TYPE_LABELS[item._itemType] ?? item._itemType}</span>
        <span className="kanban-card-id">{item.id}</span>
      </div>
      <div className="kanban-card-title">{item.title}</div>
      <StatusBadge status={item.status} />
    </div>
  )
}

// Read-only kanban rendering of the board (E06_S05_T02) — one column per
// status per the story's Acceptance Criteria, Pending items excluded from
// the whole view, empty columns collapsed. No drag-and-drop (board stays
// read-only per E06_S02).
export default function KanbanBoard({ epics }) {
  if (!epics || epics.length === 0) {
    return <div className="empty-state">No board data available.</div>
  }

  const items = flattenBoardItems(epics)
  const buckets = bucketIntoColumns(items)

  return (
    <div className="kanban-board">
      {KANBAN_COLUMNS.map((col) => {
        const colItems = buckets[col.key]
        const isEmpty = colItems.length === 0
        return (
          <div
            key={col.key}
            className={`kanban-column${isEmpty ? ' kanban-column-empty' : ''}`}
          >
            <div className="kanban-column-header">
              <span className="kanban-column-title">{col.label}</span>
              <span className="kanban-column-count">{colItems.length}</span>
            </div>
            {isEmpty ? (
              <div className="kanban-column-empty-state">No items</div>
            ) : (
              <div className="kanban-column-items">
                {colItems.map((item) => (
                  <KanbanCard key={`${item._itemType}-${item.id}`} item={item} />
                ))}
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}
