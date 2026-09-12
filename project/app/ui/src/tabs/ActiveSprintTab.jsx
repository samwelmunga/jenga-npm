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

  useEffect(() => {
    get('/v1/board')
      .then(setData)
      .catch(setError)
      .finally(() => setLoading(false))
  }, [])

  if (loading) return <LoadingSpinner />
  if (error) return <ErrorMessage error={error} />
  return <KanbanBoard epics={data} />
}
