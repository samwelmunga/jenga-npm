import HistoryEntry from './HistoryEntry'
import './history.css'

export default function HistoryList({ entries, onSelect, selectedId }) {
  if (!entries || entries.length === 0) {
    return <div className="history-empty">No history entries found.</div>
  }

  return (
    <ul className="history-list">
      {entries.map(entry => {
        const id = entry.sha || entry.filename
        return (
          <HistoryEntry
            key={id}
            entry={entry}
            isSelected={selectedId === id}
            onSelect={onSelect}
          />
        )
      })}
    </ul>
  )
}
