import { useState, useEffect } from 'react'
import { get } from '../api/client'
import LoadingSpinner from '../components/LoadingSpinner'
import ErrorMessage from '../components/ErrorMessage'
import BoardView from '../components/board/BoardView'

export default function BoardTab() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [data, setData] = useState(null)
  // E92_S06_T08: card progress is best-effort. It loads in parallel with the board, is never awaited by it, and a
  // rejection (or a snapshot without the key) leaves it null so the cards simply show no bar and no banner.
  const [cards, setCards] = useState(null)

  useEffect(() => {
    get('/v1/board')
      .then(setData)
      .catch(setError)
      .finally(() => setLoading(false))
    get('/v1/progress-cards')
      .then(setCards)
      .catch(() => setCards(null))
  }, [])

  if (loading) return <LoadingSpinner />
  if (error) return <ErrorMessage error={error} />
  return <BoardView epics={data} cards={cards} />
}
