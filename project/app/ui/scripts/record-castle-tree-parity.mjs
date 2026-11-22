#!/usr/bin/env node
// E92_S13_T06: records the `castleTree` section of tests/fixtures/progress/dependency-tree-parity.json. It builds a temporary board for
// each case, prints its REAL `scripts/board-progress.sh --graph --within <epic>` payload (so a key the castle or the tree reads that the
// script does not print would show up as a missing fact), keeps the keys the models read, and records castle-tree-summary.mjs's output
// for it from the CURRENT model. Nothing else in the fixture is touched. Run: node project/app/ui/scripts/record-castle-tree-parity.mjs
// Cases (inputs): stacking on one story and a bridge on two; an out-of-epic, an uncounted and a self dependency and a cycle; an
// undecomposed dependency, a rejected task and a failed story; a 26-task story (widened); 94 tasks in 22 stories stacked and independent;
// the growth stage boundaries 24 / 25 / 45 / 65 / 85 / 99 / 100 percent; a complete epic.
import cp from 'child_process'
import fs from 'fs'
import os from 'os'
import path from 'path'
import { fileURLToPath } from 'url'
import { summariseCastleAndTree } from './castle-tree-summary.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.join(here, '..', '..', '..', '..')
const fixturePath = path.join(root, 'tests', 'fixtures', 'progress', 'dependency-tree-parity.json')
const pad = n => String(n).padStart(2, '0')

// One epic = stories [{ t tasks, d done, p in progress, f failed, r rejected, deps: [story number | 'E99_S01' external], undec }]
function writeEpic(board, n, title, stories) {
  const E = 'E' + pad(n)
  const item = (dir, id, extra, ttl, status) => fs.writeFileSync(path.join(board, dir, `${id}_item.md`),
    ['---', `id: ${id}`, ...extra, `title: "${ttl}"`, `status: ${status}`, 'date_created: "2026-11-17"', '---', '', `Body of ${id}.`, ''].join('\n'))
  item('epics', E, [], title, 'In Progress')
  stories.forEach((s, i) => {
    const S = `${E}_S${pad(i + 1)}`
    const deps = (s.deps || []).map(d => (typeof d === 'number' ? `${E}_S${pad(d)}` : d))
    const t = s.undec ? 0 : s.t
    const done = s.d || 0, prog = s.p || 0, fail = s.f || 0, rej = s.r || 0
    const st = s.undec ? 'Pending' : done === t ? 'Passed' : fail ? 'Failed' : done + prog > 0 ? 'In Progress' : 'Pending'
    item('stories', S, [`epic_id: ${E}`, ...(deps.length ? [`depends_on: [${deps.join(', ')}]`] : [])], `Story ${i + 1}`, st)
    for (let k = 1; k <= t + rej; k++) {
      const ts = k <= done ? 'Passed' : k <= done + prog ? 'In Progress' : k <= done + prog + fail ? 'Failed' : k > t ? 'Rejected' : 'Pending'
      item('tasks', `${S}_T${pad(k)}`, [`story_id: ${S}`], `Task ${k}`, ts)
    }
  })
  return E
}
const dist = (counts, done, deps) => { let left = done; return counts.map((c, i) => { const d = Math.min(c, left); left -= d; return { t: c, d, deps: deps ? deps(i + 1) : [] } }) }
const stage4 = (done, total = 20) => dist([total / 4, total / 4, total / 4, total / 4], done, i => (i === 1 ? [] : i === 2 || i === 3 ? [1] : [2, 3]))
const counts94 = [9, 7, 7, 6, 6, 5, 5, 5, 5, 4, 4, 4, 4, 3, 3, 3, 3, 3, 2, 2, 2, 2]

const CASES = [
  ['castle and tree: stacking on one story and a bridge on two (median, 16 tasks, 6 stories, one rejected)', [
    { t: 3, d: 3 }, { t: 3, d: 3, deps: [1] }, { t: 3, d: 2, p: 1, deps: [1] }, { t: 3, d: 1, p: 1, deps: [2, 3] }, { t: 2, deps: [4] }, { t: 2, r: 1 }]],
  ['castle and tree: out-of-epic, uncounted, self and cyclic dependencies', [
    { t: 2, d: 2 }, { t: 2, d: 1, deps: ['E99_S01'] }, { t: 2, deps: [3] }, { t: 2, d: 1, deps: [5] }, { t: 2, deps: [4] }, { t: 2, d: 2, deps: [1, 1] }]],
  ['castle and tree: undecomposed stories, one a dependency, and a rejected task', [
    { t: 3, d: 3 }, { t: 3, d: 1, p: 1, deps: [1] }, { undec: true, deps: [1] }, { t: 2, d: 1, r: 1, deps: [2] }, { undec: true, deps: [3] }, { undec: true }]],
  ['castle and tree: a failed story blocks the goal (leaning tower, withered clump, drooping branch)', [
    { t: 3, d: 3 }, { t: 4, d: 2, f: 1, deps: [1] }, { t: 3, deps: [2] }, { t: 3, d: 2, p: 1 }, { t: 2, d: 1 }]],
  ['castle and tree: a 26-task story is widened (7 layers of 4) and its clumps shrink', dist([26, 4, 3, 3, 2], 20, i => (i === 1 ? [] : [1]))],
  ['castle and tree: max size, 94 tasks in 22 stories, stacked', dist(counts94, 47, i => (i <= 2 ? [] : i % 5 === 0 ? [i - 3, i - 2] : [i - 3 > 0 ? i - 3 : 1]))],
  ['castle and tree: max size, 94 tasks in 22 independent root stories', dist(counts94, 30, () => [])],
  ['tree stage: 24 percent is Seedling, no stone yet', dist([7, 6, 6, 6], 6, i => (i === 1 ? [] : i === 2 || i === 3 ? [1] : [2, 3]))],
  ['tree stage: 25 percent is Sapling, first stone', stage4(5)],
  ['tree stage: 45 percent is Young tree, two stones', stage4(9)],
  ['tree stage: 65 percent, three stones, mushrooms', stage4(13)],
  ['tree stage: 85 percent is Mature tree, four stones', stage4(17)],
  ['tree stage: 99 percent is still Mature tree (99 of 100 tasks)', dist([50, 50], 99, i => (i === 1 ? [] : [1]))],
  ['castle and tree: complete epic, goal reached, Majestic tree', [
    { t: 3, d: 3 }, { t: 3, d: 3, deps: [1] }, { t: 3, d: 3, deps: [1] }, { t: 3, d: 3, deps: [2, 3] }, { t: 2, d: 2, deps: [4] }, { t: 2, d: 2 }]],
]

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'castle-tree-parity-'))
const cases = []
try {
  CASES.forEach(([name, stories], i) => {
    const proj = path.join(tmp, `p${i}`)
    for (const d of ['epics', 'stories', 'tasks']) fs.mkdirSync(path.join(proj, 'project', 'board', d), { recursive: true })
    fs.mkdirSync(path.join(proj, 'project', 'configs'), { recursive: true })
    fs.writeFileSync(path.join(proj, 'project', 'configs', 'workflow.json'), '{}\n')
    const epicId = writeEpic(path.join(proj, 'project', 'board'), 1, 'Recorded epic', stories)
    const raw = JSON.parse(cp.execFileSync('bash', [path.join(root, 'scripts', 'board-progress.sh'), '--graph', '--within', epicId, '--root', proj], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }))
    // the keys the castle and the tree read (castleModel.js, treeLayout.js), nothing else: a smaller recording of a real payload
    const graph = {
      schema_version: raw.schema_version,
      scope: raw.scope,
      epics: raw.epics.map(e => ({ id: e.id, title: e.title, depends_on: e.depends_on, epic_progress: e.epic_progress })),
      stories: raw.stories.map(s => ({ id: s.id, epic_id: s.epic_id, title: s.title, depends_on: s.depends_on, totals: s.totals, complete: s.complete, decomposed: s.decomposed, stop: s.stop })),
      tasks: raw.tasks.map(t => ({ id: t.id, story_id: t.story_id, epic_id: t.epic_id, title: t.title, status: t.status, bucket: t.bucket, state: t.state, depends_on: t.depends_on, blocked_by: t.blocked_by, waiting_on: t.waiting_on, unlocked_by: t.unlocked_by })),
    }
    cases.push({ name, epicId, graph, expected: summariseCastleAndTree(graph, epicId) })
  })
} finally {
  fs.rmSync(tmp, { recursive: true, force: true })
}

const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'))
fixture.castleTree = {
  recorded_from: 'E92_S13_T06: the dashboard model of E92_S13_T01 to T07 at the commit that adds this key, over real `board-progress.sh --graph --within` payloads (record-castle-tree-parity.mjs)',
  rerecorded: 'none: this key is new; no case of `cases` or of dependency-tree-ghost-bands.json was changed or re-recorded',
  cases,
}
fs.writeFileSync(fixturePath, JSON.stringify(fixture))
console.log(`recorded ${cases.length} castleTree cases into ${path.relative(root, fixturePath)}`)
