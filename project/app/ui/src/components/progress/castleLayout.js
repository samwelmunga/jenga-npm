/**
 * castleLayout - E92_S13_T02.
 *
 * Pure (React-free, DOM-free, import-free) geometry of the citadel: where every tower, bridge deck, pier, wall block, bastion
 * and the gate stands, and how big the whole castle is (its box). It takes the castle MODEL of castleModel.js (what stands on
 * what, the layers, the wall share) and draws nothing: CitadelGoal.jsx only paints what this file returns. No percent, status
 * or "decomposed" is worked out here: the layers, the states, the stacking and the wall share come from the model; the only
 * numbers made here are positions and sizes. It holds no colour and no user-visible word.
 *
 * The picture is a 2:1 isometric one. A footprint of half-width w is a diamond: left corner (cx - w, cy), right corner
 * (cx + w, cy), front corner (cx, cy + w / 2), back corner (cx, cy - w / 2); a layer of height h stands up from it (y grows
 * downwards, "up" is a smaller y). All coordinates below are in the NATURAL frame (the table-top centre is 0,0, scale 1);
 * `scale` and `shiftY` turn them into the goal frame (the goal node's own coordinates, centre 0,0): x * scale, y * scale + shiftY.
 *
 * What stands where (story decisions 3, 4 and 6):
 *  - Every story that stands on the table (stacking `ground`) is a root; roots stand side by side in one row along the table, in
 *    the model's `order`. Roots are the only things placed beside each other on the table, so the x-extents of two roots never
 *    overlap, whatever stands on them.
 *  - A story that stands on one tower sits on that tower's top; a story on a bridge sits on the top of its tree parent (the
 *    model's `tree.parent`, the highest of its supports) and the bridge deck runs from it to the other supports. Several
 *    stories on one tower stand side by side on its top, so a tower that carries others is as wide as they need (half-width
 *    `w`); a story is never wider than the tower it stands on, so a stack never reaches past its root's extent.
 *  - A story stands at the top of the HIGHEST of its supports. A support lower than that gets a pier up to the deck.
 *  - A tower is a status base, then its layers (`plan` of the model: three blocks across, or k blocks across above the height
 *    cap H = 8, which makes the footprint wider, never the tower taller), then its top (roof, battlements or nothing). An
 *    undecomposed story is a dashed foundation: no layers.
 *
 * Size limits, and why (also in project/documentation/progress-visualisation.md):
 *  - block        5 units: half-width of one block across the footprint, so a normal tower (3 blocks) is 15 wide on each side of
 *                 its centre and a tower widened by the height cap k blocks is 5 * k. One block size for every tower keeps the
 *                 bricks the same everywhere; a tower that carries several others is wider and its bricks scale with it.
 *  - layer height one layer is 7.5 units tall for a normal tower and never below 7 or above 14 (a tower made wide by what it
 *                 carries has proportionally taller bricks), so a tower of the cap's 8 layers is about 64 units tall, about
 *                 as tall as the median castle (16 tasks, 6 stories, a row of ~190 units) is wide / 3.
 *  - max width    440 units and max height 420 units of the finished castle in the goal frame. A castle that is naturally bigger
 *                 (the 94 task, 22 story one is about 870 wide) is drawn at a uniform scale, which cannot create an overlap and
 *                 keeps every proportion; the scale never goes below 0.3, below which a block is too small to tell its state, and
 *                 a castle that would still be larger is allowed to be larger rather than unreadable.
 *  - table top    a plank table under everything, wider than the wall by a rim; the wall is a diamond around the row of roots.
 */

import { BLOCKS_PER_LAYER } from './castleModel.js'

export const CASTLE_LIMITS = Object.freeze({
  block: 5,
  gap: 6, // clear space between two stories side by side
  slabH: 3, // status base thickness
  slabPad: 1.5, // status base overhang
  layerRatio: 1.5, // layer height = block width x ratio
  layerMin: 7,
  layerMax: 14,
  foundationH: 7, // a dashed foundation
  roofRatio: 1.7, // roof height = tower half-width x ratio
  flagH: 16, // pole and flag over a roof
  battlementH: 5,
  deckH: 4, // thickness of a bridge deck
  pierW: 3, // half-width of a pier
  rowMargin: 26, // wall diamond half-width beyond the row of roots
  rimMargin: 12, // table beyond the wall
  minHalf: 70, // smallest wall half-width (a castle with one small tower is still a castle)
  tableH: 7,
  wallH: 11, // wall block height
  merlonH: 4,
  bastionLayers: 5,
  bastionLayerH: 4,
  bastionHalf: 8,
  bastionTop: 46, // room above a bastion for its roof and flag, fixed so the box does not change when the goal is reached
  perEdgeMin: 5,
  perEdgeMax: 12,
  maxWidth: 440,
  maxHeight: 420,
  minScale: 0.3,
  textGap: 22, // from the box bottom to the first goal text line
  textBlockH: 100, // room for the goal text under the castle (name, title, count, decomposed, a wrapped failed line)
  looseMax: 3, // most rejected blocks drawn beside a tower
})

const L = CASTLE_LIMITS
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))
const round2 = v => Math.round(v * 100) / 100
const lerp = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]

/** Places every tower and builds the table, the wall and the box. A castle with no tower is still a table, a wall and a gate. */
function finish(castle, roots, towersById, facts) {
  const towersOut = castle.towers.map(t => towersById.get(t.storyId))
  const rowHalf = roots.length ? (roots.reduce((s, r) => s + 2 * towersById.get(r).w, 0) + L.gap * (roots.length - 1)) / 2 : 0
  const half = Math.max(L.minHalf, rowHalf + L.rowMargin) // wall diamond half-width
  const table = half + L.rimMargin

  // roots side by side, centred on the table
  let x = -rowHalf
  for (const r of roots) {
    const t = towersById.get(r)
    t.cx = x + t.w
    x += 2 * t.w + L.gap
  }
  // then everything standing on them, level by level (a support is always placed before what stands on it)
  const hostRow = parent => {
    const kids = parent.kids.map(id => towersById.get(id))
    const span = kids.reduce((s, k) => s + 2 * k.w, 0) + L.gap * Math.max(0, kids.length - 1)
    let kx = parent.cx - span / 2
    for (const k of kids) {
      k.cx = kx + k.w
      kx += 2 * k.w + L.gap
      hostRow(k)
    }
  }
  for (const r of roots) hostRow(towersById.get(r))

  // heights: base y of every tower (the top of its highest support), decks and piers
  const byLevel = towersOut.slice().sort((a, b) => a.level - b.level)
  for (const t of byLevel) {
    if (t.supports.length === 0) {
      t.base = 0
    } else {
      const tops = t.supports.map(id => towersById.get(id).topY)
      t.base = Math.min(...tops)
    }
    t.stackH = t.undecomposed ? L.foundationH : t.layers.length * t.layerH
    t.topY = t.base - L.slabH - t.stackH
    const crown = t.top === 'roof' ? t.w * L.roofRatio + L.flagH : t.top === 'battlements' ? L.battlementH : 0
    t.crownH = round2(crown)
    t.roofH = t.top === 'roof' ? round2(t.w * L.roofRatio) : 0
    t.reachY = t.topY - t.crownH
    if (t.stacking === 'bridge') {
      const xs = [t.cx, ...t.supports.map(id => towersById.get(id).cx)]
      t.deck = { x1: round2(Math.min(...xs) - L.pierW), x2: round2(Math.max(...xs) + L.pierW), y: t.base, thick: L.deckH }
      t.piers = t.supports
        .map(id => towersById.get(id))
        .filter(s => s.topY > t.base + 0.5)
        .map(s => ({ support: s.storyId, x: round2(s.storyId === t.parent ? t.cx : s.cx), y1: round2(s.topY), y2: round2(t.base) }))
    } else {
      t.deck = null
      t.piers = []
    }
  }

  // the wall: a diamond of lying blocks around the row, built from the gate by the model's wall share
  const per = clamp(Math.round(half / 14), L.perEdgeMin, L.perEdgeMax)
  const N = per * 4
  const corners = { F: [0, half / 2], R: [half, 0], B: [0, -half / 2], L: [-half, 0] }
  const edges = [['F', 'R', 'R'], ['R', 'B', 'B'], ['B', 'L', 'B'], ['L', 'F', 'L']]
  const gateJ = per * 3 + Math.floor(per / 2)
  const built = Math.round(N * castle.wall.share)
  const isBuilt = j => ((j - gateJ + N) % N) < built
  const blocks = []
  edges.forEach(([from, to, side], ei) => {
    for (let k = 0; k < per; k++) {
      const j = ei * per + k
      const p0 = lerp(corners[from], corners[to], k / per + 0.01)
      const p1 = lerp(corners[from], corners[to], (k + 1) / per - 0.01)
      blocks.push({ index: j, side, back: side === 'B', built: isBuilt(j), gate: j === gateJ, p0: p0.map(round2), p1: p1.map(round2) })
    }
  })
  const bastions = [['F', 0], ['R', per], ['B', 2 * per], ['L', 3 * per]].map(([c, j]) => ({
    corner: c, index: j, x: corners[c][0], y: corners[c][1], back: c === 'B', built: isBuilt(j),
  }))

  // extents of the natural frame
  const left = -table
  const right = table
  let top = -half / 2 - L.wallH - L.merlonH - L.bastionTop
  for (const t of towersOut) top = Math.min(top, t.reachY)
  const bottom = table / 2 + L.tableH
  const naturalW = right - left
  const naturalH = bottom - top
  const scale = clamp(Math.min(1, L.maxWidth / naturalW, L.maxHeight / naturalH), L.minScale, 1)
  const w = naturalW * scale
  const h = naturalH * scale
  const shiftY = -((top + bottom) / 2) * scale
  const box = { left: round2(-w / 2), right: round2(w / 2), top: round2(-h / 2), bottom: round2(h / 2), w: round2(w), h: round2(h) }

  return {
    source: castle, // the castle model (castleModel.js) this geometry was made from; the facade is made from the same object
    empty: castle.empty,
    scale: round2(scale),
    shiftY: round2(shiftY),
    limits: { ...L },
    natural: { left: round2(left), right: round2(right), top: round2(top), bottom: round2(bottom), w: round2(naturalW), h: round2(naturalH) },
    box,
    text: { top: round2(box.bottom + L.textGap), blockH: L.textBlockH },
    table: { half: round2(table), thick: L.tableH },
    wall: { half: round2(half), per, count: N, built, share: castle.wall.share, percent: castle.wall.percent, reached: castle.wall.reached, gate: gateJ, height: L.wallH, merlon: L.merlonH, corners, blocks, bastions },
    roots,
    towers: towersOut.map(t => ({ ...t, w: round2(t.w), cx: round2(t.cx), base: round2(t.base), topY: round2(t.topY), reachY: round2(t.reachY), layerH: round2(t.layerH), stackH: round2(t.stackH) })),
    facts: facts || {},
  }
}

/**
 * The geometry of one castle. `castle` is buildCastleModel's output; `facts` maps a story id to { done, total, failed } as the
 * payload states them (never counted here), kept on each tower for its label. Pure; the input is not changed.
 */
export function layoutCastle(castle, facts) {
  const model = castle && typeof castle === 'object' && Array.isArray(castle.towers) ? castle : { empty: true, towers: [], stories: [], order: [], wall: { percent: 0, share: 0, reached: false } }
  const storyOf = new Map((model.stories || []).map(s => [s.storyId, s]))
  const index = new Map((model.order || []).map((id, i) => [id, i]))
  const towersById = new Map()
  for (const t of model.towers) {
    const story = storyOf.get(t.storyId)
    const kind = t.stacking.kind
    const parent = kind === 'ground' ? null : kind === 'tower' ? t.stacking.on[0] : (story && story.tree && story.tree.parent) || t.stacking.on[0]
    const blocksAcross = t.plan ? t.plan.width : BLOCKS_PER_LAYER
    towersById.set(t.storyId, {
      storyId: t.storyId,
      title: t.title,
      status: t.status,
      undecomposed: t.undecomposed,
      finished: t.finished,
      leaf: t.leaf,
      lean: t.lean,
      level: t.level,
      stacking: kind,
      supports: kind === 'ground' ? [] : t.stacking.on.slice(),
      ...(kind === 'bridge' ? { adjacent: t.stacking.adjacent === true } : {}),
      parent,
      top: t.top,
      plan: t.plan,
      layers: t.layers,
      loose: t.loose.slice(0, L.looseMax),
      looseCount: t.loose.length,
      blocksAcross,
      own: blocksAcross * L.block,
      w: 0,
      layerH: 0,
      kids: [],
      facts: facts && facts[t.storyId] ? facts[t.storyId] : null,
    })
  }
  // children, in the model's order, and the footprint of every tower (what it carries decides how wide it is)
  for (const t of towersById.values()) if (t.parent && towersById.has(t.parent)) towersById.get(t.parent).kids.push(t.storyId)
  for (const t of towersById.values()) t.kids.sort((a, b) => index.get(a) - index.get(b))
  const width = id => {
    const t = towersById.get(id)
    if (t.w) return t.w
    const kids = t.kids.map(width)
    const need = kids.length ? (kids.reduce((s, k) => s + 2 * k, 0) + L.gap * (kids.length - 1)) / 2 : 0
    t.w = Math.max(t.own, need)
    t.layerH = clamp((t.w / t.blocksAcross) * L.layerRatio, L.layerMin, L.layerMax)
    return t.w
  }
  for (const id of towersById.keys()) width(id)
  const roots = model.towers.filter(t => t.stacking.kind === 'ground' || !towersById.has(towersById.get(t.storyId).parent)).map(t => t.storyId)
  return finish(model, roots, towersById, facts)
}

/**
 * Where an edge to the goal ends: `count` points spread along the left half of the wall's top edge (back corner, left corner,
 * front corner), in the goal frame, top to bottom, so the edges of several end stories do not pile onto one point. The points
 * are in order of y, so a caller that sorts its edges by the y of their source draws no crossing. One edge ends at the left corner.
 */
export function goalAnchors(layout, count) {
  const n = Math.max(0, Math.floor(count))
  if (!layout || !layout.wall) return Array.from({ length: n }, () => ({ x: 0, y: 0 }))
  const { corners, height } = layout.wall
  const s = layout.scale
  const ty = layout.shiftY
  const path = [corners.B, corners.L, corners.F]
  const at = t => {
    const seg = t < 0.5 ? 0 : 1
    const u = seg === 0 ? t * 2 : (t - 0.5) * 2
    const p = lerp(path[seg], path[seg + 1], u)
    return { x: round2(p[0] * s), y: round2((p[1] - height) * s + ty) }
  }
  const spread = 0.8 // of the half perimeter, centred on the left corner
  return Array.from({ length: n }, (_, i) => at(0.5 + ((i + 0.5) / n - 0.5) * spread))
}
