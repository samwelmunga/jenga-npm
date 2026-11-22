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
import { buildCastleModel } from './castleModel.js'
import { layoutCastle } from './castleLayout.js'
import { layoutFacade } from './facadeLayout.js'
import { layoutSeasonsTree } from './treeLayout.js'

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
  gateR: 10, // gate badge radius, the badge sits on the left edge of a card
  minHeight: 300,
})
export const COL_WIDTH = LAYOUT.columnW

/**
 * The room the goal takes right of the last column (E92_S13_T02). It is no longer one fixed number: it depends on what the
 * goal is drawn as (`goalArea`), and for the citadel on the castle box the model carries.
 *   'disc'    the star (and any design drawn inside a disc): a fixed area, DISC_AREA, as it always was: 260 wide, the goal
 *             centre 70 right of the area's left edge, the goal centred on the content's height.
 *   'castle'  the citadel: the area is as wide as the castle box (model.castle.box) plus CASTLE_MARGIN either side, the goal
 *             centre is the box centre, and the goal sits at the height that keeps the whole castle and the goal text inside
 *             the drawing (the drawing grows when the castle is taller than the tree).
 *   'facade'  the flat facade (E92_S13_T03): the same, with the facade's own box and text position (model.castle.facade); the
 *             facade is wide and low where the citadel is square, so it has its own room.
 *   'tree'    the seasons tree (E92_S13_T07): the same, with the tree's own box and text position (model.castle.tree, treeLayout.js).
 *             The tree box is sized for the fully grown tree, so it does not change while the epic is worked on; Fit and the large
 *             view (E92_S07) read the layout's width and height, which therefore include it.
 */
export const DISC_AREA = Object.freeze({ w: 260, offsetX: 70 })
export const CASTLE_MARGIN = Object.freeze({ left: 10, right: 20 })
export const GOAL_AREAS = Object.freeze(['castle', 'facade', 'tree', 'disc'])

/**
 * Pure pixel layout of a structure (see lib/progress/dependency-structure.js): positions every band, node, collapse header,
 * the start nodes and the goal, and adds the `layout` totals. Nothing structural is decided here.
 */
export function layoutTree(s, options) {
  const { columns, ...rest } = s
  const L = LAYOUT
  if (s.empty) return { ...rest, goal: { ...s.goal, x: 0, y: 0 }, layout: { ...L, goalAreaW: DISC_AREA.w, goalOffsetX: DISC_AREA.offsetX, width: 0, height: 0, columns: 0 } }

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
  const castle = s.castle && s.castle.box ? s.castle : null
  const mode = options && options.goalArea === 'disc' ? 'disc' : options && options.goalArea === 'facade' ? 'facade' : options && options.goalArea === 'tree' ? 'tree' : 'castle'
  // the geometry the goal area is made for: the citadel's, the facade's or the seasons tree's (kept inside it, built from the same castle model)
  const inner = key => (castle && castle[key] && castle[key].box ? castle[key] : null)
  const geo = mode === 'facade' ? inner('facade') : mode === 'tree' ? inner('tree') : castle
  let goalAreaW
  let goalOffsetX
  let height = Math.max(contentH, L.minHeight)
  let goalY = contentH / 2
  const useCastle = mode !== 'disc' && !!geo
  if (useCastle) {
    // the castle box is centred on the goal: the box, then the goal text under it, must lie inside the drawing
    goalOffsetX = CASTLE_MARGIN.left + geo.box.w / 2
    goalAreaW = CASTLE_MARGIN.left + geo.box.w + CASTLE_MARGIN.right
    const up = -geo.box.top
    const down = geo.text.top + geo.text.blockH
    height = Math.max(height, up + down + 2 * L.pad)
    goalY = Math.min(Math.max(height / 2 - (down - up) / 2, L.pad + up), height - L.pad - down)
  } else {
    goalAreaW = DISC_AREA.w
    goalOffsetX = DISC_AREA.offsetX
  }
  // The disc layout has exactly the keys it always had (the parity recordings are byte-identical); only the castle layout adds
  // `goalX` (the left edge of the goal area) and `goalArea: 'castle'`, which is also how unfoldGroups knows which layout it has.
  const layout = {
    ...L,
    goalAreaW,
    goalOffsetX,
    ...(useCastle ? { goalX, goalArea: mode } : {}),
    width: goalX + goalAreaW,
    height,
    columns,
  }
  const goal = { ...s.goal, x: goalX + goalOffsetX, y: goalY }
  // the castle geometry travels with a castle layout only (a disc layout has no use for it)
  const { castle: _castle, ...restNoCastle } = rest

  return useCastle ? { ...rest, goal, nodes, headers, bands, layout } : { ...restNoCastle, goal, nodes, headers, bands, layout }
}

/**
 * The dashboard model of one epic. The dashboard shows undecomposed stories as ghost bands (E92_S12_T02), so
 * `includeUndecomposed` is on by default; the fourth argument can override it, e.g. `{ includeUndecomposed: false }`.
 * A payload without the per-story `decomposed` flag (an older script) gives the model it always gave.
 *
 * E92_S13_T02: the model also carries `castle` (the geometry of the citadel, castleLayout.js, built from the castle model of
 * castleModel.js: towers, bridges, wall, `box`, `text`, `scale`) and lays the goal out for `options.goalArea` ('castle', the
 * default, or 'disc', the star's fixed area; see DISC_AREA). A castle layout carries `castle` and `layout.goalArea: 'castle'`;
 * a disc layout has neither and is exactly the layout the model had before the goal designs.
 */
export function buildDependencyTreeModel(graph, epicId, labels, options) {
  const { goalArea, ...structureOptions } = options || {}
  const structure = buildDependencyStructure(graph, epicId, labels, { includeUndecomposed: true, ...structureOptions })
  if (structure.empty) return layoutTree(structure)
  // ONE castle model, three geometries: the citadel's, the facade's and the seasons tree's are all made from this same object
  // (`castle.source`, `castle.facade.source`, `castle.tree.source`), so the designs can never disagree about a state, a stacking
  // or the wall share
  const source = buildCastleModel(graph, epicId)
  const facts = factsOf(structure.stories)
  const castle = { ...layoutCastle(source, facts), facade: layoutFacade(source, facts), tree: layoutSeasonsTree(source, facts) }
  return layoutTree({ ...structure, castle }, { goalArea })
}

/** { storyId: { done, total, failed } } as the structure states them (`done` and `total` are the payload's, `failed` its bucket). */
function factsOf(stories) {
  const out = {}
  for (const st of stories || []) out[st.storyId] = { done: st.done, total: st.total, failed: st.buckets && Number.isFinite(st.buckets.failed) ? st.buckets.failed : 0 }
  return out
}

/**
 * Pure helper for the renderer's expansion state: the model with the groups whose ids are in `expandedIds` (a Set or
 * an array) unfolded. Returns the new nodes, collapse headers, bands, edges (de-duplicated), goal position and layout;
 * an unknown id is ignored. With no ids it returns the folded model again. `options.goalArea` ('castle' or 'disc') lays the
 * goal out for another goal design (E92_S13_T02); the default is the area the model was built with.
 */
export function unfoldGroups(model, expandedIds, options) {
  if (!model || model.empty) return model
  const goalArea = (options && options.goalArea) || (model.layout && model.layout.goalArea) || 'disc'
  return layoutTree({ ...foldStructure(model, expandedIds ? [...expandedIds] : []), ...(model.castle ? { castle: model.castle } : {}) }, { goalArea })
}
