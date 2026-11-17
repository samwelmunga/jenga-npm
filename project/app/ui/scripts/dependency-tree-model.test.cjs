#!/usr/bin/env node
'use strict'
// E92_S06_T09 / E92_S06_T19: model test for the dependency tree v2. Plain node, no framework, like
// progress-model.test.cjs (dependencyTreeModel.js is pure ESM, loaded with a dynamic import).
// Run: node project/app/ui/scripts/dependency-tree-model.test.cjs
const assert = require('assert')
const fs = require('fs')
const path = require('path')
const { pathToFileURL } = require('url')

const modelPath = path.join(__dirname, '..', 'src', 'components', 'progress', 'dependencyTreeModel.js')

const LABELS_EN = { unlocked_by: '%s unlocked by %s', tree_empty: 'No tasks to show' }
const LABELS_SV = { unlocked_by: '%s låstes upp av %s', tree_empty: 'Inga uppgifter att visa' }

const BUCKET = { done: 'done', in_progress: 'in_progress', failed: 'failed', rejected: 'rejected', ready: 'pending', locked: 'pending' }
// T(id, story, epic, state, deps, unlockedBy): bucket follows the state like the script does.
const T = (id, story, epic, state, deps, unlockedBy, status, bucket) => ({
  id, story_id: story, epic_id: epic, title: 'Title ' + id, status: status || 'Pending', bucket: bucket || BUCKET[state] || 'pending',
  state, depends_on: deps || [], blocked_by: [], unlocked_by: unlockedBy || null,
})
const totals = (done, in_progress, failed, pending, rejected, unknown) => ({
  done, in_progress, failed, pending, rejected, unknown, denominator: done + in_progress + failed + pending,
})
const graphOf = (epic, tasks, extra) => {
  const sids = [...new Set(tasks.map(t => t.story_id))].sort()
  return {
    schema_version: 1, scope: { type: 'graph' }, labels: LABELS_EN, lang: 'en',
    epics: [{ id: epic, title: 'Goal epic' }],
    stories: sids.map(s => ({ id: s, epic_id: epic, title: 'Story ' + s })),
    tasks, external: null, warnings: [], ...(extra || {}),
  }
}

// Full-board fixture: epic E01 (two stories, one external dependency on E00_S01_T01), plus another epic E00.
const FULL = {
  schema_version: 1,
  scope: { type: 'graph' },
  labels: LABELS_EN,
  lang: 'en',
  epics: [{ id: 'E00', title: 'Other' }, { id: 'E01', title: 'Goal epic' }],
  stories: [
    { id: 'E00_S01', epic_id: 'E00', title: 'Other story' },
    { id: 'E01_S01', epic_id: 'E01', title: 'First story' },
    { id: 'E01_S02', epic_id: 'E01', title: 'Second story' },
  ],
  tasks: [
    T('E00_S01_T01', 'E00_S01', 'E00', 'done', [], null, 'Passed', 'done'),
    T('E01_S01_T01', 'E01_S01', 'E01', 'done', ['E00_S01_T01'], null, 'Passed', 'done'),
    T('E01_S01_T02', 'E01_S01', 'E01', 'ready', ['E01_S01_T01'], 'E01_S01_T01'),
    T('E01_S02_T01', 'E01_S02', 'E01', 'locked', ['E01_S01_T02']),
    T('E01_S02_T02', 'E01_S02', 'E01', 'ready', ['E01_S01_T01'], 'E01_S01_T01'),
    T('E01_S02_T03', 'E01_S02', 'E01', 'failed', []),
  ],
  ready: ['E01_S01_T02', 'E01_S02_T02'],
  external: null,
  warnings: [],
}

// The ?within-style restricted payload for E01: only E01's rows, `external` lists the outside dependency.
const WITHIN = {
  ...FULL,
  scope: { type: 'graph', within: 'E01' },
  epics: [{ id: 'E01', title: 'Goal epic' }],
  stories: FULL.stories.filter(s => s.epic_id === 'E01'),
  tasks: FULL.tasks.filter(t => t.epic_id === 'E01'),
  external: [{ id: 'E00_S01_T01', status: 'Passed', bucket: 'done' }],
}

let count = 0
const test = async (name, fn) => { await fn(); count++; console.log('ok  ' + name) }
const node = (m, id) => m.nodes.find(n => n.id === id)
const task = (m, id) => m.tasks.find(n => n.id === id)
const ids = list => list.map(n => n.id)

async function main() {
  const mod = await import(pathToFileURL(modelPath).href)
  const { buildDependencyTreeModel: build, fillUnlockedBy, goalFailedText, unfinishedDepText, unfoldGroups, FOLD_THRESHOLD, LAYOUT, GOAL_NODE_ID } = mod
  const { buildDependencyStructure } = await import(pathToFileURL(path.join(__dirname, '..', '..', '..', '..', 'lib', 'progress', 'dependency-structure.js')).href)
  const src = fs.readFileSync(modelPath, 'utf8')

  await test('depth columns are epic-wide: story B depending on story A depth-2 task sits in column 3', () => {
    const g = graphOf('E01', [
      T('E01_S01_T01', 'E01_S01', 'E01', 'done', []),
      T('E01_S01_T02', 'E01_S01', 'E01', 'done', ['E01_S01_T01']),
      T('E01_S01_T03', 'E01_S01', 'E01', 'done', ['E01_S01_T02']), // depth 2
      T('E01_S02_T01', 'E01_S02', 'E01', 'ready', ['E01_S01_T03']), // depth 3, other story
      T('E01_S02_T02', 'E01_S02', 'E01', 'locked', ['E99_S01_T01']), // only a boundary dependency: depth 0
    ], { external: [{ id: 'E99_S01_T01', status: 'Pending', bucket: 'pending' }] })
    const m = build(g, 'E01', LABELS_EN)
    const col = Object.fromEntries(m.nodes.map(n => [n.id, n.column]))
    assert.deepStrictEqual(col, { E01_S01_T01: 0, E01_S01_T02: 1, E01_S01_T03: 2, E01_S02_T01: 3, E01_S02_T02: 0 })
    assert.strictEqual(m.layout.columns, 4)
    for (const n of m.nodes) assert.strictEqual(n.x, LAYOUT.columnX0 + n.column * LAYOUT.columnW)
    // boundary ids never become columns or nodes
    assert.ok(!m.nodes.some(n => n.id === 'E99_S01_T01'))
    assert.deepStrictEqual(m.boundary, [{ id: 'E99_S01_T01', status: 'Pending', bucket: 'pending' }])
    const withBoundary = build({ ...g, tasks: [...g.tasks, T('E01_S02_T03', 'E01_S02', 'E01', 'locked', ['E99_S01_T01', 'E01_S02_T02'])] }, 'E01', LABELS_EN)
    assert.strictEqual(node(withBoundary, 'E01_S02_T03').column, 1) // the boundary id adds nothing to the depth
    assert.strictEqual(withBoundary.layout.columns, 4)
  })

  await test('groups, nodes, goal and the boundary of the full-board fixture', () => {
    const m = build(FULL, 'E01', LABELS_EN)
    assert.strictEqual(m.empty, false)
    assert.deepStrictEqual(m.bands.map(b => b.storyId), ['E01_S01', 'E01_S02'])
    assert.strictEqual(m.nodes.length, 5)
    assert.strictEqual(m.tasks.length, 5)
    assert.deepStrictEqual(Object.fromEntries(m.tasks.map(n => [n.id, n.state])), {
      E01_S01_T01: 'done', E01_S01_T02: 'ready', E01_S02_T01: 'locked', E01_S02_T02: 'ready', E01_S02_T03: 'failed',
    })
    assert.deepStrictEqual(m.boundary, [{ id: 'E00_S01_T01', status: 'Passed', bucket: 'done' }])
    assert.deepStrictEqual(Object.fromEntries(m.nodes.map(n => [n.id, n.column])),
      { E01_S01_T01: 0, E01_S01_T02: 1, E01_S02_T01: 2, E01_S02_T02: 1, E01_S02_T03: 0 })
    for (const n of m.nodes) assert.ok(Number.isFinite(n.x) && Number.isFinite(n.y) && n.w === LAYOUT.cardW && n.h === LAYOUT.cardH)
    assert.ok(m.layout.width > 0 && m.layout.height > 0)
  })

  await test('story bands: one band and start node per story, id, done/total, title, bucket counts, own-story source', () => {
    const g = graphOf('E01', FULL.tasks.filter(t => t.epic_id === 'E01'), {
      stories: [
        { id: 'E01_S01', epic_id: 'E01', title: 'A rather long first story title that the renderer will truncate', totals: totals(1, 0, 0, 1, 0, 0) },
        { id: 'E01_S02', epic_id: 'E01', title: 'Second story' }, // no totals: read from the tasks' buckets
      ],
    })
    const m = build(g, 'E01', LABELS_EN)
    assert.strictEqual(m.bands.length, 2)
    const [a, b] = m.bands
    assert.strictEqual(a.start.id, 'story:E01_S01')
    assert.strictEqual(a.start.storyId, 'E01_S01')
    assert.strictEqual(a.start.title, 'A rather long first story title that the renderer will truncate') // full title
    assert.strictEqual(a.start.done, 1); assert.strictEqual(a.start.total, 2)
    assert.deepStrictEqual(a.start.buckets, { done: 1, in_progress: 0, failed: 0, pending: 1, rejected: 0, unknown: 0 })
    assert.strictEqual(b.start.done, 0); assert.strictEqual(b.start.total, 3) // 2 pending + 1 failed
    assert.deepStrictEqual(b.start.buckets, { done: 0, in_progress: 0, failed: 1, pending: 2, rejected: 0, unknown: 0 })
    // bands stack top to bottom and the start node is centred in its band
    assert.ok(b.y >= a.y + a.h)
    assert.strictEqual(a.start.midY, a.y + a.h / 2)
    assert.strictEqual(a.start.x, LAYOUT.pad)
    assert.strictEqual(a.start.outX, LAYOUT.pad + LAYOUT.startW)
    // tasks with no in-epic dependency branch from their own story's start node
    const startEdges = m.edges.filter(e => e.kind === 'start')
    assert.deepStrictEqual(startEdges.map(e => [e.from, e.to]), [
      ['story:E01_S01', 'E01_S01_T01'], // its only dependency is outside the epic
      ['story:E01_S02', 'E01_S02_T03'],
    ])
    assert.ok(startEdges.every(e => e.crossStory === false))
    for (const t of m.tasks) assert.strictEqual(t.dependsOn.some(d => m.tasks.some(x => x.id === d)), !startEdges.some(e => e.to === t.id))
    // a task's band is its story's: the node sits inside the band
    for (const n of m.nodes) {
      const band = m.bands.find(x => x.storyId === n.storyId)
      assert.ok(n.y >= band.y && n.y + n.h <= band.y + band.h, n.id)
      assert.strictEqual(n.row, band.row)
    }
  })

  await test('edges run dependency to dependent, carry crossStory, are de-duplicated; only sinks reach the goal', () => {
    // The direction is part of the file header.
    assert.ok(/\{ from, to \}` means `from` is the DEPENDENCY and `to` is the DEPENDENT/.test(src), 'header states the direction')
    const m = build(FULL, 'E01', LABELS_EN)
    const dep = m.edges.filter(e => e.kind === 'dependency' || e.kind === 'boundary')
    assert.deepStrictEqual(dep.map(e => ({ from: e.from, to: e.to, crossStory: e.crossStory })), [
      { from: 'E00_S01_T01', to: 'E01_S01_T01', crossStory: true }, // boundary edge
      { from: 'E01_S01_T01', to: 'E01_S01_T02', crossStory: false },
      { from: 'E01_S01_T02', to: 'E01_S02_T01', crossStory: true },
      { from: 'E01_S01_T01', to: 'E01_S02_T02', crossStory: true },
    ])
    assert.ok(!dep.some(e => e.from === 'E01_S01_T02' && e.to === 'E01_S01_T01'), 'not the old dependent-to-dependency direction')
    // only tasks nothing depends on connect to the goal
    const goalEdges = m.edges.filter(e => e.kind === 'goal')
    assert.ok(goalEdges.every(e => e.to === GOAL_NODE_ID && e.crossStory === false))
    assert.deepStrictEqual(goalEdges.map(e => e.from).sort(), ['E01_S02_T01', 'E01_S02_T02', 'E01_S02_T03'])
    for (const e of goalEdges) assert.deepStrictEqual(task(m, e.from).unlocks, [])
    // no edge key twice
    const keys = m.edges.map(e => e.from + '>' + e.to)
    assert.strictEqual(new Set(keys).size, keys.length)
    // duplicate and self depends_on entries produce one edge, none for the self reference
    const dup = build(graphOf('E01', [
      T('E01_S01_T01', 'E01_S01', 'E01', 'done', []),
      T('E01_S01_T02', 'E01_S01', 'E01', 'ready', ['E01_S01_T01', 'E01_S01_T01', 'E01_S01_T02']),
    ]), 'E01', LABELS_EN)
    assert.deepStrictEqual(dup.edges.filter(e => e.kind === 'dependency').map(e => [e.from, e.to]), [['E01_S01_T01', 'E01_S01_T02']])
  })

  await test('gate and status mark cover all four cells of (has dependencies, all done)', () => {
    const g = graphOf('E01', [
      T('E01_S01_T01', 'E01_S01', 'E01', 'done', []), // no dependency, done
      T('E01_S01_T02', 'E01_S01', 'E01', 'ready', []), // no dependency, ready
      T('E01_S01_T03', 'E01_S01', 'E01', 'ready', ['E01_S01_T01']), // has dependencies, all done: open, ready
      T('E01_S01_T04', 'E01_S01', 'E01', 'in_progress', ['E01_S01_T01']), // open, in progress
      T('E01_S01_T05', 'E01_S01', 'E01', 'done', ['E01_S01_T01']), // open, done
      T('E01_S01_T06', 'E01_S01', 'E01', 'locked', ['E01_S01_T01', 'E01_S01_T02']), // one dependency not done: locked
      T('E01_S01_T07', 'E01_S01', 'E01', 'locked', ['E01_S01_T04']), // locked, dependency in progress
      // failed while its dependency is unfinished: locked gate, failed mark. waiting_on as the script prints it (E92_S10_T01:
      // without it the payload states nothing a non-pending task waits for, and the gate is open)
      { ...T('E01_S01_T08', 'E01_S01', 'E01', 'failed', ['E01_S01_T02']), waiting_on: ['E01_S01_T02'] },
      T('E01_S01_T09', 'E01_S01', 'E01', 'failed', ['E01_S01_T01']), // failed, open gate
      T('E01_S01_T10', 'E01_S01', 'E01', 'rejected', []),
    ])
    const m = build(g, 'E01', LABELS_EN)
    const pick = id => [task(m, id).gate, task(m, id).mark]
    assert.deepStrictEqual(pick('E01_S01_T01'), ['none', 'done'])
    assert.deepStrictEqual(pick('E01_S01_T02'), ['none', 'ready'])
    assert.deepStrictEqual(pick('E01_S01_T03'), ['open', 'ready'])
    assert.deepStrictEqual(pick('E01_S01_T04'), ['open', 'in_progress'])
    assert.deepStrictEqual(pick('E01_S01_T05'), ['open', 'done'])
    assert.deepStrictEqual(pick('E01_S01_T06'), ['locked', 'none']) // a locked task has no status mark
    assert.deepStrictEqual(pick('E01_S01_T07'), ['locked', 'none'])
    assert.deepStrictEqual(pick('E01_S01_T08'), ['locked', 'failed'])
    assert.deepStrictEqual(pick('E01_S01_T09'), ['open', 'failed'])
    assert.deepStrictEqual(pick('E01_S01_T10'), ['none', 'rejected'])
    // a boundary dependency counts: done boundary opens, a pending one locks
    const b = build(graphOf('E01', [
      T('E01_S01_T01', 'E01_S01', 'E01', 'ready', ['E00_S01_T01']),
      T('E01_S01_T02', 'E01_S01', 'E01', 'locked', ['E00_S01_T02']),
      T('E01_S01_T03', 'E01_S01', 'E01', 'locked', ['E00_S01_T03']), // unknown id: not done
    ], { external: [{ id: 'E00_S01_T01', status: 'Passed', bucket: 'done' }, { id: 'E00_S01_T02', status: 'Pending', bucket: 'pending' }] }), 'E01', LABELS_EN)
    assert.deepStrictEqual([task(b, 'E01_S01_T01').gate, task(b, 'E01_S01_T02').gate, task(b, 'E01_S01_T03').gate], ['open', 'locked', 'locked'])
    // the gate does not look at the status list, only at the bucket: a status name alone changes nothing
    const s = build(graphOf('E01', [
      T('E01_S01_T01', 'E01_S01', 'E01', 'locked', [], null, 'Passed', 'pending'),
      T('E01_S01_T02', 'E01_S01', 'E01', 'locked', ['E01_S01_T01']),
    ]), 'E01', LABELS_EN)
    assert.strictEqual(task(s, 'E01_S01_T02').gate, 'locked')
  })

  await test('folding: more than FOLD_THRESHOLD same-state tasks per row and column fold into one group', () => {
    // E92_S11_T03 (user request 2026-11-15): the threshold was lowered from 5 to 3, so "5 do not fold" became "4 fold, 3 do not"
    assert.strictEqual(FOLD_THRESHOLD, 3)
    const fan = (n, state, story, deps) => Array.from({ length: n }, (_, i) =>
      T(`E01_${story}_T${String(i + 2).padStart(2, '0')}`, `E01_${story}`, 'E01', state, deps || ['E01_S01_T01']))
    const root = T('E01_S01_T01', 'E01_S01', 'E01', 'done', [])

    // 6 fold, with count 6, row/column/state
    const six = build(graphOf('E01', [root, ...fan(6, 'ready', 'S01')]), 'E01', LABELS_EN)
    const groups = six.nodes.filter(n => n.kind === 'group')
    assert.strictEqual(groups.length, 1)
    const grp = groups[0]
    assert.strictEqual(grp.count, 6)
    assert.strictEqual(grp.members.length, 6)
    assert.strictEqual(grp.state, 'ready'); assert.strictEqual(grp.row, 0); assert.strictEqual(grp.column, 1)
    assert.deepStrictEqual(grp.members, ['E01_S01_T02', 'E01_S01_T03', 'E01_S01_T04', 'E01_S01_T05', 'E01_S01_T06', 'E01_S01_T07'])
    assert.strictEqual(six.nodes.length, 2) // the root and the group
    assert.strictEqual(six.tasks.length, 7) // the facts keep every task
    assert.deepStrictEqual(six.foldable, [grp.id])

    // 4 fold (the smallest group), 3 do not
    const four = build(graphOf('E01', [root, ...fan(4, 'ready', 'S01')]), 'E01', LABELS_EN)
    assert.strictEqual(four.nodes.length, 2)
    assert.strictEqual(four.nodes.find(n => n.kind === 'group').count, 4)
    const three = build(graphOf('E01', [root, ...fan(3, 'ready', 'S01')]), 'E01', LABELS_EN)
    assert.ok(three.nodes.every(n => n.kind === 'task'))
    assert.strictEqual(three.nodes.length, 4)
    assert.deepStrictEqual(three.foldable, [])

    // same state in different rows (3 + 3) or different columns (3 + 3) do not fold together
    const rows = build(graphOf('E01', [root, ...fan(3, 'ready', 'S01'), ...fan(3, 'ready', 'S02')]), 'E01', LABELS_EN)
    assert.ok(rows.nodes.every(n => n.kind === 'task'))
    const colsM = build(graphOf('E01', [
      root, ...fan(3, 'ready', 'S01'),
      T('E01_S01_T20', 'E01_S01', 'E01', 'ready', ['E01_S01_T02']), T('E01_S01_T21', 'E01_S01', 'E01', 'ready', ['E01_S01_T02']), T('E01_S01_T22', 'E01_S01', 'E01', 'ready', ['E01_S01_T02']),
    ]), 'E01', LABELS_EN)
    assert.ok(colsM.nodes.every(n => n.kind === 'task'))
    assert.deepStrictEqual([...new Set(colsM.nodes.map(n => n.column))], [0, 1, 2])

    // different states in the same cell (3 + 3, and 4 + 2) do not fold together
    const mixed = build(graphOf('E01', [root, ...fan(3, 'ready', 'S01'), ...fan(3, 'in_progress', 'S01').map(t => ({ ...t, id: t.id.replace('_T0', '_T3')}))]), 'E01', LABELS_EN)
    assert.ok(mixed.nodes.every(n => n.kind === 'task'))
    assert.strictEqual(mixed.nodes.length, 7)
    // 6 ready + 2 locked in one cell: only the ready ones fold, the locked ones stay separate
    const part = build(graphOf('E01', [
      root, ...fan(6, 'ready', 'S01'),
      T('E01_S01_T31', 'E01_S01', 'E01', 'locked', ['E01_S01_T01']), T('E01_S01_T32', 'E01_S01', 'E01', 'locked', ['E01_S01_T01']),
    ]), 'E01', LABELS_EN)
    assert.deepStrictEqual(part.nodes.map(n => n.kind).sort(), ['group', 'task', 'task', 'task'])
    // within a cell, states are ordered in progress, ready, failed, locked, done
    const order = build(graphOf('E01', [
      root,
      T('E01_S01_T02', 'E01_S01', 'E01', 'done', ['E01_S01_T01']),
      T('E01_S01_T03', 'E01_S01', 'E01', 'locked', ['E01_S01_T01']),
      T('E01_S01_T04', 'E01_S01', 'E01', 'failed', ['E01_S01_T01']),
      T('E01_S01_T05', 'E01_S01', 'E01', 'ready', ['E01_S01_T01']),
      T('E01_S01_T06', 'E01_S01', 'E01', 'in_progress', ['E01_S01_T01']),
    ]), 'E01', LABELS_EN)
    assert.deepStrictEqual(ids(order.nodes.filter(n => n.column === 1).sort((a, b) => a.slot - b.slot)),
      ['E01_S01_T06', 'E01_S01_T05', 'E01_S01_T04', 'E01_S01_T03', 'E01_S01_T02'])
  })

  await test('unfold helper restores the members and de-duplicates edges, folded and unfolded', () => {
    const tasks = [
      T('E01_S01_T01', 'E01_S01', 'E01', 'done', []),
      ...Array.from({ length: 6 }, (_, i) => T(`E01_S01_T0${i + 2}`, 'E01_S01', 'E01', 'ready', ['E01_S01_T01'])),
      T('E01_S02_T01', 'E01_S02', 'E01', 'locked', ['E01_S01_T02', 'E01_S01_T03', 'E01_S01_T04', 'E01_S01_T05', 'E01_S01_T06', 'E01_S01_T07']),
    ]
    const m = build(graphOf('E01', tasks), 'E01', LABELS_EN)
    const gid = m.foldable[0]
    const dependency = model => model.edges.filter(e => e.kind === 'dependency').map(e => e.from + '>' + e.to)
    // folded: 12 raw task edges collapse to 2, no key twice anywhere
    assert.deepStrictEqual(dependency(m), ['E01_S01_T01>' + gid, gid + '>E01_S02_T01'])
    assert.strictEqual(new Set(m.edges.map(e => e.from + '>' + e.to)).size, m.edges.length)
    assert.strictEqual(m.tasks.filter(t => t.kind === 'task').length, 8)
    // the group's edges are the union of its members'
    const grp = m.nodes.find(n => n.id === gid)
    assert.deepStrictEqual(grp.dependsOn, ['E01_S01_T01'])
    assert.deepStrictEqual(grp.unlocks, ['E01_S02_T01'])
    assert.deepStrictEqual(grp.upstream, ['E01_S01_T01'])
    assert.deepStrictEqual(grp.downstream, ['E01_S02_T01'])
    assert.strictEqual(grp.gate, 'open')

    // unfolded: the members are back, 6 + 6 + 0 dependency edges, no duplicate keys, a collapse header exists
    const u = unfoldGroups(m, new Set([gid]))
    assert.strictEqual(u.nodes.length, 8)
    assert.ok(u.nodes.every(n => n.kind === 'task'))
    assert.deepStrictEqual(ids(u.nodes.filter(n => n.column === 1)), grp.members)
    assert.strictEqual(dependency(u).length, 12)
    assert.strictEqual(new Set(u.edges.map(e => e.from + '>' + e.to)).size, u.edges.length)
    assert.deepStrictEqual(u.headers.map(h => [h.id, h.count, h.state, h.column, h.row]), [[gid, 6, 'ready', 1, 0]])
    assert.deepStrictEqual(u.expanded, [gid])
    // the unfolded band is taller (members plus header), positions follow
    assert.ok(u.bands[0].h > m.bands[0].h)
    assert.ok(u.layout.height > m.layout.height)
    // an array works too; unknown ids are ignored; no ids or an empty set gives the folded model back
    assert.deepStrictEqual(unfoldGroups(m, [gid]), u)
    assert.deepStrictEqual(unfoldGroups(m, new Set(['group:nope|0|ready'])), m)
    assert.deepStrictEqual(unfoldGroups(m, new Set()), m)
    assert.deepStrictEqual(unfoldGroups(u, new Set()), m) // folding again is the same pure function
    // it does not mutate its input
    const before = JSON.stringify(m)
    unfoldGroups(m, [gid])
    assert.strictEqual(JSON.stringify(m), before)
    // an empty model passes through
    const empty = build(null, 'E01')
    assert.strictEqual(unfoldGroups(empty, [gid]), empty)
  })

  await test('chains: upstream, downstream, dependsOn and unlocks per node; empty unlocks means straight to the goal', () => {
    const g = graphOf('E01', [
      T('E01_S01_T01', 'E01_S01', 'E01', 'done', ['E00_S01_T01']),
      T('E01_S01_T02', 'E01_S01', 'E01', 'done', ['E01_S01_T01']),
      T('E01_S01_T03', 'E01_S01', 'E01', 'ready', ['E01_S01_T02']),
      T('E01_S02_T01', 'E01_S02', 'E01', 'locked', ['E01_S01_T03', 'E01_S01_T01']),
      T('E01_S02_T02', 'E01_S02', 'E01', 'ready', []),
    ], { external: [{ id: 'E00_S01_T01', status: 'Passed', bucket: 'done' }] })
    const m = build(g, 'E01', LABELS_EN)
    const t1 = task(m, 'E01_S01_T01'), t3 = task(m, 'E01_S01_T03'), last = task(m, 'E01_S02_T01'), alone = task(m, 'E01_S02_T02')
    assert.deepStrictEqual(t1.dependsOn, ['E00_S01_T01'])
    assert.deepStrictEqual(t1.unlocks, ['E01_S01_T02', 'E01_S02_T01'])
    assert.deepStrictEqual(t1.upstream, ['E00_S01_T01']) // a boundary node is part of the chain
    assert.deepStrictEqual(t1.downstream, ['E01_S01_T02', 'E01_S01_T03', 'E01_S02_T01'])
    assert.deepStrictEqual(t3.upstream, ['E00_S01_T01', 'E01_S01_T01', 'E01_S01_T02'])
    assert.deepStrictEqual(t3.downstream, ['E01_S02_T01'])
    assert.deepStrictEqual(last.dependsOn, ['E01_S01_T01', 'E01_S01_T03'])
    assert.deepStrictEqual(last.upstream, ['E00_S01_T01', 'E01_S01_T01', 'E01_S01_T02', 'E01_S01_T03'])
    assert.deepStrictEqual(last.unlocks, [])
    assert.deepStrictEqual(last.downstream, [])
    assert.deepStrictEqual(alone.dependsOn, []); assert.deepStrictEqual(alone.upstream, [])
    // empty unlocks <=> a goal edge, and the visible nodes expose the same facts
    for (const n of m.nodes) assert.strictEqual(n.unlocks.length === 0, m.edges.some(e => e.kind === 'goal' && e.from === n.id), n.id)
    assert.deepStrictEqual(node(m, 'E01_S01_T03').downstream, t3.downstream)
    // a cycle terminates and excludes the node itself
    const cyc = build(graphOf('E02', [
      T('E02_S01_T01', 'E02_S01', 'E02', 'locked', ['E02_S01_T03']),
      T('E02_S01_T02', 'E02_S01', 'E02', 'locked', ['E02_S01_T01']),
      T('E02_S01_T03', 'E02_S01', 'E02', 'locked', ['E02_S01_T02']),
    ]), 'E02', LABELS_EN)
    assert.ok(cyc.tasks.every(t => !t.upstream.includes(t.id) && !t.downstream.includes(t.id)))
    assert.ok(cyc.tasks.every(t => t.upstream.length === 2 && t.downstream.length === 2))
  })

  // E92_S09_T04 replaces the goal cases of E92_S06 (task counts from tasks.totals or the tasks' own buckets): the goal is the
  // script's epic_progress, read as stated and never recomputed (section 5.1 of progress-visualisation.md); a payload
  // without it gives the zero goal. The figures below are what board-progress.sh prints for the cases of
  // tests/board-progress-epic-percent.bats.
  await test('goal: the epic percent of epic_progress, as stated: 30 %, 60 % (goal not reached), 100 % (reached), 0 without it', () => {
    const TASKS = [T('E01_S01_T01', 'E01_S01', 'E01', 'done', []), T('E01_S01_T02', 'E01_S01', 'E01', 'ready', ['E01_S01_T01'])]
    const ep = (stories, decomposed, tasksDone, tasksDen, percent, goalReached = false) =>
      ({ stories, decomposed, tasks_done: tasksDone, tasks_denominator: tasksDen, percent, goal_reached: goalReached })
    const goalWith = progress => build(graphOf('E01', TASKS,
      { epics: [{ id: 'E01', title: 'Goal epic', tasks: { totals: totals(1, 0, 0, 1, 0, 0) }, epic_progress: progress }] }), 'E01', LABELS_EN).goal
    const pick = g => [g.done, g.total, g.percent, g.fraction, g.reached, g.decomposed, g.stories]
    // 5 stories, 3 decomposed, half their tasks done: 30 %
    assert.deepStrictEqual(pick(goalWith(ep(5, 3, 3, 6, 30))), [3, 6, 30, 0.3, false, 3, 5])
    // the same 3 stories all done: 60 %, the goal is not reached
    assert.deepStrictEqual(pick(goalWith(ep(5, 3, 6, 6, 60))), [6, 6, 60, 0.6, false, 3, 5])
    // every story decomposed and done: 100 %, reached
    assert.deepStrictEqual(pick(goalWith(ep(5, 5, 10, 10, 100, true))), [10, 10, 100, 1, true, 5, 5])
    // the floor is the script's: 199 of 200 is 99, never rounded up here
    assert.deepStrictEqual(pick(goalWith(ep(1, 1, 199, 200, 99))), [199, 200, 99, 0.99, false, 1, 1])
    // no epic_progress: the zero goal, whatever tasks.totals says (nothing is recomputed)
    const none = build(graphOf('E01', TASKS, { epics: [{ id: 'E01', title: 'Goal epic', tasks: { totals: totals(1, 0, 0, 1, 0, 0) } }] }), 'E01', LABELS_EN).goal
    assert.deepStrictEqual(pick(none), [0, 0, 0, 0, false, 0, 0])
    // 0 tasks: the structure is empty, the goal still comes from epic_progress
    const zero = build({ ...FULL, tasks: [] }, 'E01', LABELS_EN)
    assert.strictEqual(zero.empty, true)
    assert.deepStrictEqual({ ...zero.goal, x: 0, y: 0 },
      { id: 'E01', title: 'Goal epic', fraction: 0, percent: 0, done: 0, total: 0, reached: false, stories: 0, decomposed: 0, failedStories: [], x: 0, y: 0 })
    const zeroStated = build(graphOf('E01', [], { epics: [{ id: 'E01', title: 'Goal epic', epic_progress: ep(3, 0, 0, 0, 0) }] }), 'E01', LABELS_EN).goal
    assert.deepStrictEqual(pick(zeroStated), [0, 0, 0, 0, false, 0, 3])
    // the goal sits to the right of the last column
    const m = build(FULL, 'E01', LABELS_EN)
    assert.ok(m.goal.x > Math.max(...m.nodes.map(n => n.outX)))
  })

  // E92_S10_T02 (user decision 2026-11-15: no goal while a story of the epic has failed): the goal carries the script's
  // failed_stories as failedStories, read as stated (strings only, [] without the key), and goalFailedText words the goal
  // line from it only where the congratulation would have been: not reached, at the 99 % cap, a failed story stated.
  await test('E92_S10_T02: the goal reads failed_stories as stated; goalFailedText names the first and the count of the others at the cap', () => {
    const TASKS = [T('E01_S01_T01', 'E01_S01', 'E01', 'done', []), T('E01_S01_T02', 'E01_S01', 'E01', 'done', ['E01_S01_T01'])]
    const goalWith = progress => build(graphOf('E01', TASKS, { epics: [{ id: 'E01', title: 'Goal epic', epic_progress: progress }] }), 'E01', LABELS_EN).goal
    const ep = (percent, reached, failed) => ({ stories: 2, decomposed: 2, tasks_done: 2, tasks_denominator: 2, percent, goal_reached: reached, failed_stories: failed })
    const g = goalWith(ep(99, false, ['E01_S02']))
    assert.deepStrictEqual([g.percent, g.reached, g.failedStories], [99, false, ['E01_S02']])
    // nothing is recomputed: a payload without the key has none, junk entries are dropped
    assert.deepStrictEqual(goalWith({ ...ep(100, true), failed_stories: undefined }).failedStories, [])
    assert.deepStrictEqual(goalWith(ep(99, false, ['E01_S02', 3, '', null])).failedStories, ['E01_S02'])
    const L = { goal_failed: 'Goal not reached - %s has failed', goal_failed_more: 'Goal not reached - %s and %d more have failed' }
    assert.strictEqual(goalFailedText(L, g), 'Goal not reached - E01_S02 has failed')
    assert.strictEqual(goalFailedText(L, goalWith(ep(99, false, ['E01_S02', 'E01_S07', 'E01_S10']))), 'Goal not reached - E01_S02 and 2 more have failed')
    // below the cap, with the goal reached, without a failed story, or without the label: no text
    assert.strictEqual(goalFailedText(L, goalWith(ep(98, false, ['E01_S02']))), '')
    assert.strictEqual(goalFailedText(L, goalWith(ep(100, true, []))), '')
    assert.strictEqual(goalFailedText(L, goalWith(ep(99, false, []))), '')
    assert.strictEqual(goalFailedText({}, g), '')
    assert.strictEqual(goalFailedText(L, undefined), '')
  })

  await test('ready and unlocked lists in en and sv; labels fall back to graph.labels', () => {
    const m = build(FULL, 'E01', LABELS_EN)
    assert.deepStrictEqual(m.ready, [
      { id: 'E01_S01_T02', title: 'Title E01_S01_T02', storyId: 'E01_S01' },
      { id: 'E01_S02_T02', title: 'Title E01_S02_T02', storyId: 'E01_S02' },
    ])
    assert.deepStrictEqual(m.unlocked, [
      { taskId: 'E01_S01_T02', text: 'E01_S01_T02 unlocked by E01_S01_T01' },
      { taskId: 'E01_S02_T02', text: 'E01_S02_T02 unlocked by E01_S01_T01' },
    ])
    assert.strictEqual(build(FULL, 'E01', LABELS_SV).unlocked[0].text, 'E01_S01_T02 låstes upp av E01_S01_T01')
    assert.strictEqual(build(FULL, 'E01').unlocked[0].text, 'E01_S01_T02 unlocked by E01_S01_T01')
    assert.strictEqual(build({ ...FULL, labels: undefined }, 'E01').unlocked[0].text, '')
    assert.strictEqual(fillUnlockedBy('', 'a', 'b'), '')
  })

  await test('full-board and ?within payloads give the same model', () => {
    assert.deepStrictEqual(build(FULL, 'E01', LABELS_EN), build(WITHIN, 'E01', LABELS_EN))
  })

  await test('empty cases: no tasks, unknown epic, null graph (only zero tasks is empty, E92_S09_T01); a cycle does not hang', () => {
    const cyc = graphOf('E02', [
      T('E02_S01_T01', 'E02_S01', 'E02', 'locked', ['E02_S01_T03']),
      T('E02_S01_T02', 'E02_S01', 'E02', 'locked', ['E02_S01_T01']),
      T('E02_S01_T03', 'E02_S01', 'E02', 'locked', ['E02_S01_T02']),
    ])
    const m = build(cyc, 'E02', LABELS_EN)
    assert.strictEqual(m.empty, false)
    assert.strictEqual(m.nodes.length, 3)
    assert.strictEqual(m.edges.filter(e => e.kind === 'dependency').length, 3)
    assert.ok(m.nodes.every(n => Number.isInteger(n.column) && n.column >= 0 && n.column < 3))
    // a self-edge is ignored, so the epic has a task and no edge: it still gets its tree (E92_S09_T01)
    const self = build({ ...FULL, tasks: [T('E01_S01_T01', 'E01_S01', 'E01', 'done', ['E01_S01_T01'])] }, 'E01', LABELS_EN)
    assert.strictEqual(self.empty, false)
    assert.deepStrictEqual(self.tasks.map(t => [t.id, t.column, t.gate, t.dependsOn]), [['E01_S01_T01', 0, 'none', []]])
    assert.deepStrictEqual(self.edges.map(e => e.kind), ['start', 'goal'])
    for (const e of [build({ ...FULL, tasks: [] }, 'E01'), build(FULL, 'E99'), build(null, 'E01'), build(FULL, '')]) {
      assert.strictEqual(e.empty, true)
      assert.deepStrictEqual([e.nodes, e.tasks, e.edges, e.bands, e.headers, e.foldable], [[], [], [], [], [], []])
    }
  })

  await test('E92_S09_T01: an epic with tasks but no dependency edge draws its tree: bands, start nodes in column 0 with gate none, goal', () => {
    const flat = build({ ...FULL, tasks: [
      T('E01_S01_T01', 'E01_S01', 'E01', 'ready', []), T('E01_S01_T02', 'E01_S01', 'E01', 'done', []), T('E01_S02_T01', 'E01_S02', 'E01', 'in_progress', []),
    ] }, 'E01', LABELS_EN)
    assert.strictEqual(flat.empty, false)
    // the goal carries no progress of its own: FULL states no epic_progress, so the zero goal (E92_S09_T04; before it the
    // goal counted the tasks, 1 of 3, 33 %); with epic_progress it shows the stated figure
    assert.deepStrictEqual([flat.goal.done, flat.goal.total, flat.goal.percent], [0, 0, 0])
    const flatStated = build({ ...FULL, epics: [{ id: 'E01', title: 'Goal epic', epic_progress: { stories: 2, decomposed: 2, tasks_done: 1, tasks_denominator: 3, percent: 33, goal_reached: false } }],
      tasks: [
        T('E01_S01_T01', 'E01_S01', 'E01', 'ready', []), T('E01_S01_T02', 'E01_S01', 'E01', 'done', []), T('E01_S02_T01', 'E01_S02', 'E01', 'in_progress', []),
      ] }, 'E01', LABELS_EN)
    assert.deepStrictEqual([flatStated.goal.done, flatStated.goal.total, flatStated.goal.percent], [1, 3, 33])
    // one band per story, each with its start node
    assert.deepStrictEqual(flat.bands.map(b => [b.storyId, b.start.id]), [['E01_S01', 'story:E01_S01'], ['E01_S02', 'story:E01_S02']])
    // every task in the first depth column, no gate, no dependency
    assert.strictEqual(flat.layout.columns, 1)
    assert.ok(flat.tasks.every(t => t.column === 0 && t.gate === 'none' && t.dependsOn.length === 0 && t.unlocks.length === 0))
    assert.deepStrictEqual(flat.nodes.map(n => n.id).sort(), ['E01_S01_T01', 'E01_S01_T02', 'E01_S02_T01'])
    // a start edge into and a goal edge out of every task, nothing else
    assert.deepStrictEqual(flat.edges.filter(e => e.kind === 'start').map(e => `${e.from}>${e.to}`).sort(),
      ['story:E01_S01>E01_S01_T01', 'story:E01_S01>E01_S01_T02', 'story:E01_S02>E01_S02_T01'])
    assert.deepStrictEqual(flat.edges.filter(e => e.kind === 'goal').map(e => e.from).sort(), ['E01_S01_T01', 'E01_S01_T02', 'E01_S02_T01'])
    assert.strictEqual(flat.edges.length, 6)
    // laid out like any tree: the goal to the right of the column, a non-zero drawing
    assert.ok(flat.layout.width > 0 && flat.goal.x > Math.max(...flat.nodes.map(n => n.outX)))
    // the ready list is filled as for any tree
    assert.deepStrictEqual(flat.ready.map(r => r.id), ['E01_S01_T01'])
  })

  await test('E92_S09_T02: the gate follows the effective dependencies (own plus story); every ready task is ready-marked', () => {
    // blocked_by as the script prints it: the unsatisfied ids, own first, then the story's; [] unless locked
    const B = (t, blockedBy) => ({ ...t, blocked_by: blockedBy })
    const g = {
      ...graphOf('E01', [
        T('E01_S01_T01', 'E01_S01', 'E01', 'done', [], null, 'Passed', 'done'),
        T('E01_S01_T02', 'E01_S01', 'E01', 'ready', []), // no dependency anywhere: no gate
        T('E01_S01_T03', 'E01_S01', 'E01', 'ready', ['E01_S01_T01'], 'E01_S01_T01'), // own dependency done: open
        B(T('E01_S02_T01', 'E01_S02', 'E01', 'locked', []), ['E01_S01']), // only its story waits (E91_S02_T01 shape): closed
        B(T('E01_S02_T02', 'E01_S02', 'E01', 'locked', ['E01_S01_T01']), ['E01_S01']), // own done, story waits (E91_S04_T03 shape): closed
        T('E01_S03_T01', 'E01_S03', 'E01', 'ready', []), // its story's dependency is done: open, no own depends_on
        T('E01_S03_T02', 'E01_S03', 'E01', 'done', [], null, 'Passed', 'done'), // done, story had a dependency: open
        T('E01_S01_T04', 'E01_S01', 'E01', 'ready', ['E00_S01_T01']), // ready over a rejected dependency (the script counts it satisfied): open
      ], { external: [{ id: 'E00_S01_T01', status: 'Rejected', bucket: 'rejected' }] }),
    }
    g.stories = [
      { id: 'E01_S01', epic_id: 'E01', title: 'Story E01_S01', depends_on: [] },
      { id: 'E01_S02', epic_id: 'E01', title: 'Story E01_S02', depends_on: ['E01_S01'] },
      { id: 'E01_S03', epic_id: 'E01', title: 'Story E01_S03', depends_on: ['E00_S09'] },
    ]
    const m = build(g, 'E01', LABELS_EN)
    const pick = id => [task(m, id).state, task(m, id).gate, task(m, id).mark]
    assert.deepStrictEqual(pick('E01_S01_T02'), ['ready', 'none', 'ready'])
    assert.deepStrictEqual(pick('E01_S01_T03'), ['ready', 'open', 'ready'])
    assert.deepStrictEqual(pick('E01_S02_T01'), ['locked', 'locked', 'none'])
    assert.deepStrictEqual(pick('E01_S02_T02'), ['locked', 'locked', 'none'])
    assert.deepStrictEqual(pick('E01_S03_T01'), ['ready', 'open', 'ready'])
    assert.deepStrictEqual(pick('E01_S03_T02'), ['done', 'open', 'done'])
    assert.deepStrictEqual(pick('E01_S01_T04'), ['ready', 'open', 'ready'])
    // a ready task never carries the closed padlock, a locked one never the open padlock or no gate
    assert.ok(m.tasks.filter(t => t.state === 'ready').every(t => t.gate !== 'locked' && t.mark === 'ready'))
    assert.ok(m.tasks.filter(t => t.state === 'locked').every(t => t.gate === 'locked' && t.mark === 'none'))
    // the story's dependency draws no edge: dependsOn and the edges are the task's own
    assert.deepStrictEqual(task(m, 'E01_S02_T01').dependsOn, [])
    assert.ok(m.edges.some(e => e.kind === 'start' && e.to === 'E01_S02_T01'))
    // every ready task is in the ready list, gated or not
    assert.deepStrictEqual(m.ready.map(r => r.id), ['E01_S01_T02', 'E01_S01_T03', 'E01_S01_T04', 'E01_S03_T01'])
    // the --within payload gives the same gates
    const w = build({ ...g, scope: { type: 'graph', within: 'E01' } }, 'E01', LABELS_EN)
    assert.deepStrictEqual(w.tasks.map(t => t.gate), m.tasks.map(t => t.gate))
  })

  await test('E92_S10_T01: closed padlock exactly when the task is not done and waits; open in every other case', () => {
    // waiting_on as board-progress.sh --graph prints it: the unsatisfied effective ids (own depends_on, then the story's)
    // for every task not in the done bucket, [] for a done task; blocked_by is the same list for a pending task only
    const W = (t, waiting) => ({ ...t, waiting_on: waiting, blocked_by: t.bucket === 'pending' ? waiting : [] })
    const g = graphOf('E01', [
      W(T('E01_S01_T01', 'E01_S01', 'E01', 'done', ['E01_S01_T02'], null, 'Passed', 'done'), []), // done, own dependency not done: open
      W(T('E01_S01_T02', 'E01_S01', 'E01', 'ready', ['E01_S01_T03'], 'E01_S01_T03'), []), // ready with a dependency: open
      W(T('E01_S01_T03', 'E01_S01', 'E01', 'done', [], null, 'Passed', 'done'), []),
      W(T('E01_S01_T04', 'E01_S01', 'E01', 'locked', ['E01_S01_T05']), ['E01_S01_T05']), // locked pending task: locked
      W(T('E01_S01_T05', 'E01_S01', 'E01', 'in_progress', ['E01_S01_T03'], 'E01_S01_T03', 'In Progress'), []), // in progress, all satisfied: open
      W(T('E01_S01_T06', 'E01_S01', 'E01', 'ready', ['E00_S01_T01']), []), // only dependency rejected: satisfied, open
      W(T('E01_S01_T07', 'E01_S01', 'E01', 'done', [], null, 'Passed', 'done'), []), // no effective dependency: none
      W(T('E01_S02_T01', 'E01_S02', 'E01', 'done', [], null, 'Passed', 'done'), []), // done, its story's dependency not done: open
      W(T('E01_S02_T02', 'E01_S02', 'E01', 'locked', []), ['E01_S01']), // pending, locked only through its story: locked
      W(T('E01_S02_T03', 'E01_S02', 'E01', 'in_progress', [], null, 'In Progress'), ['E01_S01']), // in progress, story waits: locked (literal rule)
      W(T('E01_S02_T04', 'E01_S02', 'E01', 'rejected', [], null, 'Rejected'), ['E01_S01']), // rejected, story waits: locked (literal rule, open point)
      W(T('E01_S01_T08', 'E01_S01', 'E01', 'failed', ['E01_S01_T04'], null, 'Failed'), ['E01_S01_T04']), // failed, dependency pending: locked
      W(T('E01_S01_T09', 'E01_S01', 'E01', 'rejected', ['E00_S01_T01'], null, 'Rejected'), []), // rejected, dependency satisfied: open
    ], { external: [{ id: 'E00_S01_T01', status: 'Rejected', bucket: 'rejected' }] })
    g.stories = [
      { id: 'E01_S01', epic_id: 'E01', title: 'Story E01_S01', depends_on: [] },
      { id: 'E01_S02', epic_id: 'E01', title: 'Story E01_S02', depends_on: ['E01_S01'] },
    ]
    const m = build(g, 'E01', LABELS_EN)
    const gate = id => task(m, id).gate
    assert.strictEqual(gate('E01_S01_T01'), 'open') // a done task whose own dependency is not done
    assert.strictEqual(gate('E01_S02_T01'), 'open') // a done task whose story dependency is not done
    assert.strictEqual(gate('E01_S01_T02'), 'open') // a ready task with dependencies
    assert.strictEqual(gate('E01_S01_T04'), 'locked') // a locked pending task
    assert.strictEqual(gate('E01_S02_T02'), 'locked') // a pending task locked only through its story
    assert.strictEqual(gate('E01_S01_T05'), 'open') // an in-progress task whose dependencies are all satisfied
    assert.strictEqual(gate('E01_S01_T06'), 'open') // a task whose only dependency is rejected
    assert.strictEqual(gate('E01_S01_T07'), 'none') // a task with no effective dependency
    assert.strictEqual(gate('E01_S02_T03'), 'locked')
    assert.strictEqual(gate('E01_S02_T04'), 'locked')
    assert.strictEqual(gate('E01_S01_T08'), 'locked')
    assert.strictEqual(gate('E01_S01_T09'), 'open')
    // a done task never carries the closed padlock, whatever the payload says it waits for
    const stale = build(graphOf('E01', [W(T('E01_S01_T01', 'E01_S01', 'E01', 'done', ['E01_S01_T02'], null, 'Passed', 'done'), ['E01_S01_T02']), T('E01_S01_T02', 'E01_S01', 'E01', 'ready', [])]), 'E01', LABELS_EN)
    assert.strictEqual(task(stale, 'E01_S01_T01').gate, 'open')
    // closed exactly when not done and waiting; a gated task is open otherwise
    for (const t of m.tasks) {
      if (t.gate === 'none') continue
      const raw = g.tasks.find(x => x.id === t.id)
      assert.strictEqual(t.gate === 'locked', t.bucket !== 'done' && raw.waiting_on.length > 0, t.id)
    }
    // a payload from an older script (no waiting_on): only a locked pending task gets the closed padlock
    const old = build(graphOf('E01', [
      T('E01_S01_T01', 'E01_S01', 'E01', 'locked', ['E01_S01_T03']),
      T('E01_S01_T02', 'E01_S01', 'E01', 'in_progress', ['E01_S01_T03'], null, 'In Progress'),
      T('E01_S01_T03', 'E01_S01', 'E01', 'ready', []),
      T('E01_S01_T04', 'E01_S01', 'E01', 'done', ['E01_S01_T03'], null, 'Passed', 'done'),
    ]), 'E01', LABELS_EN)
    assert.deepStrictEqual(['E01_S01_T01', 'E01_S01_T02', 'E01_S01_T04'].map(id => task(old, id).gate), ['locked', 'open', 'open'])
  })

  // E92_S11_T02 (user decision 2026-11-15: a done task whose dependency is not done is flagged with a "?"): the model reads
  // the stated unfinished_deps into unfinishedDeps, only for a task whose list is not empty, and changes nothing else.
  await test('E92_S11_T02: unfinishedDeps is read from unfinished_deps, only where non-empty; gate, mark, state and counts unchanged', () => {
    const U = (t, unfinished) => ({ ...t, waiting_on: [], unfinished_deps: unfinished })
    const tasks = [
      U(T('E01_S01_T01', 'E01_S01', 'E01', 'done', ['E01_S01_T02'], null, 'Passed', 'done'), ['E01_S01_T02']), // own dependency reopened
      T('E01_S01_T02', 'E01_S01', 'E01', 'failed', [], null, 'Failed'),
      U(T('E01_S02_T01', 'E01_S02', 'E01', 'done', [], null, 'Passed', 'done'), ['E01_S01']), // its story's dependency is not done
      U(T('E01_S02_T02', 'E01_S02', 'E01', 'done', ['E01_S01_T02'], null, 'Passed', 'done'), ['E01_S01_T02', 'E01_S01']), // two
      U(T('E01_S01_T03', 'E01_S01', 'E01', 'done', [], null, 'Passed', 'done'), []), // stated, empty: no field
    ]
    const g = graphOf('E01', tasks)
    g.stories = [
      { id: 'E01_S01', epic_id: 'E01', title: 'Story E01_S01', depends_on: [] },
      { id: 'E01_S02', epic_id: 'E01', title: 'Story E01_S02', depends_on: ['E01_S01'] },
    ]
    const m = build(g, 'E01', LABELS_EN)
    assert.deepStrictEqual(task(m, 'E01_S01_T01').unfinishedDeps, ['E01_S01_T02'])
    assert.deepStrictEqual(task(m, 'E01_S02_T01').unfinishedDeps, ['E01_S01'])
    assert.deepStrictEqual(task(m, 'E01_S02_T02').unfinishedDeps, ['E01_S01_T02', 'E01_S01'], 'the stated order, own first')
    assert.ok(!('unfinishedDeps' in task(m, 'E01_S01_T03')), 'an empty list adds no field')
    assert.ok(!('unfinishedDeps' in task(m, 'E01_S01_T02')), 'no key, no field')
    // the visible node carries it too (the renderer draws from nodes)
    assert.deepStrictEqual(m.nodes.find(n => n.id === 'E01_S02_T02').unfinishedDeps, ['E01_S01_T02', 'E01_S01'])
    // nothing else changes: still done, done mark, open padlock (E92_S10_T01), done counts
    for (const id of ['E01_S01_T01', 'E01_S02_T01', 'E01_S02_T02']) {
      const t = task(m, id)
      assert.deepStrictEqual([t.state, t.bucket, t.mark, t.gate], ['done', 'done', 'done', 'open'], id)
    }
    assert.deepStrictEqual(m.stories.map(s => [s.storyId, s.done, s.total]), [['E01_S01', 2, 3], ['E01_S02', 2, 2]])
    // a payload without the key (an older script) gives exactly the model it gave before
    const strip = x => { const { unfinished_deps, ...rest } = x; return rest }
    const before = build({ ...g, tasks: tasks.map(strip) }, 'E01', LABELS_EN)
    const without = JSON.parse(JSON.stringify(m), (k, v) => (k === 'unfinishedDeps' ? undefined : v))
    assert.deepStrictEqual(JSON.parse(JSON.stringify(before)), without)
    assert.ok(before.tasks.every(t => !('unfinishedDeps' in t)))
    // a folded group of done tasks carries the union of its members' lists
    const many = [T('E01_S01_T01', 'E01_S01', 'E01', 'failed', [], null, 'Failed')].concat(
      [2, 3, 4, 5, 6, 7].map(n => U(T(`E01_S01_T0${n}`, 'E01_S01', 'E01', 'done', ['E01_S01_T01'], null, 'Passed', 'done'), n < 4 ? ['E01_S01_T01'] : [])))
    const folded = build(graphOf('E01', many), 'E01', LABELS_EN)
    const group = folded.nodes.find(n => n.kind === 'group')
    assert.ok(group && group.state === 'done', 'six done tasks fold')
    assert.deepStrictEqual(group.unfinishedDeps, ['E01_S01_T01'])
  })

  await test('E92_S11_T02: unfinishedDepText names the one dependency, or the first and a count, in en and sv; "" without ids or label', () => {
    const EN = { dep_unfinished: 'Done although dependency %s is not done - check the dependency', dep_unfinished_more: 'Done although dependency %s and %d more are not done - check the dependencies' }
    const SV = { dep_unfinished: 'Klar trots att beroendet %s inte är klart - kontrollera beroendet', dep_unfinished_more: 'Klar trots att beroendet %s och %d till inte är klara - kontrollera beroendena' }
    assert.strictEqual(unfinishedDepText(EN, ['E01_S01_T02']), 'Done although dependency E01_S01_T02 is not done - check the dependency')
    assert.strictEqual(unfinishedDepText(EN, ['E01_S01_T02', 'E01_S01', 'E02']), 'Done although dependency E01_S01_T02 and 2 more are not done - check the dependencies')
    assert.strictEqual(unfinishedDepText(SV, ['E01_S01']), 'Klar trots att beroendet E01_S01 inte är klart - kontrollera beroendet')
    assert.strictEqual(unfinishedDepText(SV, ['E01_S01', 'E01_S02']), 'Klar trots att beroendet E01_S01 och 1 till inte är klara - kontrollera beroendena')
    assert.strictEqual(unfinishedDepText(EN, []), '')
    assert.strictEqual(unfinishedDepText(EN, undefined), '')
    assert.strictEqual(unfinishedDepText({}, ['E01_S01']), '')
  })

  // ---- E92_S12_T02: ghost bands for undecomposed stories (the `decomposed` flag of graph.stories[] is read, never derived) ----
  // ghostGraph(entries): epic E01 with the stories of `entries` ({ id, decomposed?, tasks? }); a story carries `decomposed` only when the entry has the key.
  const ghostGraph = (entries, epicProgress) => {
    const tasks = []
    for (const e of entries) for (const t of e.tasks || []) tasks.push(t)
    return {
      schema_version: 1, scope: { type: 'graph' }, labels: LABELS_EN, lang: 'en',
      epics: [{ id: 'E01', title: 'Goal epic', ...(epicProgress ? { epic_progress: epicProgress } : {}) }],
      stories: entries.map(e => ({
        id: e.id, epic_id: 'E01', title: 'Story ' + e.id,
        ...('decomposed' in e ? { decomposed: e.decomposed } : {}),
        ...(e.totals ? { totals: e.totals } : {}),
      })),
      tasks, external: null, warnings: [],
    }
  }
  const OPT = { includeUndecomposed: true }
  const t1 = id => T(id, id.slice(0, 7), 'E01', 'ready', [])
  const WORKED = ghostGraph([
    { id: 'E01_S01', decomposed: true, tasks: [t1('E01_S01_T01'), T('E01_S01_T02', 'E01_S01', 'E01', 'locked', ['E01_S01_T01'])] },
    { id: 'E01_S02', decomposed: false },
    { id: 'E01_S03', decomposed: false },
  ])
  const structureOf = (g, options) => buildDependencyStructure(g, 'E01', LABELS_EN, options)

  await test('E92_S12_T02: the worked example, three stories of which two are undecomposed, gives three bands, two with empty cells and two undecomposed start facts', () => {
    const m = build(WORKED, 'E01', LABELS_EN)
    assert.deepStrictEqual(m.bands.map(b => b.storyId), ['E01_S01', 'E01_S02', 'E01_S03'])
    assert.deepStrictEqual(m.bands.map(b => b.row), [0, 1, 2])
    assert.deepStrictEqual(m.stories.map(s => s.storyId), ['E01_S01', 'E01_S02', 'E01_S03'])
    const s = structureOf(WORKED, OPT)
    assert.deepStrictEqual(s.bands.map(b => b.cells.length), [2, 0, 0], 'two ghost bands have empty cells')
    assert.deepStrictEqual(s.bands.map(b => b.start.undecomposed === true), [false, true, true])
    assert.deepStrictEqual(s.bands.map(b => b.undecomposed === true), [false, true, true])
    assert.ok(!('undecomposed' in s.bands[0]) && !('undecomposed' in s.bands[0].start) && !('undecomposed' in s.stories[0]), 'a decomposed story gains no key')
    // the start node of a ghost band: 0/0, title, buckets, ids
    assert.deepStrictEqual(s.bands[1].start, {
      kind: 'start', id: 'story:E01_S02', storyId: 'E01_S02', title: 'Story E01_S02', done: 0, total: 0,
      buckets: { done: 0, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0 }, undecomposed: true,
    })
    assert.deepStrictEqual(s.stories[1], { storyId: 'E01_S02', title: 'Story E01_S02', done: 0, total: 0, buckets: s.bands[1].start.buckets, undecomposed: true })
    // no task, node or header belongs to a ghost story
    assert.ok(s.tasks.every(t => t.storyId === 'E01_S01') && s.nodes.every(n => n.storyId === 'E01_S01'))
    // the dashboard model builds them without being asked and the start nodes carry the flag after layout
    assert.deepStrictEqual(m.bands.map(b => b.start.undecomposed === true), [false, true, true])
    assert.deepStrictEqual(m.bands.map(b => b.undecomposed === true), [false, true, true])
  })

  await test('E92_S12_T02: ghost and decomposed stories interleave in story-id order and rowOf covers the full list', () => {
    const g = ghostGraph([
      { id: 'E01_S04', decomposed: true, tasks: [t1('E01_S04_T01')] },
      { id: 'E01_S02', decomposed: true, tasks: [t1('E01_S02_T01'), t1('E01_S02_T02')] },
      { id: 'E01_S03', decomposed: false },
      { id: 'E01_S01', decomposed: false },
      { id: 'E01_S05', decomposed: false },
    ])
    const s = structureOf(g, OPT)
    assert.deepStrictEqual(s.bands.map(b => b.storyId), ['E01_S01', 'E01_S02', 'E01_S03', 'E01_S04', 'E01_S05'])
    assert.deepStrictEqual(s.bands.map(b => b.row), [0, 1, 2, 3, 4])
    assert.deepStrictEqual(s.stories.map(x => x.storyId), s.bands.map(b => b.storyId))
    assert.deepStrictEqual(s.bands.map(b => b.cells.length > 0), [false, true, false, true, false])
    // every task row is the index of its story's band
    for (const t of s.tasks) assert.strictEqual(s.bands[t.row].storyId, t.storyId)
    assert.deepStrictEqual(s.tasks.map(t => [t.id, t.row]), [['E01_S02_T01', 1], ['E01_S02_T02', 1], ['E01_S04_T01', 3]])
    for (const n of s.nodes) assert.strictEqual(s.bands[n.row].storyId, n.storyId)
  })

  await test('E92_S12_T02: decomposed true, null and a missing key give output deep-equal to the structure built without the option', () => {
    for (const flag of [true, null, undefined]) {
      const entries = (extra) => [
        { id: 'E01_S01', ...extra, tasks: [t1('E01_S01_T01')] },
        { id: 'E01_S02', ...extra }, // a story without tasks: no band, whatever a missing or non-false flag says
      ]
      const g = ghostGraph(flag === undefined ? entries({}) : entries({ decomposed: flag }))
      const plain = structureOf(g)
      assert.deepStrictEqual(structureOf(g, OPT), plain, 'flag ' + flag)
      assert.deepStrictEqual(structureOf(g, { includeUndecomposed: false }), plain)
      assert.deepStrictEqual(plain.bands.map(b => b.storyId), ['E01_S01'])
      assert.ok(!JSON.stringify(structureOf(g, OPT)).includes('undecomposed'), 'no new key at all')
      assert.ok(!JSON.stringify(build(g, 'E01', LABELS_EN)).includes('undecomposed'))
    }
    // the option is off by default and for anything but true; FULL (no flag anywhere) is untouched either way
    const flagged = ghostGraph([{ id: 'E01_S01', decomposed: true, tasks: [t1('E01_S01_T01')] }, { id: 'E01_S02', decomposed: false }])
    assert.deepStrictEqual(structureOf(flagged), structureOf(ghostGraph([{ id: 'E01_S01', tasks: [t1('E01_S01_T01')] }])))
    assert.deepStrictEqual(structureOf(flagged, { includeUndecomposed: 'yes' }), structureOf(flagged))
    assert.deepStrictEqual(build(FULL, 'E01', LABELS_EN), build(FULL, 'E01', LABELS_EN, { includeUndecomposed: false }))
    assert.deepStrictEqual(structureOf(FULL, OPT), structureOf(FULL))
  })

  await test('E92_S12_T02: a story of only rejected tasks stated decomposed false keeps its nodes and flags its start fact only; no edge or band flag', () => {
    const rej = T('E01_S02_T01', 'E01_S02', 'E01', 'rejected', [], null, 'Rejected', 'rejected')
    const g = ghostGraph([
      { id: 'E01_S01', decomposed: true, tasks: [t1('E01_S01_T01')] },
      { id: 'E01_S02', decomposed: false, tasks: [rej], totals: totals(0, 0, 0, 0, 1, 0) },
    ])
    const s = structureOf(g, OPT)
    assert.deepStrictEqual(s.nodes.map(n => n.id), ['E01_S01_T01', 'E01_S02_T01'])
    assert.strictEqual(s.bands[1].cells.length, 1)
    assert.strictEqual(s.bands[1].start.undecomposed, true)
    assert.ok(!('undecomposed' in s.bands[1]), 'not a ghost band')
    assert.ok(!('undecomposed' in s.bands[0].start))
    assert.strictEqual(s.stories[1].undecomposed, true)
    assert.ok(s.edges.every(e => e.kind !== 'ghost'), 'a story with nodes needs no ghost edge')
    assert.ok(task({ tasks: s.tasks }, 'E01_S02_T01') && s.tasks.length === 2)
    // without the option the very same payload gives today's structure, the flag unread
    assert.ok(!JSON.stringify(structureOf(g)).includes('undecomposed'))
    // its start node 0/0 comes from the stated totals, nothing is recomputed
    assert.deepStrictEqual([s.bands[1].start.done, s.bands[1].start.total, s.bands[1].start.buckets.rejected], [0, 0, 1])
  })

  await test('E92_S12_T02: only stories of this epic are considered, and a story with task nodes is not a second band', () => {
    const g = ghostGraph([{ id: 'E01_S01', decomposed: true, tasks: [t1('E01_S01_T01')] }, { id: 'E01_S02', decomposed: false }])
    g.stories.push({ id: 'E02_S01', epic_id: 'E02', title: 'Other epic', decomposed: false })
    g.stories.push({ id: 'E01_S03', title: 'No epic id', decomposed: false })
    const s = structureOf(g, OPT)
    assert.deepStrictEqual(s.bands.map(b => b.storyId), ['E01_S01', 'E01_S02'])
    const dup = ghostGraph([{ id: 'E01_S01', decomposed: false, tasks: [t1('E01_S01_T01')] }])
    dup.stories.push({ id: 'E01_S01', epic_id: 'E01', title: 'Dup', decomposed: false })
    assert.deepStrictEqual(structureOf(dup, OPT).bands.map(b => b.storyId), ['E01_S01'])
  })

  await test('E92_S12_T02: the ghost edge, story start node to the goal, exists for ghost bands only, once each, after the task edges', () => {
    const s = structureOf(WORKED, OPT)
    const ghost = s.edges.filter(e => e.kind === 'ghost')
    assert.deepStrictEqual(ghost, [
      { from: 'story:E01_S02', to: GOAL_NODE_ID, crossStory: false, kind: 'ghost' },
      { from: 'story:E01_S03', to: GOAL_NODE_ID, crossStory: false, kind: 'ghost' },
    ])
    assert.deepStrictEqual(s.edges.slice(-2), ghost, 'after every task edge, in band order')
    assert.deepStrictEqual(s.edges.slice(0, -2), structureOf(WORKED).edges, 'the other edges are exactly the ones built without ghosts')
    assert.strictEqual(new Set(s.edges.map(e => e.from + '>' + e.to)).size, s.edges.length, 'de-duplicated')
    // an epic without ghost bands has no ghost edge and no ghost key
    assert.ok(structureOf(FULL, OPT).edges.every(e => e.kind !== 'ghost'))
    assert.ok(structureOf(ghostGraph([{ id: 'E01_S01', decomposed: true, tasks: [t1('E01_S01_T01')] }]), OPT).edges.every(e => e.kind !== 'ghost'))
    // folding keeps them: expanding a group or refolding gives the ghost bands and edges back
    const many = ghostGraph([
      { id: 'E01_S01', decomposed: true, tasks: Array.from({ length: 5 }, (_, i) => T(`E01_S01_T0${i + 1}`, 'E01_S01', 'E01', 'ready', [])) },
      { id: 'E01_S02', decomposed: false },
    ])
    const folded = build(many, 'E01', LABELS_EN)
    assert.strictEqual(folded.foldable.length, 1)
    for (const model of [unfoldGroups(folded, new Set(folded.foldable)), unfoldGroups(unfoldGroups(folded, new Set(folded.foldable)), new Set()), unfoldGroups(folded)]) {
      assert.deepStrictEqual(model.bands.map(b => b.storyId), ['E01_S01', 'E01_S02'])
      assert.strictEqual(model.bands[1].undecomposed, true)
      assert.strictEqual(model.bands[1].start.undecomposed, true)
      assert.deepStrictEqual(model.edges.filter(e => e.kind === 'ghost').map(e => e.from), ['story:E01_S02'])
    }
    assert.deepStrictEqual(unfoldGroups(folded), folded)
  })

  await test('E92_S12_T02: layout places zero-cell bands in the middle and at the end, with the content height and the goal right', () => {
    const g = ghostGraph([
      { id: 'E01_S01', decomposed: true, tasks: [t1('E01_S01_T01')] },
      { id: 'E01_S02', decomposed: false }, // middle
      { id: 'E01_S03', decomposed: true, tasks: [t1('E01_S03_T01'), T('E01_S03_T02', 'E01_S03', 'E01', 'locked', ['E01_S03_T01'])] },
      { id: 'E01_S04', decomposed: false }, // end
    ])
    const m = build(g, 'E01', LABELS_EN)
    const band = LAYOUT.cardH + LAYOUT.bandPad * 3 // a zero-cell band: bandPad * 2 + max(cardH + bandPad)
    assert.deepStrictEqual(m.bands.map(b => b.h), [band, band, band, band], 'every band here is one card tall; a ghost band is cardH + bandPad inside')
    assert.strictEqual(m.bands[0].y, LAYOUT.pad)
    for (let i = 1; i < m.bands.length; i++) assert.strictEqual(m.bands[i].y, m.bands[i - 1].y + m.bands[i - 1].h + LAYOUT.bandGap, 'bands stack with bandGap')
    for (const b of m.bands) {
      assert.deepStrictEqual([b.start.x, b.start.w, b.start.h, b.start.outX], [LAYOUT.pad, LAYOUT.startW, LAYOUT.startH, LAYOUT.pad + LAYOUT.startW])
      assert.strictEqual(b.start.y, b.y + b.h / 2 - LAYOUT.startH / 2)
      assert.strictEqual(b.start.midY, b.y + b.h / 2)
    }
    const last = m.bands[3]
    const contentH = last.y + last.h + LAYOUT.pad
    assert.strictEqual(m.layout.height, Math.max(contentH, LAYOUT.minHeight))
    assert.strictEqual(m.layout.columns, 2, 'columns follow the tasks, ghost bands add none')
    assert.strictEqual(m.goal.y, contentH / 2)
    assert.strictEqual(m.goal.x, LAYOUT.columnX0 + LAYOUT.columnW + LAYOUT.cardW + LAYOUT.goalGap + LAYOUT.goalOffsetX)
    assert.strictEqual(m.layout.width, LAYOUT.columnX0 + LAYOUT.columnW + LAYOUT.cardW + LAYOUT.goalGap + LAYOUT.goalAreaW)
    // nodes stay inside their own bands
    for (const n of m.nodes) { const b = m.bands[n.row]; assert.ok(n.y >= b.y && n.y + n.h <= b.y + b.h, n.id) }
    // a ghost band between two taller bands, and an epic of one task beside ghosts, keep the same rules
    const tall = ghostGraph([
      { id: 'E01_S01', decomposed: true, tasks: Array.from({ length: 3 }, (_, i) => T(`E01_S01_T0${i + 1}`, 'E01_S01', 'E01', 'ready', [])) },
      { id: 'E01_S02', decomposed: false },
    ])
    const tm = build(tall, 'E01', LABELS_EN)
    assert.strictEqual(tm.bands[1].h, band)
    assert.ok(tm.bands[0].h > band)
    assert.strictEqual(tm.layout.height, Math.max(tm.bands[1].y + tm.bands[1].h + LAYOUT.pad, LAYOUT.minHeight))
  })

  await test('E92_S12_T02: an epic with no task node stays empty even when every story is undecomposed (open question for the user)', () => {
    const g = ghostGraph([{ id: 'E01_S01', decomposed: false }, { id: 'E01_S02', decomposed: false }])
    for (const m of [build(g, 'E01', LABELS_EN), structureOf(g, OPT)]) {
      assert.strictEqual(m.empty, true)
      assert.deepStrictEqual(m.bands, [])
      assert.deepStrictEqual(m.edges, [])
    }
  })

  await test('E92_S12_T02: ghost-band output is deterministic: same input twice and any input order', () => {
    const g = ghostGraph([
      { id: 'E01_S03', decomposed: false },
      { id: 'E01_S02', decomposed: true, tasks: [t1('E01_S02_T01'), t1('E01_S02_T02')] },
      { id: 'E01_S01', decomposed: false },
    ])
    const a = build(g, 'E01', LABELS_EN)
    assert.deepStrictEqual(a, build(g, 'E01', LABELS_EN))
    assert.deepStrictEqual(a, build({ ...g, stories: g.stories.slice().reverse(), tasks: g.tasks.slice().reverse() }, 'E01', LABELS_EN))
    assert.deepStrictEqual(JSON.parse(JSON.stringify(a)), a)
    assert.deepStrictEqual(a.bands.map(b => b.storyId), ['E01_S01', 'E01_S02', 'E01_S03'])
  })

  await test('deterministic: same input twice and any input order give deep-equal output', () => {
    const a = build(FULL, 'E01', LABELS_EN)
    assert.deepStrictEqual(a, build(FULL, 'E01', LABELS_EN))
    assert.deepStrictEqual(a, build({ ...FULL, tasks: FULL.tasks.slice().reverse() }, 'E01', LABELS_EN))
    const tasks = [T('E01_S01_T01', 'E01_S01', 'E01', 'done', [])].concat(Array.from({ length: 7 }, (_, i) => T(`E01_S01_T0${i + 2}`, 'E01_S01', 'E01', 'ready', ['E01_S01_T01'])))
    const g = graphOf('E01', tasks)
    assert.deepStrictEqual(build(g, 'E01', LABELS_EN), build({ ...g, tasks: tasks.slice().reverse() }, 'E01', LABELS_EN))
    // rows inside a band are stable
    const rowsA = build(g, 'E01', LABELS_EN).nodes.map(n => [n.id, n.slot, n.y])
    assert.deepStrictEqual(rowsA, build(g, 'E01', LABELS_EN).nodes.map(n => [n.id, n.slot, n.y]))
    // the model survives a JSON round trip (plain data only)
    assert.deepStrictEqual(JSON.parse(JSON.stringify(a)), a)
  })

  await test('layout numbers are exported and drive the totals', () => {
    for (const k of ['pad', 'startW', 'startH', 'columnX0', 'columnW', 'cardW', 'cardH', 'rowGap', 'bandPad', 'bandGap', 'goalGap', 'gateR']) {
      assert.ok(Number.isFinite(LAYOUT[k]) && LAYOUT[k] > 0, k)
    }
    assert.ok(Object.isFrozen(LAYOUT))
    assert.strictEqual(mod.COL_WIDTH, LAYOUT.columnW)
    const m = build(FULL, 'E01', LABELS_EN)
    assert.strictEqual(m.layout.width, LAYOUT.columnX0 + (m.layout.columns - 1) * LAYOUT.columnW + LAYOUT.cardW + LAYOUT.goalGap + LAYOUT.goalAreaW)
    const last = m.bands[m.bands.length - 1]
    assert.ok(m.layout.height >= last.y + last.h + LAYOUT.pad)
    for (const k of Object.keys(LAYOUT)) assert.strictEqual(m.layout[k], LAYOUT[k])
    // a gated card's input anchor leaves room for the gate badge
    for (const n of m.nodes) assert.strictEqual(n.inX, n.x - (n.gate === 'none' ? 0 : LAYOUT.gateR))
  })

  await test('source hygiene: no colour, label or user-visible word in the model', () => {
    const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(code), 'hex colour')
    assert.ok(!/\b(rgb|rgba|hsl|hsla)\(/.test(code), 'functional colour')
    assert.ok(!/var\(--/.test(code), 'css token')
    const literals = [...code.matchAll(/'([^'\\]*)'/g)].map(m => m[1])
    for (const l of literals) assert.ok(!/\s/.test(l) && !/^[A-Z]/.test(l), 'user-visible word: ' + l)
    assert.ok(!/\bimport\b[^\n]*\b(react|react-dom)\b/.test(code) && !/\b(document|window)\./.test(code), 'React/DOM free')
  })

  console.log(`\ndependency-tree-model: ${count} tests passed`)
}

main().catch(err => { console.error(err); process.exit(1) })
