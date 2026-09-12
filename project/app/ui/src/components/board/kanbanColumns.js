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
 * they still appear in the Backlog tab). Items whose status doesn't map to
 * any known column (unrecognized/non-schema status) are silently dropped
 * from the view rather than crashing the render.
 * @param {Object[]} items
 * @returns {Object.<string, Object[]>} column key -> items in that column
 */
export function bucketIntoColumns(items) {
  const buckets = {}
  for (const col of KANBAN_COLUMNS) buckets[col.key] = []

  for (const item of items || []) {
    if (item.status === 'Pending') continue
    const key = columnKeyForStatus(item.status)
    if (key) buckets[key].push(item)
  }

  return buckets
}
