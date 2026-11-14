import { useCallback, useEffect, useState } from 'react'
import { addTag, pruneTags, readTags, tagStorageKey, writeTags } from '../components/todo/todoModel'

// E47_S10_T04 - tags for one project, kept in the browser only. `entries` is null until the todo list has
// loaded; stored tags are pruned against it once it has. Storage failures leave the tags working in memory.
export default function useTodoTags(projectName, entries) {
  const key = tagStorageKey(projectName)
  const [tags, setTags] = useState({})

  useEffect(() => {
    if (!entries) return
    const kept = pruneTags(readTags(key), entries)
    setTags(kept)
    writeTags(key, kept)
  }, [key, entries])

  // Returns { ok } or { ok: false, error } so the panel can show the message.
  const createTag = useCallback((name, refs) => {
    const result = addTag(tags, name, refs)
    if (result.ok) {
      setTags(result.tags)
      writeTags(key, result.tags)
    }
    return result
  }, [key, tags])

  return { tags, createTag }
}
