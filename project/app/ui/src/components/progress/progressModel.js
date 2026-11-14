/**
 * progressModel — E92_S03_T04.
 *
 * Pure (React-free, DOM-free) view model for the progress pies. Input is one block of the
 * `levels.<level>` object the progress API returns: `{ counts, totals }` (see
 * `project/documentation/progress-visualisation.md`, sections 3 to 5), or `{ empty: true }`, or nothing.
 *
 * Rules this module owns:
 *   - Slice sizes come from `totals` (the script's own bucket totals). Statuses are never recounted here
 *     and never decide which bucket an item is in.
 *   - `counts` is read only to build each slice's `detail` string (the raw statuses behind the bucket,
 *     for a tooltip). STATUS_BUCKET below is the contract's section 4 table, used for that attribution only.
 *   - A bucket with a zero count yields no slice. A block with nothing in it is `empty`.
 *   - `rejected` has its own token and is never drawn in a done, in-progress, failed or pending colour.
 */

/** Slice order, fixed: done, in_progress, failed, pending, rejected, unknown. */
export const BUCKETS = [
  { key: 'done', label: 'Done', colorVar: '--color-progress-done' },
  { key: 'in_progress', label: 'In progress', colorVar: '--color-progress-in-progress' },
  { key: 'failed', label: 'Failed or blocked', colorVar: '--color-progress-failed' },
  { key: 'pending', label: 'Pending', colorVar: '--color-progress-pending' },
  { key: 'rejected', label: 'Rejected (not counted)', colorVar: '--color-progress-rejected' },
  { key: 'unknown', label: 'Unknown status', colorVar: '--color-border-strong' },
]

/** Contract section 4: status -> bucket. Anything not listed is `unknown`. Used for `detail` only. */
export const STATUS_BUCKET = {
  'Pending': 'pending',
  'In Progress': 'in_progress',
  'Passed': 'done',
  'Passed with remarks': 'done',
  'Failed': 'failed',
  'Rejected': 'rejected',
  'Blocked': 'failed',
  'Backlog': 'pending',
  'Done': 'done',
  'Merged': 'done',
  'Publicized': 'done',
  'Privatized': 'done',
  'Deployed to Stage': 'done',
  'Deployed to Prod': 'done',
}

/** A non-negative whole number, or 0. */
function num(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0
}

function isBlock(block) {
  return !!block && typeof block === 'object' && block.empty !== true && !!block.totals && typeof block.totals === 'object'
}

/** "Passed: 4, Merged: 1" for one bucket, from the `counts` map; '' when `counts` says nothing about it. */
function detailFor(key, counts) {
  if (!counts || typeof counts !== 'object') return ''
  const parts = []
  for (const [status, n] of Object.entries(counts)) {
    if ((STATUS_BUCKET[status] || 'unknown') !== key) continue
    const c = num(n)
    if (c > 0) parts.push(`${status}: ${c}`)
  }
  return parts.join(', ')
}

/** Whole percents of the given counts that total exactly 100 (largest remainder; ties go to the earlier slice). */
function percents(counts, sum) {
  const exact = counts.map(c => (c * 100) / sum)
  const out = exact.map(Math.floor)
  let left = 100 - out.reduce((a, b) => a + b, 0)
  const order = exact
    .map((x, i) => ({ i, r: x - Math.floor(x) }))
    .sort((a, b) => b.r - a.r || a.i - b.i)
  for (let k = 0; left > 0 && k < order.length; k++, left--) out[order[k].i] += 1
  return out
}

/**
 * One block -> `{ title, total, empty, slices }`.
 * `total` is the sum of the shown slices (so it includes rejected and unknown, which the denominator does not).
 */
export function buildPieModel(block, title) {
  const empty = { title, total: 0, empty: true, slices: [] }
  if (!isBlock(block)) return empty
  const shown = BUCKETS
    .map(b => ({ ...b, count: num(block.totals[b.key]) }))
    .filter(b => b.count > 0)
  const total = shown.reduce((a, b) => a + b.count, 0)
  if (total === 0) return empty
  const pct = percents(shown.map(b => b.count), total)
  const slices = shown.map((b, i) => ({
    key: b.key,
    label: b.label,
    count: b.count,
    percent: pct[i],
    colorVar: b.colorVar,
    detail: detailFor(b.key, block.counts),
  }))
  return { title, total, empty: false, slices }
}

/** "<done> of <denominator> done", from the script's `totals.denominator` (which excludes rejected and unknown). */
export function progressHeadline(block) {
  const totals = isBlock(block) ? block.totals : {}
  return `${num(totals.done)} of ${num(totals.denominator)} done`
}
