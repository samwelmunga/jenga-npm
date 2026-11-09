import { useState, useEffect } from 'react'
import { get } from '../api/client'
import LoadingSpinner from '../components/LoadingSpinner'
import ErrorMessage from '../components/ErrorMessage'
import BudgetView from '../components/budget/BudgetView'

/**
 * BudgetTab — E76_S03_T07. Fetches the board through `client.js`'s `get()` (so the embedded snapshot
 * branch works from file:// with no server) and renders the budget view. App.jsx only offers this tab
 * when the board carries usage data; BudgetView itself renders nothing without it.
 */
export default function BudgetTab() {
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
  return <BudgetView epics={data} />
}
