import { useEffect, useState } from 'react'
import { get } from '../api/client'
import LoadingSpinner from '../components/LoadingSpinner'
import ErrorMessage from '../components/ErrorMessage'
import HistoryList from '../components/history/HistoryList'
import EntryDetailPanel from '../components/history/EntryDetailPanel'

export default function HistoryTab() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [entries, setEntries] = useState([])
  const [selected, setSelected] = useState(null)

  useEffect(() => {
    setLoading(true)
    setError(null)
    get('/v1/history')
      .then(data => {
        const sorted = [...(data || [])].sort(
          (a, b) => new Date(b.date || 0) - new Date(a.date || 0)
        )
        setEntries(sorted)
      })
      .catch(err => setError(err))
      .finally(() => setLoading(false))
  }, [])

  return (
    <div className="history-tab">
      <h2>History</h2>
      {loading && <LoadingSpinner />}
      {error && <ErrorMessage error={error} />}
      {!loading && !error && (
        <HistoryList entries={entries} onSelect={setSelected} selectedId={selected?.sha || selected?.filename} />
      )}
      <EntryDetailPanel entry={selected} onClose={() => setSelected(null)} />
    </div>
  )
}
