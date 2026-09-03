const STATUS_CLASSES = {
  Pending: 'badge-pending',
  Running: 'badge-running',
  'In Progress': 'badge-in-progress',
  Passed: 'badge-passed',
  'Passed with remarks': 'badge-passed-remarks',
  Done: 'badge-done',
  Failed: 'badge-failed',
}

export default function StatusBadge({ status }) {
  const cls = STATUS_CLASSES[status] ?? 'badge-pending'
  return <span className={`status-badge ${cls}`}>{status}</span>
}
