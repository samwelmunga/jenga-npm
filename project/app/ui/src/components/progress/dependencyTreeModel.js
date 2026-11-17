/**
 * dependencyTreeModel — E92_S06_T09, reworked to dependency-tree v2 by E92_S06_T19.
 *
 * Pure (React-free, DOM-free) model for the epic dependency tree in the overlay.
 *
 * E92_S08_T02: the graph STRUCTURE (depth columns, gates, marks, folding, bands, edges, ready/unlocked, goal facts) now lives in
 * lib/progress/dependency-structure.js, shared with the Node terminal renderer, which has no use for pixels. This file keeps
 * what is specific to the dashboard: the pixel layout (LAYOUT, COL_WIDTH, layoutTree) and unfoldGroups, and re-exports every
 * name it exported before the split, so DependencyTree.jsx and EntryDetailPanel.jsx are unchanged.
 * Input is the body of
 * `GET /v1/progress-graph` (the output of `scripts/board-progress.sh --graph [--within <id>]` plus `labels`).
 * It accepts the full-board payload or a `--within`-restricted one and selects the epic itself, so both give the
 * same model. It derives no state, readiness or unlocked_by: those are the script's. It counts nothing the payload
 * does not already state: epic and story figures are read from the payload's `totals`, and only when a `totals`
 * object is absent are they read off the tasks' own `bucket`. What it computes is layout and presentation facts only.
 * It holds no colour, no label and no user-visible word: the renderer owns all of those.
 *
 * Edge direction (changed in v2): `{ from, to }` means `from` is the DEPENDENCY and `to` is the DEPENDENT, so an
 * edge runs from the right edge of the dependency to the left edge of the dependent. The old v1 convention was the
 * reverse (`from` the dependent). Every edge carries `crossStory` (the two ends sit in different stories; boundary
 * edges always do) and a `kind`: `dependency` (task to task), `boundary` (a node outside the epic to a task),
 * `start` (a story's start node to a task with no in-epic dependency), `goal` (a task that nothing in the epic
 * depends on to the goal, whose id is GOAL_NODE_ID) and `ghost` (E92_S12_T02: the start node of a ghost band to the goal,
 * drawn dashed; see below). Edges between the visible nodes are de-duplicated by
 * `from` + `to`; once groups fold, the edges of a group are the union of its members'.
 *
 * Model shape (arrays are sorted, so the same input gives a deep-equal output):
 *   empty        true only when the epic has no tasks (the goal is still filled in); an epic with tasks but no
 *                dependency edge gets its tree, every task in column 0 (E92_S09_T01)
 *   goal         { id, title, fraction, percent, done, total, reached, x, y }  fraction 0..1, rejected not counted
 *   stories      per story: { storyId, title, done, total, buckets }   the start-node facts, id order, plus
 *                undecomposed: true on a story the payload states `decomposed: false` (E92_S12_T02)
 *   tasks        every task, never folded: { kind:'task', id, title, storyId, state, bucket, row, column, gate,
 *                mark, dependsOn, unlocks, upstream, downstream }   gate: none | locked | open, from the task's own
 *                and its story's depends_on (E92_S09_T02, see gateOf in dependency-structure.js);
 *                mark: done | in_progress | ready | failed | rejected | none (none for a locked task)
 *   nodes        the VISIBLE nodes: tasks and folded groups, each with x, y, w, h, inX, outX, midY and slot
 *                group: { kind:'group', id, members, count, state, row, column, gate, mark, dependsOn, unlocks,
 *                upstream, downstream }
 *   headers      one collapse header per expanded group
 *   bands        per story: { storyId, row, y, h, start }   `start` is the start node (id `story:<storyId>`; it carries
 *                `undecomposed: true` for an undecomposed story). A GHOST band (E92_S12_T02: an undecomposed story with no task
 *                node, built because buildDependencyTreeModel asks for includeUndecomposed) has `undecomposed: true` too and no
 *                node; it is laid out like any band, `cardH + bandPad` tall, and has one `ghost` edge to the goal
 *   edges        the visible edges, see above
 *   boundary     nodes outside the epic, { id, status, bucket }
 *   foldable     ids of every group that would fold, folded or not
 *   expanded     ids currently unfolded
 *   ready, unlocked   the lists the overlay prints below the tree (unchanged)
 *   layout       LAYOUT numbers plus width, height, columns
 *
 * The layout numbers are exported (LAYOUT) so the renderer and the zoom/fit code share one source.
 */

import { buildDependencyStructure, foldStructure, fillUnlockedBy, goalFailedText, unfinishedDepText, FOLD_THRESHOLD, GOAL_NODE_ID } from '../../../../../../lib/progress/dependency-structure.js'

export { fillUnlockedBy, goalFailedText, unfinishedDepText, FOLD_THRESHOLD, GOAL_NODE_ID }

/** Layout numbers, in user units. width and height of the whole drawing are in `model.layout`. */
export const LAYOUT = Object.freeze({
  pad: 20,
  startW: 200, // story start node width
  startH: 68,
  columnX0: 280, // x of the first column
  columnW: 260, // distance between two columns
  cardW: 200,
  cardH: 48,
  rowGap: 18,
  headerH: 22, // the collapse header of an expanded group
  headerGap: 8,
  bandPad: 20,
  bandGap: 14,
  goalGap: 100,
  goalAreaW: 260,
  goalOffsetX: 70,
  gateR: 10, // gate badge radius, the badge sits on the left edge of a card
  minHeight: 300,
})
export const COL_WIDTH = LAYOUT.columnW

/**
 * Pure pixel layout of a structure (see lib/progress/dependency-structure.js): positions every band, node, collapse header,
 * the start nodes and the goal, and adds the `layout` totals. Nothing structural is decided here.
 */
export function layoutTree(s) {
  const { columns, ...rest } = s
  const L = LAYOUT
  if (s.empty) return { ...rest, goal: { ...s.goal, x: 0, y: 0 }, layout: { ...L, width: 0, height: 0, columns: 0 } }

  const nodes = []
  const headers = []
  const bands = []
  let y = L.pad

  for (const band of s.bands) {
    const { row } = band
    const slotH = sl => (sl.type === 'header' ? L.headerH : L.cardH)
    const gapAfter = sl => (sl.type === 'header' ? L.headerGap : L.rowGap)
    const cellH = slots => slots.reduce((h, sl, i) => h + slotH(sl) + (i < slots.length - 1 ? gapAfter(sl) : 0), 0)
    const inner = Math.max(L.cardH + L.bandPad, ...band.cells.map(c => cellH(c.slots)))
    const h = L.bandPad * 2 + inner

    for (const { column, slots } of band.cells) {
      let cy = y + (h - cellH(slots)) / 2
      const x = L.columnX0 + column * L.columnW
      for (const sl of slots) {
        if (sl.type === 'header') {
          headers.push({ ...sl.header, x, y: cy, w: L.cardW, h: L.headerH })
        } else {
          const gated = sl.node.gate !== 'none'
          nodes.push({ ...sl.node, x, y: cy, w: L.cardW, h: L.cardH, inX: x - (gated ? L.gateR : 0), outX: x + L.cardW, midY: cy + L.cardH / 2 })
        }
        cy += slotH(sl) + gapAfter(sl)
      }
    }

    bands.push({
      storyId: band.storyId,
      row,
      y,
      h,
      ...(band.undecomposed ? { undecomposed: true } : {}),
      start: {
        ...band.start,
        x: L.pad,
        y: y + h / 2 - L.startH / 2,
        w: L.startW,
        h: L.startH,
        outX: L.pad + L.startW,
        midY: y + h / 2,
      },
    })
    y += h + L.bandGap
  }

  const contentH = y - L.bandGap + L.pad
  const goalX = L.columnX0 + (columns - 1) * L.columnW + L.cardW + L.goalGap
  const layout = {
    ...L,
    width: goalX + L.goalAreaW,
    height: Math.max(contentH, L.minHeight),
    columns,
  }
  const goal = { ...s.goal, x: goalX + L.goalOffsetX, y: contentH / 2 }

  return { ...rest, goal, nodes, headers, bands, layout }
}

/**
 * The dashboard model of one epic. The dashboard shows undecomposed stories as ghost bands (E92_S12_T02), so
 * `includeUndecomposed` is on by default; the fourth argument can override it, e.g. `{ includeUndecomposed: false }`.
 * A payload without the per-story `decomposed` flag (an older script) gives the model it always gave.
 */
export function buildDependencyTreeModel(graph, epicId, labels, options) {
  return layoutTree(buildDependencyStructure(graph, epicId, labels, { includeUndecomposed: true, ...(options || {}) }))
}

/**
 * Pure helper for the renderer's expansion state: the model with the groups whose ids are in `expandedIds` (a Set or
 * an array) unfolded. Returns the new nodes, collapse headers, bands, edges (de-duplicated), goal position and layout;
 * an unknown id is ignored. With no ids it returns the folded model again.
 */
export function unfoldGroups(model, expandedIds) {
  if (!model || model.empty) return model
  return layoutTree(foldStructure(model, expandedIds ? [...expandedIds] : []))
}
