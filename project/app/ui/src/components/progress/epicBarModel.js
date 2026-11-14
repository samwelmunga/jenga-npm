/**
 * epicBarModel — E92_S06_T07.
 *
 * Pure (React-free, DOM-free) view model for the compact epic card progress bar. Input is one epic entry and its story
 * entries from `GET /v1/progress-cards` (the output of `scripts/board-progress.sh --graph --counts-only`) plus the
 * payload's `labels`. It counts nothing: `stop` is the script's story bucket, and the percent comes from
 * `tasks.totals` (done / denominator). Only a `complete` story is ever `done`.
 */

export const STOP_BUCKETS = ['done', 'in_progress', 'failed', 'pending', 'rejected']

function num(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0
}

function stopBucket(story) {
  if (story && story.complete === true) return 'done'
  const s = story && story.stop
  // A story that is not complete is never drawn as done, whatever `stop` says.
  return STOP_BUCKETS.includes(s) && s !== 'done' ? s : 'pending'
}

/** Substitute the `%d of %d ... %d%%` placeholders of the card_bar_aria label, in order. '' when the label is missing. */
export function fillAria(template, complete, total, percent) {
  if (typeof template !== 'string' || !template) return ''
  const values = [complete, total, percent]
  let i = 0
  return template.replace(/%d%%|%d/g, m => {
    const v = values[i++]
    return m === '%d%%' ? `${v}%` : String(v)
  })
}

/** -> `{ stops: [{id, bucket}], percent, completeStories, totalStories, ariaLabel }`. */
export function buildEpicBarModel(epicEntry, storyEntries, labels) {
  const stories = Array.isArray(storyEntries) ? storyEntries.filter(s => s && typeof s === 'object') : []
  const totals = (epicEntry && epicEntry.tasks && epicEntry.tasks.totals) || {}
  const denominator = num(totals.denominator)
  const percent = denominator > 0 ? Math.round((num(totals.done) * 100) / denominator) : 0
  const stops = stories.map(s => ({ id: s.id, bucket: stopBucket(s) }))
  const fromScript = epicEntry && epicEntry.stories && epicEntry.stories.complete
  const completeStories = typeof fromScript === 'number' ? num(fromScript) : stops.filter(s => s.bucket === 'done').length
  const totalStories = stops.length
  const ariaLabel = fillAria(labels && labels.card_bar_aria, completeStories, totalStories, percent)
  return { stops, percent, completeStories, totalStories, ariaLabel }
}
