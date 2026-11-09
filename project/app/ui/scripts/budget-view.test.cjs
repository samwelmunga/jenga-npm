#!/usr/bin/env node
'use strict'
// E76_S03_T07: render and model test for the dashboard budget view. Zero test framework, like
// findings-table.test.cjs. It does not use scripts/task-usage.sh (private, blocklisted): fixtures are
// literal board payloads in the shape GET /v1/board returns (frontmatter keys passed through).
// Run: node project/app/ui/scripts/budget-view.test.cjs
const assert = require('assert')
const { renderBudgetView, load } = require('./budget-view-render.cjs')

const { hasUsageData, buildBudgetRows, formatTokens, measured, NOT_MEASURED } = load()
const count = (html, needle) => html.split(needle).length - 1

const task = (id, extra = {}) => ({ id, story_id: 'E01_S01', epic_id: 'E01', title: `Task ${id}`, status: 'Passed', ...extra })
const measuredTask = (id, i, o, w, r, extra = {}) => task(id, {
  usage_input_tokens: i, usage_output_tokens: o, usage_cache_write_tokens: w, usage_cache_read_tokens: r,
  usage_total_tokens: i + o + w + r, usage_transcripts: 1, usage_measured_on: '2026-10-25', ...extra,
})
const board = (stories) => [{ id: 'E01', title: 'Epic', stories }]
const story = (id, tasks, extra = {}) => ({ id, epic_id: 'E01', title: `Story ${id}`, status: 'Passed', tasks, ...extra })

// formatting and the measured rule
assert.strictEqual(formatTokens(1234567), '1,234,567')
assert.strictEqual(formatTokens(0), '0')
for (const bad of [null, undefined, '12', NaN, -1, {}]) assert.strictEqual(formatTokens(bad), NOT_MEASURED)
assert.strictEqual(measured(0), 0)

// 1. Full usage: four-field breakdown, totals, task part / overhead part / total as separate numbers.
{
  const epics = board([
    story('E01_S01', [
      measuredTask('E01_S01_T01', 1200, 3400, 56000, 780000),
      measuredTask('E01_S01_T02', 10, 20, 30, 40, { usage_possibly_incomplete: true }),
    ], {
      usage_tasks_input_tokens: 1210, usage_tasks_output_tokens: 3420, usage_tasks_cache_write_tokens: 56030,
      usage_tasks_cache_read_tokens: 780040, usage_tasks_total_tokens: 840700,
      usage_overhead_input_tokens: 5, usage_overhead_output_tokens: 6, usage_overhead_cache_write_tokens: 7,
      usage_overhead_cache_read_tokens: 8, usage_overhead_total_tokens: 26,
      usage_total_tokens: 840726,
    }),
  ])
  assert.ok(hasUsageData(epics))
  const html = renderBudgetView(epics)
  assert.strictEqual(count(html, 'data-testid="budget-view"'), 1)
  const row = id => html.match(new RegExp(`<tr data-row="task" data-id="${id}"[\\s\\S]*?</tr>`))[0]
  const t1 = row('E01_S01_T01')
  for (const s of ['>1,200<', '>3,400<', '>56,000<', '>780,000<', '>840,600<']) assert.ok(t1.includes(s), 'task row missing ' + s)
  assert.ok(!t1.includes(NOT_MEASURED))
  const part = name => html.match(new RegExp(`<tr data-row="${name}"[\\s\\S]*?</tr>`))[0]
  const tasksPart = part('story-tasks-part')
  for (const s of ['>1,210<', '>3,420<', '>56,030<', '>780,040<', '>840,700<']) assert.ok(tasksPart.includes(s), 'tasks part missing ' + s)
  const overhead = part('story-overhead-part')
  for (const s of ['>5<', '>6<', '>7<', '>8<', '>26<']) assert.ok(overhead.includes(s), 'overhead part missing ' + s)
  const total = part('story-total')
  assert.ok(total.includes('>840,726<'))
  // the three story numbers are separate: the total is not repeated inside the parts, nor the parts in the total
  assert.ok(!tasksPart.includes('840,726') && !overhead.includes('840,726') && !total.includes('840,700'))
  // possibly-incomplete is shown on that task only; the unit is stated; headings name the four fields
  assert.strictEqual(count(row('E01_S01_T02'), 'class="budget-flag"'), 1)
  assert.strictEqual(count(t1, 'class="budget-flag"'), 0)
  assert.ok(html.includes('in tokens'))
  for (const h of ['Fresh input', 'Output', 'Cache write', 'Cache read', 'Total']) assert.ok(html.includes('>' + h + '<'), h)
  assert.ok(!html.includes('budget-not-measured'))
}

// 2. Partial data: unmeasured tasks and parts say so, nothing is shown as zero, nothing throws.
{
  const epics = board([
    story('E01_S01', [
      measuredTask('E01_S01_T01', 100, 200, 300, 400),
      task('E01_S01_T02'),
      task('E01_S01_T03', { usage_input_tokens: 7 }),
    ]),
    story('E01_S02', [task('E01_S02_T01')]),
  ])
  const html = renderBudgetView(epics)
  const row = id => html.match(new RegExp(`<tr data-row="task" data-id="${id}"[\\s\\S]*?</tr>`))[0]
  assert.ok(row('E01_S01_T02').includes('budget-not-measured'))
  assert.ok(!/>0</.test(row('E01_S01_T02')))
  // a half-measured task: the one field it has, "not measured" in the others, no invented zero
  const t3 = row('E01_S01_T03')
  assert.ok(t3.includes('>7<'))
  assert.strictEqual(count(t3, 'budget-not-measured'), 4)
  assert.ok(!/>0</.test(t3))
  // the story has no story-level fields: each part and the total say "not measured"
  for (const name of ['story-tasks-part', 'story-overhead-part', 'story-total']) {
    const tr = html.match(new RegExp(`<tr data-row="${name}"[\\s\\S]*?</tr>`))[0]
    assert.ok(tr.includes('budget-not-measured'), name)
  }
  // the story with no measurement anywhere is counted, not listed
  assert.ok(!html.includes('E01_S02_T01'))
  assert.ok(html.includes('1 story has no measurement'))
  assert.ok(!/undefined|NaN|null/.test(html))
}

// 2b. An explicit measured 0 stays 0 (it is a measurement), unlike an absent field.
{
  const html = renderBudgetView(board([story('E01_S01', [measuredTask('E01_S01_T01', 0, 5, 0, 0)])]))
  const t = html.match(/<tr data-row="task"[\s\S]*?<\/tr>/)[0]
  assert.strictEqual(count(t, '>0<'), 3)
  assert.ok(!t.includes(NOT_MEASURED))
}

// 3. Guard: no usage anywhere (or no board at all) renders nothing, not even a heading or placeholder.
{
  const noUsage = board([story('E01_S01', [task('E01_S01_T01'), task('E01_S01_T02')])])
  for (const epics of [noUsage, [], null, undefined, board([]), [{ id: 'E01' }]]) {
    assert.strictEqual(hasUsageData(epics), false)
    assert.strictEqual(renderBudgetView(epics), '')
  }
  // non-token usage keys alone (a date, a transcript count) are not a measurement
  const metaOnly = board([story('E01_S01', [task('E01_S01_T01', { usage_measured_on: '2026-10-25', usage_transcripts: 2 })])])
  assert.strictEqual(hasUsageData(metaOnly), false)
  assert.strictEqual(renderBudgetView(metaOnly), '')
  assert.deepStrictEqual(buildBudgetRows(noUsage), { stories: [], unmeasuredStories: 1 })
}

// 4. No dollar or price figure anywhere in the view.
{
  const html = renderBudgetView(board([story('E01_S01', [measuredTask('E01_S01_T01', 1, 2, 3, 4)], {
    usage_tasks_total_tokens: 10, usage_overhead_total_tokens: 0, usage_total_tokens: 10,
  })]))
  assert.ok(html.length > 0)
  assert.ok(!/\$|USD|EUR|\bprice|\bcost|dollar/i.test(html))
}

console.log('budget-view.test.cjs: ok')
