/**
 * castleModel - E92_S13_T01.
 *
 * Pure (React-free, DOM-free, import-free) model of the epic Goal as a Jenga castle (citadel and facade, story decisions
 * 3 to 7) and of the per-story data and the tree parent and lean rule the seasons tree reads (story decision 9). It draws
 * nothing and holds no pixel, no colour and no user-visible word: the renderers (E92_S13_T02, T03, T07) own all of those.
 *
 * Input is the body of `GET /v1/progress-graph` (the output of `scripts/board-progress.sh --graph [--within <id>]`) and an
 * epic id. It reads, per story of the epic, `depends_on`, `decomposed`, `complete`, `stop` and `title`; per task `state`
 * (`bucket` when `state` is absent), `story_id` and `epic_id`; and the epic's `epic_progress`. It counts no percent and
 * states no "decomposed" or "finished" the payload does not state: the wall share IS `epic_progress.percent` and the goal
 * flag IS `epic_progress.goal_reached` (E92 decision 1). What it does compute is geometry (layers per tower, the order
 * of the towers, what stands on what), which the payload does not carry. Every key it reads is already in the payload, so
 * `--graph` needed no new key; a payload without a key it can live without (an older one) still gives a valid model:
 * no `stories[]` means towers from the tasks alone, no stacking, no tree parents; no `decomposed` means no dashed
 * foundation; no `state` means the task's `bucket` is read. It never throws on odd input.
 *
 * Where it lives: next to epicBarModel.js, not in lib/progress/. The castle is dashboard-only (story decision 8), so it has
 * no terminal consumer and must not be imported by the renderers under lib/progress/; it has no second copy, so no parity
 * test is needed; and the UI bundle and the `--snapshot` export already bundle files from this folder.
 *
 * Output shape (every list is sorted, so the same input gives a deep-equal output):
 *   epicId, empty (no story is drawn), levels (the highest stacking level + 1, 0 when empty), trunk (story id or null)
 *   constants    { MAX_TOWER_LAYERS, BLOCKS_PER_LAYER }
 *   wall         { percent, share, reached }   percent is epic_progress.percent as stated (0..100), share is percent / 100,
 *                reached is epic_progress.goal_reached === true; all zero / false without epic_progress
 *   stories      the normalised per-story data, board (id) order. This is what the seasons tree reads; it holds no castle shape.
 *                { storyId, title, status, undecomposed, finished, leaf, lean, cycle,
 *                  tasks: [{ id, state }]   the counted tasks in census order (done, in_progress, failed, pending), then id;
 *                                           ready and locked are 'pending'; [] for an undecomposed story
 *                  loose: [task id]         rejected tasks (not counted, not a layer)
 *                  dependsOn, redundantDeps, externalDeps, level,
 *                  tree: { parent, lean, anchor, isTrunk } }
 *   towers       the castle, in `order`. { storyId, title, status, undecomposed, finished, leaf, lean, cycle, level,
 *                  stacking: { kind: 'ground' | 'tower' | 'bridge', on: [story ids], adjacent? },
 *                  top: 'roof' | 'battlements' | 'none', plan: widenLayers(n) with n = counted tasks,
 *                  layers: [{ index, direction: 'x' | 'z', state, blocks, blockStates, tasks: [task id] }], loose }
 *   bridges      [{ storyId (the story that stands on it), ends: [story ids in `order`], adjacent }]
 *   order        story ids in the order the renderers lay the towers out; bridge end towers are adjacent where the shape allows
 *
 * The rules (also stated in the task summary and in progress-visualisation.md):
 *  - A story is drawn when the payload does not state it uncounted: `decomposed: null` or `stop: 'rejected'` (a rejected or
 *    unknown story, which epic_progress does not count either) is not drawn. A story is an undecomposed (dashed) foundation
 *    exactly when the payload states `decomposed: false`: it has no layers, no roof, no battlements.
 *  - Layers are one per counted task, in census order bottom-up, alternating direction (`x` at the bottom, then `z`), three
 *    blocks each, until the height cap widens the tower (widenLayers). A rejected task is a loose block, not a layer; a task
 *    of unknown state is neither.
 *  - lean: any failed task. Such a tower is not finished, so it has no roof and no battlements.
 *  - finished: the payload's `complete` for the story (derived from its counted tasks only when `complete` is absent), and
 *    never an undecomposed story. leaf: no drawn story depends on it. roof (leaning plank with a flag): finished and leaf;
 *    battlements: finished and not leaf; otherwise none.
 *  - Dependencies that count are those on another drawn story of this epic. A dependency on a story outside the epic (or on
 *    one that is not drawn, or on nothing the board knows) does not stack and gives no tree parent (listed in externalDeps).
 *    A dependency already implied through another dependency of the same story is dropped (transitive reduction, listed in
 *    redundantDeps): a story on A and B where B stands on A stands on B. A story on an undecomposed story stands on its
 *    dashed foundation (and, in the tree, grows from its stub).
 *  - A dependency cycle (two or more stories reaching each other) falls back to the ground for every member: no stacking,
 *    no tree parent, `cycle: true`, and nothing throws or hangs. A story outside the cycle that depends on a member stands
 *    on it as on any tower. A self-dependency is ignored.
 *  - Stacking: no counted dependency is the ground (the table top); one is that tower; two or more is a bridge between those
 *    towers. `level` is 0 on the ground, else 1 + the highest level of what it stands on.
 *  - Bridge adjacency: `order` starts as the board (id) order. Bridges are taken in board order of the story standing on them;
 *    each merges the units of its end towers into one unit (earlier bridges stay together, a unit may be reversed when that
 *    brings the ends closer), so the ends become consecutive where the shape allows. A shape that cannot be a line (three
 *    towers each bridged to the other two) leaves one bridge not adjacent; `adjacent` says which. Ends are listed in `order`.
 *  - Tree parent (seasons tree, story decision 4 as branching): none for a story with no counted dependency (the root, an
 *    out-of-epic dependency, a cycle member). One counted dependency: that story. Two or more: the FIRST is the one with the
 *    highest `level` (the one the story most directly continues; ties go to the lowest id), it becomes the parent, and the
 *    others, in board order, are the lean targets. The trunk is the first parentless story in board order that is not in a
 *    cycle (a cycle member only when nothing else qualifies); any other parentless story has `anchor` = the trunk, so a
 *    renderer can grow it from the trunk base. How far a branch leans is the tree renderer's call.
 */

/** H: the maximum number of layers of one tower. Above it a tower widens instead of growing taller (story decision 6). */
export const MAX_TOWER_LAYERS = 8
// H = 8 because the measured tasks per story are median 3, p75 5, p90 7, max 26 (story decision 7): 90 % of the stories
// never widen and still fit under the cap with a layer to spare, the 26-task story widens to k = 4 (7 layers of 4), and a
// tower of 8 layers stays about as tall as the median castle (16 tasks, 6 stories) is wide, so no tower dwarfs the wall.

/** Blocks in a normal layer (one task = one layer of three blocks). */
export const BLOCKS_PER_LAYER = 3

const LAYER_STATES = ['done', 'in_progress', 'failed', 'pending']
const RANK = { done: 0, in_progress: 1, failed: 2, pending: 3 }
const STATUS_STOPS = ['in_progress', 'failed', 'pending']

const arr = v => (Array.isArray(v) ? v : [])
const isObj = v => !!v && typeof v === 'object'
const str = v => (typeof v === 'string' ? v : '')
const finite = v => typeof v === 'number' && Number.isFinite(v) && v >= 0

/** Numeric-aware id order (E92_S2 < E92_S10), independent of the host locale. */
export function idCompare(a, b) {
  const pa = String(a).split(/(\d+)/)
  const pb = String(b).split(/(\d+)/)
  for (let i = 0; i < Math.min(pa.length, pb.length); i++) {
    if (pa[i] === pb[i]) continue
    if (i % 2 === 1) return Number(pa[i]) - Number(pb[i]) || (pa[i] < pb[i] ? -1 : 1)
    return pa[i] < pb[i] ? -1 : 1
  }
  return pa.length - pb.length
}

/**
 * The height cap in ONE place (story decision 6, confirmed 2026-11-17: the story's own tower widens, the castle's base does
 * not). n counted tasks under a cap of H layers: k = ceil(n / H) tasks per layer, so the tower holds ceil(n / k) <= H layers.
 * k = 1 is a normal tower (a layer is one task as BLOCKS_PER_LAYER blocks); above the cap a layer holds k tasks as k blocks.
 * `width` is the footprint in blocks, never narrower than a normal layer (k = 2 is 2 blocks drawn across 3 blocks of width).
 * Returns { tasksPerLayer, layers, blocks, width, widened }.
 */
export function widenLayers(n, cap = MAX_TOWER_LAYERS) {
  const count = Number.isFinite(n) && n > 0 ? Math.floor(n) : 0
  const h = Number.isFinite(cap) && cap >= 1 ? Math.floor(cap) : MAX_TOWER_LAYERS
  const k = Math.max(1, Math.ceil(count / h))
  return {
    tasksPerLayer: k,
    layers: count === 0 ? 0 : Math.ceil(count / k),
    blocks: k === 1 ? BLOCKS_PER_LAYER : k,
    width: Math.max(BLOCKS_PER_LAYER, k),
    widened: k > 1,
  }
}

/** A task's layer state: done, in_progress, failed, pending (ready and locked too), rejected or unknown. */
function taskState(t) {
  const map = { done: 'done', in_progress: 'in_progress', failed: 'failed', ready: 'pending', locked: 'pending', pending: 'pending', rejected: 'rejected', unknown: 'unknown' }
  if (typeof t.state === 'string' && t.state in map) return map[t.state]
  if (typeof t.bucket === 'string' && t.bucket in map) return map[t.bucket]
  return 'unknown'
}

function censusOf(tasks) {
  return tasks
    .map(t => ({ id: t.id, state: taskState(t) }))
    .filter(t => LAYER_STATES.includes(t.state))
    .sort((a, b) => RANK[a.state] - RANK[b.state] || idCompare(a.id, b.id))
}

/** Ids reachable from `start` by one or more edges of `deps` (id -> ids), cycle-safe through the visited set. */
function reach(start, deps) {
  const seen = new Set()
  const stack = [...(deps.get(start) || [])]
  while (stack.length) {
    const id = stack.pop()
    if (seen.has(id)) continue
    seen.add(id)
    for (const n of deps.get(id) || []) stack.push(n)
  }
  return seen
}

/** The order of the towers: board order, with bridge end towers pulled together (see the rules above). */
function arrangeOrder(ids, bridgeEnds) {
  let units = ids.map(id => [id])
  const unitIndex = id => units.findIndex(u => u.includes(id))
  for (const ends of bridgeEnds) {
    const idx = [...new Set(ends.map(unitIndex))].sort((a, b) => a - b)
    if (idx.length < 2) continue
    let merged = units[idx[0]]
    for (const i of idx.slice(1)) {
      const next = units[i]
      const rev = a => a.slice().reverse()
      const candidates = [merged.concat(next), merged.concat(rev(next)), rev(merged).concat(next), rev(merged).concat(rev(next))]
      const span = c => {
        const pos = ends.filter(e => c.includes(e)).map(e => c.indexOf(e))
        return Math.max(...pos) - Math.min(...pos)
      }
      merged = candidates.reduce((best, c) => (span(c) < span(best) ? c : best), candidates[0])
    }
    units = units.filter((_, i) => !idx.includes(i))
    units.splice(idx[0], 0, merged)
  }
  return units.reduce((all, u) => all.concat(u), [])
}

/** The layers of one tower from its counted tasks (census order), bottom-up. */
function layersOf(tasks, plan) {
  const layers = []
  const k = plan.tasksPerLayer
  for (let i = 0; i < plan.layers; i++) {
    const chunk = tasks.slice(i * k, (i + 1) * k)
    // a layer is done only when every task in it is: its state is the least finished task's (the last in census order)
    const state = chunk[chunk.length - 1].state
    const blockStates = k === 1 ? Array(BLOCKS_PER_LAYER).fill(state) : chunk.map(t => t.state)
    layers.push({ index: i, direction: i % 2 === 0 ? 'x' : 'z', state, blocks: blockStates.length, blockStates, tasks: chunk.map(t => t.id) })
  }
  return layers
}

function wallOf(graph, epicId) {
  const entry = arr(graph.epics).find(e => isObj(e) && e.id === epicId)
  const ep = entry && isObj(entry.epic_progress) ? entry.epic_progress : {}
  const percent = finite(ep.percent) ? Math.min(100, Math.floor(ep.percent)) : 0
  return { percent, share: percent / 100, reached: ep.goal_reached === true }
}

function emptyModel(epicId, wall) {
  return { epicId, empty: true, levels: 0, trunk: null, constants: { MAX_TOWER_LAYERS, BLOCKS_PER_LAYER }, wall, stories: [], towers: [], bridges: [], order: [] }
}

/** The castle model and the seasons tree's per-story data of one epic. Pure; the input is not changed. */
export function buildCastleModel(graph, epicId) {
  const eid = typeof epicId === 'string' ? epicId : ''
  if (!isObj(graph) || !eid) return emptyModel(eid, { percent: 0, share: 0, reached: false })
  const wall = wallOf(graph, eid)

  const entries = new Map()
  for (const s of arr(graph.stories)) if (isObj(s) && str(s.id) && s.epic_id === eid && !entries.has(s.id)) entries.set(s.id, s)
  const tasksByStory = new Map()
  for (const t of arr(graph.tasks)) {
    if (!isObj(t) || !str(t.id) || t.epic_id !== eid || !str(t.story_id)) continue
    if (!tasksByStory.has(t.story_id)) tasksByStory.set(t.story_id, [])
    tasksByStory.get(t.story_id).push(t)
  }

  // Drawn stories: every story entry of the epic and every story a task names, minus the ones the payload states uncounted.
  const uncounted = e => !!e && (e.decomposed === null || e.stop === 'rejected')
  const ids = [...new Set([...entries.keys(), ...tasksByStory.keys()])].filter(id => !uncounted(entries.get(id))).sort(idCompare)
  if (ids.length === 0) return emptyModel(eid, wall)
  const drawn = new Set(ids)

  // Cleaned dependencies: drawn, other, de-duplicated; a cycle member loses all of them (ground).
  const rawDeps = new Map()
  const external = new Map()
  for (const id of ids) {
    const e = entries.get(id)
    const all = [...new Set(arr(e && e.depends_on).filter(d => typeof d === 'string' && d && d !== id))].sort(idCompare)
    rawDeps.set(id, all.filter(d => drawn.has(d)))
    external.set(id, all.filter(d => !drawn.has(d)))
  }
  const inCycle = new Set(ids.filter(id => reach(id, rawDeps).has(id)))
  const deps = new Map(ids.map(id => [id, inCycle.has(id) ? [] : rawDeps.get(id)]))

  // Transitive reduction on the (now acyclic) graph, and the level of every story.
  const ancestors = new Map()
  const ancestorsOf = id => {
    if (!ancestors.has(id)) {
      const set = new Set()
      for (const d of deps.get(id)) { set.add(d); for (const a of ancestorsOf(d)) set.add(a) }
      ancestors.set(id, set)
    }
    return ancestors.get(id)
  }
  const supports = new Map()
  const redundant = new Map()
  for (const id of ids) {
    const all = deps.get(id)
    const keep = all.filter(d => !all.some(e => e !== d && ancestorsOf(e).has(d)))
    supports.set(id, keep)
    redundant.set(id, all.filter(d => !keep.includes(d)))
  }
  const levels = new Map()
  const levelOf = id => {
    if (!levels.has(id)) levels.set(id, supports.get(id).reduce((m, d) => Math.max(m, levelOf(d) + 1), 0))
    return levels.get(id)
  }
  const carried = new Set()
  for (const id of ids) for (const d of deps.get(id)) carried.add(d)

  // Normalised per-story data (what the seasons tree reads).
  const parentOf = new Map()
  const leanOf = new Map()
  for (const id of ids) {
    const sup = supports.get(id)
    if (sup.length === 0) { parentOf.set(id, null); leanOf.set(id, []); continue }
    const first = sup.reduce((best, d) => (levelOf(d) > levelOf(best) ? d : best), sup[0]) // sup is in id order, so ties keep the lowest id
    parentOf.set(id, first)
    leanOf.set(id, sup.filter(d => d !== first))
  }
  const parentless = ids.filter(id => parentOf.get(id) === null)
  const trunk = parentless.find(id => !inCycle.has(id)) || parentless[0] || null

  const stories = ids.map(id => {
    const e = entries.get(id)
    const all = tasksByStory.get(id) || []
    const undecomposed = !!e && e.decomposed === false
    const tasks = undecomposed ? [] : censusOf(all)
    const complete = e && typeof e.complete === 'boolean' ? e.complete : tasks.length > 0 && tasks.every(t => t.state === 'done')
    const finished = !undecomposed && complete
    const lean = tasks.some(t => t.state === 'failed')
    const stop = e && e.stop
    let status
    if (finished) status = 'done'
    else if (STATUS_STOPS.includes(stop)) status = stop
    else if (lean) status = 'failed'
    else if (tasks.some(t => t.state === 'in_progress' || t.state === 'done')) status = 'in_progress'
    else status = 'pending'
    return {
      storyId: id,
      title: (e && str(e.title)) || '',
      status,
      undecomposed,
      finished,
      leaf: !carried.has(id),
      lean,
      cycle: inCycle.has(id),
      tasks,
      loose: all.filter(t => taskState(t) === 'rejected').map(t => t.id).sort(idCompare),
      dependsOn: deps.get(id),
      redundantDeps: redundant.get(id),
      externalDeps: external.get(id),
      level: levelOf(id),
      tree: { parent: parentOf.get(id), lean: leanOf.get(id), anchor: parentOf.get(id) || (id === trunk ? null : trunk), isTrunk: id === trunk },
    }
  })
  const byId = new Map(stories.map(s => [s.storyId, s]))

  // Order with adjacent bridge ends, then the towers and the bridges.
  const bridgeStories = stories.filter(s => supports.get(s.storyId).length >= 2)
  const order = arrangeOrder(ids, bridgeStories.map(s => supports.get(s.storyId)))
  const pos = new Map(order.map((id, i) => [id, i]))
  const bridges = bridgeStories.map(s => {
    const ends = supports.get(s.storyId).slice().sort((a, b) => pos.get(a) - pos.get(b))
    return { storyId: s.storyId, ends, adjacent: ends.every((e, i) => i === 0 || pos.get(e) === pos.get(ends[i - 1]) + 1) }
  })
  const bridgeOf = new Map(bridges.map(b => [b.storyId, b]))

  const towers = order.map(id => {
    const s = byId.get(id)
    const sup = supports.get(id)
    const plan = widenLayers(s.tasks.length)
    const stacking = sup.length === 0 ? { kind: 'ground', on: [] }
      : sup.length === 1 ? { kind: 'tower', on: sup.slice() }
      : { kind: 'bridge', on: bridgeOf.get(id).ends, adjacent: bridgeOf.get(id).adjacent }
    return {
      storyId: id,
      title: s.title,
      status: s.status,
      undecomposed: s.undecomposed,
      finished: s.finished,
      leaf: s.leaf,
      lean: s.lean,
      cycle: s.cycle,
      level: s.level,
      stacking,
      top: s.finished ? (s.leaf ? 'roof' : 'battlements') : 'none',
      plan,
      layers: layersOf(s.tasks, plan),
      loose: s.loose,
    }
  })

  return {
    epicId: eid,
    empty: false,
    levels: stories.reduce((m, s) => Math.max(m, s.level + 1), 0),
    trunk,
    constants: { MAX_TOWER_LAYERS, BLOCKS_PER_LAYER },
    wall,
    stories,
    towers,
    bridges,
    order,
  }
}
