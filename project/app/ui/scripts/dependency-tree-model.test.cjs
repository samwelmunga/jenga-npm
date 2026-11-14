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

const LABELS_EN = { unlocked_by: '%s unlocked by %s', tree_empty: 'No dependencies to show' }
const LABELS_SV = { unlocked_by: '%s låstes upp av %s', tree_empty: 'Inga beroenden att visa' }

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
  const { buildDependencyTreeModel: build, fillUnlockedBy, unfoldGroups, FOLD_THRESHOLD, LAYOUT, GOAL_NODE_ID } = mod
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
      T('E01_S01_T08', 'E01_S01', 'E01', 'failed', ['E01_S01_T02']), // failed: locked gate, failed mark
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
    assert.strictEqual(FOLD_THRESHOLD, 5)
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

    // 5 do not
    const five = build(graphOf('E01', [root, ...fan(5, 'ready', 'S01')]), 'E01', LABELS_EN)
    assert.ok(five.nodes.every(n => n.kind === 'task'))
    assert.strictEqual(five.nodes.length, 6)
    assert.deepStrictEqual(five.foldable, [])

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

  await test('goal: fraction, percent, done, total, reached for 0 tasks, all rejected, partial and 100 %', () => {
    const goalOf = tasks => build(graphOf('E01', tasks), 'E01', LABELS_EN).goal
    // 0 tasks: no division by zero
    const zero = build({ ...FULL, tasks: [] }, 'E01', LABELS_EN)
    assert.strictEqual(zero.empty, true)
    assert.deepStrictEqual({ ...zero.goal, x: 0, y: 0 }, { id: 'E01', title: 'Goal epic', fraction: 0, percent: 0, done: 0, total: 0, reached: false, x: 0, y: 0 })
    // all rejected: rejected tasks are not counted, so 0 of 0
    const rej = goalOf([T('E01_S01_T01', 'E01_S01', 'E01', 'rejected', []), T('E01_S01_T02', 'E01_S01', 'E01', 'rejected', ['E01_S01_T01'])])
    assert.strictEqual(rej.total, 0); assert.strictEqual(rej.done, 0); assert.strictEqual(rej.fraction, 0); assert.strictEqual(rej.percent, 0); assert.strictEqual(rej.reached, false)
    // partial: 1 of 3 counted, one rejected ignored
    const part = goalOf([
      T('E01_S01_T01', 'E01_S01', 'E01', 'done', []),
      T('E01_S01_T02', 'E01_S01', 'E01', 'ready', ['E01_S01_T01']),
      T('E01_S01_T03', 'E01_S01', 'E01', 'locked', ['E01_S01_T02']),
      T('E01_S01_T04', 'E01_S01', 'E01', 'rejected', ['E01_S01_T01']),
    ])
    assert.strictEqual(part.done, 1); assert.strictEqual(part.total, 3)
    assert.strictEqual(part.fraction, 1 / 3); assert.strictEqual(part.percent, 33); assert.strictEqual(part.reached, false)
    // 100 %
    const full = goalOf([T('E01_S01_T01', 'E01_S01', 'E01', 'done', []), T('E01_S01_T02', 'E01_S01', 'E01', 'done', ['E01_S01_T01']), T('E01_S01_T03', 'E01_S01', 'E01', 'rejected', [])])
    assert.deepStrictEqual([full.done, full.total, full.fraction, full.percent, full.reached], [2, 2, 1, 100, true])
    // percent rounds: 2 of 3 is 67
    assert.strictEqual(goalOf([
      T('E01_S01_T01', 'E01_S01', 'E01', 'done', []), T('E01_S01_T02', 'E01_S01', 'E01', 'done', ['E01_S01_T01']), T('E01_S01_T03', 'E01_S01', 'E01', 'ready', ['E01_S01_T01']),
    ]).percent, 67)
    // a payload that states the epic totals is used as stated (unknown statuses are not in the denominator)
    const stated = build(graphOf('E01', [T('E01_S01_T01', 'E01_S01', 'E01', 'done', []), T('E01_S01_T02', 'E01_S01', 'E01', 'ready', ['E01_S01_T01'])],
      { epics: [{ id: 'E01', title: 'Goal epic', tasks: { totals: totals(51, 3, 0, 5, 2, 1) } }] }), 'E01', LABELS_EN).goal
    assert.deepStrictEqual([stated.done, stated.total, stated.percent, stated.reached], [51, 59, 86, false])
    // the goal sits to the right of the last column
    const m = build(FULL, 'E01', LABELS_EN)
    assert.ok(m.goal.x > Math.max(...m.nodes.map(n => n.outX)))
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

  await test('empty cases: no tasks, unknown epic, null graph, no dependencies; a cycle does not hang', () => {
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
    assert.strictEqual(build({ ...FULL, tasks: [T('E01_S01_T01', 'E01_S01', 'E01', 'done', ['E01_S01_T01'])] }, 'E01', LABELS_EN).empty, true) // self-edge ignored
    for (const e of [build({ ...FULL, tasks: [] }, 'E01'), build(FULL, 'E99'), build(null, 'E01'), build(FULL, '')]) {
      assert.strictEqual(e.empty, true)
      assert.deepStrictEqual([e.nodes, e.tasks, e.edges, e.bands, e.headers, e.foldable], [[], [], [], [], [], []])
    }
    // tasks but no dependency at all: empty, yet the goal still carries the progress
    const flat = build({ ...FULL, tasks: [T('E01_S01_T01', 'E01_S01', 'E01', 'ready', []), T('E01_S01_T02', 'E01_S01', 'E01', 'done', [])] }, 'E01', LABELS_EN)
    assert.strictEqual(flat.empty, true)
    assert.deepStrictEqual([flat.goal.done, flat.goal.total, flat.goal.percent], [1, 2, 50])
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
