/**
 * treeLayout - E92_S13_T07.
 *
 * Pure (React-free, DOM-free, import-free) geometry of the seasons tree: the third goal design (story decision 9, prototype
 * project/documentation/prototypes/E92_S13/seasons-tree.html). It takes the SAME castle model as the citadel and the facade
 * (castleModel.js, E92_S13_T01: the per-story data, the states of the counted tasks in census order, the tree parent and lean
 * rule, the wall share) and draws nothing: TreeGoal.jsx only paints what this file returns. It computes no count, percent,
 * status or "decomposed" of its own: the percent and the goal-reached state are the model's `wall` (epic_progress), the
 * done / total figures are the payload's (`facts`, as for the castle), and the only numbers made here are positions, sizes and
 * the deterministic order things are placed in. It holds no colour and no user-visible word. The model object it was built
 * from is kept in `source`, so a test (and a reader) can see that all three designs drew one and the same model.
 *
 * Why it lives here, as a file of its own next to castleLayout.js and facadeLayout.js: the branching is geometry on top of the
 * castle model's per-story data (the model owns WHAT stands on what; the layout owns WHERE), it feeds the edge routing, zoom,
 * Fit and fullscreen through the box dependencyTreeModel.js carries, and it must be Node-testable without a bundler
 * (scripts/tree-layout.test.cjs). The renderer file stays a painter. It is dashboard-only (story decision 8), so it is not in
 * lib/progress/ and has no second copy.
 *
 * COORDINATES. The tree is laid out in TREE SPACE: x to the right, y down, the base of the trunk (the middle of the island) at
 * 0,0, "up" is a smaller y. `scale`, `shiftX` and `shiftY` turn tree space into the goal node's own coordinates (centre 0,0):
 * x * scale + shiftX, y * scale + shiftY. The frame (the drawing box: sky, forest, pool) is sized for the FULLY GROWN tree, so
 * it never changes with the percent (the edges to the goal and Fit stay put while the epic is worked on).
 *
 * THE RULES (also in the task summary and in progress-visualisation.md):
 *  - Trunk. The root story is the trunk and the heart of the crown: the model's `trunk` (the first story without an in-epic
 *    dependency in board order that is not in a cycle). Every other story without a tree parent (a second root, a story
 *    whose dependency is outside the epic, a dependency-cycle member: castleModel gives it `parent: null` and `anchor` = the
 *    trunk) grows from the trunk. A story with a parent grows out of its parent's branch; one with two or more dependencies
 *    grows from the FIRST (the model's `parent`) and its branch bends toward the others (`tree.lean`). A parent that is not a
 *    drawn story, or a parent chain that loops (castleModel never makes one, this is defence), falls back to the trunk. Nothing
 *    here throws or loops on odd input.
 *  - Angles. Branches radiate from the crown heart (the trunk's tip) in a fan of FAN degrees (upward, a little below the
 *    horizontal at both ends). A story's sector is as wide as its subtree needs (a subtree of the territories of its clump
 *    clusters at the smallest radius its tips can have), the children of a node divide its sector in board order, a story points
 *    at the middle of its sector. Sectors of different subtrees are disjoint, the rings of tips of consecutive depths are
 *    separated by the territories of both, so two clusters of clumps never overlap. When the fan is not wide enough for the
 *    sectors, the rings move out (the drawing is then scaled down to its box), never the other way round.
 *  - Length. A branch lengthens with its story's done share (the payload's done / total): its tip stands at a radius between
 *    BRANCH.minReach and 1 of the ring. A failed story's branch droops: its tip sags by DROOP and its curve sags.
 *  - Attachment. Children of one parent attach along its branch between ATTACH.from and ATTACH.to; on each side of the parent's
 *    heading the child that points furthest sideways attaches lowest, so siblings do not cross.
 *  - Clumps: one per counted task, in the model's census order (done, in progress, failed, pending), the done ones on the slots
 *    nearest the crown heart. The clumps are a status picture, not a dependency structure. arrangeClumps() is the large-story rule.
 *  - Rejected tasks are not counted (E92 decision 3) and are not drawn: the tree has no loose-block counterpart, because a
 *    rejected task is neither a season nor a leaf, and a fallen leaf would read as a state the board does not have.
 */

import { idCompare } from './castleModel.js'

const D = Math.PI / 180
const round2 = v => Math.round(v * 100) / 100 + 0 // + 0: never -0
const floor2 = v => Math.floor(v * 100 + 1e-9) / 100 + 0 // rounded down, so a box made from a scale never exceeds its limit
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))
/** A deterministic pseudo-random number in [0, 1) from a number (the prototype's hash). */
export const hsh = n => {
  const x = Math.sin(n * 127.1 + 311.7) * 43758.5453
  return x - Math.floor(x)
}

/** Sizes of the frame, the box the tree is scaled into and the room the goal text takes under it. All in tree space unless stated. */
export const TREE_LIMITS = Object.freeze({
  minHalfW: 340, // the frame is at least 680 wide (the prototype's width) and symmetric round the trunk
  above: 440, // and at least this high above the base of the trunk
  below: 120, // the island hangs, then the pool: this far below the base
  margin: 30, // room beyond the outermost clump
  labelRoom: 26, // room above the highest cluster for its label pill
  maxWidth: 560, // the box in the goal frame, scaled uniformly
  maxHeight: 460,
  minScale: 0.3,
  textGap: 22, // from the box bottom to the first goal text line
  textBlockH: 100, // room for the goal text under the tree (name, title, count, decomposed, a wrapped failed line)
})

/** Growth of the whole tree with epic_progress k (0..1): scale S = minScale + (1 - minScale) * k about the base of the trunk. */
export const GROWTH = Object.freeze({ minScale: 0.42 })

/** The trunk: height and girth grow with k (prototype: 122 * (.85 + .55 k) and 22 + 40 sqrt k, then the growth scale). */
export const TRUNK = Object.freeze({ height: 122, heightMin: 0.85, heightGrow: 0.55, girth: 22, girthGrow: 40, bend: 0.1 })

/** Branches: girth (tapering with what grows beyond them, never more than 3/4 of the parent where they leave it), curve, droop. */
export const BRANCH = Object.freeze({
  girth: 7,
  girthGrow: 28,
  girthOfParent: 0.75,
  tipRatio: 0.3, // the tip's girth as a share of the base's
  minReach: 0.9, // a branch with no done task reaches this share of its ring, one with every task done reaches the ring
  stubReach: 0.9,
  bend: 0.1, // sideways bulge of the curve, as a share of the length
  leanBend: 0.14, // extra bend toward the other dependencies of a story
  droop: 4, // a failed story's tip sags this far (it is part of the territory)
  droopSag: 0.16, // and its curve sags this share of the length
  ribbonAt: 0.12,
})

/** Where along the parent's branch the children attach, from the lowest to the highest. */
export const ATTACH = Object.freeze({ from: 0.45, to: 0.88 })

/** The fan the sectors of the crown heart's children share, in degrees: up, and a little below the horizontal at both ends. */
export const FAN = 220
/** The gap kept between two territories (tree space). */
export const TERRITORY_GAP = 4

/**
 * One clump and the room one story's clumps need. A done clump has radius CLUMP.radius * shrink; the other states are smaller
 * (CLUMP.share); `pitch` is the distance between neighbouring slots as a multiple of the radius, so no two clumps overlap.
 */
export const CLUMP = Object.freeze({
  radius: 22,
  pitch: 2.05,
  pad: 5, // territory = outermost slot centre + the clump radius + this (it also covers the droop)
  share: Object.freeze({ done: 1, failed: 0.78, in_progress: 0.66, pending: 0.4 }),
})

/** The large-story rule's constants: up to `fanMax` clumps keep the full radius, beyond that the radius shrinks, never below `minShrink`. */
export const LARGE_STORY = Object.freeze({ fanMax: 7, minShrink: 0.55 })

/** A dormant stub (an undecomposed story) takes this much room. */
export const STUB = Object.freeze({ territory: 12, radius: 7 })

/** The six growth stages, in order, as ONE table: the percent each starts at and the labels key of its name. Majestic tree only at goal reached. */
export const GROWTH_STAGES = Object.freeze([
  Object.freeze({ id: 'sprout', percent: 0, labelKey: 'tree_stage_sprout' }),
  Object.freeze({ id: 'seedling', percent: 10, labelKey: 'tree_stage_seedling' }),
  Object.freeze({ id: 'sapling', percent: 25, labelKey: 'tree_stage_sapling' }),
  Object.freeze({ id: 'young', percent: 45, labelKey: 'tree_stage_young' }),
  Object.freeze({ id: 'mature', percent: 70, labelKey: 'tree_stage_mature' }),
  Object.freeze({ id: 'majestic', percent: 100, labelKey: 'tree_stage_majestic', goalOnly: true }),
])

/** The index of the growth stage: the last stage whose percent is reached, but the goal-only one only when the goal is reached (99 is Mature tree). */
export function growthStage(percent, reached) {
  const last = GROWTH_STAGES.length - 1
  if (reached === true) return last
  const p = typeof percent === 'number' && Number.isFinite(percent) ? percent : 0
  let idx = 0
  for (let i = 0; i < last; i++) if (p >= GROWTH_STAGES[i].percent) idx = i
  return idx
}

/** The pool's stones with the percent each lifts out at ([x, y, radius], tree space, relative to the base): one named table. */
export const STONES = Object.freeze([
  Object.freeze({ x: -220, y: -70, r: 22, at: 25 }),
  Object.freeze({ x: 226, y: -60, r: 20, at: 45 }),
  Object.freeze({ x: -150, y: 6, r: 12, at: 65 }),
  Object.freeze({ x: 152, y: 10, r: 13, at: 85 }),
])
/** From this percent the mushrooms stand on the island (the prototype's 55). */
export const MUSHROOM_AT = 55

/** The labels: the pill's size and the bounded, deterministic push that keeps them apart. */
export const LABEL = Object.freeze({ fontMin: 10, fontScreen: 10, fontMax: 30, charW: 0.63, padX: 10, height: 1.5, iterations: 240, gap: 2 })

/**
 * THE LARGE-STORY RULE, in one function. A story's clumps are packed on a hexagonal lattice whose neighbouring slots are `pitch`
 * radii apart, so nothing overlaps whatever the count: the lattice is centred on the point (a lattice point, the middle of an edge
 * or the middle of a triangle) that holds the n slots in the smallest circle, so 1 clump is one slot, 2 sit side by side, 3 form a
 * triangle, 7 are a middle and a ring of six, and a larger story fills ring after ring (19 is two rings, the 26-task story three).
 * A story with up to LARGE_STORY.fanMax clumps keeps the full clump radius (that is the middle and the first ring; the 90th
 * percentile of the measured stories has 7 tasks); a larger story shrinks its clumps by sqrt(fanMax / n), never below
 * LARGE_STORY.minShrink, so the 26-task story's three rings stay about as wide as a normal branch's reach instead of dominating the
 * crown. `territory` is the radius of the circle round the tip that holds every slot; the layout keeps the territories of
 * different stories apart. Returns { count, shrink, radius, rings, slots: [{ x, y, ring }], territory }.
 */
export function arrangeClumps(n) {
  const count = Number.isFinite(n) && n > 0 ? Math.floor(n) : 0
  const shrink = count <= LARGE_STORY.fanMax ? 1 : Math.max(LARGE_STORY.minShrink, Math.sqrt(LARGE_STORY.fanMax / count))
  const radius = round2(CLUMP.radius * shrink)
  const step = radius * CLUMP.pitch
  if (count === 0) return { count, shrink: round2(shrink), radius, rings: 0, slots: [], territory: 0 }
  const K = Math.ceil(Math.sqrt(count)) + 2
  const lattice = []
  for (let q = -K; q <= K; q++) for (let r = -K; r <= K; r++) lattice.push([step * (q + r / 2), step * r * (Math.sqrt(3) / 2)])
  const centres = [[0, 0], [step / 2, 0], [step / 2, step * (Math.sqrt(3) / 6)]]
  let best = null
  for (const c of centres) {
    const pts = lattice
      .map(p => ({ x: p[0] - c[0], y: p[1] - c[1] }))
      .map(p => ({ ...p, d: Math.hypot(p.x, p.y), a: Math.atan2(p.y, p.x) }))
      .sort((a, b) => a.d - b.d || a.a - b.a)
      .slice(0, count)
    const reach = pts[pts.length - 1].d
    if (!best || reach < best.reach - 1e-9) best = { pts, reach }
  }
  const slots = best.pts.map(p => ({ x: round2(p.x), y: round2(p.y), ring: Math.round(p.d / step) }))
  const rings = Math.ceil(best.reach / step - 1e-9)
  return { count, shrink: round2(shrink), radius, rings, slots, territory: round2(best.reach + radius + CLUMP.pad) }
}

/** True while a stone has lifted out of the pool at this percent (table STONES): the surroundings read the percent only. */
export const stoneLifted = (percent, stone) => typeof percent === 'number' && percent >= stone.at
/** The number of lifted stones at a percent (0 to 4). */
export const stonesLifted = percent => STONES.filter(s => stoneLifted(percent, s)).length
/** True when the mushrooms stand (from MUSHROOM_AT). */
export const mushroomsShown = percent => typeof percent === 'number' && percent >= MUSHROOM_AT

/** A point of a branch curve (a quadratic bezier { p0, c, p1 }) at t, and the unit tangent there. */
export function curvePoint(b, t) {
  const u = 1 - t
  return [u * u * b.p0[0] + 2 * u * t * b.c[0] + t * t * b.p1[0], u * u * b.p0[1] + 2 * u * t * b.c[1] + t * t * b.p1[1]]
}
export function curveTangent(b, t) {
  const x = 2 * (1 - t) * (b.c[0] - b.p0[0]) + 2 * t * (b.p1[0] - b.c[0])
  const y = 2 * (1 - t) * (b.c[1] - b.p0[1]) + 2 * t * (b.p1[1] - b.c[1])
  const l = Math.hypot(x, y) || 1
  return [x / l, y / l]
}
/** The girth of a branch at t (it tapers from w0 to w1). */
export const girthAt = (b, t) => b.w0 + (b.w1 - b.w0) * Math.pow(t, 0.7)

/** The outline of a label pill, used by the push and by the tests. */
export const labelBox = l => ({ left: l.x - l.w / 2, right: l.x + l.w / 2, top: l.y - l.h / 2, bottom: l.y + l.h / 2 })
const overlap = (a, b, gap = 0) => a.left < b.right + gap && b.left < a.right + gap && a.top < b.bottom + gap && b.top < a.bottom + gap

/**
 * Pushes label pills apart: a bounded (LABEL.iterations passes), deterministic relaxation. Each pass takes every overlapping
 * pair in list order and moves the two apart along the axis of smaller overlap, half each. Returns the same labels, moved; each
 * has `moved` (its distance from its anchor).
 */
export function pushLabels(labels) {
  for (let it = 0; it < LABEL.iterations; it++) {
    let moved = false
    for (let i = 0; i < labels.length; i++) {
      for (let j = i + 1; j < labels.length; j++) {
        const a = labels[i]
        const b = labels[j]
        const ox = (a.w + b.w) / 2 + LABEL.gap - Math.abs(a.x - b.x)
        const oy = (a.h + b.h) / 2 + LABEL.gap - Math.abs(a.y - b.y)
        if (ox > 0 && oy > 0) {
          moved = true
          if (oy < ox) {
            const d = oy / 2 + 0.3
            if (a.y <= b.y) { a.y -= d; b.y += d } else { a.y += d; b.y -= d }
          } else {
            const d = ox / 2 + 0.3
            if (a.x <= b.x) { a.x -= d; b.x += d } else { a.x += d; b.x -= d }
          }
        }
      }
    }
    if (!moved) break
  }
  for (const l of labels) { l.x = round2(l.x); l.y = round2(l.y); l.moved = round2(Math.hypot(l.x - l.ax, l.y - l.ay)) }
  return labels
}

/** True when two label pills overlap (for the tests and for callers that want to check). */
export const labelsOverlap = (a, b) => overlap(labelBox(a), labelBox(b))

/** The box in the goal frame, centred on 0,0 (left is exactly minus right: the half is rounded once). */
const boxOf = (w, h) => ({ left: -round2(w / 2), right: round2(w / 2), top: -round2(h / 2), bottom: round2(h / 2), w: round2(w), h: round2(h) })

/** The stage track: a pill in the lower left corner of the frame. `u` is its size factor, the on-screen size kept whatever the scale (at most 2). */
const trackOf = (frame, scale) => {
  const u = round2(Math.min(2, 1 / scale))
  return { x0: round2(frame.left + 28 * u), x1: round2(frame.left + 28 * u + 232), y: round2(frame.bottom - 32 * u - 8), u }
}

const emptyLayout = (model, wall) => {
  const w = TREE_LIMITS.minHalfW * 2
  const h = TREE_LIMITS.above + TREE_LIMITS.below
  const scale = floor2(clamp(Math.min(1, TREE_LIMITS.maxWidth / w, TREE_LIMITS.maxHeight / h), TREE_LIMITS.minScale, 1))
  const bw = w * scale
  const bh = h * scale
  const box = boxOf(bw, bh)
  return {
    source: model,
    empty: true,
    scale,
    shiftX: 0,
    shiftY: round2(-((-TREE_LIMITS.above + TREE_LIMITS.below) / 2) * scale),
    frame: { x: -TREE_LIMITS.minHalfW, y: -TREE_LIMITS.above, w, h },
    sky: { x: -TREE_LIMITS.minHalfW, y: -TREE_LIMITS.above, w, h, k: round2(1.2 / scale) },
    box,
    text: { top: round2(box.bottom + TREE_LIMITS.textGap), blockH: TREE_LIMITS.textBlockH },
    growth: { percent: wall.percent, k: wall.share, S: GROWTH.minScale + (1 - GROWTH.minScale) * wall.share, stage: growthStage(wall.percent, wall.reached), reached: wall.reached, effects: false },
    stages: GROWTH_STAGES,
    trunk: null,
    branches: [],
    clumps: [],
    stubs: [],
    sections: [],
    crown: null,
    vines: [],
    labels: [],
    surroundings: surroundingsOf(wall, { left: -TREE_LIMITS.minHalfW, right: TREE_LIMITS.minHalfW, top: -TREE_LIMITS.above, bottom: TREE_LIMITS.below }, 0),
    track: trackOf({ left: -TREE_LIMITS.minHalfW, bottom: TREE_LIMITS.below }, scale),
    effects: { active: false },
    facts: {},
  }
}

/** The island, the pool, the stones, the rays and the motes: they read the percent and the goal-reached state only. */
function surroundingsOf(wall, frame, trunkGirth) {
  const k = wall.share
  const pct = wall.percent
  const iw = round2(95 + 75 * k)
  const grass = Array.from({ length: 6 + Math.round(14 * k) }, (_, i) => ({ x: round2(-iw * 0.85 + iw * 1.7 * hsh(i * 2.3)), y: round2(-4 + hsh(i * 4.4) * 10) })).filter(g => Math.abs(g.x) >= trunkGirth * 0.7)
  const flowers = Array.from({ length: Math.round((12 * Math.max(0, k - 0.2)) / 0.8) }, (_, i) => ({ x: round2(-iw * 0.8 + iw * 1.6 * hsh(i * 6.1 + 2)), y: round2(-2 + hsh(i * 8.8) * 10), tone: i % 4 })).filter(g => Math.abs(g.x) >= trunkGirth * 0.8)
  const roots = Array.from({ length: 3 + Math.round(5 * k) }, (_, i) => ({ x: round2(-iw * 0.6 + iw * 1.2 * hsh(i * 4.7 + 1)), y: round2(40 + hsh(i * 2.2) * 40), len: round2(10 + 18 * k * hsh(i * 3)), sway: round2(-3 + 6 * hsh(i)) }))
  const tufts = Array.from({ length: 2 + Math.round(6 * k) }, (_, i) => ({ x: round2(-iw * 0.9 + iw * 1.8 * hsh(i * 3.1)), y: round2(10 + hsh(i * 7) * 8), len: round2(8 + hsh(i * 5) * 22 * k) }))
  const motes = Array.from({ length: Math.round(4 + (wall.reached ? 26 : 16) * k) }, (_, i) => ({
    x: round2(frame.left + 60 + hsh(i * 9.7) * (frame.right - frame.left - 120)),
    y: round2(frame.top + 60 + hsh(i * 3.9) * (frame.bottom - frame.top) * 0.6),
    r: round2(1.4 + hsh(i) * 1.4),
    delay: round2(-hsh(i * 2) * 3),
  }))
  return {
    percent: pct,
    islandHalfW: iw,
    islandY: 8,
    glow: round2(0.15 + 0.35 * k),
    grass,
    flowers,
    mushrooms: mushroomsShown(pct) ? [{ x: -trunkGirth * 0.9 - 16, s: 1 }, { x: trunkGirth * 0.9 + 12, s: 0.8 }] : [],
    stones: STONES.map((s, i) => ({ ...s, lifted: stoneLifted(pct, s), delay: round2(-i * 1.3) })),
    roots,
    tufts,
    rays: { day: round2(0.15 + 0.45 * k), night: round2((0.15 + 0.45 * k) * 0.5) },
    motes,
    poolRipples: [1, 1.5, 2.1, 2.8],
    drips: [[-0.3, 66, 0], [0.2, 80, 1.2], [-0.05, 94, 2.1]].map(([fx, y, delay]) => ({ x: round2(fx * iw), y: y + 8, delay })),
  }
}

const active0 = (wall, stories) => wall.reached === true && !stories.some(s => s.lean || s.undecomposed)

/** The geometry of one seasons tree. `model` is buildCastleModel's output; `facts` maps a story id to { done, total, failed } as the payload states them. Pure; the input is not changed. */
export function layoutSeasonsTree(model, facts) {
  const wall = model && model.wall && typeof model.wall === 'object' ? model.wall : { percent: 0, share: 0, reached: false }
  const stories = model && Array.isArray(model.stories) ? model.stories : []
  if (!stories.length) return emptyLayout(model || null, wall)
  const k = clamp(Number.isFinite(wall.share) ? wall.share : 0, 0, 1)
  const S = GROWTH.minScale + (1 - GROWTH.minScale) * k
  const fx = facts && typeof facts === 'object' ? facts : {}

  const ids = stories.map(s => s.storyId)
  const has = new Set(ids)
  const byId = new Map(stories.map(s => [s.storyId, s]))
  const trunkId = model.trunk && has.has(model.trunk) ? model.trunk : ids[0]

  // parents: the model's tree parent, else the trunk (an anchor of the model is always the trunk); loops fall back to the trunk
  const parent = new Map()
  for (const s of stories) {
    const t = s.tree || {}
    let p = s.storyId === trunkId ? null : t.parent && has.has(t.parent) && t.parent !== s.storyId ? t.parent : trunkId
    if (s.storyId !== trunkId && p === s.storyId) p = trunkId
    parent.set(s.storyId, p)
  }
  for (const id of ids) {
    const seen = new Set([id])
    let p = parent.get(id)
    while (p) {
      if (seen.has(p)) { parent.set(id, trunkId === id ? null : trunkId); break }
      seen.add(p)
      p = parent.get(p)
    }
  }
  const kids = new Map(ids.map(id => [id, []]))
  for (const id of ids) if (parent.get(id)) kids.get(parent.get(id)).push(id)
  const order = new Map(ids.map((id, i) => [id, i]))
  for (const list of kids.values()) list.sort((a, b) => order.get(a) - order.get(b))
  const depth = new Map([[trunkId, 0]])
  const queue = [trunkId]
  for (let q = 0; q < queue.length; q++) for (const c of kids.get(queue[q])) { depth.set(c, depth.get(queue[q]) + 1); queue.push(c) }
  // a story the walk did not reach (defence: cannot happen after the loop repair) hangs from the trunk
  for (const id of ids) if (!depth.has(id)) { parent.set(id, trunkId); kids.get(trunkId).push(id); depth.set(id, 1) }
  const maxDepth = Math.max(...depth.values())

  // the room each story's clumps take
  const plan = new Map()
  const terr = new Map()
  for (const s of stories) {
    const n = s.undecomposed ? 0 : s.tasks.length
    const pl = arrangeClumps(n)
    plan.set(s.storyId, pl)
    terr.set(s.storyId, s.undecomposed || n === 0 ? STUB.territory : pl.territory)
  }
  const Tmax = Array.from({ length: maxDepth + 1 }, () => 0)
  for (const id of ids) Tmax[depth.get(id)] = Math.max(Tmax[depth.get(id)], terr.get(id))

  // the rings of tips: the smallest radius a tip of depth d can have (minReach of its ring) keeps the territories of depth d - 1 and d apart
  const reachMin = BRANCH.minReach
  const base = [0]
  for (let d = 1; d <= maxDepth; d++) base.push((base[d - 1] + Tmax[d - 1] + Tmax[d] + TERRITORY_GAP) / reachMin)
  const subtree = new Map()
  const weight = id => {
    if (!subtree.has(id)) subtree.set(id, 1 + (byId.get(id).undecomposed ? 0 : byId.get(id).tasks.length) + kids.get(id).reduce((a, c) => a + weight(c), 0))
    return subtree.get(id)
  }
  weight(trunkId)

  let X = 1
  let demand = new Map()
  const demandOf = () => {
    const out = new Map()
    const walk = id => {
      const r = depth.get(id) === 0 ? 0 : X * base[depth.get(id)] * reachMin
      const own = depth.get(id) === 0 ? 0 : r <= terr.get(id) + TERRITORY_GAP / 2 ? 180 : 2 * Math.asin((terr.get(id) + TERRITORY_GAP / 2) / r) / D
      const sum = kids.get(id).reduce((a, c) => a + walk(c), 0)
      const dd = Math.max(own, sum)
      out.set(id, dd)
      return dd
    }
    return { out, total: walk(trunkId) }
  }
  for (let it = 0; it < 80; it++) {
    const r = demandOf()
    demand = r.out
    if (r.total <= FAN) break
    X *= (r.total / FAN) * 1.02
  }

  // sectors, top down, then the tips of the rings (relative to the crown heart, before the done share pulls them in)
  const theta = new Map([[trunkId, -90]])
  const assign = (id, lo, hi) => {
    const list = kids.get(id)
    if (!list.length) return
    const need = list.reduce((a, c) => a + demand.get(c), 0)
    const extra = Math.max(0, (hi - lo - need) / list.length)
    let at = lo
    for (const c of list) {
      const w = demand.get(c) + extra
      theta.set(c, (at + at + w) / 2)
      assign(c, at, at + w)
      at += w
    }
  }
  assign(trunkId, -90 - FAN / 2, -90 + FAN / 2)

  const share = id => {
    const s = byId.get(id)
    const f = fx[id]
    if (s.undecomposed) return 0
    if (f && Number.isFinite(f.total) && f.total > 0 && Number.isFinite(f.done)) return clamp(f.done / f.total, 0, 1)
    const n = s.tasks.length
    return n ? s.tasks.filter(t => t.state === 'done').length / n : 0
  }
  const heightK = TRUNK.height * (TRUNK.heightMin + TRUNK.heightGrow * k)
  const heightFull = TRUNK.height * (TRUNK.heightMin + TRUNK.heightGrow)

  // ---- branches, in relative coordinates (crown heart at 0,0; trunk base at 0,heightK), S = 1 ----
  const geo = new Map()
  const tipOf = id => {
    const s = byId.get(id)
    const r0 = X * base[depth.get(id)]
    const reach = s.undecomposed ? BRANCH.stubReach : BRANCH.minReach + (1 - BRANCH.minReach) * share(id)
    const a = theta.get(id) * D
    const droop = s.lean ? BRANCH.droop : 0
    return [Math.cos(a) * r0 * reach, Math.sin(a) * r0 * reach + droop]
  }
  const tips = new Map(ids.filter(id => id !== trunkId).map(id => [id, tipOf(id)]))
  const tot = weight(trunkId)
  const trunk = { id: trunkId, depth: 0, parent: null, p0: [0, heightK], c: [heightK * TRUNK.bend, heightK / 2], p1: [0, 0], w0: 0, w1: 0 }
  trunk.w0 = TRUNK.girth + TRUNK.girthGrow * Math.sqrt(k)
  trunk.w1 = Math.max(1.4, trunk.w0 * BRANCH.tipRatio)
  geo.set(trunkId, trunk)
  const attachT = new Map()
  const walkAttach = id => {
    const list = kids.get(id)
    if (!list.length) return
    const heading = theta.get(id)
    const dev = c => ((theta.get(c) - heading + 540) % 360) - 180
    for (const side of [-1, 1]) {
      const group = list.filter(c => (side < 0 ? dev(c) < 0 : dev(c) >= 0)).sort((a, b) => Math.abs(dev(b)) - Math.abs(dev(a)) || order.get(a) - order.get(b))
      group.forEach((c, i) => attachT.set(c, ATTACH.from + ((ATTACH.to - ATTACH.from) * (i + 0.5)) / group.length))
    }
    list.forEach(walkAttach)
  }
  walkAttach(trunkId)
  for (const id of queue.slice(1).concat(ids.filter(i => !queue.includes(i) && i !== trunkId))) {
    const s = byId.get(id)
    const pg = geo.get(parent.get(id))
    const t = attachT.get(id) != null ? attachT.get(id) : 0.6
    const p0 = curvePoint(pg, t)
    const p1 = tips.get(id)
    const dx = p1[0] - p0[0]
    const dy = p1[1] - p0[1]
    const L = Math.hypot(dx, dy) || 1
    const mid = [(p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2]
    const perp = [-dy / L, dx / L]
    // the curve bulges away from the parent's heading (a branch leaves its parent sideways, then turns up), so siblings stay apart
    const dev = ((theta.get(id) - theta.get(parent.get(id)) + 540) % 360) - 180
    const side = dev < 0 ? -1 : 1
    let c = [mid[0] + perp[0] * side * BRANCH.bend * L, mid[1] + perp[1] * side * BRANCH.bend * L]
    const leanIds = ((s.tree && s.tree.lean) || []).filter(x => tips.has(x))
    if (leanIds.length) {
      const ax = leanIds.reduce((a, x) => a + tips.get(x)[0], 0) / leanIds.length
      const ay = leanIds.reduce((a, x) => a + tips.get(x)[1], 0) / leanIds.length
      const ll = Math.hypot(ax - mid[0], ay - mid[1]) || 1
      c = [c[0] + ((ax - mid[0]) / ll) * BRANCH.leanBend * L, c[1] + ((ay - mid[1]) / ll) * BRANCH.leanBend * L]
    }
    if (s.lean) c = [c[0], c[1] + BRANCH.droopSag * L]
    const w0 = Math.min(BRANCH.girth + BRANCH.girthGrow * Math.sqrt((weight(id) + 1) / (tot + 1)), girthAt(pg, t) * BRANCH.girthOfParent)
    geo.set(id, { id, depth: depth.get(id), parent: parent.get(id), p0, c, p1, w0, w1: Math.max(1.4, w0 * BRANCH.tipRatio), len: L, t })
  }

  // ---- clumps: the large-story rule's slots round each tip, nearest the crown heart first, census order ----
  const clumpsRel = []
  const sectionsRel = []
  const stubsRel = []
  for (const s of stories) {
    const g = geo.get(s.storyId)
    if (s.undecomposed || !s.tasks.length) {
      if (s.undecomposed) stubsRel.push({ storyId: s.storyId, x: g.p1[0], y: g.p1[1] })
      continue
    }
    const pl = plan.get(s.storyId)
    const tip = g.p1
    const heart = s.storyId === trunkId ? tip : [0, 0]
    const slots = pl.slots
      .map((sl, i) => ({ ...sl, ax: tip[0] + sl.x, ay: tip[1] + sl.y, i }))
      .sort((a, b) => Math.hypot(a.ax - heart[0], a.ay - heart[1]) - Math.hypot(b.ax - heart[0], b.ay - heart[1]) || a.i - b.i)
    s.tasks.forEach((t, i) => {
      const sl = slots[i]
      const r = round2(pl.radius * (CLUMP.share[t.state] != null ? CLUMP.share[t.state] : CLUMP.share.pending))
      clumpsRel.push({ storyId: s.storyId, taskId: t.id, state: t.state, x: sl.ax, y: sl.ay, r, slotR: pl.radius, ring: sl.ring, i, si: order.get(s.storyId) })
    })
  }
  const doneBy = id => clumpsRel.filter(c => c.storyId === id && c.state === 'done')
  for (const s of stories) {
    const ds = doneBy(s.storyId)
    if (!ds.length) continue
    const cx = ds.reduce((a, c) => a + c.x, 0) / ds.length
    const cy = ds.reduce((a, c) => a + c.y, 0) / ds.length
    sectionsRel.push({ storyId: s.storyId, si: order.get(s.storyId), x: cx, y: cy + 6, r: Math.min(plan.get(s.storyId).territory, plan.get(s.storyId).radius * (1.1 + 0.55 * Math.sqrt(ds.length))), count: ds.length })
  }
  const allDone = clumpsRel.filter(c => c.state === 'done')
  let crownRel = null
  if (allDone.length > 1) {
    const cx = allDone.reduce((a, c) => a + c.x, 0) / allDone.length
    const cy = allDone.reduce((a, c) => a + c.y, 0) / allDone.length
    const rr = allDone.reduce((a, c) => a + Math.hypot(c.x - cx, (c.y - cy) * 1.25), 0) / allDone.length
    crownRel = { x: cx, y: cy + 8, r: rr + CLUMP.radius * 0.55, count: allDone.length }
  }

  // ---- the frame: sized for the fully grown tree, symmetric round the trunk ----
  const fullHeart = [0, -heightFull]
  let minX = 0
  let maxX = 0
  let minY = -TREE_LIMITS.above
  for (const id of ids) {
    const g = geo.get(id)
    const T = terr.get(id)
    const tip = id === trunkId ? [0, 0] : r0Full(id)
    minX = Math.min(minX, fullHeart[0] + tip[0] - T)
    maxX = Math.max(maxX, fullHeart[0] + tip[0] + T)
    minY = Math.min(minY, fullHeart[1] + tip[1] - T - TREE_LIMITS.labelRoom)
    void g
  }
  function r0Full(id) {
    const r0 = X * base[depth.get(id)]
    const a = theta.get(id) * D
    return [Math.cos(a) * r0, Math.sin(a) * r0 + BRANCH.droop]
  }
  const halfW = Math.max(TREE_LIMITS.minHalfW, Math.max(Math.abs(minX), Math.abs(maxX)) + TREE_LIMITS.margin)
  const frame = { left: -halfW, right: halfW, top: round2(Math.min(minY - TREE_LIMITS.margin, -TREE_LIMITS.above)), bottom: TREE_LIMITS.below }
  const fw = frame.right - frame.left
  const fh = frame.bottom - frame.top
  const scale = floor2(clamp(Math.min(1, TREE_LIMITS.maxWidth / fw, TREE_LIMITS.maxHeight / fh), TREE_LIMITS.minScale, 1))
  const bw = fw * scale
  const bh = fh * scale
  const shiftY = round2(-((frame.top + frame.bottom) / 2) * scale)
  const box = boxOf(bw, bh)

  // ---- to tree space (the grown tree: the crown heart rises with the trunk, everything scales by S about the base) ----
  const heart = [0, -S * heightK]
  const tf = p => [round2(heart[0] + S * p[0]), round2(heart[1] + S * p[1])]
  const branches = stories.map(s => {
    const g = geo.get(s.storyId)
    const p0 = tf(g.p0)
    const c = tf(g.c)
    const p1 = tf(g.p1)
    const b = { storyId: s.storyId, title: s.title, parent: g.parent, depth: g.depth, isTrunk: s.storyId === trunkId, status: s.status, undecomposed: s.undecomposed, finished: s.finished, leaf: s.leaf, lean: s.lean, droops: s.lean, p0, c, p1, w0: round2(g.w0 * S), w1: round2(g.w1 * S), share: round2(share(s.storyId)), snow: !s.undecomposed && s.tasks.length > 0 && s.status === 'pending', facts: fx[s.storyId] || null, tone: 0 }
    const ra = curvePoint(b, BRANCH.ribbonAt)
    const rt = curveTangent(b, BRANCH.ribbonAt)
    b.ribbon = { x: round2(s.storyId === trunkId ? 0 : ra[0]), y: round2(s.storyId === trunkId ? -b.w0 * 0.9 : ra[1]), angle: round2((Math.atan2(rt[1], rt[0]) / D) + 90), w: round2(b.w0 * 0.9) }
    return b
  })
  const branchOf = new Map(branches.map(b => [b.storyId, b]))
  const clumps = clumpsRel.map(c => { const p = tf([c.x, c.y]); return { ...c, x: p[0], y: p[1], r: round2(c.r * S), slotR: round2(c.slotR * S) } })
  const sections = sectionsRel.map(c => { const p = tf([c.x, c.y]); return { ...c, x: p[0], y: p[1], r: round2(c.r * S) } })
  const stubs = stubsRel.map(c => { const p = tf([c.x, c.y]); return { storyId: c.storyId, x: p[0], y: p[1], r: round2(STUB.radius * S) } })
  let crown = null
  if (crownRel) { const p = tf([crownRel.x, crownRel.y]); crown = { x: p[0], y: p[1], r: round2(crownRel.r * S), count: crownRel.count } }

  // vines with lanterns: a finished story nothing depends on hangs one from its lowest clump
  const vines = []
  for (const s of stories) {
    if (!(s.finished && s.leaf)) continue
    const cs = clumps.filter(c => c.storyId === s.storyId)
    if (!cs.length) continue
    const lo = cs.reduce((a, c) => (c.y + c.r > a.y + a.r ? c : a), cs[0])
    const x = lo.x + lo.r * 0.2
    const y0 = lo.y + lo.r * 0.6
    vines.push({ storyId: s.storyId, si: order.get(s.storyId), x: round2(x), y0: round2(y0), y1: round2(y0 + (24 + 14 * S) * 1), delay: round2(-order.get(s.storyId) * 0.6) })
  }

  // labels: one pill per branch, above its highest clump, pushed apart (the size keeps its on-screen size however far the drawing is scaled down)
  const fontSize = round2(clamp(LABEL.fontScreen / scale, LABEL.fontMin, LABEL.fontMax))
  const labels = stories.map(s => {
    const cs = clumps.filter(c => c.storyId === s.storyId)
    const g = branchOf.get(s.storyId)
    let ax
    let ay
    if (cs.length) { const top = cs.reduce((a, c) => (c.y - c.r < a.y - a.r ? c : a), cs[0]); ax = top.x; ay = top.y - top.r - fontSize * 0.5 - 2 } else { ax = g.p1[0]; ay = g.p1[1] - fontSize * 1.6 }
    const f = fx[s.storyId]
    const text = s.undecomposed ? `${s.storyId} ?` : f && Number.isFinite(f.done) && Number.isFinite(f.total) ? `${s.storyId} · ${f.done}/${f.total}` : s.storyId
    return { storyId: s.storyId, text, ax: round2(ax), ay: round2(ay), x: round2(ax), y: round2(ay), w: round2(text.length * fontSize * LABEL.charW + LABEL.padX), h: round2(fontSize * LABEL.height), font: fontSize, state: s.undecomposed ? 'pending' : s.status }
  })
  pushLabels(labels)

  if (active0(wall, stories)) for (const b of branches) b.tone = order.get(b.storyId) % 7
  const bodyGirth = branches.find(b => b.isTrunk).w0
  const sur = surroundingsOf(wall, frame, bodyGirth)
  // effects of the goal being reached: only when nothing is failed or not broken down (those states are never "reached" in the payload, this is defence)
  const active = wall.reached === true && !stories.some(s => s.lean || s.undecomposed)
  const host = branchOf.get(kids.get(trunkId)[0])
  const effects = {
    active,
    swing: active && host ? { a: curvePoint(host, 0.55).map(round2), b: curvePoint(host, 0.8).map(round2), y: -28 } : null,
    spirits: active ? [{ x: round2(-sur.islandHalfW * 0.62), tone: 0, dir: 1 }, { x: round2(sur.islandHalfW * 0.55), tone: 1, dir: -1 }] : [],
    petals: active ? [[260, 140, 0], [420, 120, 2.6], [330, 200, 5.2], [470, 230, 1.3], [220, 220, 3.9]].map(([px, py, dl], i) => ({ x: round2(frame.left + (px / 680) * fw), y: round2(frame.top + 40 + (py / 560) * (fh - 100)), delay: dl, leaf: i % 2 === 1, tone: i })) : [],
  }

  return {
    source: model,
    empty: false,
    scale,
    shiftX: 0,
    shiftY,
    limits: { ...TREE_LIMITS },
    frame: { x: frame.left, y: frame.top, w: round2(fw), h: round2(fh) },
    sky: { x: frame.left, y: frame.top, w: round2(fw), h: round2(fh), k: round2(1.2 / scale) },
    box,
    text: { top: round2(box.bottom + TREE_LIMITS.textGap), blockH: TREE_LIMITS.textBlockH },
    growth: { percent: wall.percent, k, S: round2(S), stage: growthStage(wall.percent, wall.reached), reached: wall.reached === true, effects: active },
    stages: GROWTH_STAGES,
    trunk: { storyId: trunkId, girth: bodyGirth, height: round2(S * heightK), heart },
    ring: { X: round2(X), base: base.map(round2), fan: FAN },
    branches,
    clumps,
    stubs,
    sections,
    crown,
    vines,
    labels,
    surroundings: sur,
    track: trackOf(frame, scale),
    effects,
    facts: fx,
  }
}

/**
 * Where an edge to the goal ends: `count` points spread down the left rim of the island (in the goal frame), top to bottom, so
 * the edges of several end stories do not pile onto one point. The points are in order of y, so a caller that sorts its edges
 * by the y of their source draws no crossing.
 */
export function treeAnchors(layout, count) {
  const n = Math.max(0, Math.floor(count))
  if (!layout || layout.empty || !layout.surroundings) return Array.from({ length: n }, () => ({ x: 0, y: 0 }))
  const s = layout.scale
  const ty = layout.shiftY
  const xLeft = -(layout.surroundings.islandHalfW + 8)
  const hi = -46
  const lo = 44
  return Array.from({ length: n }, (_, i) => ({ x: round2(xLeft * s), y: round2((hi + ((i + 0.5) / n) * (lo - hi)) * s + ty) }))
}

/** Numeric-aware story id order, re-exported so a caller sorts ids the way the model does. */
export { idCompare }
