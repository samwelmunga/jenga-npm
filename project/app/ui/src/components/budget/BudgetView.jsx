import { FIELDS, NOT_MEASURED, TOKEN_UNIT, buildBudgetRows, formatTokens, hasUsageData } from './budgetModel'
import './budget-view.css'

/**
 * BudgetView — E76_S03_T07.
 *
 * Renders the per-story and per-task token usage carried by the `GET /v1/board` payload (`epics`), as one
 * plain table: fresh input, output, cache write, cache read and total, in tokens. A story is a block:
 * its line, then "Tasks (sum)", "Overhead (allocated)" and "Story total" as separate rows (the schema
 * stores the story total as one number, the sum of the two parts, so only that number is shown for it),
 * then one row per task. A row (or a part) with no measurement at all shows "not measured" across its
 * cells; a row with some fields measured shows "not measured" only in the missing cells. Never zero.
 *
 * Public-mirror guard (E76 epic decision 6): with no usage field on any task or story this returns null,
 * so nothing at all is rendered (no heading, no empty placeholder). The tab that hosts it is not offered
 * in that case either (App.jsx), so this is the second line of defence.
 *
 * Plain table, no chart: exact budgeting numbers across four fields with cache reads dominating the
 * scale are read, not eyeballed, and a chart would hide the small fields.
 */

const FIELD_COUNT = FIELDS.length

function NotMeasured({ colSpan = 1 }) {
  return <td className="budget-cell budget-not-measured" colSpan={colSpan}>{NOT_MEASURED}</td>
}

function Num({ value, field }) {
  if (value === null || value === undefined) return <NotMeasured />
  return <td className="budget-cell budget-num" data-field={field}>{formatTokens(value)}</td>
}

function FieldCells({ part }) {
  if (!part.measured) return <NotMeasured colSpan={FIELD_COUNT + 1} />
  return (
    <>
      {FIELDS.map(f => <Num key={f.id} value={part.fields[f.id]} field={f.id} />)}
      <Num value={part.total} field="total" />
    </>
  )
}

function Flag({ on }) {
  return on ? <span className="budget-flag" title="Some transcripts looked pruned: these numbers are a lower bound">lower bound</span> : null
}

function StoryBlock({ story }) {
  return (
    <tbody className="budget-story" data-testid="budget-story" data-id={story.id}>
      <tr className="budget-story-head" data-row="story">
        <th scope="rowgroup" colSpan={FIELD_COUNT + 2}>
          <span className="budget-id">{story.id}</span> {story.title} <Flag on={story.possiblyIncomplete} />
        </th>
      </tr>
      <tr data-row="story-tasks-part">
        <th scope="row" className="budget-label">Tasks (sum)</th>
        <FieldCells part={story.tasksPart} />
      </tr>
      <tr data-row="story-overhead-part">
        <th scope="row" className="budget-label">Overhead (allocated)</th>
        <FieldCells part={story.overheadPart} />
      </tr>
      <tr data-row="story-total" className="budget-story-total">
        <th scope="row" className="budget-label">Story total</th>
        {story.total === null
          ? <NotMeasured colSpan={FIELD_COUNT + 1} />
          : (
            <>
              <td className="budget-cell budget-na" colSpan={FIELD_COUNT}>tasks plus overhead</td>
              <Num value={story.total} field="total" />
            </>
          )}
      </tr>
      {story.tasks.map(task => (
        <tr key={task.id} data-row="task" data-id={task.id} className={task.measured ? '' : 'budget-task-unmeasured'}>
          <th scope="row" className="budget-label budget-task-label">
            <span className="budget-id">{task.id}</span> {task.title} <Flag on={task.possiblyIncomplete} />
          </th>
          <FieldCells part={task} />
        </tr>
      ))}
    </tbody>
  )
}

export default function BudgetView({ epics }) {
  if (!hasUsageData(epics)) return null
  const { stories, unmeasuredStories } = buildBudgetRows(epics)
  return (
    <section className="budget-view" data-testid="budget-view" aria-labelledby="budget-view-heading">
      <h2 id="budget-view-heading">Budget</h2>
      <p className="budget-intro">
        Token usage per story and per task. Every figure is in {TOKEN_UNIT}; a story's total is its tasks
        plus its allocated overhead, shown as separate numbers. &quot;{NOT_MEASURED}&quot; means no
        measurement was recorded, not zero.
      </p>
      <div className="budget-scroll">
        <table className="budget-table">
          <caption className="budget-caption">Tokens per story and task</caption>
          <thead>
            <tr>
              <th scope="col">Item</th>
              {FIELDS.map(f => <th scope="col" key={f.id} className="budget-num">{f.label}</th>)}
              <th scope="col" className="budget-num">Total</th>
            </tr>
          </thead>
          {stories.map(s => <StoryBlock key={s.id} story={s} />)}
        </table>
      </div>
      {unmeasuredStories > 0 && (
        <p className="budget-footnote" data-testid="budget-unmeasured-count">
          {unmeasuredStories} {unmeasuredStories === 1 ? 'story has' : 'stories have'} no measurement and {unmeasuredStories === 1 ? 'is' : 'are'} not listed.
        </p>
      )}
    </section>
  )
}
