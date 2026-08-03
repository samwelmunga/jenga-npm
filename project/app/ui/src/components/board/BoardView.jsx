import EpicCard from './EpicCard'
import './board.css'

export default function BoardView({ epics }) {
  if (!epics || epics.length === 0) {
    return <div className="empty-state">No board data available.</div>
  }
  return (
    <div className="board-view">
      {epics.map(epic => (
        <EpicCard key={epic.id} epic={epic} />
      ))}
    </div>
  )
}
