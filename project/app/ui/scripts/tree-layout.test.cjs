#!/usr/bin/env node
'use strict'
// E92_S13_T07: test of the seasons tree's pure layout (treeLayout.js). Zero test framework and no DOM, plain node, like
// castle-model.test.cjs: treeLayout.js is pure ESM whose only import is castleModel.js, so it is loaded with a dynamic import.
// The fixtures are the sizes of story decision 7: 16 tasks / 6 stories (the median), 32 / 8 (p75), 94 / 22 (the maximum), and one
// 26-task story. Every fixture is checked for the properties the story promises: one clump per counted task, no two clumps
// overlap, no two branches cross, no two labels overlap, everything lies inside the frame, and the same input gives the same output.
// Run: node project/app/ui/scripts/tree-layout.test.cjs
const assert = require('assert')
const fs = require('fs')
const path = require('path')
const { pathToFileURL } = require('url')

const progressDir = path.join(__dirname, '..', 'src', 'components', 'progress')
let count = 0
const test = async (name, fn) => { await fn(); count++; console.log('ok  ' + name) }

const EPIC = 'E01'
const STATE = { d: 'done', i: 'in_progress', f: 'failed', p: 'ready', l: 'locked', r: 'rejected' }
const BUCKET = { d: 'done', i: 'in_progress', f: 'failed', p: 'pending', l: 'pending', r: 'rejected' }
const sid = n => `${EPIC}_S${String(n).padStart(2, '0')}`

/** One story as `board-progress.sh --graph` would print it, with its tasks (one letter per task; null = undecomposed). */
function story(n, spec, deps) {
  const id = sid(n)
  const letters = spec ? spec.split('') : []
  const counted = letters.filter(c => 'dipfl'.includes(c))
  const done = counted.filter(c => c === 'd').length
  const complete = counted.length > 0 && done === counted.length
  const stop = complete ? 'done' : counted.includes('f') ? 'failed' : counted.includes('i') || done > 0 ? 'in_progress' : 'pending'
  const entry = { id, epic_id: EPIC, title: `Story ${n}`, depends_on: (deps || []).map(sid), complete, decomposed: counted.length > 0, stop }
  const tasks = letters.map((c, i) => ({ id: `${id}_T${String(i + 1).padStart(2, '0')}`, story_id: id, epic_id: EPIC, title: `t${i + 1}`, status: '', bucket: BUCKET[c], state: STATE[c], depends_on: [] }))
  return { entry, tasks }
}
const graph = (list, progress) => ({
  schema_version: 1,
  epics: [{ id: EPIC, title: 'Epic', depends_on: [], ...(progress ? { epic_progress: progress } : {}) }],
  stories: list.map(s => s.entry),
  tasks: list.flatMap(s => s.tasks),
})
const progress = (percent, reached) => ({ percent, goal_reached: reached === true })
const factsOf = list => Object.fromEntries(list.map(s => {
  const counted = s.tasks.filter(t => ['done', 'in_progress', 'failed', 'pending', 'ready', 'locked'].includes(t.state))
  return [s.entry.id, { done: counted.filter(t => t.state === 'done').length, total: counted.length, failed: counted.filter(t => t.state === 'failed').length }]
}))
/** A repeatable mix of states for a story of n tasks: the first `d` done, then one in progress, one failed (when asked), the rest to do. */
const mix = (n, d, opts) => {
  const o = opts || {}
  let s = ''
  for (let i = 0; i < n; i++) s += i < d ? 'd' : i === d && !o.noWip ? 'i' : i === d + 1 && o.fail ? 'f' : 'p'
  return s
}

// ---- the fixtures ----------------------------------------------------------------------------------------------------
/** 16 tasks / 6 stories: S1 the trunk, S2 and S3 on it, S4 on S2, S5 on S3, S6 on both S2 and S3 (leans). */
const median = () => [story(1, mix(3, 3)), story(2, mix(3, 2)), story(3, mix(3, 1)), story(4, mix(3, 0)), story(5, mix(2, 0, { noWip: true })), story(6, mix(2, 0, { noWip: true }), [2, 3])]
  .map((s, i) => (i === 0 ? s : { ...s, entry: { ...s.entry, depends_on: s.entry.depends_on.length ? s.entry.depends_on : [sid([0, 1, 1, 2, 3][i - 1] || 1)] } }))
/** 32 tasks / 8 stories. */
const p75 = () => {
  const deps = [[], [1], [1], [2], [2], [3], [4, 6], [5]]
  return deps.map((d, i) => story(i + 1, mix(4, i === 0 ? 4 : i < 3 ? 2 : 0, { fail: i === 5 }), d))
}
/** 94 tasks / 22 stories: a binary-ish tree of dependencies, a second root, two multi-dependency stories, an out-of-epic dependency and an undecomposed story. */
const maximum = () => {
  const list = []
  const counts = [6, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 3]
  for (let i = 1; i <= 22; i++) {
    let deps = i === 1 ? [] : [Math.floor(i / 2)]
    if (i === 9) deps = []
    if (i === 15) deps = [14, 7]
    if (i === 20) deps = [18, 19, 4]
    const spec = i === 12 ? null : mix(counts[i - 1], i < 6 ? counts[i - 1] : i < 14 ? 1 : 0, { fail: i === 17 })
    list.push(story(i, spec, deps))
  }
  list[20].entry.depends_on.push('E99_S01')
  return list
}
/** one 26-task story on a three-task root and a sibling. */
const large = () => [story(1, mix(3, 3)), story(2, mix(26, 9), [1]), story(3, mix(2, 0), [1])]

const FIXTURES = [
  ['16 tasks / 6 stories', median, 61, false],
  ['32 tasks / 8 stories', p75, 38, false],
  ['94 tasks / 22 stories', maximum, 24, false],
  ['a 26-task story', large, 45, false],
]

// ---- geometry helpers -------------------------------------------------------------------------------------------------
const sample = (b, n = 28) => Array.from({ length: n + 1 }, (_, i) => {
  const t = i / n
  const u = 1 - t
  return [u * u * b.p0[0] + 2 * u * t * b.c[0] + t * t * b.p1[0], u * u * b.p0[1] + 2 * u * t * b.c[1] + t * t * b.p1[1]]
})
const cross = (a, b, c) => (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
const segCross = (p1, p2, p3, p4) => {
  const d1 = cross(p3, p4, p1)
  const d2 = cross(p3, p4, p2)
  const d3 = cross(p1, p2, p3)
  const d4 = cross(p1, p2, p4)
  return ((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9)) && ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9))
}
const curvesCross = (a, b) => {
  const pa = sample(a)
  const pb = sample(b)
  for (let i = 0; i < pa.length - 1; i++) for (let j = 0; j < pb.length - 1; j++) if (segCross(pa[i], pa[i + 1], pb[j], pb[j + 1])) return true
  return false
}

async function main() {
  const M = await import(pathToFileURL(path.join(progressDir, 'treeLayout.js')).href)
  const C = await import(pathToFileURL(path.join(progressDir, 'castleModel.js')).href)
  const { layoutSeasonsTree, arrangeClumps, growthStage, GROWTH_STAGES, STONES, stonesLifted, mushroomsShown, MUSHROOM_AT, LARGE_STORY, CLUMP, treeAnchors, pushLabels, labelsOverlap, TREE_LIMITS } = M
  const build = (list, pct, reached) => {
    const model = C.buildCastleModel(graph(list, progress(pct, reached)), EPIC)
    return { model, layout: layoutSeasonsTree(model, factsOf(list)) }
  }

  for (const [name, make, pct] of FIXTURES) {
    await test(`${name}: one clump per counted task, in census order, none overlapping another`, () => {
      const list = make()
      for (const p of [0, pct, 100]) {
        const { model, layout } = build(list, p, false)
        const counted = model.stories.reduce((a, s) => a + s.tasks.length, 0)
        assert.strictEqual(layout.clumps.length, counted, 'a clump for every counted task, no more')
        for (const s of model.stories) {
          const mine = layout.clumps.filter(c => c.storyId === s.storyId)
          assert.deepStrictEqual(mine.map(c => c.taskId), s.tasks.map(t => t.id), s.storyId + ': census order of the model')
          assert.deepStrictEqual(mine.map(c => c.state), s.tasks.map(t => t.state))
        }
        for (let i = 0; i < layout.clumps.length; i++) {
          for (let j = i + 1; j < layout.clumps.length; j++) {
            const a = layout.clumps[i]
            const b = layout.clumps[j]
            assert.ok(Math.hypot(a.x - b.x, a.y - b.y) >= a.r + b.r - 0.02, `${name} at ${p}%: clumps ${a.taskId} and ${b.taskId} overlap`)
          }
        }
      }
    })

    await test(`${name}: no two branches cross, no two labels overlap, everything inside the frame, the same input gives the same output`, () => {
      for (const p of [0, pct, 100]) {
        const { layout } = build(make(), p, false)
        const bs = layout.branches
        for (let i = 0; i < bs.length; i++) {
          for (let j = i + 1; j < bs.length; j++) {
            if (bs[i].parent === bs[j].storyId || bs[j].parent === bs[i].storyId) continue
            assert.ok(!curvesCross(bs[i], bs[j]), `${name} at ${p}%: branches ${bs[i].storyId} and ${bs[j].storyId} cross`)
          }
        }
        for (let i = 0; i < layout.labels.length; i++) for (let j = i + 1; j < layout.labels.length; j++) assert.ok(!labelsOverlap(layout.labels[i], layout.labels[j]), `labels ${layout.labels[i].storyId} and ${layout.labels[j].storyId} overlap`)
        const f = layout.frame
        for (const c of layout.clumps) assert.ok(c.x - c.r >= f.x && c.x + c.r <= f.x + f.w && c.y - c.r >= f.y && c.y + c.r <= f.y + f.h, `clump ${c.taskId} outside the frame`)
        for (const b of bs) for (const pt of [b.p0, b.p1]) assert.ok(pt[0] >= f.x && pt[0] <= f.x + f.w && pt[1] >= f.y && pt[1] <= f.y + f.h, `branch ${b.storyId} outside the frame`)
        assert.deepStrictEqual(build(make(), p, false).layout, build(make(), p, false).layout, 'deterministic')
      }
    })
  }

  await test('the frame does not change with the percent, the tree and its trunk grow with it', () => {
    const list = median()
    const a = build(list, 0, false).layout
    const b = build(list, 50, false).layout
    const c = build(list, 100, false).layout
    assert.deepStrictEqual([a.frame, a.box, a.scale], [b.frame, b.box, b.scale])
    assert.deepStrictEqual([b.frame, b.box, b.scale], [c.frame, c.box, c.scale])
    assert.ok(a.trunk.girth < b.trunk.girth && b.trunk.girth < c.trunk.girth, 'trunk girth grows with epic_progress')
    assert.ok(a.trunk.height < b.trunk.height && b.trunk.height < c.trunk.height, 'trunk height grows with epic_progress')
    assert.ok(a.growth.S < b.growth.S && b.growth.S < c.growth.S)
  })

  await test('the root story is the trunk; every other story grows from its tree parent, or from the trunk when it has none', () => {
    const { model, layout } = build(maximum(), 24, false)
    assert.strictEqual(layout.trunk.storyId, model.trunk)
    const trunkBranch = layout.branches.find(b => b.isTrunk)
    assert.strictEqual(trunkBranch.storyId, model.trunk)
    for (const s of model.stories) {
      const b = layout.branches.find(x => x.storyId === s.storyId)
      if (s.storyId === model.trunk) assert.strictEqual(b.parent, null)
      else assert.strictEqual(b.parent, s.tree.parent || model.trunk, s.storyId)
    }
    const second = layout.branches.find(b => b.storyId === sid(9))
    assert.strictEqual(second.parent, model.trunk, 'a second root grows from the trunk')
    assert.strictEqual(layout.branches.find(b => b.storyId === sid(20)).parent, model.stories.find(s => s.storyId === sid(20)).tree.parent, 'two or more dependencies: the first is the parent')
  })

  await test('a branch lengthens with its story\'s done share, a failed story\'s branch droops', () => {
    const mk = d => [story(1, mix(3, 3)), story(2, mix(4, d, { noWip: true }), [1]), story(3, mix(4, 2, { noWip: true }), [1])]
    const len = d => { const l = build(mk(d), 50, false).layout; const b = l.branches.find(x => x.storyId === sid(2)); return Math.hypot(b.p1[0] - b.p0[0], b.p1[1] - b.p0[1]) / l.growth.S }
    assert.ok(len(0) < len(2) && len(2) < len(4), 'longer with more done')
    const ok = build([story(1, mix(3, 3)), story(2, 'dpp', [1])], 40, false).layout.branches.find(b => b.storyId === sid(2))
    const bad = build([story(1, mix(3, 3)), story(2, 'dfp', [1])], 40, false).layout.branches.find(b => b.storyId === sid(2))
    assert.ok(bad.droops && !ok.droops)
    assert.ok(bad.p1[1] > ok.p1[1] - 0.01 + 0 || bad.c[1] > ok.c[1], 'the failed branch sags')
  })

  await test('the worked example: 11 branches, 2 stubs, 9 decomposed stories carry 16 clumps of which 12 are done', () => {
    const list = [story(1, 'dd'), story(2, 'dd', [1]), story(3, 'dd', [1]), story(4, 'dd', [2]), story(5, 'dd', [3]), story(6, 'dd', [1]), story(7, 'ip', [4]), story(8, 'p', [5]), story(9, 'p', [6]), story(10, null, [7]), story(11, null, [8])]
    const { layout } = build(list, 61, false)
    assert.strictEqual(layout.branches.length, 11)
    assert.strictEqual(layout.stubs.length, 2)
    assert.strictEqual(layout.clumps.length, 16)
    assert.strictEqual(layout.clumps.filter(c => c.state === 'done').length, 12)
    assert.ok(layout.branches.filter(b => b.undecomposed).length === 2)
    assert.strictEqual(layout.source.towers.length, 11, 'the same model object the castle renders')
  })

  await test('the layout reads the model the castle renders: the same object is kept as `source`, nothing is recomputed', () => {
    const list = median()
    const model = C.buildCastleModel(graph(list, progress(61, false)), EPIC)
    const layout = layoutSeasonsTree(model, factsOf(list))
    assert.strictEqual(layout.source, model)
    assert.strictEqual(layout.growth.percent, model.wall.percent)
    assert.strictEqual(layout.growth.reached, model.wall.reached)
    const before = JSON.stringify(model)
    layoutSeasonsTree(model, factsOf(list))
    assert.strictEqual(JSON.stringify(model), before, 'the model is not changed')
  })

  await test('the large-story rule: one function, rings of slots at least `pitch` radii apart, the radius shrinks to the stated minimum, the territory holds every slot', () => {
    assert.ok(Object.isFrozen(LARGE_STORY) && Object.isFrozen(CLUMP), 'named constants')
    assert.strictEqual(arrangeClumps(0).slots.length, 0)
    assert.strictEqual(arrangeClumps(7).shrink, 1, 'up to fanMax keeps the full radius')
    assert.strictEqual(arrangeClumps(7).rings, 1)
    const big = arrangeClumps(26)
    assert.strictEqual(big.slots.length, 26)
    assert.strictEqual(big.shrink, LARGE_STORY.minShrink, 'shrinks to the minimum')
    assert.ok(big.radius >= CLUMP.radius * LARGE_STORY.minShrink - 0.01)
    assert.strictEqual(big.rings, 3)
    for (let i = 0; i < big.slots.length; i++) for (let j = i + 1; j < big.slots.length; j++) assert.ok(Math.hypot(big.slots[i].x - big.slots[j].x, big.slots[i].y - big.slots[j].y) >= big.radius * 2 - 0.01, 'slots apart')
    assert.ok(big.slots.every(s => Math.hypot(s.x, s.y) + big.radius <= big.territory + 0.01))
    const n = [1, 2, 6, 7, 8, 12, 19, 26, 40]
    for (const x of n) assert.strictEqual(arrangeClumps(x).slots.length, x)
    assert.deepStrictEqual(arrangeClumps(26), arrangeClumps(26), 'deterministic')
    // the source states it in one place
    const src = fs.readFileSync(path.join(progressDir, 'treeLayout.js'), 'utf8')
    assert.strictEqual((src.match(/export function arrangeClumps/g) || []).length, 1)
    assert.ok(/LARGE_STORY\.fanMax/.test(src) && /LARGE_STORY\.minShrink/.test(src))
  })

  await test('the growth stages are one table; Majestic tree only at goal reached; 99 percent is still Mature tree; a failed task blocks it', () => {
    assert.deepStrictEqual(GROWTH_STAGES.map(s => s.id), ['sprout', 'seedling', 'sapling', 'young', 'mature', 'majestic'])
    assert.deepStrictEqual(GROWTH_STAGES.map(s => s.percent), [0, 10, 25, 45, 70, 100])
    const at = (p, r) => GROWTH_STAGES[growthStage(p, r)].id
    assert.deepStrictEqual([0, 9, 10, 24, 25, 44, 45, 69, 70, 99, 100].map(p => at(p, false)), ['sprout', 'sprout', 'seedling', 'seedling', 'sapling', 'sapling', 'young', 'young', 'mature', 'mature', 'mature'], '100 without goal reached is still Mature tree')
    assert.strictEqual(at(99, true), 'majestic')
    assert.strictEqual(at(99, false), 'mature')
    assert.strictEqual(at(NaN, false), 'sprout')
    const failed = build([story(1, 'dd'), story(2, 'df', [1])], 99, false).layout
    assert.strictEqual(GROWTH_STAGES[failed.growth.stage].id, 'mature', 'a failed task blocks the goal and so Majestic tree')
    const reached = build([story(1, 'dd'), story(2, 'dd', [1])], 100, true).layout
    assert.strictEqual(GROWTH_STAGES[reached.growth.stage].id, 'majestic')
    // the thresholds live in the table only
    const src = fs.readFileSync(path.join(progressDir, 'treeLayout.js'), 'utf8')
    assert.strictEqual((src.match(/export const GROWTH_STAGES/g) || []).length, 1)
  })

  await test('the surroundings read the percent only: stones lift out at 25, 45, 65 and 85 (24/25, 44/45, 64/65, 84/85), mushrooms from 55', () => {
    assert.deepStrictEqual(STONES.map(s => s.at), [25, 45, 65, 85])
    const lifted = p => build(median(), p, false).layout.surroundings.stones.filter(s => s.lifted).length
    assert.deepStrictEqual([0, 24, 25, 44, 45, 64, 65, 84, 85, 100].map(lifted), [0, 0, 1, 1, 2, 2, 3, 3, 4, 4])
    assert.deepStrictEqual([24, 25, 44, 45, 64, 65, 84, 85].map(stonesLifted), [0, 1, 1, 2, 2, 3, 3, 4])
    assert.ok(!mushroomsShown(MUSHROOM_AT - 1) && mushroomsShown(MUSHROOM_AT))
    const a = build(median(), 54, false).layout.surroundings
    const b = build(median(), 55, false).layout.surroundings
    assert.strictEqual(a.mushrooms.length, 0)
    assert.strictEqual(b.mushrooms.length, 2)
    const lo = build(median(), 10, false).layout.surroundings
    const hi = build(median(), 90, false).layout.surroundings
    assert.ok(lo.islandHalfW < hi.islandHalfW, 'the island widens')
    assert.ok(lo.grass.length < hi.grass.length && lo.flowers.length < hi.flowers.length, 'grass and flowers spread')
    assert.ok(lo.rays.day < hi.rays.day && lo.motes.length < hi.motes.length, 'rays and motes strengthen')
    // the same percent over a different tree gives the same surroundings (it counts nothing)
    const other = build(maximum(), 90, false).layout.surroundings
    assert.strictEqual(other.islandHalfW, hi.islandHalfW)
    assert.deepStrictEqual(other.stones.map(s => s.lifted), hi.stones.map(s => s.lifted))
  })

  await test('goal-reached effects: only when the goal is reached, never with a failed or an undecomposed story; each crown section takes a season tone', () => {
    const done = [story(1, 'dd'), story(2, 'dd', [1]), story(3, 'dd', [1])]
    const on = build(done, 100, true).layout
    assert.strictEqual(on.effects.active, true)
    assert.strictEqual(on.effects.spirits.length, 2)
    assert.ok(on.effects.swing && on.effects.petals.length > 0)
    assert.deepStrictEqual(on.branches.map(b => b.tone), [0, 1, 2], 'each story its own season tone')
    const off = build(done, 99, false).layout
    assert.strictEqual(off.effects.active, false)
    assert.deepStrictEqual(off.effects.spirits, [])
    assert.deepStrictEqual(off.branches.map(b => b.tone), [0, 0, 0])
    const failed = build([story(1, 'dd'), story(2, 'df', [1])], 100, true).layout
    assert.strictEqual(failed.effects.active, false, 'a failed story shows none of them')
    const undec = build([story(1, 'dd'), story(2, null, [1])], 100, true).layout
    assert.strictEqual(undec.effects.active, false, 'an undecomposed story shows none of them')
  })

  await test('finished leaf stories carry a vine with a lantern, an undecomposed story is a stub marked with a "?", a branch where nothing started carries snow', () => {
    const { layout } = build([story(1, 'dd'), story(2, 'dd', [1]), story(3, 'pp', [1]), story(4, null, [1])], 50, false)
    assert.deepStrictEqual(layout.vines.map(v => v.storyId), [sid(2)], 'finished and nothing depends on it')
    assert.strictEqual(layout.stubs.length, 1)
    assert.strictEqual(layout.labels.find(l => l.storyId === sid(4)).text, `${sid(4)} ?`)
    assert.strictEqual(layout.labels.find(l => l.storyId === sid(2)).text, `${sid(2)} · 2/2`)
    assert.deepStrictEqual(layout.branches.filter(b => b.snow).map(b => b.storyId), [sid(3)])
  })

  await test('a dependency cycle, an out-of-epic dependency and a second root never throw and grow from the trunk', () => {
    const cyc = [story(1, 'dd'), story(2, 'dp', [3]), story(3, 'pp', [2]), story(4, 'dd', ['99']), story(5, 'p', [4])]
    cyc[3].entry.depends_on = ['E77_S01']
    const { model, layout } = build(cyc, 30, false)
    assert.strictEqual(layout.branches.length, 5)
    for (const b of layout.branches) assert.ok(b.isTrunk || layout.branches.some(x => x.storyId === b.parent), b.storyId + ' has a parent')
    assert.strictEqual(layout.branches.find(b => b.storyId === sid(2)).parent, model.trunk)
    assert.strictEqual(layout.branches.find(b => b.storyId === sid(3)).parent, model.trunk)
    assert.strictEqual(layout.branches.find(b => b.storyId === sid(4)).parent, model.trunk)
    assert.strictEqual(layout.branches.find(b => b.storyId === sid(5)).parent, sid(4))
    // a hand-made model with a looping parent chain falls back to the trunk
    const odd = JSON.parse(JSON.stringify(model))
    odd.stories.find(s => s.storyId === sid(2)).tree.parent = sid(3)
    odd.stories.find(s => s.storyId === sid(3)).tree.parent = sid(2)
    const l2 = layoutSeasonsTree(odd, {})
    assert.strictEqual(l2.branches.length, 5)
    assert.ok(l2.branches.filter(b => !b.isTrunk).every(b => b.parent), 'every branch has a parent')
  })

  await test('an empty or odd model gives an empty layout with a box and does not throw', () => {
    for (const bad of [null, undefined, {}, { stories: [] }, 'x', { stories: 3 }]) {
      const l = layoutSeasonsTree(bad, null)
      assert.strictEqual(l.empty, true)
      assert.ok(l.box.w > 0 && l.box.h > 0 && l.text.top > l.box.bottom)
      assert.deepStrictEqual(l.branches, [])
      assert.strictEqual(treeAnchors(l, 3).length, 3)
    }
    const m = C.buildCastleModel(graph([story(1, 'd')]), EPIC)
    assert.strictEqual(layoutSeasonsTree(m, undefined).branches.length, 1)
  })

  await test('labels are pushed apart deterministically (bounded) and keep a leader anchor; a moved label reports how far', () => {
    const mk = () => [{ ax: 0, ay: 0, x: 0, y: 0, w: 60, h: 16 }, { ax: 5, ay: 2, x: 5, y: 2, w: 60, h: 16 }, { ax: 10, ay: 1, x: 10, y: 1, w: 60, h: 16 }]
    const a = pushLabels(mk())
    const b = pushLabels(mk())
    assert.deepStrictEqual(a, b)
    for (let i = 0; i < a.length; i++) for (let j = i + 1; j < a.length; j++) assert.ok(!labelsOverlap(a[i], a[j]))
    assert.ok(a.some(l => l.moved > 0))
    assert.ok(a.every(l => l.ax !== undefined && l.ay !== undefined))
    assert.strictEqual(M.LABEL.iterations > 0 && Number.isFinite(M.LABEL.iterations), true)
  })

  await test('the box, the text under it and the goal anchors: spread points down the left rim of the island, in order of y', () => {
    const { layout } = build(median(), 61, false)
    assert.ok(layout.box.w <= TREE_LIMITS.maxWidth + 0.01 && layout.box.h <= TREE_LIMITS.maxHeight + 0.01)
    assert.ok(layout.box.w > 0 && layout.box.h > 0)
    assert.ok(Math.abs(layout.box.left + layout.box.right) < 0.01, 'centred')
    assert.strictEqual(layout.text.top, Math.round((layout.box.bottom + TREE_LIMITS.textGap) * 100) / 100)
    const pts = treeAnchors(layout, 5)
    assert.strictEqual(pts.length, 5)
    assert.ok(pts.every((p, i) => i === 0 || p.y > pts[i - 1].y), 'top to bottom')
    assert.ok(new Set(pts.map(p => p.y)).size === 5, 'spread over several points')
    assert.ok(pts.every(p => p.x < 0), 'on the left')
    assert.deepStrictEqual(treeAnchors(layout, 0), [])
    const big = build(maximum(), 24, false).layout
    assert.ok(big.scale < layout.scale, 'a larger tree is scaled down to its box')
    assert.ok(big.scale >= TREE_LIMITS.minScale)
  })

  await test('the stage track sits inside the frame at the size it is drawn, in every fixture', () => {
    for (const [, make] of FIXTURES) {
      const { layout } = build(make(), 40, false)
      const t = layout.track
      const f = layout.frame
      assert.ok(t.u >= 1 && t.u <= 2)
      assert.ok(t.x0 - 14 * t.u >= f.x && t.x1 + 14 * t.u <= f.x + f.w && t.y - 14 * t.u >= f.y && t.y + 32 * t.u <= f.y + f.h, 'the track pill is inside the frame')
    }
  })

  await test('treeLayout.js is pure: no import but the castle model, no React, DOM, colour or user-visible word', () => {
    const src = fs.readFileSync(path.join(progressDir, 'treeLayout.js'), 'utf8')
    const imports = [...src.matchAll(/^import .* from '(.*)'/gm)].map(m => m[1])
    assert.deepStrictEqual(imports, ['./castleModel.js'])
    assert.ok(!/\bdocument\b|\bwindow\b|from 'react'/.test(src))
    const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(code) && !/\b(rgb|rgba|hsl|hsla|oklch|color-mix)\(/.test(code), 'no colour literal')
    assert.ok(!/Math\.random|Date\.now|new Date/.test(code), 'deterministic')
  })

  console.log(`\n${count} tests passed`)
}

main().catch(e => { console.error('FAIL', e && e.stack ? e.stack : e); process.exit(1) })
