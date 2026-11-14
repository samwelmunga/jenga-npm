import { useCallback, useEffect, useState } from 'react'
import { pruneTicks, readTicks, storageKey, writeTicks } from '../components/todo/todoModel'

// E47_S10_T03 - ticked todo refs for one project. `entries` is null until the todo list has loaded; the
// stored ticks are pruned against it once it has. Storage failures leave the ticks working in memory.
export default function useTodoSelection(projectName, entries) {
  const key = storageKey(projectName)
  const [ticks, setTicks] = useState([])

  useEffect(() => {
    if (!entries) return
    const kept = pruneTicks(readTicks(key), entries)
    setTicks(kept)
    writeTicks(key, kept)
  }, [key, entries])

  const toggle = useCallback(ref => {
    const id = String(ref).toUpperCase()
    setTicks(prev => {
      const next = prev.includes(id) ? prev.filter(r => r !== id) : [...prev, id]
      writeTicks(key, next)
      return next
    })
  }, [key])

  // Replace the whole tick set (bulk mark/unmark).
  const setAll = useCallback(next => {
    setTicks(next)
    writeTicks(key, next)
  }, [key])

  return { ticks, toggle, setAll }
}
