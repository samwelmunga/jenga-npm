/**
 * @file kanbanColumns.js
 * Pure logic for the "Active Sprint" kanban view (E06_S05_T02): column
 * definitions, tree-flattening, and status-bucketing. Kept separate from any
 * rendering component so the mapping/merge rules are readable and testable
 * in isolation.
 *
 * Column order, merge rules, and exclusions per the story's Acceptance
 * Criteria (project/board/stories/E06_S05_kanban-status-columns.md):
 * Backlog → Pending → In Progress → Blocked → Failed → Rejected → Done
 * (merging Passed / Passed with remarks / Done) → Merged →
 * Publicized/Privatized → Deployed to Stage → Deployed to Prod.
 *
 * `Running` is not a canonical status per templates/SCRUM_BOARD_SCHEMA.md's
 * STATUS_VALUES (only present in project/configs/workflow.json's stale copy —
 * see open rapport project/rapports/problems/E40_S04_T01-status-running-schema-drift.md).
 * Any item still carrying it (legacy data) falls back to the In Progress
 * column, folded into the lookup below rather than special-cased at render
 * time.
 *
 * The Pending column is intentionally kept in this list (for left-to-right
 * order parity with the story's own AC bullet) even though `bucketIntoColumns`
 * below excludes all Pending items from the result set — it will therefore
 * always render empty/collapsed as a natural consequence of that filter, not
 * a special case. Pending items still appear in the Backlog tab (E06_S05_T01).
 *
 * A second, independent exclusion (E06_S05_T03) applies only to the
 * `Deployed to Prod` column: an item whose `date_deployed_prod` frontmatter
 * field (written by `scripts/mark-deployed.sh`, see E51_S05) is more than 10
 * days before today is excluded from the Active Sprint view entirely. An
 * item with no `date_deployed_prod` set is treated as not stale (rendered
 * normally) rather than excluded — see `isStaleDeployedProd` below. This
 * filter is scoped to this module only; the Backlog tab (E06_S05_T01) does
 * not import kanbanColumns.js and is unaffected.
 */

export const KANBAN_COLUMNS = [
  { key: 'backlog', label: 'Backlog', statuses: ['Backlog'] },
  { key: 'pending', label: 'Pending', statuses: ['Pending'] },
  { key: 'in-progress', label: 'In Progress', statuses: ['In Progress', 'Running'] },
  { key: 'blocked', label: 'Blocked', statuses: ['Blocked'] },
  { key: 'failed', label: 'Failed', statuses: ['Failed'] },
  { key: 'rejected', label: 'Rejected', statuses: ['Rejected'] },
  { key: 'done', label: 'Done', statuses: ['Passed', 'Passed with remarks', 'Done'] },
  { key: 'merged', label: 'Merged', statuses: ['Merged'] },
  {
    key: 'publicized-privatized',
    label: 'Publicized/Privatized',
    statuses: ['Publicized', 'Privatized'],
  },
  { key: 'deployed-stage', label: 'Deployed to Stage', statuses: ['Deployed to Stage'] },
  { key: 'deployed-prod', label: 'Deployed to Prod', statuses: ['Deployed to Prod'] },
]

function columnKeyForStatus(status) {
  const col = KANBAN_COLUMNS.find((c) => c.statuses.includes(status))
  return col ? col.key : null
}

const MS_PER_DAY = 24 * 60 * 60 * 1000

/**
 * Returns true when `dateValue` (the `date_deployed_prod` frontmatter field,
 * as written by `scripts/mark-deployed.sh`) is more than `thresholdDays` days
 * before `now`. A missing/falsy `dateValue` is treated as NOT stale (returns
 * false) per the story's AC — an item that hasn't had the field written yet
 * (or predates E51_S05) should still render normally rather than be silently
 * excluded.
 *
 * `dateValue` arrives as EITHER a plain ISO 8601 `YYYY-MM-DD` string OR a
 * native JS `Date` instance, depending on the caller: gray-matter/js-yaml
 * (the parser `parseBoard()` actually uses in production) auto-parses an
 * unquoted `YYYY-MM-DD` YAML scalar into a `Date` object, not a string — a
 * real defect found by the tester (see
 * project/rapports/problems/E06_S05_T03-stale-filter-fails-on-real-gray-matter-date-objects.md):
 * the original string-only implementation silently fell into the
 * "unparseable → not stale" fail-safe for every real board item, making the
 * filter a no-op in production. Both shapes are handled explicitly here
 * rather than assuming one.
 *
 * Dates are compared at UTC-midnight granularity (both `dateValue` and `now`
 * are floored to their UTC calendar day) so the result doesn't depend on the
 * server's local timezone, and a same-day boundary can't tip over from an
 * unrelated few hours of clock drift.
 *
 * @param {string|Date|undefined|null} dateValue - ISO 8601 `YYYY-MM-DD` string, or a Date (as produced by gray-matter/js-yaml)
 * @param {number} [thresholdDays=10]
 * @param {Date} [now=new Date()]
 * @returns {boolean}
 */
export function isStaleDeployedProd(dateValue, thresholdDays = 10, now = new Date()) {
  if (!dateValue) return false

  const parsed = dateValue instanceof Date ? dateValue : new Date(`${dateValue}T00:00:00Z`)
  if (Number.isNaN(parsed.getTime())) return false

  // Floor `parsed` to its own UTC calendar day too — defensive against a
  // Date instance that isn't exactly UTC midnight (gray-matter/js-yaml's
  // default schema does produce UTC midnight for a bare `YYYY-MM-DD` scalar,
  // but flooring here costs nothing and removes the assumption).
  const parsedUTC = Date.UTC(parsed.getUTCFullYear(), parsed.getUTCMonth(), parsed.getUTCDate())
  const todayUTC = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())
  const diffDays = (todayUTC - parsedUTC) / MS_PER_DAY

  return diffDays > thresholdDays
}

/**
 * Flattens the epic→story→task tree returned by GET /v1/board into a flat
 * list of items, each tagged with its item type. Kanban columns are per-item
 * (every epic, story, and task carries its own independent status), so the
 * tree nesting BoardView.jsx relies on isn't meaningful for this view.
 * @param {Object[]} epics
 * @returns {Object[]}
 */
export function flattenBoardItems(epics) {
  const items = []
  for (const epic of epics || []) {
    items.push({ ...epic, _itemType: 'epic' })
    for (const story of epic.stories || []) {
      items.push({ ...story, _itemType: 'story' })
      for (const task of story.tasks || []) {
        items.push({ ...task, _itemType: 'task' })
      }
    }
  }
  return items
}

/**
 * Buckets a flat item list into the kanban columns above. Items with
 * `status: Pending` are excluded entirely (Active Sprint tab's own filter —
 * they still appear in the Backlog tab). Items with `status: Deployed to
 * Prod` whose `date_deployed_prod` is more than 10 days old are also
 * excluded entirely (E06_S05_T03) — an absent `date_deployed_prod` is not
 * treated as stale. Items whose status doesn't map to any known column
 * (unrecognized/non-schema status) are silently dropped from the view
 * rather than crashing the render.
 * @param {Object[]} items
 * @returns {Object.<string, Object[]>} column key -> items in that column
 */
export function bucketIntoColumns(items) {
  const buckets = {}
  for (const col of KANBAN_COLUMNS) buckets[col.key] = []

  for (const item of items || []) {
    if (item.status === 'Pending') continue
    if (item.status === 'Deployed to Prod' && isStaleDeployedProd(item.date_deployed_prod)) continue
    const key = columnKeyForStatus(item.status)
    if (key) buckets[key].push(item)
  }

  return buckets
}
