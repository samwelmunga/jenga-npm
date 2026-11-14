import { STATUS_BUCKET } from '../progress/progressModel'

// E47_S10_T03 - pure model for the todo panel: board join, terminal hiding, tick persistence.

export const UNRESOLVED_STATUS = 'Not on board'
const KEY_PREFIX = 'jenga.todo.ticks.'

const canon = ref => String(ref ?? '').trim().toUpperCase()

/** Every story and task of `/v1/board` as Map<UPPER id, {id, title, status}>. */
export function flattenBoard(epics) {
  const map = new Map()
  const add = item => {
    if (item && item.id) map.set(canon(item.id), { id: item.id, title: item.title ?? '', status: item.status ?? '' })
  }
  for (const epic of Array.isArray(epics) ? epics : []) {
    for (const story of epic.stories || []) {
      add(story)
      for (const task of story.tasks || []) add(task)
    }
  }
  return map
}

/** Terminal = the progress model's `done` bucket, plus Rejected. */
export function isTerminal(status) {
  return STATUS_BUCKET[status] === 'done' || status === 'Rejected'
}

/**
 * Join `/v1/todo` entries to the board. Entries with no ref are dropped; a ref the board does not know stays
 * in the list as `unresolved` (title from the todo line). Duplicate refs collapse to the first. Terminal items
 * are hidden unless `showTerminal`.
 */
export function joinTodo(entries, boardMap, { showTerminal = false } = {}) {
  const seen = new Set()
  const rows = []
  for (const entry of Array.isArray(entries) ? entries : []) {
    const key = canon(entry && entry.ref)
    if (!key || seen.has(key)) continue
    seen.add(key)
    const hit = boardMap.get(key)
    const row = hit
      ? { ref: key, id: hit.id, title: hit.title, status: hit.status, unresolved: false }
      : { ref: key, id: key, title: (entry.title ?? '').trim(), status: UNRESOLVED_STATUS, unresolved: true }
    if (!showTerminal && !row.unresolved && isTerminal(row.status)) continue
    rows.push(row)
  }
  return rows
}

/** localStorage key for one project, so ticks never mix between projects. */
export function storageKey(projectName) {
  const name = typeof projectName === 'string' && projectName.trim() ? projectName.trim() : 'default'
  return KEY_PREFIX + name
}

/** Drop ticks whose ref is no longer in the todo list. `ticks` and result are arrays of upper-case refs. */
export function pruneTicks(ticks, entries) {
  const live = new Set((Array.isArray(entries) ? entries : []).map(e => canon(e && e.ref)).filter(Boolean))
  return [...new Set((Array.isArray(ticks) ? ticks : []).map(canon))].filter(r => live.has(r))
}

function defaultStorage() {
  try { return typeof localStorage === 'undefined' ? null : localStorage } catch { return null }
}

/** Never throws: unavailable storage, a throwing getItem or corrupt JSON all give `[]`. */
export function readTicks(key, storage = defaultStorage()) {
  try {
    const parsed = JSON.parse(storage.getItem(key))
    return Array.isArray(parsed) ? parsed.filter(r => typeof r === 'string').map(canon) : []
  } catch { return [] }
}

/** Never throws; returns whether the write took. */
export function writeTicks(key, ticks, storage = defaultStorage()) {
  try { storage.setItem(key, JSON.stringify(ticks)); return true } catch { return false }
}

// E47_S10_T04 - tags. A tag set is a plain object { [tag name]: [UPPER refs] }; a tag exists only while it has rows.
const TAG_KEY_PREFIX = 'jenga.todo.tags.'
export const MAX_TAG_LENGTH = 24
export const TAG_NO_SELECTION_HINT = 'Tick at least one row first.'

export function tagStorageKey(projectName) {
  const name = typeof projectName === 'string' && projectName.trim() ? projectName.trim() : 'default'
  return TAG_KEY_PREFIX + name
}

/** Validate a new tag name against the existing tag set. Returns { ok, name } or { ok: false, error }. */
export function validateTagName(raw, tags = {}) {
  const name = String(raw ?? '').trim()
  if (!name) return { ok: false, error: 'Tag name cannot be empty.' }
  if (name.length > MAX_TAG_LENGTH) return { ok: false, error: `Tag name is limited to ${MAX_TAG_LENGTH} characters.` }
  const lower = name.toLowerCase()
  if (Object.keys(tags || {}).some(t => t.toLowerCase() === lower)) return { ok: false, error: `Tag "${name}" already exists.` }
  return { ok: true, name }
}

/** Create `rawName` on `refs`. Returns { ok, tags } (new object) or { ok: false, error }. Nothing ticked is a no-op with a hint. */
export function addTag(tags, rawName, refs) {
  const checked = validateTagName(rawName, tags)
  if (!checked.ok) return checked
  const rows = [...new Set((Array.isArray(refs) ? refs : []).map(canon).filter(Boolean))]
  if (rows.length === 0) return { ok: false, error: TAG_NO_SELECTION_HINT }
  return { ok: true, tags: { ...tags, [checked.name]: rows } }
}

/** Drop refs that left the todo list, then tags left without rows. */
export function pruneTags(tags, entries) {
  const live = new Set((Array.isArray(entries) ? entries : []).map(e => canon(e && e.ref)).filter(Boolean))
  const out = {}
  for (const [name, refs] of Object.entries(tags && typeof tags === 'object' ? tags : {})) {
    const kept = [...new Set((Array.isArray(refs) ? refs : []).map(canon))].filter(r => live.has(r))
    if (kept.length) out[name] = kept
  }
  return out
}

export function tagsForRef(tags, ref) {
  const id = canon(ref)
  return Object.keys(tags || {}).filter(name => tags[name].includes(id))
}

/** Group dropdown options: "All" first, then one per tag. */
export function groupOptions(tags) {
  return [{ value: '', label: 'All' }, ...Object.keys(tags || {}).sort((a, b) => a.localeCompare(b)).map(t => ({ value: t, label: t }))]
}

/** Never throws: unavailable storage, throwing getItem or corrupt JSON give {}. */
export function readTags(key, storage = defaultStorage()) {
  try {
    const parsed = JSON.parse(storage.getItem(key))
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {}
    const out = {}
    for (const [name, refs] of Object.entries(parsed)) {
      if (Array.isArray(refs)) out[name] = refs.filter(r => typeof r === 'string').map(canon)
    }
    return out
  } catch { return {} }
}

/** Never throws; returns whether the write took. */
export function writeTags(key, tags, storage = defaultStorage()) {
  try { storage.setItem(key, JSON.stringify(tags)); return true } catch { return false }
}

// E47_S10_T05 - bulk mark and the /jenga command string.

/** Refs of the visible `rows` in a group: '' (All) is every row, otherwise rows carrying that tag. */
export function groupRefs(rows, tags, group) {
  const list = Array.isArray(rows) ? rows : []
  if (!group) return list.map(r => r.ref)
  const members = new Set(((tags || {})[group]) || [])
  return list.filter(r => members.has(r.ref)).map(r => r.ref)
}

/** Tick ('mark') or untick ('unmark') exactly the group's visible rows. Returns a new array; other ticks untouched. */
export function applyMark(ticks, mode, rows, tags, group) {
  const current = Array.isArray(ticks) ? ticks : []
  const target = new Set(groupRefs(rows, tags, group))
  if (mode === 'unmark') return current.filter(r => !target.has(r))
  const have = new Set(current)
  return [...current, ...[...target].filter(r => !have.has(r))]
}

/** `/jenga E02_S01_T00, E102_S09_T10`: canonical ids of ticked rows, in list order. '' when nothing is ticked. */
export function formatJengaCommand(rows, ticks) {
  const on = new Set(Array.isArray(ticks) ? ticks : [])
  const ids = (Array.isArray(rows) ? rows : []).filter(r => on.has(r.ref)).map(r => r.ref)
  return ids.length ? '/jenga ' + ids.join(', ') : ''
}
