#!/usr/bin/env node
'use strict'
// E92_S13_T01: model test for the Jenga castle and the seasons tree's per-story data. Zero test framework and no DOM, plain
// node, like progress-model.test.cjs and epic-card-bar.test.cjs. castleModel.js is pure ESM with no import, so it is loaded
// with a dynamic import (the ui package is "type": "module"); no bundler is involved. One test builds a real `--graph`
// payload from a temporary board with scripts/board-progress.sh, so a key the model needs but the script does not print
// would fail here. Run: node project/app/ui/scripts/castle-model.test.cjs
const assert = require('assert')
const cp = require('child_process')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { pathToFileURL } = require('url')

const root = path.join(__dirname, '..', '..', '..', '..')
const modelPath = path.join(root, 'project', 'app', 'ui', 'src', 'components', 'progress', 'castleModel.js')
const boardProgress = path.join(root, 'scripts', 'board-progress.sh')

let count = 0
const test = async (name, fn) => { await fn(); count++; console.log('ok  ' + name) }

// ---- fixture builders ------------------------------------------------------------------------------------------------
const EPIC = 'E01'
const STATE = { d: 'done', i: 'in_progress', f: 'failed', p: 'ready', l: 'locked', r: 'rejected', u: 'unknown' }
const BUCKET = { d: 'done', i: 'in_progress', f: 'failed', p: 'pending', l: 'pending', r: 'rejected', u: 'unknown' }
const sid = n => `${EPIC}_S${String(n).padStart(2, '0')}`

/**
 * One story as board-progress.sh --graph would print it, plus its tasks. `spec` is a string, one letter per task:
 * d done, i in progress, f failed, p ready, l locked, r rejected, u unknown; null spec = an undecomposed story (no tasks).
 * The story's stop, complete and decomposed follow the script's rules (header of scripts/board-progress.sh).
 */
function story(n, spec, deps, extra) {
  const id = sid(n)
  const letters = spec ? spec.split('') : []
  const counted = letters.filter(c => 'dipfl'.includes(c))
  const done = counted.filter(c => c === 'd').length
  const complete = counted.length > 0 && done === counted.length
  const stop = complete ? 'done' : counted.includes('f') ? 'failed' : counted.includes('i') || done > 0 ? 'in_progress' : 'pending'
  const entry = { id, epic_id: EPIC, title: `Story ${n}`, depends_on: deps || [], complete, decomposed: counted.length > 0, stop, ...extra }
  const tasks = letters.map((c, i) => ({
    id: `${id}_T${String(i + 1).padStart(2, '0')}`, story_id: id, epic_id: EPIC, title: `t${i + 1}`, status: '', bucket: BUCKET[c], state: STATE[c], depends_on: [],
  }))
  return { entry, tasks }
}

function graph(list, progress) {
  return {
    schema_version: 1,
    epics: [{ id: EPIC, title: 'Epic', depends_on: [], ...(progress ? { epic_progress: progress } : {}) }],
    stories: list.map(s => s.entry),
    tasks: list.flatMap(s => s.tasks),
  }
}

const ids = (...ns) => ns.map(sid)

async function main() {
  const M = await import(pathToFileURL(modelPath).href)
  const { buildCastleModel, widenLayers, MAX_TOWER_LAYERS, BLOCKS_PER_LAYER } = M
  const build = (list, progress) => buildCastleModel(graph(list, progress), EPIC)
  const tower = (m, n) => m.towers.find(t => t.storyId === sid(n))
  const story_ = (m, n) => m.stories.find(s => s.storyId === sid(n))
  const deepFreeze = v => { if (v && typeof v === 'object') { Object.values(v).forEach(deepFreeze); Object.freeze(v) } return v }

  await test('the worked example: 16 tasks, 12 done, 11 stories of which 9 decomposed: 11 towers, 2 dashed foundations, 12 done layers', () => {
    // nine decomposed stories hold 16 tasks between them, 12 done; two undecomposed stories hold none; 9/11 x 12/16 = 61 %
    const list = [
      story(1, 'dd'), story(2, 'dd'), story(3, 'dd'), story(4, 'dd'), story(5, 'dd'), story(6, 'dd'),
      story(7, 'ip'), story(8, 'p'), story(9, 'p'), story(10, null), story(11, null),
    ]
    const tasks = list.reduce((a, s) => a + s.tasks.length, 0)
    const done = list.reduce((a, s) => a + s.tasks.filter(t => t.state === 'done').length, 0)
    assert.deepStrictEqual([tasks, done], [16, 12])
    const m = build(list, { stories: 11, decomposed: 9, tasks_done: 12, tasks_denominator: 16, percent: 61, goal_reached: false })
    assert.strictEqual(m.towers.length, 11)
    assert.strictEqual(m.towers.filter(t => t.undecomposed).length, 2)
    assert.ok(m.towers.filter(t => t.undecomposed).every(t => t.layers.length === 0 && t.top === 'none'))
    assert.strictEqual(m.towers.reduce((a, t) => a + t.layers.filter(l => l.state === 'done').length, 0), 12)
    assert.strictEqual(m.towers.reduce((a, t) => a + t.layers.length, 0), 16)
    assert.strictEqual(m.wall.percent, 61)
    assert.strictEqual(m.empty, false)
  })

  await test('each layer state: ready and locked give pending, a rejected task is a loose block and unknown is neither', () => {
    const m = build([story(1, 'dipflru')])
    const t = tower(m, 1)
    assert.deepStrictEqual(t.layers.map(l => l.state), ['done', 'in_progress', 'failed', 'pending', 'pending'])
    assert.deepStrictEqual(t.loose, [`${sid(1)}_T06`])
    assert.strictEqual(t.layers.length, 5, 'the rejected and the unknown task are not layers')
    assert.ok(!JSON.stringify(t.layers).includes('_T06') && !JSON.stringify(t.layers).includes('_T07'))
  })

  await test('three blocks per layer, alternating direction, bottom-up census order whatever the input order', () => {
    const m = build([story(1, 'pfipddl')])
    const t = tower(m, 1)
    assert.deepStrictEqual(t.layers.map(l => l.state), ['done', 'done', 'in_progress', 'failed', 'pending', 'pending', 'pending'])
    assert.deepStrictEqual(t.layers.map(l => l.direction), ['x', 'z', 'x', 'z', 'x', 'z', 'x'])
    assert.deepStrictEqual(t.layers.map(l => l.index), [0, 1, 2, 3, 4, 5, 6])
    assert.ok(t.layers.every(l => l.blocks === BLOCKS_PER_LAYER && l.blockStates.length === 3 && l.blockStates.every(b => b === l.state)))
    assert.deepStrictEqual(t.layers.map(l => l.tasks.length), [1, 1, 1, 1, 1, 1, 1])
    // inside one state the order is by task id, and the story-level task list (for the tree) has the same census order
    assert.deepStrictEqual(story_(m, 1).tasks.map(x => x.state), ['done', 'done', 'in_progress', 'failed', 'pending', 'pending', 'pending'])
    assert.deepStrictEqual(t.layers.map(l => l.tasks[0]), story_(m, 1).tasks.map(x => x.id))
    const doneIds = story_(m, 1).tasks.filter(x => x.state === 'done').map(x => x.id)
    assert.deepStrictEqual(doneIds, [...doneIds].sort())
  })

  await test('a failed task makes the tower lean and take neither roof nor battlements', () => {
    const m = build([story(1, 'ddf'), story(2, 'dd', [sid(1)])])
    const t = tower(m, 1)
    assert.strictEqual(t.lean, true)
    assert.strictEqual(t.status, 'failed')
    assert.strictEqual(t.finished, false)
    assert.strictEqual(t.top, 'none')
    assert.strictEqual(tower(m, 2).lean, false)
    assert.strictEqual(tower(m, 2).top, 'roof')
  })

  await test('a loose rejected block is not counted: no layer, no change to status, finished or roof', () => {
    const m = build([story(1, 'ddr')])
    const t = tower(m, 1)
    assert.strictEqual(t.layers.length, 2)
    assert.strictEqual(t.loose.length, 1)
    assert.strictEqual(t.finished, true)
    assert.strictEqual(t.top, 'roof')
    assert.strictEqual(t.status, 'done')
    assert.strictEqual(story_(m, 1).tasks.length, 2)
    // an undecomposed story whose only tasks are rejected: dashed foundation, the rejected block still lies beside it
    const u = tower(build([story(1, 'rr')]), 1)
    assert.strictEqual(u.undecomposed, true)
    assert.deepStrictEqual([u.layers.length, u.loose.length], [0, 2])
  })

  await test('status base: the payload\'s own stop and complete, never invented', () => {
    const m = build([story(1, 'dd'), story(2, 'di'), story(3, 'f'), story(4, 'pl'), story(5, null)])
    assert.deepStrictEqual(m.towers.map(t => t.status), ['done', 'in_progress', 'failed', 'pending', 'pending'])
    // a stop of done on a story that is not complete is not drawn done (like epicBarModel)
    const odd = story(1, 'dp'); odd.entry.stop = 'done'; odd.entry.complete = false
    assert.strictEqual(tower(build([odd]), 1).status, 'in_progress')
  })

  await test('a story with one in-epic dependency stands on that tower', () => {
    const m = build([story(1, 'dd'), story(2, 'dp', [sid(1)])])
    assert.deepStrictEqual(tower(m, 1).stacking, { kind: 'ground', on: [] })
    assert.deepStrictEqual(tower(m, 2).stacking, { kind: 'tower', on: [sid(1)] })
    assert.deepStrictEqual([tower(m, 1).level, tower(m, 2).level, m.levels], [0, 1, 2])
    assert.deepStrictEqual(m.bridges, [])
  })

  await test('a story with two or more dependencies stands on a bridge between their towers (over two and over three)', () => {
    const two = build([story(1, 'd'), story(2, 'd'), story(3, 'p', [sid(1), sid(2)])])
    assert.deepStrictEqual(tower(two, 3).stacking, { kind: 'bridge', on: ids(1, 2), adjacent: true })
    assert.deepStrictEqual(two.bridges, [{ storyId: sid(3), ends: ids(1, 2), adjacent: true }])
    assert.strictEqual(tower(two, 3).level, 1)

    // the end towers are not next to each other in board order: S01 S02 S03 S04, the bridge over S01 and S04
    const apart = build([story(1, 'd'), story(2, 'd'), story(3, 'd'), story(4, 'd'), story(5, 'p', ids(1, 4))])
    assert.deepStrictEqual(apart.bridges[0], { storyId: sid(5), ends: ids(1, 4), adjacent: true })
    const pos = id => apart.order.indexOf(id)
    assert.strictEqual(Math.abs(pos(sid(1)) - pos(sid(4))), 1)
    assert.deepStrictEqual([...apart.order].sort(), ids(1, 2, 3, 4, 5))

    const three = build([story(1, 'd'), story(2, 'd'), story(3, 'd'), story(4, 'd'), story(5, 'p', ids(1, 3, 4))])
    assert.strictEqual(tower(three, 5).stacking.kind, 'bridge')
    assert.deepStrictEqual(tower(three, 5).stacking.on.slice().sort(), ids(1, 3, 4))
    assert.strictEqual(three.bridges[0].adjacent, true)
    const p3 = three.bridges[0].ends.map(e => three.order.indexOf(e))
    assert.deepStrictEqual(p3, [p3[0], p3[0] + 1, p3[0] + 2])
    assert.deepStrictEqual(three.bridges[0].ends, [...three.bridges[0].ends].sort((a, b) => three.order.indexOf(a) - three.order.indexOf(b)))
  })

  await test('bridge adjacency: earlier bridges stay together; a triangle of bridges cannot all be adjacent and says so', () => {
    // S04 bridges S01+S02 and S05 bridges S02+S03: S01 S02 S03 keeps both adjacent
    const chain = build([story(1, 'd'), story(2, 'd'), story(3, 'd'), story(4, 'p', ids(1, 2)), story(5, 'p', ids(2, 3))])
    assert.ok(chain.bridges.every(b => b.adjacent))
    // three bridges over every pair of S01 S02 S03: one pair has the third tower between them
    const tri = build([story(1, 'd'), story(2, 'd'), story(3, 'd'), story(4, 'p', ids(1, 2)), story(5, 'p', ids(2, 3)), story(6, 'p', ids(1, 3))])
    assert.strictEqual(tri.bridges.filter(b => b.adjacent).length, 2)
    assert.strictEqual(tri.bridges.filter(b => !b.adjacent).length, 1)
    assert.deepStrictEqual(tri.bridges.find(b => b.storyId === sid(6)).adjacent, false)
  })

  await test('diamond and chain: a story on two towers that stand on a third; a redundant dependency is dropped', () => {
    const diamond = build([story(1, 'd'), story(2, 'd', [sid(1)]), story(3, 'd', [sid(1)]), story(4, 'p', ids(2, 3))])
    assert.deepStrictEqual(tower(diamond, 4).stacking.on, ids(2, 3))
    assert.deepStrictEqual([1, 2, 3, 4].map(n => tower(diamond, n).level), [0, 1, 1, 2])
    assert.strictEqual(tower(diamond, 1).top, 'battlements')
    assert.strictEqual(tower(diamond, 4).top, 'none')
    // S03 depends on S01 and on S02, and S02 already stands on S01: S03 stands on S02 alone
    const chain = build([story(1, 'd'), story(2, 'd', [sid(1)]), story(3, 'p', ids(1, 2))])
    assert.deepStrictEqual(tower(chain, 3).stacking, { kind: 'tower', on: [sid(2)] })
    assert.deepStrictEqual(story_(chain, 3).dependsOn, ids(1, 2))
    assert.deepStrictEqual(story_(chain, 3).redundantDeps, [sid(1)])
    assert.deepStrictEqual(story_(chain, 3).tree, { parent: sid(2), lean: [], anchor: sid(2), isTrunk: false })
    assert.strictEqual(tower(chain, 1).leaf, false)
  })

  await test('a dependency outside the epic, on an uncounted story or on nothing known does not stack and gives no tree parent', () => {
    const rejected = story(3, 'd'); rejected.entry.stop = 'rejected'; rejected.entry.decomposed = null
    const m = build([story(1, 'd', ['E99_S01', 'E01_S77']), story(2, 'p', [sid(1), sid(3), 'E99_S01']), rejected])
    assert.deepStrictEqual(tower(m, 1).stacking, { kind: 'ground', on: [] })
    assert.deepStrictEqual(story_(m, 1).externalDeps, ['E01_S77', 'E99_S01'])
    assert.deepStrictEqual(story_(m, 1).tree, { parent: null, lean: [], anchor: null, isTrunk: true })
    assert.deepStrictEqual(tower(m, 2).stacking, { kind: 'tower', on: [sid(1)] })
    assert.deepStrictEqual(story_(m, 2).externalDeps, [sid(3), 'E99_S01'])
    assert.strictEqual(m.towers.length, 2, 'the rejected story is not drawn (epic_progress does not count it)')
    assert.strictEqual(tower(m, 1).leaf, false)
  })

  await test('a story on an undecomposed story stands on its dashed foundation (and in the tree grows from its stub)', () => {
    const m = build([story(1, null), story(2, 'dp', [sid(1)])])
    assert.strictEqual(tower(m, 1).undecomposed, true)
    assert.deepStrictEqual(tower(m, 2).stacking, { kind: 'tower', on: [sid(1)] })
    assert.strictEqual(story_(m, 2).tree.parent, sid(1))
    assert.strictEqual(tower(m, 1).top, 'none', 'a dashed foundation carries other towers but has no battlements')
    assert.strictEqual(tower(m, 1).leaf, false)
    assert.strictEqual(story_(m, 1).finished, false)
  })

  await test('a dependency cycle never throws or hangs: its members fall back to the ground, are flagged, and have no tree parent', () => {
    const two = build([story(1, 'd', [sid(2)]), story(2, 'd', [sid(1)]), story(3, 'p', [sid(1)])])
    assert.ok(tower(two, 1).cycle && tower(two, 2).cycle && !tower(two, 3).cycle)
    assert.deepStrictEqual(tower(two, 1).stacking, { kind: 'ground', on: [] })
    assert.deepStrictEqual(tower(two, 2).stacking, { kind: 'ground', on: [] })
    assert.strictEqual(story_(two, 1).tree.parent, null)
    assert.strictEqual(story_(two, 2).tree.parent, null)
    // an outsider that depends on a member stands on it like on any tower
    assert.deepStrictEqual(tower(two, 3).stacking, { kind: 'tower', on: [sid(1)] })
    assert.strictEqual(tower(two, 3).level, 1)
    // a three-story ring, a ring with a tail, a self dependency, and a cycle that includes an undecomposed story
    const ring = build([story(1, 'd', [sid(3)]), story(2, 'd', [sid(1)]), story(3, 'd', [sid(2)]), story(4, 'p', [sid(3), sid(4)])])
    assert.deepStrictEqual(ring.towers.filter(t => t.cycle).map(t => t.storyId).sort(), ids(1, 2, 3))
    assert.strictEqual(ring.towers.length, 4)
    const self = build([story(1, 'd', [sid(1)])])
    assert.strictEqual(tower(self, 1).cycle, false, 'a self dependency is ignored, not a cycle')
    assert.deepStrictEqual(tower(self, 1).stacking, { kind: 'ground', on: [] })
    const ghost = build([story(1, null, [sid(2)]), story(2, 'd', [sid(1)])])
    assert.ok(ghost.towers.every(t => t.cycle))
    // the trunk is never a cycle member while another parentless story exists
    assert.strictEqual(build([story(1, 'd', [sid(2)]), story(2, 'd', [sid(1)]), story(3, 'p')]).trunk, sid(3))
    assert.strictEqual(two.trunk, sid(1), 'only cycle members are parentless: the first of them')
  })

  await test('roof versus battlements: finished leaf has a roof with a flag, finished carrier has battlements, otherwise neither', () => {
    const m = build([
      story(1, 'dd'), // finished, carries S02: battlements
      story(2, 'dd', [sid(1)]), // finished, leaf: roof
      story(3, 'di'), // unfinished leaf: none
      story(4, 'dd'), // finished, carries S05 (unfinished): battlements
      story(5, 'p', [sid(4)]), // unfinished leaf: none
      story(6, 'df'), // failed: none
      story(7, null), // undecomposed: none
    ])
    assert.deepStrictEqual(m.towers.map(t => [t.storyId, t.top]), [
      [sid(1), 'battlements'], [sid(2), 'roof'], [sid(3), 'none'], [sid(4), 'battlements'], [sid(5), 'none'], [sid(6), 'none'], [sid(7), 'none'],
    ])
    assert.deepStrictEqual(m.towers.map(t => t.leaf), [false, true, true, false, true, true, true])
  })

  await test('the height cap: H is one named constant, widening is one function (k = ceil(n / H) tasks as k blocks)', () => {
    assert.strictEqual(MAX_TOWER_LAYERS, 8)
    assert.strictEqual(typeof widenLayers, 'function')
    for (const n of [0, 1, 3, 7, 8]) {
      const p = widenLayers(n)
      assert.deepStrictEqual([p.tasksPerLayer, p.layers, p.blocks, p.width, p.widened], [1, n, BLOCKS_PER_LAYER, 3, false], `n = ${n}`)
    }
    assert.deepStrictEqual(widenLayers(9), { tasksPerLayer: 2, layers: 5, blocks: 2, width: 3, widened: true })
    assert.deepStrictEqual(widenLayers(16), { tasksPerLayer: 2, layers: 8, blocks: 2, width: 3, widened: true })
    assert.deepStrictEqual(widenLayers(17), { tasksPerLayer: 3, layers: 6, blocks: 3, width: 3, widened: true })
    assert.deepStrictEqual(widenLayers(26), { tasksPerLayer: 4, layers: 7, blocks: 4, width: 4, widened: true })
    assert.deepStrictEqual(widenLayers(94), { tasksPerLayer: 12, layers: 8, blocks: 12, width: 12, widened: true })
    for (let n = 0; n <= 400; n++) {
      const p = widenLayers(n)
      assert.ok(p.layers <= MAX_TOWER_LAYERS, `n = ${n}: at most H layers`)
      assert.ok(p.layers * p.tasksPerLayer >= n && (p.layers - 1) * p.tasksPerLayer < Math.max(n, 1), `n = ${n}: every task has a place and no layer is spare`)
      assert.strictEqual(p.tasksPerLayer, Math.max(1, Math.ceil(n / MAX_TOWER_LAYERS)))
    }
    assert.strictEqual(widenLayers(9, 4).tasksPerLayer, 3, 'another cap only through the argument, the model always uses the constant')
  })

  await test('a story above H gets wider layers, not more layers; the castle\'s base does not widen', () => {
    const big = 'ddddddddddddpppppppppppppp' // 26 tasks: 12 done, 14 pending
    const m = build([story(1, big), story(2, 'dd'), story(3, 'p')])
    const t = tower(m, 1)
    assert.strictEqual(t.plan.widened, true)
    assert.strictEqual(t.layers.length, 7)
    assert.deepStrictEqual(t.layers.map(l => l.blocks), [4, 4, 4, 4, 4, 4, 2])
    assert.deepStrictEqual(t.layers.map(l => l.tasks.length), [4, 4, 4, 4, 4, 4, 2])
    assert.strictEqual(t.layers.reduce((a, l) => a + l.tasks.length, 0), 26)
    assert.deepStrictEqual(t.layers.map(l => l.state), ['done', 'done', 'done', 'pending', 'pending', 'pending', 'pending'])
    assert.deepStrictEqual(t.layers[0].blockStates, ['done', 'done', 'done', 'done'])
    assert.deepStrictEqual(t.layers.map(l => l.direction), ['x', 'z', 'x', 'z', 'x', 'z', 'x'])
    // a layer is done only when all of its tasks are: 13 done of 26 at k = 4 gives 3 done layers and a mixed fourth one that is not done
    const mixed = build([story(1, 'ddddddddddddd' + 'pppppppppppp' + 'p')])
    assert.deepStrictEqual(tower(mixed, 1).layers.map(l => l.state).slice(0, 5), ['done', 'done', 'done', 'pending', 'pending'])
    assert.deepStrictEqual(tower(mixed, 1).layers[3].blockStates, ['done', 'pending', 'pending', 'pending'])
    // the other towers keep their normal plan and the model has no base width of its own
    assert.deepStrictEqual([tower(m, 2).plan.widened, tower(m, 2).plan.tasksPerLayer, tower(m, 3).plan.width], [false, 1, 3])
    assert.ok(!('width' in m) && !('baseWidth' in m))
    assert.strictEqual(m.towers.length, 3)
  })

  await test('the wall share is the input epic_progress, never recomputed; reached is the stated goal flag', () => {
    const list = [story(1, 'dd'), story(2, 'dd', [sid(1)])]
    const stated = build(list, { stories: 2, decomposed: 2, tasks_done: 4, tasks_denominator: 4, percent: 37, goal_reached: false })
    assert.deepStrictEqual(stated.wall, { percent: 37, share: 0.37, reached: false }, 'every task done, yet the stated 37 % is what it reports')
    const reached = build(list, { stories: 2, decomposed: 2, tasks_done: 4, tasks_denominator: 4, percent: 100, goal_reached: true })
    assert.deepStrictEqual(reached.wall, { percent: 100, share: 1, reached: true })
    for (const p of [0, 1, 17, 61, 99, 100]) assert.strictEqual(build(list, { percent: p, goal_reached: p === 100 }).wall.percent, p)
    assert.deepStrictEqual(build(list).wall, { percent: 0, share: 0, reached: false })
    assert.strictEqual(build(list, { percent: 12.9 }).wall.percent, 12, 'floored like the goal facts, as the script states it')
    assert.strictEqual(build(list, { percent: 250 }).wall.percent, 100)
    assert.strictEqual(build(list, { percent: -3 }).wall.percent, 0)
    assert.strictEqual(build(list, { percent: 100, goal_reached: 'yes' }).wall.reached, false)
    // a wall of a payload that has more epics reads its own epic's entry
    const g = graph(list, { percent: 40, goal_reached: false })
    g.epics.unshift({ id: 'E00', epic_progress: { percent: 99, goal_reached: true } })
    assert.strictEqual(buildCastleModel(g, EPIC).wall.percent, 40)
  })

  await test('tree parent and lean targets: none, one and several dependencies; the first is the deepest, then the lowest id', () => {
    const m = build([
      story(1, 'd'), // root: trunk
      story(2, 'd', [sid(1)]), // one dependency: parent S01
      story(3, 'd', [sid(1)]),
      story(4, 'd', [sid(2)]), // level 2
      story(5, 'p', ids(1, 3, 4)), // S04 is the deepest (level 2): the parent; S01 is implied through S04 and dropped, lean toward S03
      story(6, 'p', ids(3, 2)), // S02 and S03 are both level 1: the lowest id is the parent, lean toward the other
      story(7, 'd'), // a second parentless story
    ])
    const tree = n => story_(m, n).tree
    assert.deepStrictEqual(tree(1), { parent: null, lean: [], anchor: null, isTrunk: true })
    assert.deepStrictEqual(tree(2), { parent: sid(1), lean: [], anchor: sid(1), isTrunk: false })
    assert.deepStrictEqual(tree(4), { parent: sid(2), lean: [], anchor: sid(2), isTrunk: false })
    assert.deepStrictEqual(tree(5), { parent: sid(4), lean: [sid(3)], anchor: sid(4), isTrunk: false })
    assert.deepStrictEqual(story_(m, 5).dependsOn, ids(1, 3, 4))
    assert.deepStrictEqual(tree(6), { parent: sid(2), lean: [sid(3)], anchor: sid(2), isTrunk: false })
    assert.deepStrictEqual(tree(7), { parent: null, lean: [], anchor: sid(1), isTrunk: false })
    assert.strictEqual(m.trunk, sid(1))
    assert.strictEqual(m.stories.filter(s => s.tree.isTrunk).length, 1)
    // S05 depends on S01 (redundant through S04) and on S03 and S04: the parent S04, and S01 is dropped, not a lean target
    assert.deepStrictEqual(story_(m, 5).redundantDeps, [sid(1)])
    assert.deepStrictEqual(tree(5).lean, [sid(3)])
  })

  await test('the per-story data the seasons tree reads: census tasks, in-epic dependencies, undecomposed, finished, leaf and status', () => {
    const m = build([story(1, 'dd'), story(2, 'pdi', [sid(1)]), story(3, null, [sid(1)]), story(4, 'dr')])
    assert.deepStrictEqual(Object.keys(m.stories[0]).sort(), [
      'cycle', 'dependsOn', 'externalDeps', 'finished', 'leaf', 'lean', 'level', 'loose', 'redundantDeps', 'status', 'storyId', 'tasks', 'title', 'tree', 'undecomposed',
    ])
    assert.deepStrictEqual(m.stories.map(s => s.storyId), ids(1, 2, 3, 4), 'board order, not the tower order')
    const s2 = story_(m, 2)
    assert.deepStrictEqual(s2.tasks.map(t => t.state), ['done', 'in_progress', 'pending'])
    assert.deepStrictEqual([s2.finished, s2.leaf, s2.undecomposed, s2.status, s2.dependsOn], [false, true, false, 'in_progress', [sid(1)]])
    assert.deepStrictEqual([story_(m, 3).undecomposed, story_(m, 3).tasks, story_(m, 3).status], [true, [], 'pending'])
    assert.deepStrictEqual([story_(m, 1).finished, story_(m, 1).leaf], [true, false])
    assert.deepStrictEqual([story_(m, 4).finished, story_(m, 4).leaf, story_(m, 4).loose.length], [true, true, 1])
    assert.ok(m.stories.every(s => !('layers' in s) && !('stacking' in s) && !('top' in s)), 'no castle shape in the story data')
  })

  await test('deterministic: the same input in any order gives a deep-equal output, and the input is never changed', () => {
    const list = [story(1, 'dd'), story(2, 'dpf', [sid(1)]), story(3, 'ip', ids(1, 2)), story(4, null, [sid(3)]), story(5, 'dr', ids(2, 3))]
    const progress = { stories: 5, decomposed: 4, tasks_done: 4, tasks_denominator: 10, percent: 32, goal_reached: false }
    const g = deepFreeze(graph(list, progress))
    const first = buildCastleModel(g, EPIC)
    assert.deepStrictEqual(buildCastleModel(g, EPIC), first)
    const shuffled = JSON.parse(JSON.stringify(graph(list.slice().reverse(), progress)))
    shuffled.tasks.reverse(); shuffled.stories.reverse()
    shuffled.stories.forEach(s => { s.depends_on = s.depends_on.slice().reverse() })
    assert.deepStrictEqual(buildCastleModel(shuffled, EPIC), first)
    assert.strictEqual(JSON.stringify(buildCastleModel(JSON.parse(JSON.stringify(g)), EPIC)), JSON.stringify(first))
  })

  await test('an older payload without the new keys still gives a valid model (no stacking, no tree parents, no loose blocks)', () => {
    const full = graph([story(1, 'dd'), story(2, 'dp', [sid(1)]), story(3, 'dr')], { percent: 50, goal_reached: false })
    // no stories[] at all, no epic_progress, and tasks that only carry a bucket
    const bare = {
      tasks: full.tasks.map(t => ({ id: t.id, story_id: t.story_id, epic_id: t.epic_id, bucket: t.bucket })),
    }
    const m = buildCastleModel(bare, EPIC)
    assert.strictEqual(m.empty, false)
    assert.deepStrictEqual(m.order, ids(1, 2, 3))
    assert.deepStrictEqual(m.towers.map(t => t.layers.length), [2, 2, 1])
    assert.ok(m.towers.every(t => t.stacking.kind === 'ground' && !t.undecomposed && !t.cycle))
    assert.ok(m.stories.every(s => s.tree.parent === null && s.tree.lean.length === 0))
    assert.deepStrictEqual(m.wall, { percent: 0, share: 0, reached: false })
    assert.strictEqual(m.trunk, sid(1))
    assert.strictEqual(tower(m, 1).finished, true, 'derived from its counted tasks when the payload carries no complete')
    assert.strictEqual(tower(m, 3).loose.length, 1, 'a payload without state still states the rejected task through its bucket')
    assert.ok(m.towers.every(t => t.stacking.on.length === 0 && t.stacking.kind === 'ground'), 'no stories[] means no depends_on, so no stacking')
    // an older stories[] entry without decomposed, complete, stop or depends_on
    const legacy = { stories: [{ id: sid(1), epic_id: EPIC, title: 'Old' }], tasks: full.tasks.filter(t => t.story_id === sid(1)), epics: [{ id: EPIC }] }
    const l = buildCastleModel(legacy, EPIC)
    assert.deepStrictEqual([l.towers.length, l.towers[0].undecomposed, l.towers[0].status, l.towers[0].title], [1, false, 'done', 'Old'])
  })

  await test('odd input never throws: no graph, no epic, unknown epic, junk entries, an epic with no stories', () => {
    for (const [g, e] of [[null, EPIC], [undefined, EPIC], [{}, EPIC], [{}, ''], [{}, null], [graph([story(1, 'd')]), 'E99'], [graph([]), EPIC],
      [{ stories: [null, 3, 'x', { id: 5 }, { epic_id: EPIC }], tasks: [null, {}, { id: 'T', story_id: 7, epic_id: EPIC }], epics: [null] }, EPIC]]) {
      const m = buildCastleModel(g, e)
      assert.strictEqual(m.empty, true)
      assert.deepStrictEqual([m.towers, m.stories, m.bridges, m.order, m.levels, m.trunk], [[], [], [], [], 0, null])
      assert.deepStrictEqual(m.constants, { MAX_TOWER_LAYERS: 8, BLOCKS_PER_LAYER: 3 })
    }
    assert.deepStrictEqual(buildCastleModel(graph([story(1, 'd')], { percent: 61 }), 'E99').wall, { percent: 0, share: 0, reached: false })
    assert.strictEqual(buildCastleModel(graph([], { percent: 61 }), EPIC).wall.percent, 61, 'an epic with no story still states its percent')
  })

  await test('size fixtures: median 16 tasks / 6 stories, p75 32 / 8, max 94 / 22 and a 26-task story all build, hold their invariants', () => {
    const fixtures = {
      median: { tasks: 16, stories: 6, perStory: [3, 3, 3, 3, 2, 2] },
      p75: { tasks: 32, stories: 8, perStory: [5, 5, 4, 4, 4, 4, 3, 3] },
      max: { tasks: 94, stories: 22, perStory: [26, 12, 9, 8, 6, 5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 1, 1, 1, 0, 0, 0, 0] },
      big: { tasks: 26, stories: 1, perStory: [26] },
    }
    for (const [name, f] of Object.entries(fixtures)) {
      assert.strictEqual(f.perStory.reduce((a, b) => a + b, 0), f.tasks, `${name}: the fixture holds ${f.tasks} tasks`)
      assert.strictEqual(f.perStory.length, f.stories, `${name}: the fixture holds ${f.stories} stories`)
      const letters = 'dddipfplpdd'
      const list = f.perStory.map((n, i) => {
        const spec = n === 0 ? null : Array.from({ length: n }, (_, j) => letters[(i + j) % letters.length]).join('')
        // every story after the first stands on one earlier story, every fifth on two (a bridge)
        const deps = i === 0 ? [] : i % 5 === 4 ? [sid(i), sid(i - 1)] : [sid(Math.max(1, Math.floor(i / 2)))]
        return story(i + 1, spec, deps)
      })
      const m = build(list, { stories: f.stories, decomposed: f.perStory.filter(Boolean).length, percent: 40, goal_reached: false })
      assert.strictEqual(m.towers.length, f.stories, name)
      assert.strictEqual(m.stories.length, f.stories, name)
      assert.deepStrictEqual([...m.order].sort(idCompareLike), m.stories.map(s => s.storyId), `${name}: every story exactly once in the order`)
      assert.strictEqual(m.towers.filter(t => t.undecomposed).length, f.perStory.filter(n => n === 0).length, name)
      for (const t of m.towers) {
        assert.ok(t.layers.length <= MAX_TOWER_LAYERS, `${name} ${t.storyId}: at most H layers`)
        const n = story_(m, Number(t.storyId.slice(-2))).tasks.length
        assert.strictEqual(t.layers.reduce((a, l) => a + l.tasks.length, 0), n, `${name} ${t.storyId}: every counted task on exactly one layer`)
        assert.strictEqual(t.plan.widened, n > MAX_TOWER_LAYERS)
        assert.ok(t.layers.every((l, i) => l.direction === (i % 2 ? 'z' : 'x') && l.index === i))
        assert.ok(t.level >= 0 && t.level < m.levels)
      }
      assert.ok(m.bridges.every(b => b.ends.length >= 2))
      const widest = Math.max(...m.towers.map(t => t.plan.width))
      assert.strictEqual(widest, name === 'max' || name === 'big' ? 4 : 3, `${name}: only the 26-task story is wider than a normal tower`)
      assert.deepStrictEqual(buildCastleModel(graph(list, { percent: 40 }), EPIC), buildCastleModel(graph(list, { percent: 40 }), EPIC), `${name}: deterministic`)
    }
  })

  await test('a payload printed by scripts/board-progress.sh --graph already carries every key the model reads', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'castle-model-'))
    try {
      for (const d of ['epics', 'stories', 'tasks']) fs.mkdirSync(path.join(dir, 'project', 'board', d), { recursive: true })
      fs.mkdirSync(path.join(dir, 'project', 'configs'), { recursive: true })
      fs.writeFileSync(path.join(dir, 'project', 'configs', 'workflow.json'), '{}\n')
      const item = (id, status, ...lines) => {
        const kind = /_T\d/.test(id) ? 'tasks' : /_S\d/.test(id) ? 'stories' : 'epics'
        const own = kind === 'tasks' ? [`story_id: ${id.replace(/_T\d+$/, '')}`, `epic_id: ${id.split('_')[0]}`] : kind === 'stories' ? [`epic_id: ${id.split('_')[0]}`] : []
        fs.writeFileSync(path.join(dir, 'project', 'board', kind, `${id}_x.md`), ['---', `id: ${id}`, `title: "Title of ${id}"`, `status: ${status}`, ...own, ...lines, '---', '', '# body', ''].join('\n'))
      }
      item('E01', 'In Progress')
      item('E01_S01', 'Passed'); item('E01_S01_T01', 'Passed'); item('E01_S01_T02', 'Passed')
      item('E01_S02', 'In Progress', 'depends_on: [E01_S01]'); item('E01_S02_T01', 'Passed'); item('E01_S02_T02', 'In Progress'); item('E01_S02_T03', 'Rejected')
      item('E01_S03', 'Pending', 'depends_on: [E01_S01, E99_S01]'); item('E01_S03_T01', 'Failed'); item('E01_S03_T02', 'Pending', 'depends_on: [E01_S03_T01]')
      item('E01_S04', 'Pending')
      item('E01_S05', 'Pending', 'depends_on: [E01_S02, E01_S03]'); item('E01_S05_T01', 'Pending')
      const out = cp.execFileSync('bash', [boardProgress, '--graph', '--root', dir], { encoding: 'utf8' })
      const g = JSON.parse(out)
      assert.strictEqual(g.schema_version, 1)
      const m = buildCastleModel(g, 'E01')
      assert.deepStrictEqual(m.towers.map(t => [t.storyId, t.status, t.undecomposed, t.stacking.kind]).sort(), [
        ['E01_S01', 'done', false, 'ground'], ['E01_S02', 'in_progress', false, 'tower'], ['E01_S03', 'failed', false, 'tower'],
        ['E01_S04', 'pending', true, 'ground'], ['E01_S05', 'pending', false, 'bridge'],
      ])
      assert.deepStrictEqual(tower(m, 2).loose, ['E01_S02_T03'])
      assert.deepStrictEqual(tower(m, 2).layers.map(l => l.state), ['done', 'in_progress'])
      assert.deepStrictEqual(tower(m, 3).layers.map(l => l.state), ['failed', 'pending'])
      assert.strictEqual(tower(m, 3).lean, true)
      assert.deepStrictEqual(story_(m, 3).externalDeps, ['E99_S01'])
      assert.deepStrictEqual(m.bridges.map(b => [b.storyId, b.ends, b.adjacent]), [['E01_S05', ['E01_S02', 'E01_S03'], true]])
      assert.deepStrictEqual(tower(m, 1).top, 'battlements')
      const ep = g.epics.find(e => e.id === 'E01').epic_progress
      assert.deepStrictEqual([m.wall.percent, m.wall.reached], [ep.percent, ep.goal_reached])
      assert.strictEqual(ep.decomposed, 4)
      assert.strictEqual(m.towers.filter(t => t.undecomposed).length, ep.stories - ep.decomposed)
    } finally {
      fs.rmSync(dir, { recursive: true, force: true })
    }
  })

  await test('no DOM and no import in the model; the terminal renderers under lib/progress/ never import it', () => {
    const src = fs.readFileSync(modelPath, 'utf8')
    const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
    assert.ok(!/^\s*import\s/m.test(code) && !/\brequire\s*\(/.test(code), 'no import, no require')
    for (const word of ['document', 'window', 'navigator', 'localStorage', 'React', 'getElementById', 'fetch(']) assert.ok(!code.includes(word), word)
    assert.ok(!/#[0-9a-fA-F]{3,8}\b|rgba?\(|\bpx\b/.test(code), 'no colour and no pixel number')
    const libDir = path.join(root, 'lib', 'progress')
    for (const f of fs.readdirSync(libDir)) {
      if (!/\.(m?js|cjs)$/.test(f)) continue
      assert.ok(!/castleModel/.test(fs.readFileSync(path.join(libDir, f), 'utf8')), `${f} does not import the castle model`)
    }
  })

  console.log(`\n${count} passed`)
}

// numeric-aware sort used on the fixture ids (E01_S01 .. E01_S22): plain string order is enough for zero-padded ids
function idCompareLike(a, b) { return a < b ? -1 : a > b ? 1 : 0 }

main().catch(err => { console.error(err); process.exit(1) })
