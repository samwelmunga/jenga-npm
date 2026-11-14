import PieChart from './PieChart'
import { buildPieModel, progressHeadline } from './progressModel'
import './progress.css'

/**
 * ProgressView — E92_S03_T05.
 *
 * A heading and four pies in a responsive grid: Tasks, Stories, Epics and Backlog. The input is the body of
 * `GET /v1/progress` (E92_S03_T01): `{ schema_version, charts: { tasks, stories, epics, backlog } }`.
 * `tasks`, `stories` and `epics` are the script's `levels.<level>` blocks (`{ counts, totals }`) or
 * `{ empty: true }`. Nothing is counted here; the model reads the script's own `totals`.
 *
 * Which block the single Backlog pie plots (E92_S03_T05 open point, decided): the TASKS block.
 * `charts.backlog` is not one block but the `--backlog` script output's `levels` (`{ tasks?, stories?, epics? }`),
 * because the backlog is whatever `project/todo.md` queues, and the queue is a list of work to do, i.e. tasks:
 * a queued story already expands to its tasks (progress-visualisation.md section 6), and todo.md holds task and
 * story ids today. If the backlog has no tasks block (only stories or epics were queued and none had a task) the
 * pie falls back to `stories`, then `epics`, so a queue is never shown as empty when it is not. A backlog that
 * already is a block (carries `totals`) is plotted as is. `{ empty: true }` (missing or empty todo.md) is the
 * "Nothing to show" state.
 */

const LEVEL_ORDER = ['tasks', 'stories', 'epics']

/** The single block the Backlog pie plots, or `{ empty: true }`. */
export function backlogBlock(backlog) {
  if (!backlog || typeof backlog !== 'object' || backlog.empty === true) return { empty: true }
  if (backlog.totals && typeof backlog.totals === 'object') return backlog
  for (const level of LEVEL_ORDER) {
    const block = backlog[level]
    if (block && typeof block === 'object' && block.empty !== true && block.totals) return block
  }
  return { empty: true }
}

/** The four charts in display order: `[{ title, block }]`. */
export function chartBlocks(charts) {
  const c = charts && typeof charts === 'object' ? charts : {}
  return [
    { title: 'Tasks', block: c.tasks },
    { title: 'Stories', block: c.stories },
    { title: 'Epics', block: c.epics },
    { title: 'Backlog', block: backlogBlock(c.backlog) },
  ]
}

export default function ProgressView({ data }) {
  const charts = data && typeof data === 'object' ? (data.charts ?? null) : null
  return (
    <div className="progress-view" data-testid="progress-view">
      <h2>Progress</h2>
      <div className="progress-grid">
        {chartBlocks(charts).map(({ title, block }) => {
          const model = buildPieModel(block, title)
          return <PieChart key={title} model={model} headline={model.empty ? '' : progressHeadline(block)} />
        })}
      </div>
    </div>
  )
}
