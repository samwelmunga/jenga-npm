/**
 * facadeLayout - E92_S13_T03.
 *
 * Pure (React-free, DOM-free) geometry of the facade: the flat elevation of the Jenga castle (story decision 1, prototype C3).
 * It takes the SAME castle model as the citadel (castleModel.js, E92_S13_T01: what stands on what, the layers and their
 * states, the wall share) and draws nothing: FacadeGoal.jsx only paints what this file returns. No percent, status or
 * "decomposed" is worked out here; the layers, the states, the stacking and the wall share come from the model, and the only
 * numbers made here are positions and sizes. It holds no colour and no user-visible word. The model object it was built from
 * is kept in `source`, so a test (and a reader) can see that the citadel and the facade drew one and the same model.
 *
 * The picture is a flat elevation: x to the right, the ground line at y = 0, "up" is a smaller y. All coordinates are in the
 * NATURAL frame (centre of the castle x = 0, scale 1); `scale` and `shiftY` turn them into the goal frame (the goal node's
 * own coordinates, centre 0,0): x * scale, y * scale + shiftY.
 *
 * What stands where (decisions 3 and 4, the same rules as the citadel):
 *  - A tower is a status base, then its layers (`plan` of the model: three blocks across, or k blocks across above the height
 *    cap H = 8), then its top (roof, battlements or nothing). A layer whose direction is `x` shows its block ENDS (n blocks
 *    side by side), a layer whose direction is `z` shows ONE LONG block, so the layers alternate like a real Jenga tower. An
 *    undecomposed story is a dashed foundation with no layers.
 *  - Roots (stacking `ground`) stand side by side on the ground line, in the model's `order`; a story on one tower stands on
 *    that tower's top, a story on a bridge stands on the top of its tree parent with a deck to the other supports and piers
 *    under the lower ones. Several stories on one tower stand side by side on its top, so a tower that carries others is as
 *    wide as they need and a stack never reaches past its root's extent.
 *  - The curtain wall grows OUTWARD from the main building in BOTH directions: its segments alternate left, right, left,
 *    right, starting next to the row of roots, and the two bastions at the outer ends come last, so `built = round(count *
 *    wall share)` segments are built, the same number (plus at most one) on each side, always the ones nearest the building.
 *  - The gate is a block pulled out of the ground in front of the main building (the trunk root of the model, else the first
 *    root); it is built (dark) once the wall has started.
 *
 * Size limits (also in project/documentation/progress-visualisation.md): the facade has its own box because it is wide and low
 * where the citadel is square: at most 480 units wide and 360 high in the goal frame, scaled uniformly (never below 0.3).
 */

import { BLOCKS_PER_LAYER } from './castleModel.js'

export const FACADE_LIMITS = Object.freeze({
  blockHalf: 4.5, // half-width of one block end: a normal tower (3 blocks) is 13.5 on each side of its centre
  gap: 12, // clear space between two stories side by side (room for a pulled-out block and the loose blocks)
  slabH: 3, // status base thickness
  slabPad: 1.5, // status base overhang
  layerRatio: 2.2, // layer height = block half-width x ratio
  layerMin: 9,
  layerMax: 16,
  foundationH: 7, // a dashed foundation
  roofRatio: 1.6, // roof height = tower half-width x ratio
  flagH: 16, // pole and flag over a roof
  battlementH: 6,
  deckH: 4, // thickness of a bridge deck
  pierW: 3, // half-width of a pier
  segW: 16, // one wall segment
  wallH: 18, // wall height
  merlonH: 5,
  wallGap: 3, // between the row of roots and the first wall segment
  bastionW: 20,
  bastionLayers: 5,
  bastionLayerH: 6,
  bastionTop: 66, // room above the ground for a bastion with its roof and flag, fixed so the box does not change when the goal is reached
  perMin: 3,
  perMax: 8,
  minHalf: 30, // smallest half-width of the row (a castle with one small tower is still a castle)
  groundH: 8, // the hatched ground strip under the ground line
  margin: 14, // board beyond the wall
  maxWidth: 480,
  maxHeight: 360,
  minScale: 0.3,
  textGap: 22, // from the box bottom to the first goal text line
  textBlockH: 100, // room for the goal text under the castle
  looseMax: 3, // most rejected blocks drawn beside a tower
  gateW: 9,
  gateH: 7,
})

const L = FACADE_LIMITS
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))
const round2 = v => Math.round(v * 100) / 100

/** The geometry of one facade. `castle` is buildCastleModel's output; `facts` maps a story id to { done, total, failed } as the payload states them. Pure; the input is not changed. */
export function layoutFacade(castle, facts) {
  const model = castle && typeof castle === 'object' && Array.isArray(castle.towers) ? castle : { empty: true, towers: [], stories: [], order: [], trunk: null, wall: { percent: 0, share: 0, reached: false } }
  const storyOf = new Map((model.stories || []).map(s => [s.storyId, s]))
  const index = new Map((model.order || []).map((id, i) => [id, i]))
  const byId = new Map()
  for (const t of model.towers) {
    const story = storyOf.get(t.storyId)
    const kind = t.stacking.kind
    const parent = kind === 'ground' ? null : kind === 'tower' ? t.stacking.on[0] : (story && story.tree && story.tree.parent) || t.stacking.on[0]
    const blocksAcross = t.plan ? t.plan.width : BLOCKS_PER_LAYER
    byId.set(t.storyId, {
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
      own: blocksAcross * L.blockHalf,
      w: 0,
      layerH: 0,
      kids: [],
      facts: facts && facts[t.storyId] ? facts[t.storyId] : null,
    })
  }
  for (const t of byId.values()) if (t.parent && byId.has(t.parent)) byId.get(t.parent).kids.push(t.storyId)
  for (const t of byId.values()) t.kids.sort((a, b) => index.get(a) - index.get(b))
  // the footprint of every tower: what it carries decides how wide it is
  const width = id => {
    const t = byId.get(id)
    if (t.w) return t.w
    const kids = t.kids.map(width)
    const need = kids.length ? (kids.reduce((s, k) => s + 2 * k, 0) + L.gap * (kids.length - 1)) / 2 : 0
    t.w = Math.max(t.own, need)
    t.layerH = clamp((t.w / t.blocksAcross) * L.layerRatio, L.layerMin, L.layerMax)
    return t.w
  }
  for (const id of byId.keys()) width(id)
  const roots = model.towers.filter(t => t.stacking.kind === 'ground' || !byId.has(byId.get(t.storyId).parent)).map(t => t.storyId)

  const rowHalf = roots.length ? Math.max(L.minHalf, (roots.reduce((s, r) => s + 2 * byId.get(r).w, 0) + L.gap * (roots.length - 1)) / 2) : L.minHalf
  // roots side by side, centred; then what stands on them, level by level (a support is always placed before what stands on it)
  let x = -((roots.reduce((s, r) => s + 2 * byId.get(r).w, 0) + L.gap * Math.max(0, roots.length - 1)) / 2)
  for (const r of roots) {
    const t = byId.get(r)
    t.cx = x + t.w
    x += 2 * t.w + L.gap
  }
  const hostRow = parent => {
    const kids = parent.kids.map(id => byId.get(id))
    const span = kids.reduce((s, k) => s + 2 * k.w, 0) + L.gap * Math.max(0, kids.length - 1)
    let kx = parent.cx - span / 2
    for (const k of kids) {
      k.cx = kx + k.w
      kx += 2 * k.w + L.gap
      hostRow(k)
    }
  }
  for (const r of roots) hostRow(byId.get(r))

  // heights: the base of every tower is the top of its highest support; decks and piers
  const towersOut = model.towers.map(t => byId.get(t.storyId))
  for (const t of towersOut.slice().sort((a, b) => a.level - b.level)) {
    t.base = t.supports.length === 0 ? 0 : Math.min(...t.supports.map(id => byId.get(id).topY))
    t.stackH = t.undecomposed ? L.foundationH : t.layers.length * t.layerH
    t.topY = t.base - L.slabH - t.stackH
    const crown = t.top === 'roof' ? t.w * L.roofRatio + L.flagH : t.top === 'battlements' ? L.battlementH : 0
    t.crownH = round2(crown)
    t.roofH = t.top === 'roof' ? round2(t.w * L.roofRatio) : 0
    t.reachY = t.topY - t.crownH
    if (t.stacking === 'bridge') {
      const xs = [t.cx, ...t.supports.map(id => byId.get(id).cx)]
      t.deck = { x1: round2(Math.min(...xs) - L.pierW), x2: round2(Math.max(...xs) + L.pierW), y: t.base, thick: L.deckH }
      t.piers = t.supports
        .map(id => byId.get(id))
        .filter(s => s.topY > t.base + 0.5)
        .map(s => ({ support: s.storyId, x: round2(s.storyId === t.parent ? t.cx : s.cx), y1: round2(s.topY), y2: round2(t.base) }))
    } else {
      t.deck = null
      t.piers = []
    }
  }

  // the wall: segments alternate left and right of the row of roots, nearest first, then the two bastions; built by the model's share
  const per = clamp(Math.round(rowHalf / 16), L.perMin, L.perMax)
  const count = per * 2 + 2
  const built = Math.round(count * model.wall.share)
  const inner = rowHalf + L.wallGap
  const segments = []
  for (let k = 0; k < per; k++) {
    for (const side of ['left', 'right']) {
      const index2 = k * 2 + (side === 'left' ? 0 : 1)
      const near = inner + k * L.segW
      const far = near + L.segW
      segments.push({ index: index2, side, k, x1: round2(side === 'left' ? -far : near), x2: round2(side === 'left' ? -near : far), built: index2 < built })
    }
  }
  const bastionIn = inner + per * L.segW
  const bastions = ['left', 'right'].map((side, i) => ({
    side,
    index: per * 2 + i,
    x1: round2(side === 'left' ? -(bastionIn + L.bastionW) : bastionIn),
    x2: round2(side === 'left' ? -bastionIn : bastionIn + L.bastionW),
    built: per * 2 + i < built,
  }))
  const half = bastionIn + L.bastionW // the outer extent of the wall
  // the gate stands in front of the main building: the trunk root of the model, else the first root
  const main = (model.trunk && byId.has(model.trunk) && roots.includes(model.trunk) ? byId.get(model.trunk) : roots.length ? byId.get(roots[0]) : null)

  // extents of the natural frame
  const left = -(half + L.margin)
  const right = half + L.margin
  let top = -L.bastionTop
  for (const t of towersOut) top = Math.min(top, t.reachY)
  top -= 4
  const bottom = L.groundH + 6
  const naturalW = right - left
  const naturalH = bottom - top
  const scale = clamp(Math.min(1, L.maxWidth / naturalW, L.maxHeight / naturalH), L.minScale, 1)
  const w = naturalW * scale
  const h = naturalH * scale
  const shiftY = -((top + bottom) / 2) * scale
  const box = { left: round2(-w / 2), right: round2(w / 2), top: round2(-h / 2), bottom: round2(h / 2), w: round2(w), h: round2(h) }

  return {
    source: model,
    empty: model.empty,
    scale: round2(scale),
    shiftY: round2(shiftY),
    limits: { ...L },
    natural: { left: round2(left), right: round2(right), top: round2(top), bottom: round2(bottom), w: round2(naturalW), h: round2(naturalH) },
    box,
    text: { top: round2(box.bottom + L.textGap), blockH: L.textBlockH },
    ground: { left: round2(left), right: round2(right), strip: L.groundH },
    wall: { half: round2(half), rowHalf: round2(rowHalf), per, count, built, share: model.wall.share, percent: model.wall.percent, reached: model.wall.reached, height: L.wallH, merlon: L.merlonH, segments, bastions },
    gate: { x: round2(main ? main.cx : 0), w: L.gateW, h: L.gateH, built: built > 0, main: main ? main.storyId : null },
    roots,
    towers: towersOut.map(t => ({ ...t, w: round2(t.w), cx: round2(t.cx), base: round2(t.base), topY: round2(t.topY), reachY: round2(t.reachY), layerH: round2(t.layerH), stackH: round2(t.stackH) })),
    facts: facts || {},
  }
}

/**
 * Where an edge to the goal ends: `count` points spread down the left edge of the facade (the outer face of the left bastion),
 * in the goal frame, top to bottom, so the edges of several end stories do not pile onto one point. The points are in order
 * of y, so a caller that sorts its edges by the y of their source draws no crossing.
 */
export function facadeAnchors(layout, count) {
  const n = Math.max(0, Math.floor(count))
  if (!layout || !layout.wall) return Array.from({ length: n }, () => ({ x: 0, y: 0 }))
  const s = layout.scale
  const ty = layout.shiftY
  const xLeft = -layout.wall.half
  const hi = -(L.bastionLayers * L.bastionLayerH) + 4 // near the top of the bastion
  const lo = -4 // near the ground
  return Array.from({ length: n }, (_, i) => ({ x: round2(xLeft * s), y: round2((hi + ((i + 0.5) / n) * (lo - hi)) * s + ty) }))
}
