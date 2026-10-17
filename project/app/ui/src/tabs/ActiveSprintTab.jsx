import { useState, useEffect } from 'react'
import { get } from '../api/client'
import LoadingSpinner from '../components/LoadingSpinner'
import ErrorMessage from '../components/ErrorMessage'
import KanbanBoard from '../components/board/KanbanBoard'

// Mirrors BoardTab.jsx's fetch/loading/error handling exactly — same
// GET /v1/board data source, rendered as a kanban board instead of the
// nested Backlog list. See E06_S05_T02.
export default function ActiveSprintTab() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [data, setData] = useState(null)
  const [ideas, setIdeas] = useState([])

  useEffect(() => {
    // E35_S04_T04 — ideas are additive: a failed/absent /v1/ideas (including an older snapshot
    // without the `ideas` key, where get() throws) must never fail the board, so it resolves to [].
    const ideasRequest = get('/v1/ideas').catch(() => [])
    get('/v1/board')
      .then(setData)
      .catch(setError)
      .then(() => ideasRequest)
      .then((items) => setIdeas(Array.isArray(items) ? items : []))
      .finally(() => setLoading(false))
  }, [])

  if (loading) return <LoadingSpinner />
  if (error) return <ErrorMessage error={error} />
  return <KanbanBoard epics={data} ideas={ideas} />
}
