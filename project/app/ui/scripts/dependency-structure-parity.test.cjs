#!/usr/bin/env node
'use strict'
// E92_S08_T02: parity test for the split of dependencyTreeModel.js. The graph structure moved to
// lib/progress/dependency-structure.js (shared with the terminal renderer); the dashboard model must stay deep-equal to what
// the old, single-file model produced. tests/fixtures/progress/dependency-tree-parity.json holds the inputs (the fixtures of
// dependency-tree-model.test.cjs, folding fixtures and a synthetic board; full-board and `--within` payloads) and the
// outputs RECORDED from the pre-split model (git 8d380c6e), folded and with groups unfolded in several ways. Plain node.
//
// E92_S09_T01 (user request 2026-11-15: "an epic's tree must always render whether or not it has dependencies; the only
// exception is an epic with no tasks") changed the recorded expectations of exactly the three cases with tasks but no
// dependency edge, which the pre-split model recorded as empty: they were re-recorded from the current model and renamed
//   'full-board E00 (no dependencies at all: empty)'  -> 'full-board E00 (no dependency edge: tree, E92_S09_T01)'
//   'self edge only: empty'                            -> 'self edge only: tree (E92_S09_T01)'
//   'no dependencies but progress: empty with goal'    -> 'no dependencies but progress: tree with goal (E92_S09_T01)'
// and one edge-free case was added ('edge-free epic, two stories, every mark and a fold in column 0 (E92_S09_T01)').
// Every other recorded case is byte-identical to the 8d380c6e recording (the fixture's `rerecorded` key says the same).
//
// E92_S09_T02 (user decision 2026-11-15: the padlock gate follows the task's EFFECTIVE dependencies, its own depends_on plus
// its story's, and a `ready` task, which the script found startable, always carries the open gate) changed the recorded
// `gate` of the ready tasks in exactly two cases, whose fixtures hold a ready task with an unfinished dependency (input the
// script never prints): locked became open, nothing else changed. They were re-recorded from the current model and renamed
//   'fold: 3 + 3 across two columns'              -> 'fold: 3 + 3 across two columns (ready gate open, E92_S09_T02)'
//   'fold: groups in two stories and two columns' -> 'fold: groups in two stories and two columns (ready gate open, E92_S09_T02)'
//
// E92_S09_T04 (the goal is the epic percent board-progress.sh states in epic_progress, read unchanged, never recomputed):
// every case graph whose epic entry exists now states the epic_progress the script would print for it (stories and
// decomposed from the case's stories and counted tasks, tasks_done/tasks_denominator the previously recorded goal counts),
// and ONLY the goal object of every recorded variant was re-recorded from the current model: it gains stories and
// decomposed, fraction is percent / 100 and percent is the script's floor (e.g. 1/6: 17 -> 16). Two cases have a story
// without tasks, so their goal drops: 'self edge only: tree (E92_S09_T01)' 100 -> 50 (not reached), 'no dependencies but
// progress: tree with goal (E92_S09_T01)' 50 -> 25. The re-recording asserted every other key unchanged in every variant.
// The two cases with no epic entry in their graph ('unknown epic: empty', 'empty epic id: empty') state no epic_progress;
// their zero goal was re-recorded the same way (it gains stories: 0 and decomposed: 0).
//
// E92_S10_T01 (user decision 2026-11-15, the padlock rule for every task state: "Om den inte är genomförd och har beroenden
// som inte är uppfyllda ska det vara ett stängt lås, annars ska det alltid visas ett öppet lås oavsett status på ärendet")
// changed the recorded `gate` in exactly the eight cases below and nothing else (the re-recording asserted every other key
// of every variant unchanged). The case graphs predate board-progress.sh's waiting_on key, so they read as payloads of an
// older script, where only a locked pending task closes the padlock. The cases were re-recorded from the current model and
// renamed with the suffix ' (gate rule, E92_S10_T01)':
//   'story totals, long title, one story without totals'   a done task whose own dependency is not done: locked -> open
//   'gate and mark matrix'                                 a failed task with an unfinished dependency and no waiting_on:
//                                                          locked -> open (the payload states nothing it waits for)
//   'fold: 6 ready + 2 locked'                             two pending tasks in state locked: open -> locked
//   'fold: groups in two stories and two columns (ready gate open, E92_S09_T02)'
//                                                          eight in-progress tasks, no waiting_on: locked -> open
//   'state order within a cell'                            a pending task in state locked: open -> locked
//   'goal: all rejected'                                   a rejected task: locked -> open
//   'synthetic 27-task board'                              done, in-progress and rejected tasks locked -> open; two
//                                                          pending tasks in state locked open -> locked
//   'synthetic wide fan, 29 tasks in one cell'             ten pending tasks in state locked: open -> locked
// Before T01 a gate outside `ready` and `blocked_by` came from the task's OWN dependencies' buckets (done = open), so a
// locked task whose own dependencies were done showed the open padlock and a done task the closed one.
//
// E92_S10_T02 (user decision 2026-11-15: "'Goal reached' när en story är Failed: hindra det"; board-progress.sh states
// failed_stories in epic_progress, the goal carries it as failedStories): every recorded goal object of every case and
// variant (51 objects, all 38 cases) gained `failedStories: []` after `decomposed`, and nothing else. No case graph states
// failed_stories (they read as payloads of an older script, where the key is absent and the list empty), so the value is
// [] everywhere. No case was renamed: every case changed the same way and only by that key (the re-recording asserted
// that removing the key gives back the previous recording exactly). The new test below pins it.
//
// E92_S11_T03 (user request 2026-11-15: fold same-state tasks already when more than three share a story and a column;
// FOLD_THRESHOLD 5 -> 3) changed exactly one case, re-recorded from the current model and renamed
//   'fold: 5 ready do not fold' -> 'fold: 5 ready now fold (fold threshold 3, E92_S11_T03)'
// its five ready tasks now fold into one group of 5 (nodes, bands, edges, foldable, layout and the goal's y change, and the
// unfolded variants carry the group's collapse header). Every other case is byte-identical to the previous recording.
//
// E92_S12_T02 (ghost bands for undecomposed stories, opt-in through buildDependencyStructure's `options`): NO recorded case
// changed and none was re-recorded: dependency-tree-parity.json is byte-identical, and no case graph carries a story
// `decomposed` flag, so every case stays deep-equal under the dashboard model, which now passes includeUndecomposed. The one
// new case lives in its own recording, tests/fixtures/progress/dependency-tree-ghost-bands.json ('ghost bands: ...').
//
// E92_S13_T02 (the citadel replaces the fixed goal area): NO recorded case changed and none was re-recorded; both recordings
// are byte-identical. The goal area is no longer one fixed number: the model lays the goal out for a goal area, 'castle' (the
// default, the citadel's box) or 'disc' (the star's fixed 260 x 70 area). The recordings are the disc layout, so this test
// builds them with { goalArea: 'disc' } and the layout of that area has exactly the keys and numbers it always had. The castle
// area changes only `layout` (width, height, goalAreaW, goalOffsetX, goalX, goalArea) and `goal` (x, y) and adds `castle`; the
// test 'the castle goal area changes only the layout, the goal position and the castle key' pins that for every recorded case,
// and dependency-tree-model.test.cjs covers the castle box itself.
// E92_S13_T06 (the castle and the seasons tree read the same payload): NO recorded case changed and none was re-recorded; the
// fixture gained one key, `castleTree`, whose 14 cases are real `board-progress.sh --graph --within` payloads (stacking on one story and a
// bridge on two; an out-of-epic, an uncounted, a self and a cyclic dependency; undecomposed stories and a rejected task; a failed story; a
// 26-task story; 94 tasks in 22 stories stacked and independent; the growth stages at 24 / 25 / 45 / 65 / 85 / 99 / 100 percent; a complete
// epic) with the structure the castle and the tree draw from each, recorded by project/app/ui/scripts/record-castle-tree-parity.mjs
// through castle-tree-summary.mjs (which this test uses too). No `--graph` key was added by E92_S13 (castle-model.test.cjs proves
// every key the model reads is printed), so there is no new payload key to cover. The terminal structure never imports either model.
// Run: node project/app/ui/scripts/dependency-structure-parity.test.cjs
const assert = require('assert')
const fs = require('fs')
const path = require('path')
const { pathToFileURL } = require('url')

const root = path.join(__dirname, '..', '..', '..', '..')
const modelPath = path.join(root, 'project', 'app', 'ui', 'src', 'components', 'progress', 'dependencyTreeModel.js')
const structurePath = path.join(root, 'lib', 'progress', 'dependency-structure.js')
const recordedPath = path.join(root, 'tests', 'fixtures', 'progress', 'dependency-tree-parity.json')
const ghostRecordedPath = path.join(root, 'tests', 'fixtures', 'progress', 'dependency-tree-ghost-bands.json')
const summaryPath = path.join(__dirname, 'castle-tree-summary.mjs')

const PIXEL_KEYS = ['x', 'y', 'w', 'h', 'inX', 'outX', 'midY']
let count = 0
const test = async (name, fn) => { await fn(); count++; console.log('ok  ' + name) }

/** Every object key found anywhere in a value. */
function keysOf(value, into = new Set()) {
  if (Array.isArray(value)) value.forEach(v => keysOf(v, into))
  else if (value && typeof value === 'object') for (const [k, v] of Object.entries(value)) { into.add(k); keysOf(v, into) }
  return into
}

async function main() {
  const M = await import(pathToFileURL(modelPath).href)
  const S = await import(pathToFileURL(structurePath).href)
  const recorded = JSON.parse(fs.readFileSync(recordedPath, 'utf8'))
  const labelsOf = c => (c.labelsMode === 'en' ? recorded.labels.en : c.labelsMode === 'sv' ? recorded.labels.sv : undefined)
  const build = c => {
    const l = labelsOf(c)
    return M.buildDependencyTreeModel(c.graph, c.epicId, l, { goalArea: 'disc' })
  }
  // a recorded variant is either the full output or "=<name>": the same as that other variant of the same case
  const expectedOf = (c, name) => {
    const v = c.expected[name]
    return typeof v === 'string' && v[0] === '=' ? expectedOf(c, v.slice(1)) : v
  }

  await test('the recording covers the full board, --within, folded and unfolded groups', () => {
    assert.ok(recorded.cases.length >= 30)
    assert.ok(recorded.cases.some(c => c.name === 'full-board E01') && recorded.cases.some(c => c.name === 'within E01'))
    assert.ok(recorded.cases.some(c => c.expected.folded.foldable.length > 0 && c.expected.folded.nodes.some(n => n.kind === 'group')), 'folded groups')
    assert.ok(recorded.cases.some(c => expectedOf(c, 'unfoldedAll').headers.length > 0), 'unfolded groups')
    assert.ok(recorded.cases.some(c => c.expected.folded.empty), 'empty models')
  })

  await test('E92_S09_T01: a recorded tree is empty exactly when its epic has no tasks, edges or not', () => {
    const edgeFree = recorded.cases.filter(c => /E92_S09_T01/.test(c.name))
    assert.strictEqual(edgeFree.length, 4, 'three re-recorded cases and one added case')
    for (const c of recorded.cases) {
      const tasks = (c.graph && Array.isArray(c.graph.tasks) ? c.graph.tasks : []).filter(t => t && c.epicId && t.epic_id === c.epicId)
      assert.strictEqual(c.expected.folded.empty, tasks.length === 0, c.name)
    }
    for (const c of edgeFree) {
      const f = c.expected.folded
      assert.ok(f.bands.length > 0 && f.layout.columns === 1, `${c.name}: bands in one depth column`)
      assert.ok(f.tasks.every(t => t.column === 0 && t.gate === 'none'), `${c.name}: column 0, gate none`)
      assert.ok(f.edges.every(e => e.kind === 'start' || e.kind === 'goal'), `${c.name}: only start and goal edges`)
    }
  })

  await test('E92_S10_T02: every recorded goal carries failedStories, [] since no case graph states failed_stories', () => {
    let goals = 0
    const walk = (v, k) => {
      if (Array.isArray(v)) v.forEach(x => walk(x))
      else if (v && typeof v === 'object') {
        if (k === 'goal' && 'reached' in v) { goals++; assert.deepStrictEqual(v.failedStories, [], JSON.stringify(v)); return }
        for (const [kk, vv] of Object.entries(v)) walk(vv, kk)
      }
    }
    recorded.cases.forEach(c => walk(c.expected))
    // 52 since E92_S11_T03: the re-recorded 'fold: 5 ready now fold' case's unfolded variant is no longer an alias of folded
    assert.strictEqual(goals, 52)
    assert.ok(recorded.cases.every(c => !JSON.stringify(c.graph || {}).includes('failed_stories')), 'no case graph states failed_stories')
    assert.ok(/E92_S10_T02/.test(recorded.rerecorded), 'the fixture says why')
  })

  await test('E92_S10_T01: the re-recorded gate cases are named, and no recorded done task carries the closed padlock', () => {
    const rerecorded = recorded.cases.filter(c => /\(gate rule, E92_S10_T01\)$/.test(c.name)).map(c => c.name)
    assert.deepStrictEqual(rerecorded, [
      'story totals, long title, one story without totals (gate rule, E92_S10_T01)',
      'gate and mark matrix (gate rule, E92_S10_T01)',
      'fold: 6 ready + 2 locked (gate rule, E92_S10_T01)',
      'fold: groups in two stories and two columns (ready gate open, E92_S09_T02) (gate rule, E92_S10_T01)',
      'state order within a cell (gate rule, E92_S10_T01)',
      'goal: all rejected (gate rule, E92_S10_T01)',
      'synthetic 27-task board (gate rule, E92_S10_T01)',
      'synthetic wide fan, 29 tasks in one cell (gate rule, E92_S10_T01)',
    ])
    for (const c of recorded.cases) {
      const stories = c.graph && Array.isArray(c.graph.stories) ? c.graph.stories : []
      const storyDeps = sid => {
        const s = stories.find(x => x && x.id === sid)
        return s && Array.isArray(s.depends_on) ? s.depends_on.filter(d => typeof d === 'string' && d) : []
      }
      for (const t of c.expected.folded.tasks) {
        const effective = t.dependsOn.length + storyDeps(t.storyId).filter(d => d !== t.id).length
        // no effective dependency: no padlock, whatever the state (e.g. a locked task with no dependency anywhere)
        if (effective === 0) assert.strictEqual(t.gate, 'none', `${c.name}: ${t.id} has no effective dependency`)
        if (t.bucket === 'done') assert.notStrictEqual(t.gate, 'locked', `${c.name}: ${t.id}`)
        // a task the script states locked, with a dependency, carries the closed padlock
        if (t.state === 'locked' && effective > 0) assert.strictEqual(t.gate, 'locked', `${c.name}: ${t.id}`)
      }
    }
  })

  for (const c of recorded.cases) {
    await test(`parity: ${c.name}`, () => {
      const folded = build(c)
      assert.deepStrictEqual(folded, expectedOf(c, 'folded'), 'folded')
      const all = folded.foldable
      assert.deepStrictEqual(M.unfoldGroups(folded, new Set(all)), expectedOf(c, 'unfoldedAll'), 'all groups unfolded')
      assert.deepStrictEqual(M.unfoldGroups(folded, [all[0]].filter(Boolean)), expectedOf(c, 'unfoldedFirst'), 'first group unfolded')
      assert.deepStrictEqual(M.unfoldGroups(folded, all.slice(-1)), expectedOf(c, 'unfoldedLast'), 'last group unfolded')
      assert.deepStrictEqual(M.unfoldGroups(folded, new Set(['group:nope|0|ready'])), expectedOf(c, 'unfoldedUnknown'), 'unknown id')
      assert.deepStrictEqual(M.unfoldGroups(M.unfoldGroups(folded, new Set(all)), new Set()), expectedOf(c, 'refoldedFromUnfolded'), 'refolded')
      assert.deepStrictEqual(M.unfoldGroups(M.unfoldGroups(folded, new Set(all)), new Set(all)), expectedOf(c, 'unfoldedFromUnfolded'), 'unfolded twice')
      assert.deepStrictEqual(M.unfoldGroups(folded), expectedOf(c, 'unfoldedNoArg'), 'no ids')
    })
  }

  await test('E92_S12_T02: no recorded case states a story `decomposed` flag, so the ghost option changes none of them', () => {
    for (const c of recorded.cases) {
      const stories = c.graph && Array.isArray(c.graph.stories) ? c.graph.stories : []
      assert.ok(stories.every(st => !st || !('decomposed' in st)), `${c.name}: a recorded case must predate the flag`)
      const l = labelsOf(c)
      const plain = l ? S.buildDependencyStructure(c.graph, c.epicId, l) : S.buildDependencyStructure(c.graph, c.epicId)
      const withGhosts = S.buildDependencyStructure(c.graph, c.epicId, l, { includeUndecomposed: true })
      assert.deepStrictEqual(withGhosts, plain, c.name)
      assert.ok(!keysOf(withGhosts).has('undecomposed') && !keysOf(build(c)).has('undecomposed'), `${c.name}: no new key`)
    }
  })

  const ghostRecorded = JSON.parse(fs.readFileSync(ghostRecordedPath, 'utf8'))
  for (const c of ghostRecorded.cases) {
    await test(`parity (new recording, E92_S12_T02): ${c.name}`, () => {
      const folded = build(c)
      assert.deepStrictEqual(folded, c.expected.folded, 'folded')
      assert.deepStrictEqual(M.unfoldGroups(folded, new Set(folded.foldable)), c.expected.unfoldedAll, 'all groups unfolded')
      assert.deepStrictEqual(M.unfoldGroups(M.unfoldGroups(folded, new Set(folded.foldable)), new Set()), c.expected.refoldedFromUnfolded, 'refolded')
      // what the recording stands for, stated independently of it
      const ids = b => b.map(x => x.storyId)
      assert.deepStrictEqual(ids(folded.bands), ['E01_S01', 'E01_S02', 'E01_S03', 'E01_S04', 'E01_S05'])
      assert.deepStrictEqual(folded.bands.filter(b => b.undecomposed).map(b => b.storyId), ['E01_S01', 'E01_S03'], 'ghost bands')
      assert.deepStrictEqual(folded.bands.filter(b => b.start.undecomposed).map(b => b.storyId), ['E01_S01', 'E01_S03', 'E01_S04'], 'flagged start facts')
      assert.deepStrictEqual(folded.edges.filter(e => e.kind === 'ghost').map(e => e.from), ['story:E01_S01', 'story:E01_S03'])
      assert.ok(folded.nodes.every(n => !['E01_S01', 'E01_S03'].includes(n.storyId)))
      // the terminal structure of the same payload is the one built without ghosts: no ghost band, no flag, no ghost edge
      const terminal = S.buildDependencyStructure(c.graph, c.epicId)
      assert.deepStrictEqual(ids(terminal.bands), ['E01_S02', 'E01_S04', 'E01_S05'])
      assert.ok(!keysOf(terminal).has('undecomposed') && terminal.edges.every(e => e.kind !== 'ghost'))
      assert.deepStrictEqual(S.buildDependencyStructure(c.graph, c.epicId, undefined, { includeUndecomposed: true }), S.foldStructure(S.buildDependencyStructure(c.graph, c.epicId, undefined, { includeUndecomposed: true }), []))
    })
  }

  await test('E92_S13_T02: the castle goal area changes only the layout, the goal position and the castle key; the disc area is the recording', () => {
    for (const c of [...recorded.cases, ...JSON.parse(fs.readFileSync(ghostRecordedPath, 'utf8')).cases]) {
      const l = labelsOf(c)
      const disc = build(c)
      const castle = M.buildDependencyTreeModel(c.graph, c.epicId, l)
      if (disc.empty) { assert.deepStrictEqual(castle, disc, c.name); continue }
      const { layout: dl, goal: dg, ...dRest } = disc
      const { layout: cl, goal: cg, castle: castleData, ...cRest } = castle
      assert.deepStrictEqual(cRest, dRest, c.name + ': nodes, bands, edges and the rest are the same')
      assert.ok(castleData && castleData.box && castleData.box.w > 0 && cl.goalArea === 'castle' && !('goalArea' in dl) && !('castle' in disc), c.name)
      assert.strictEqual(dl.goalAreaW, 260, c.name)
      assert.strictEqual(dl.goalOffsetX, 70, c.name)
      assert.notStrictEqual(cl.goalAreaW, undefined)
      assert.deepStrictEqual({ ...cg, x: 0, y: 0 }, { ...dg, x: 0, y: 0 }, c.name + ': the goal facts are the same')
      assert.strictEqual(cl.width, cl.goalX + cl.goalAreaW, c.name)
      assert.strictEqual(cl.columns, dl.columns, c.name)
    }
  })

  // ---- E92_S13_T06: the castle and the seasons tree over the same payloads -------------------------------------------------
  const { summariseCastleAndTree } = await import(pathToFileURL(summaryPath).href)
  const castleTree = recorded.castleTree

  await test('E92_S13_T06: the castleTree recording is new, re-records no case and names every input it covers', () => {
    assert.ok(castleTree && Array.isArray(castleTree.cases) && castleTree.cases.length === 14)
    assert.ok(/none/.test(castleTree.rerecorded) && /new/.test(castleTree.rerecorded), 'the fixture says nothing was re-recorded')
    const names = castleTree.cases.map(c => c.name)
    assert.strictEqual(new Set(names).size, names.length, 'unique names')
    for (const needle of ['bridge on two', 'out-of-epic', 'undecomposed', 'failed story', '26-task', '94 tasks in 22 stories, stacked', '22 independent', '24 percent', '25 percent', '45 percent', '65 percent', '85 percent', '99 percent', 'complete epic']) {
      assert.ok(names.some(n => n.includes(needle)), 'no case for: ' + needle)
    }
    // the older recordings are untouched: still the cases the earlier tasks recorded
    assert.ok(recorded.cases.length >= 30)
  })

  for (const c of castleTree.cases) {
    await test(`castle and tree (E92_S13_T06): ${c.name}`, () => {
      assert.deepStrictEqual(summariseCastleAndTree(c.graph, c.epicId), c.expected)
    })
  }

  await test('E92_S13_T06: the recorded castle and tree facts agree with the payload, stated independently of the recording', () => {
    const STAGE_AT = [[100, 5], [70, 4], [45, 3], [25, 2], [10, 1], [0, 0]]
    const STONES_AT = [25, 45, 65, 85]
    for (const c of castleTree.cases) {
      const e = c.expected
      const epic = c.graph.epics.find(x => x.id === c.epicId)
      const percent = epic.epic_progress.percent
      // nothing is recomputed: the wall and the growth are the script's own epic percent
      assert.strictEqual(e.castle.wall.percent, percent, c.name)
      assert.strictEqual(e.tree.growth.percent, percent, c.name)
      assert.strictEqual(e.castle.wall.reached, epic.epic_progress.goal_reached, c.name)
      // one tower and one branch per counted story (a story the payload does not count, decomposed null, is drawn by neither)
      const counted = c.graph.stories.filter(s => s.epic_id === c.epicId && s.decomposed !== null)
      assert.strictEqual(e.castle.towers.length, counted.length, c.name)
      assert.strictEqual(e.tree.branches.length, counted.length, c.name)
      assert.deepStrictEqual(e.castle.towers.filter(t => t.undecomposed).map(t => t.id), counted.filter(s => s.decomposed === false).map(s => s.id), c.name + ': dashed foundations')
      assert.deepStrictEqual(e.tree.stubs, counted.filter(s => s.decomposed === false).map(s => s.id), c.name + ': dashed stubs')
      // one layer and one clump per counted task, rejected tasks drawn by neither
      const tasks = c.graph.tasks.filter(t => t.epic_id === c.epicId && t.state !== 'rejected')
      for (const t of e.castle.towers) assert.strictEqual(t.layers.length, t.plan.layers, c.name + ': ' + t.id + ' layers follow the plan')
      assert.strictEqual(Object.values(e.tree.clumps).reduce((a, b) => a + b, 0), tasks.length, c.name + ': a clump per counted task')
      // the six growth stages by the percent, Majestic tree only at goal reached
      const stage = e.castle.wall.reached ? 5 : STAGE_AT.find(([at]) => percent >= at && at < 100)[1]
      assert.strictEqual(e.tree.growth.stage, stage, c.name)
      assert.ok(e.tree.growth.stage < 5 || e.castle.wall.reached, c.name + ': Majestic only at goal reached')
      assert.strictEqual(e.tree.growth.effects, e.castle.wall.reached, c.name + ': goal-reached effects')
      assert.deepStrictEqual(e.tree.stages, ['sprout:0', 'seedling:10', 'sapling:25', 'young:45', 'mature:70', 'majestic:100'].map(x => x), c.name)
      // the stones lift out of the pool at 25, 45, 65 and 85 percent
      assert.deepStrictEqual(e.tree.stonesLifted, STONES_AT.filter(at => percent >= at), c.name)
      assert.strictEqual(e.tree.mushrooms, percent >= 55, c.name + ': mushrooms')
      // stacking: a story on one story stands on it, on two or more on a bridge, otherwise on the ground
      for (const t of e.castle.towers) assert.ok(['ground', 'tower', 'bridge'].includes(t.stacking.kind), c.name)
      assert.strictEqual(e.castle.bridges.length, e.castle.towers.filter(t => t.stacking.kind === 'bridge').length, c.name)
      // the tree parent is the dependency a story stands on (one dependency), and the trunk has none
      assert.strictEqual(e.tree.stories.find(s => s.id === e.tree.trunkStory).tree.isTrunk, true, c.name)
    }
  })

  await test('E92_S13_T06: the stated percent of every older recorded case is the percent the castle wall and the tree growth read', () => {
    for (const c of [...recorded.cases, ...ghostRecorded.cases]) {
      const folded = expectedOf(c, 'folded')
      if (folded.empty) continue
      const sum = summariseCastleAndTree(c.graph, c.epicId)
      assert.ok(!sum.empty, c.name)
      assert.strictEqual(sum.castle.wall.percent, folded.goal.percent, c.name)
      assert.strictEqual(sum.tree.growth.percent, folded.goal.percent, c.name)
      assert.strictEqual(sum.castle.wall.reached, folded.goal.reached, c.name)
    }
  })

  await test('E92_S13_T06: the terminal structure never imports the castle model, the tree layout or the goal designs', () => {
    const dir = path.join(root, 'lib', 'progress')
    for (const f of fs.readdirSync(dir)) {
      if (!/\.(js|cjs|mjs)$/.test(f)) continue
      const code = fs.readFileSync(path.join(dir, f), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
      assert.ok(!/castleModel|castleLayout|facadeLayout|treeLayout|goalDesign|seasons-tree/.test(code), f + ' reaches into a goal design')
    }
  })

  await test('every public name of the model before the split is still exported', () => {
    for (const name of ['buildDependencyTreeModel', 'unfoldGroups', 'fillUnlockedBy', 'FOLD_THRESHOLD', 'GOAL_NODE_ID', 'LAYOUT', 'COL_WIDTH', 'layoutTree']) {
      assert.ok(name in M, name)
    }
    assert.strictEqual(M.FOLD_THRESHOLD, S.FOLD_THRESHOLD)
    assert.strictEqual(M.GOAL_NODE_ID, S.GOAL_NODE_ID)
    assert.strictEqual(M.fillUnlockedBy, S.fillUnlockedBy)
    assert.ok(Object.isFrozen(M.LAYOUT) && M.COL_WIDTH === M.LAYOUT.columnW)
  })

  await test('the structure carries no pixel number: no x, y, w, h, inX, outX, midY or layout key anywhere', () => {
    for (const c of recorded.cases) {
      const l = labelsOf(c)
      const s = l ? S.buildDependencyStructure(c.graph, c.epicId, l) : S.buildDependencyStructure(c.graph, c.epicId)
      const keys = keysOf(s)
      for (const k of [...PIXEL_KEYS, 'layout']) assert.ok(!keys.has(k), `${c.name}: ${k}`)
      const open = S.foldStructure(s, s.foldable)
      for (const k of [...PIXEL_KEYS, 'layout']) assert.ok(!keysOf(open).has(k), `${c.name} unfolded: ${k}`)
    }
  })

  await test('the structure and the dashboard model agree on every id and every edge', () => {
    for (const c of recorded.cases) {
      const l = labelsOf(c)
      const s = l ? S.buildDependencyStructure(c.graph, c.epicId, l) : S.buildDependencyStructure(c.graph, c.epicId)
      const m = build(c)
      assert.deepStrictEqual(s.nodes.map(n => n.id), m.nodes.map(n => n.id), c.name)
      assert.deepStrictEqual(s.headers.map(n => n.id), m.headers.map(n => n.id), c.name)
      assert.deepStrictEqual(s.edges, m.edges, c.name)
      assert.deepStrictEqual(s.bands.map(b => b.storyId), m.bands.map(b => b.storyId), c.name)
      assert.strictEqual(s.columns, m.layout.columns, c.name)
      // the cells list exactly the visible nodes, in order
      const fromCells = [].concat(...s.bands.map(b => [].concat(...b.cells.map(cell => cell.slots.filter(sl => sl.type === 'node').map(sl => sl.node.id)))))
      assert.deepStrictEqual(fromCells, s.nodes.map(n => n.id), c.name)
    }
  })

  await test('the structure module imports nothing and does not reach into project/app', () => {
    const code = fs.readFileSync(structurePath, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
    assert.ok(!/^\s*import\b/m.test(code) && !/\brequire\s*\(/.test(code) && !/\bimport\s*\(/.test(code), 'no imports')
    assert.ok(!/project\/app|\bLAYOUT\b/.test(code), 'no project/app and no LAYOUT')
  })

  console.log(`\ndependency-structure-parity: ${count} tests passed`)
}

main().catch(err => { console.error(err); process.exit(1) })
