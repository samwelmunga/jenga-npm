/**
 * budgetModel — E76_S03_T07.
 *
 * Pure (React-free) view model for the dashboard's budget view. Input is the `GET /v1/board` payload
 * (epics -> stories -> tasks), exactly as the live API returns it and as a snapshot embeds it. The usage
 * field names are the ones in `templates/SCRUM_BOARD_SCHEMA.md` ("Usage fields (per-task token accounting)"
 * and "Usage fields on stories"):
 *   task:  usage_input_tokens, usage_output_tokens, usage_cache_write_tokens, usage_cache_read_tokens,
 *          usage_total_tokens, usage_transcripts, usage_measured_on, usage_possibly_incomplete,
 *          usage_cost_units (E90_S01)
 *   story: usage_tasks_{input,output,cache_write,cache_read,total}_tokens (the task part),
 *          usage_overhead_{input,output,cache_write,cache_read,total}_tokens (the overhead part),
 *          usage_total_tokens (task part plus overhead part), usage_measured_on, usage_possibly_incomplete,
 *          usage_tasks_cost_units, usage_overhead_cost_units, usage_cost_units (E90_S01)
 *
 * Rules this module owns:
 *   - A number is "measured" only when it is a finite, non-negative number. An absent key, null, a string
 *     or anything else is NOT measured and becomes `null` here, so the view can say "not measured". It is
 *     never turned into 0. An explicit 0 in frontmatter is a measured 0 and stays 0.
 *   - The guard (E76 epic decision 6): `hasUsageData` is true only when some task or story carries at least
 *     one measured token field. With no usage anywhere the view renders nothing and the tab is not offered.
 *   - No currency amount is computed here and nothing is looked up in a price list. The only derived figure is the
 *     cost-equivalent unit (E90_S01_T09), read as a number the board already carries (`usage_cost_units` and the
 *     two story part fields, written by `task-usage.sh --persist` from per-model ratios). It is a relative unit,
 *     NOT a currency amount, and a labelled derived view that sits beside the four raw counts and replaces none of
 *     them. It follows the same absence rule per item: an absent field is `null` (never 0), and an item that has
 *     raw counts but no derived number is shown as "not priced".
 */

export const NOT_MEASURED = 'not measured'

export const TOKEN_UNIT = 'tokens'

/** Shown for an item that has raw counts but no derived number (an unpriced model, or never derived). */
export const NOT_PRICED = 'not priced'

export const COST_UNIT_NAME = 'cost-equivalent units'

/** The four breakdown fields, in display order, with the task-level and story-part frontmatter keys. */
export const FIELDS = [
  { id: 'input', label: 'Fresh input', task: 'usage_input_tokens', tasks: 'usage_tasks_input_tokens', overhead: 'usage_overhead_input_tokens' },
  { id: 'output', label: 'Output', task: 'usage_output_tokens', tasks: 'usage_tasks_output_tokens', overhead: 'usage_overhead_output_tokens' },
  { id: 'cacheWrite', label: 'Cache write', task: 'usage_cache_write_tokens', tasks: 'usage_tasks_cache_write_tokens', overhead: 'usage_overhead_cache_write_tokens' },
  { id: 'cacheRead', label: 'Cache read', task: 'usage_cache_read_tokens', tasks: 'usage_tasks_cache_read_tokens', overhead: 'usage_overhead_cache_read_tokens' },
]

const TOKEN_KEY = /^usage_.*_tokens$/

/** A measured number, or null. Never 0 unless the source says 0. */
export function measured(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null
}

/** Thousands separators with a fixed locale so the view reads the same everywhere; null -> "not measured". */
export function formatTokens(value) {
  const n = measured(value)
  return n === null ? NOT_MEASURED : n.toLocaleString('en-US')
}

function carriesMeasuredTokens(item) {
  if (!item || typeof item !== 'object') return false
  return Object.keys(item).some(k => TOKEN_KEY.test(k) && measured(item[k]) !== null)
}

function storiesOf(epics) {
  const out = []
  for (const epic of Array.isArray(epics) ? epics : []) {
    for (const story of Array.isArray(epic?.stories) ? epic.stories : []) out.push({ epic, story })
  }
  return out
}

/** The public-mirror guard: true when at least one task or story carries a measured token field. */
export function hasUsageData(epics) {
  return storiesOf(epics).some(({ story }) =>
    carriesMeasuredTokens(story) || (Array.isArray(story.tasks) && story.tasks.some(carriesMeasuredTokens)))
}

function breakdown(item, key) {
  const values = {}
  for (const f of FIELDS) values[f.id] = measured(item?.[f[key]])
  return values
}

const incomplete = item => item?.usage_possibly_incomplete === true

function taskRow(task) {
  const fields = breakdown(task, 'task')
  const total = measured(task.usage_total_tokens)
  const any = total !== null || Object.values(fields).some(v => v !== null)
  return {
    id: task.id ?? null,
    title: task.title ?? '',
    status: task.status ?? null,
    fields,
    total,
    cost: measured(task.usage_cost_units),
    measured: any,
    possiblyIncomplete: any && incomplete(task),
  }
}

function storyPart(story, key, totalKey, costKey) {
  const fields = breakdown(story, key)
  const total = measured(story[totalKey])
  return { fields, total, cost: measured(story[costKey]), measured: total !== null || Object.values(fields).some(v => v !== null) }
}

/**
 * One entry per story that carries a measurement itself or has at least one measured task. Every task of
 * such a story is listed, measured or not (the unmeasured ones say so). Stories with no measurement at all
 * are counted in `unmeasuredStories`, not listed.
 */
export function buildBudgetRows(epics) {
  const stories = []
  let unmeasuredStories = 0
  for (const { epic, story } of storiesOf(epics)) {
    const tasks = (Array.isArray(story.tasks) ? story.tasks : []).map(taskRow)
    const tasksPart = storyPart(story, 'tasks', 'usage_tasks_total_tokens', 'usage_tasks_cost_units')
    const overheadPart = storyPart(story, 'overhead', 'usage_overhead_total_tokens', 'usage_overhead_cost_units')
    const total = measured(story.usage_total_tokens)
    const storyMeasured = tasksPart.measured || overheadPart.measured || total !== null
    if (!storyMeasured && !tasks.some(t => t.measured)) {
      unmeasuredStories += 1
      continue
    }
    stories.push({
      id: story.id ?? null,
      epicId: epic.id ?? null,
      title: story.title ?? '',
      tasksPart,
      overheadPart,
      total,
      cost: measured(story.usage_cost_units),
      measured: storyMeasured,
      possiblyIncomplete: storyMeasured && incomplete(story),
      tasks,
    })
  }
  return { stories, unmeasuredStories }
}
