import './history.css'

const TYPE_META = {
  git_commit: { icon: '🔖', label: 'Commit', badgeClass: 'badge-commit' },
  rapport: { icon: '📄', label: 'Rapport', badgeClass: 'badge-rapport' },
}

function formatDate(iso) {
  if (!iso) return '—'
  return new Intl.DateTimeFormat(undefined, {
    year: 'numeric',
    month: 'short',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(iso))
}

export default function HistoryEntry({ entry, isSelected, onSelect }) {
  const { icon, label, badgeClass } = TYPE_META[entry.type] || { icon: '•', label: entry.type, badgeClass: '' }
  const subject = entry.subject || entry.filename || '(untitled)'

  return (
    <li
      className={`history-entry${isSelected ? ' selected' : ''}`}
      onClick={() => onSelect(entry)}
      role="button"
      tabIndex={0}
      onKeyDown={e => (e.key === 'Enter' || e.key === ' ') && onSelect(entry)}
    >
      <span className={`history-badge ${badgeClass}`}>{icon} {label}</span>
      <span className="history-subject">{subject}</span>
      <span className="history-date">{formatDate(entry.date)}</span>
    </li>
  )
}
