/**
 * lib/progress/dependency-structure.js - E92_S08_T02.
 *
 * The graph-STRUCTURE half of the epic dependency tree, shared by the dashboard (project/app/ui, through
 * dependencyTreeModel.js, which adds the pixel layout on top) and the Node terminal renderer (E92_S08_T05).
 * Input is the body of `scripts/board-progress.sh --graph [--within <id>]` (or `GET /v1/progress-graph`), plus its labels.
 *
 * Pure: no DOM, no React, no I/O, no imports, and no pixel number of any kind (no x, y, w, h or layout constant): a
 * terminal draws the same tree in character cells. It derives no state, readiness or unlocked_by (those are the script's),
 * counts nothing the payload does not already state (epic and story figures are read from the payload's `totals`, and only
 * when a `totals` object is absent are they read off the tasks' own `bucket`), and holds no colour, no label and no user-visible word.
 *
 * Shipped through the `lib/` entry of package.json `files`, and written for Node >= 14.13.1: no replaceAll, no Array
 * `at`, no logical assignment, no Object.hasOwn, no structuredClone, no node: test runner, no fetch.
 *
 * Edge direction: `{ from, to }` means `from` is the DEPENDENCY and `to` is the DEPENDENT, so an edge runs from the right
 * edge of the dependency to the left edge of the dependent. Every edge carries `crossStory` (the two ends sit in different
 * stories; boundary edges always do) and a `kind`: `dependency` (task to task), `boundary` (a node outside the epic to a
 * task), `start` (a story's start node to a task with no in-epic dependency) and `goal` (a task that nothing in the epic
 * depends on to the goal, whose id is GOAL_NODE_ID). Edges between the visible nodes are de-duplicated by `from` + `to`;
 * once groups fold, the edges of a group are the union of its members'.
 *
 * Undecomposed stories (E92_S12_T02, opt-in): a fourth `options` argument `{ includeUndecomposed: true }` (default off, so the
 * terminal renderers, which never pass it, get the structure they always got) lets a story of the epic that the payload states
 * `decomposed: false` (graph.stories[], E92_S12_T01) and that has no task nodes appear as a GHOST BAND: a band with empty
 * `cells` and a start node `0/0`, `undecomposed: true` on the band and on the start fact. A story with task nodes that is
 * stated `decomposed: false` (all its tasks rejected or of unknown status) keeps every node and carries `undecomposed: true`
 * on its start fact only. The flag is read, never derived (E92 decision 1): `true`, `null` or a missing key (an older
 * payload) adds no key at all, so such a structure is deep-equal to the one built without the option. A ghost band also gets
 * one edge of kind `ghost`, its start node to the goal, so the band is not an orphan; an epic without ghost bands has none.
 * An epic with no task nodes stays `empty` (below), also when every one of its stories is undecomposed.
 *
 * Structure shape (arrays are sorted, so the same input gives a deep-equal output):
 *   empty        true only when the epic has no tasks (the goal is still filled in). An epic with at least one task always
 *                gets the full structure, with or without dependency edges (user request 2026-11-15, E92_S09_T01): with no
 *                edge every task sits in depth column 0 of its story band, with a `start` and a `goal` edge (gate `none` unless its
 *                story has a depends_on, see gate below)
 *   goal         { id, title, fraction, percent, done, total, reached, stories, decomposed }   the epic percent of the
 *                script's `epic_progress` (E92_S09_T04, section 5.1 of progress-visualisation.md), read and never recomputed:
 *                percent and reached as stated (percent / 100 is the fraction 0..1 the drawing scales by), done/total its
 *                tasks_done/tasks_denominator, stories/decomposed its counts (the view shows decomposed/stories when lower).
 *                An epic entry without epic_progress gives the zero goal
 *   stories      per story: { storyId, title, done, total, buckets }   the start-node facts, id order, plus
 *                undecomposed: true on a story the payload states `decomposed: false` (only with includeUndecomposed)
 *   tasks        every task, never folded: { kind:'task', id, title, storyId, state, bucket, row, column, gate,
 *                mark, dependsOn, unlocks, upstream, downstream }   gate: none | locked | open, from the task's EFFECTIVE
 *                dependencies (its own depends_on plus its story's; see gateOf): none only when there are none at all,
 *                locked exactly when the task is not done and the script's waiting_on is not empty, else open (E92_S10_T01);
 *                mark: done | in_progress | ready | failed | rejected | none (none for a locked task). Every `ready` task
 *                has mark `ready` whatever its gate, so the gate is the only fact that tells a task with dependencies apart.
 *                unfinishedDeps (E92_S11_T02): present ONLY on a task whose payload states a non-empty `unfinished_deps`
 *                (a done task with an effective dependency that is not done, a board contradiction the views flag with a
 *                "?"): those ids as stated, strings only. Absent otherwise, so a payload without the key (an older script)
 *                gives exactly the structure it gave before. It changes neither the gate (a done task keeps `open`) nor
 *                the mark, the state or any count
 *   nodes        the VISIBLE nodes: tasks and folded groups, in band, column, slot order, each with its `slot`
 *                group: { kind:'group', id, members, count, state, storyId, row, column, gate, mark, dependsOn, unlocks,
 *                upstream, downstream }, plus unfinishedDeps (the union of its members', sorted) only when a member has it
 *   headers      one collapse header per expanded group: { kind:'header', id, state, count, row, column }
 *   bands        per story: { storyId, row, start, cells }   `start` is the start node (id `story:<storyId>`) with its
 *                facts (and `undecomposed: true` for an undecomposed story); a ghost band has `cells` [] and
 *                `undecomposed: true` on the band itself; `cells` is [{ column, slots }] in column order, a slot being { type:'node', node } or
 *                { type:'header', header }, in the order the cell stacks them
 *   edges        the visible edges, see above (a `ghost` edge, after the task edges, per ghost band in band order)
 *   boundary     nodes outside the epic, { id, status, bucket }
 *   foldable     ids of every group that would fold, folded or not
 *   expanded     ids currently unfolded
 *   ready, unlocked   the lists printed below the tree
 *   columns      number of depth columns (0 when empty)
 */

/** A group folds when MORE than this many tasks share a state within one story and one column. */
export const FOLD_THRESHOLD = 3 // E92_S11_T03, user request 2026-11-15: fold already at more than three (was 5)

/** Id of the goal as an edge target. */
export const GOAL_NODE_ID = 'goal'

const STATE_ORDER = { in_progress: 0, ready: 1, failed: 2, locked: 3, done: 4, rejected: 5, unknown: 6 }
const MARKED = new Set(['done', 'in_progress', 'ready', 'failed', 'rejected'])
const BUCKETS = ['done', 'in_progress', 'failed', 'pending', 'rejected', 'unknown']

const byId = (a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0)
const arr = v => (Array.isArray(v) ? v : [])
export const stateRank = s => (s in STATE_ORDER ? STATE_ORDER[s] : 7)

/** Substitute the two `%s` of the unlocked_by label, in order (task id, then unlocked_by id). '' when label missing. */
export function fillUnlockedBy(template, taskId, byTaskId) {
  if (typeof template !== 'string' || !template) return ''
  const values = [taskId, byTaskId]
  let i = 0
  return template.replace(/%s/g, () => String(values[i++] ?? ''))
}

function zeroGoal(id, title) {
  return { id, title, fraction: 0, percent: 0, done: 0, total: 0, reached: false, stories: 0, decomposed: 0, failedStories: [] }
}

/**
 * The goal line that names the failed stories (E92_S10_T02, user decision 2026-11-15: "'Goal reached' när en story är
 * Failed: hindra det"; "procenten stannar på högst 99 % och mållinjen visar vilken story som är Failed i stället för
 * gratulationen"). board-progress.sh decides: while a counted story of the epic is in the failed bucket by its own status
 * (failed_stories, Failed and Blocked) goal_reached is false and percent is capped at 99. A view shows this text where it
 * would have shown the congratulation: the goal is not reached, the stated percent is at the cap (99) and failedStories
 * is not empty; below 99 the view's existing messages stay. One story: goal_failed with its id; more: goal_failed_more
 * with the first id (numeric order, as stated) and the count of the others. '' otherwise or when the label is missing.
 * `goal` is a goalFacts object (or anything with reached, percent and failedStories). Nothing is counted here.
 */
export function goalFailedText(labels, goal) {
  const g = goal && typeof goal === 'object' ? goal : {}
  const failed = arr(g.failedStories).filter(id => typeof id === 'string' && id)
  if (g.reached === true || failed.length === 0 || !(finite(g.percent) && g.percent >= 99)) return ''
  const key = failed.length === 1 ? 'goal_failed' : 'goal_failed_more'
  const template = labels && typeof labels[key] === 'string' ? labels[key] : ''
  if (!template) return ''
  return template.replace('%s', failed[0]).replace('%d', String(failed.length - 1))
}

/**
 * The words for a done task whose dependency is not done (E92_S11_T02): `dep_unfinished` with the one id for one unfinished
 * dependency, `dep_unfinished_more` with the first id (in the stated order) and the count of the others for more, the same
 * first-and-a-count choice as goalFailedText. `ids` is a task's (or group's) unfinishedDeps. '' for none or a missing label.
 */
export function unfinishedDepText(labels, ids) {
  const list = arr(ids).filter(id => typeof id === 'string' && id)
  if (list.length === 0) return ''
  const key = list.length === 1 ? 'dep_unfinished' : 'dep_unfinished_more'
  const template = labels && typeof labels[key] === 'string' ? labels[key] : ''
  if (!template) return ''
  return template.replace('%s', list[0]).replace('%d', String(list.length - 1))
}

function emptyStructure(goal) {
  return {
    empty: true,
    goal: goal || zeroGoal('', ''),
    stories: [],
    tasks: [],
    nodes: [],
    headers: [],
    bands: [],
    edges: [],
    boundary: [],
    foldable: [],
    expanded: [],
    ready: [],
    unlocked: [],
    columns: 0,
  }
}

const finite = v => typeof v === 'number' && Number.isFinite(v) && v >= 0

/** done / total from a payload `totals` object ({ done, denominator, ... }); null when it does not carry them. */
function fromTotals(totals) {
  if (!totals || typeof totals !== 'object') return null
  const denominator = totals.denominator
  if (!finite(totals.done) || !finite(denominator)) return null
  const buckets = {}
  for (const b of BUCKETS) buckets[b] = finite(totals[b]) ? totals[b] : 0
  return { done: totals.done, total: denominator, buckets }
}

/** Fallback when the payload carries no totals: read each task's own bucket; rejected and unknown are not counted. */
function fromTasks(list) {
  const buckets = {}
  for (const b of BUCKETS) buckets[b] = 0
  for (const t of list) if (t.bucket in buckets) buckets[t.bucket]++
  return { done: buckets.done, total: buckets.done + buckets.in_progress + buckets.failed + buckets.pending, buckets }
}

/**
 * Goal progress (E92_S09_T04): the epic's `epic_progress` as board-progress.sh states it, never recomputed (E92 decision 1).
 * percent and reached are the script's; fraction is percent / 100 (the share the drawing scales by); done/total are
 * tasks_done/tasks_denominator, the counts shown beside the percent; stories/decomposed let the view add decomposed/stories
 * when decomposed < stories, so the counts shown never contradict the percent. No epic_progress: the zero goal.
 * failedStories (E92_S10_T02) is the stated failed_stories; goalFailedText() turns it into the goal line.
 */
function goalFacts(id, title, epicProgress) {
  const ep = epicProgress && typeof epicProgress === 'object' ? epicProgress : {}
  const percent = finite(ep.percent) ? Math.min(100, Math.floor(ep.percent)) : 0
  const count = v => (finite(v) ? Math.floor(v) : 0)
  return {
    id,
    title,
    fraction: percent / 100,
    percent,
    done: count(ep.tasks_done),
    total: count(ep.tasks_denominator),
    reached: ep.goal_reached === true,
    stories: count(ep.stories),
    decomposed: count(ep.decomposed),
    // E92_S10_T02: the epic's failed stories as the script states them (strings only, [] without the key)
    failedStories: arr(ep.failed_stories).filter(id => typeof id === 'string' && id),
  }
}

/** A story entry's own depends_on, cleaned like a task's (strings only, the task itself dropped). [] without an entry. */
function storyDepsOf(entry, taskId) {
  return entry ? arr(entry.depends_on).filter(d => typeof d === 'string' && d && d !== taskId) : []
}

/**
 * The gate of one task: the padlock rule for every task state (E92_S10_T01, user decision 2026-11-15: "Om den inte är
 * genomförd och har beroenden som inte är uppfyllda ska det vara ett stängt lås, annars ska det alltid visas ett öppet lås
 * oavsett status på ärendet"). It reads the task's EFFECTIVE dependencies, its own depends_on plus its story's (E92_S09_T02):
 *   none    when there are no effective dependencies at all (no padlock);
 *   locked  when the task is NOT in the done bucket AND at least one effective dependency is unsatisfied;
 *   open    in every other case: a done task (always, whatever its dependencies), and any other task (ready, in progress,
 *           failed, rejected, unknown) whose effective dependencies are all satisfied.
 * "Satisfied" is never decided here: the script states it. `waiting_on` (board-progress.sh --graph, E92_S10_T01) lists the
 * unsatisfied effective ids of every task not in the done bucket, by the script's one rule (the named item is in the done
 * bucket through its own status, or is rejected); for a pending task it equals `blocked_by`, and a pending task with
 * unsatisfied ids has state `locked`. Any of the three closes the padlock on a task that is not done. A payload from an
 * older script has no waiting_on, so there only a locked pending task gets the closed padlock (a task in progress, failed
 * or rejected shows the open one, as the payload states nothing it waits for).
 */
function gateOf(t, dependsOn, storyDeps) {
  if (dependsOn.length === 0 && storyDeps.length === 0) return 'none'
  if (t.bucket === 'done') return 'open'
  const waiting = t.state === 'locked' || arr(t.blocked_by).length > 0 || arr(t.waiting_on).length > 0
  return waiting ? 'locked' : 'open'
}

/**
 * The stated `unfinished_deps` of a task (board-progress.sh --graph, E92_S11_T02): strings only, de-duplicated, in the
 * stated order (own depends_on first, then the story's). [] when absent. Read, never derived: whether a dependency is
 * done is the script's call, and the script states the key for a task in the done bucket only.
 */
function unfinishedOf(t) {
  return [...new Set(arr(t.unfinished_deps).filter(d => typeof d === 'string' && d))]
}

/** Longest dependency path per node, cycle-safe: bounded relaxation, at most n passes, so a cycle cannot hang. */
function computeColumns(ids, deps) {
  const col = new Map(ids.map(id => [id, 0]))
  const max = ids.length
  for (let pass = 0; pass < max; pass++) {
    let changed = false
    for (const id of ids) {
      for (const d of deps.get(id)) {
        if (!col.has(d)) continue
        const next = Math.min(col.get(d) + 1, max - 1)
        if (col.get(id) < next) { col.set(id, next); changed = true }
      }
    }
    if (!changed) break
  }
  return col
}

/** Transitive closure over `next` (id -> ids), the start excluded; cycle-safe through the visited set. */
function closure(start, next) {
  const seen = new Set()
  const stack = [...(next.get(start) || [])]
  while (stack.length) {
    const id = stack.pop()
    if (seen.has(id) || id === start) continue
    seen.add(id)
    for (const n of next.get(id) || []) stack.push(n)
  }
  return [...seen].sort()
}

/**
 * The structure of the dependency tree of one epic, folded (no group expanded). Accepts the full-board payload or a
 * `--within`-restricted one and selects the epic itself, so both give the same structure. `options.includeUndecomposed === true`
 * adds the ghost bands and the `undecomposed` flags described at the top of this file; without it nothing changes.
 */
export function buildDependencyStructure(graph, epicId, labels, options) {
  if (!graph || typeof graph !== 'object' || typeof epicId !== 'string' || !epicId) return emptyStructure()
  const lab = labels || graph.labels || {}
  const allTasks = arr(graph.tasks).filter(t => t && typeof t === 'object')
  const tasks = allTasks.filter(t => t.epic_id === epicId).slice().sort(byId)
  const epicEntry = arr(graph.epics).find(e => e && e.id === epicId)
  const epicTitle = (epicEntry && epicEntry.title) || ''
  const goal = goalFacts(epicId, epicTitle, epicEntry && epicEntry.epic_progress)
  if (tasks.length === 0) return emptyStructure(goal)

  const taskIds = new Set(tasks.map(t => t.id))
  const depsOf = new Map() // task id -> its depends_on (self-references dropped, de-duplicated, sorted)
  const outside = new Set()
  for (const t of tasks) {
    const list = [...new Set(arr(t.depends_on).filter(d => typeof d === 'string' && d && d !== t.id))].sort()
    depsOf.set(t.id, list)
    for (const d of list) if (!taskIds.has(d)) outside.add(d)
  }
  // No early return without edges: an epic with tasks always gets its tree (E92_S09_T01); only zero tasks is empty (above).

  // Boundary nodes: only {id, status, bucket}, from the payload's tasks, else its `external` list.
  const lookup = new Map()
  for (const x of arr(graph.external)) if (x && x.id) lookup.set(x.id, x)
  for (const x of allTasks) lookup.set(x.id, x)
  const boundary = [...outside].sort().map(id => {
    const x = lookup.get(id) || {}
    return { id, status: x.status ?? '', bucket: x.bucket ?? '' }
  })

  // Dependents inside the epic, and the in-epic dependencies the depth is built on.
  const inner = new Map(tasks.map(t => [t.id, depsOf.get(t.id).filter(d => taskIds.has(d))]))
  const dependents = new Map(tasks.map(t => [t.id, []]))
  for (const t of tasks) for (const d of inner.get(t.id)) dependents.get(d).push(t.id)
  for (const list of dependents.values()) list.sort()
  const cols = computeColumns(tasks.map(t => t.id), inner)

  const storyEntries = new Map(arr(graph.stories).filter(s => s && s.id).map(s => [s.id, s]))
  // E92_S12_T02: with includeUndecomposed, a story of this epic stated `decomposed: false` that has no task nodes is a ghost band
  const withUndecomposed = !!options && options.includeUndecomposed === true
  const taskStoryIds = new Set(tasks.map(t => t.story_id))
  const ghostIds = withUndecomposed
    ? arr(graph.stories).filter(s => s && s.id && s.epic_id === epicId && s.decomposed === false && !taskStoryIds.has(s.id)).map(s => s.id)
    : []
  const storyIds = [...new Set([...taskStoryIds, ...ghostIds])].sort()
  const stories = storyIds.map(sid => {
    const entry = storyEntries.get(sid)
    const figures = fromTotals(entry && entry.totals) || fromTasks(tasks.filter(t => t.story_id === sid))
    return {
      storyId: sid,
      title: (entry && entry.title) || '',
      done: figures.done,
      total: figures.total,
      buckets: figures.buckets,
      ...(withUndecomposed && entry && entry.decomposed === false ? { undecomposed: true } : {}),
    }
  })
  const rowOf = new Map(storyIds.map((sid, i) => [sid, i]))

  const taskFacts = tasks.map(t => {
    const dependsOn = depsOf.get(t.id)
    const gate = gateOf(t, dependsOn, storyDepsOf(storyEntries.get(t.story_id), t.id))
    const unfinished = unfinishedOf(t)
    return {
      kind: 'task',
      id: t.id,
      title: t.title ?? '',
      storyId: t.story_id,
      state: t.state,
      bucket: t.bucket ?? '',
      row: rowOf.get(t.story_id),
      column: cols.get(t.id),
      gate,
      mark: MARKED.has(t.state) ? t.state : 'none',
      dependsOn,
      unlocks: dependents.get(t.id),
      upstream: closure(t.id, depsOf),
      downstream: closure(t.id, dependents),
      ...(unfinished.length > 0 ? { unfinishedDeps: unfinished } : {}),
    }
  })

  const ready = tasks.filter(t => t.state === 'ready').map(t => ({ id: t.id, title: t.title ?? '', storyId: t.story_id }))
  const unlocked = tasks
    .filter(t => typeof t.unlocked_by === 'string' && t.unlocked_by)
    .map(t => ({ taskId: t.id, text: fillUnlockedBy(lab.unlocked_by, t.id, t.unlocked_by) }))

  return foldStructure({ empty: false, goal, stories, tasks: taskFacts, boundary, ready, unlocked }, [])
}

/** Id of the group of the tasks of one state in one story and column. */
export const groupId = (sid, column, state) => `group:${sid}|${column}|${state}`

/** Facts of one folded group: the union of its members' dependsOn, unlocks and chains, the members excluded. */
export function groupFacts(sid, column, state, members) {
  const ids = new Set(members.map(m => m.id))
  const union = key => [...new Set(members.flatMap(m => m[key]))].filter(id => !ids.has(id)).sort()
  const gates = members.map(m => m.gate)
  return {
    kind: 'group',
    id: groupId(sid, column, state),
    members: members.map(m => m.id),
    count: members.length,
    state,
    storyId: sid,
    row: members[0].row,
    column,
    gate: gates.every(g => g === 'none') ? 'none' : gates.includes('locked') ? 'locked' : 'open',
    mark: MARKED.has(state) ? state : 'none',
    dependsOn: union('dependsOn'),
    unlocks: union('unlocks'),
    upstream: union('upstream'),
    downstream: union('downstream'),
    ...(members.some(m => m.unfinishedDeps) ? { unfinishedDeps: [...new Set(members.flatMap(m => m.unfinishedDeps || []))].sort() } : {}),
  }
}

/**
 * Fold the facts for a given set of expanded group ids. Cells are (story band, column); inside a cell the tasks are
 * ordered by state, then id. A state with more than FOLD_THRESHOLD tasks in one cell folds into one group node unless its
 * id is in `expandedIn`, in which case a collapse header precedes the members. Returns the structure: the facts it was
 * given plus nodes, headers, bands (with their cells), edges, foldable, expanded and columns. Pure; the input is not changed.
 * A story fact flagged `undecomposed` (E92_S12_T02) keeps its band, with no cells when it has no task, so folding and unfolding
 * a model that carries ghost bands gives them back.
 */
export function foldStructure(m, expandedIn) {
  const expanded = new Set(expandedIn)
  const ctask = new Map(m.tasks.map(t => [t.id, t]))
  const maxCol = m.tasks.reduce((x, t) => Math.max(x, t.column), 0)

  const nodes = []
  const headers = []
  const bands = []
  const foldable = []
  const visibleOf = new Map() // task id -> visible node id

  m.stories.forEach((story, row) => {
    const inStory = m.tasks.filter(t => t.storyId === story.storyId)
    const byColumn = new Map()
    for (const t of inStory) {
      if (!byColumn.has(t.column)) byColumn.set(t.column, [])
      byColumn.get(t.column).push(t)
    }
    const cells = []
    for (const [column, list] of [...byColumn].sort((a, b) => a[0] - b[0])) {
      list.sort((a, b) => stateRank(a.state) - stateRank(b.state) || cmp(a.id, b.id))
      const count = {}
      for (const t of list) count[t.state] = (count[t.state] || 0) + 1
      const slots = []
      const done = new Set()
      const addNode = (facts, members) => {
        const node = { ...facts, slot: slots.length }
        slots.push({ type: 'node', node })
        nodes.push(node)
        if (members) for (const mem of members) visibleOf.set(mem.id, facts.id)
        else visibleOf.set(facts.id, facts.id)
      }
      for (const t of list) {
        if (count[t.state] > FOLD_THRESHOLD) {
          const gid = groupId(story.storyId, column, t.state)
          const members = list.filter(x => x.state === t.state)
          if (!done.has(gid)) foldable.push(gid)
          if (expanded.has(gid)) {
            if (!done.has(gid)) {
              done.add(gid)
              const header = { kind: 'header', id: gid, state: t.state, count: members.length, row, column }
              slots.push({ type: 'header', header })
              headers.push(header)
            }
            addNode(t)
          } else if (!done.has(gid)) {
            done.add(gid)
            addNode(groupFacts(story.storyId, column, t.state, members), members)
          }
        } else addNode(t)
      }
      cells.push({ column, slots })
    }

    // E92_S12_T02: a story flagged undecomposed with no task nodes is a ghost band (empty cells, flag on the band too)
    const ghost = story.undecomposed === true && inStory.length === 0
    bands.push({
      storyId: story.storyId,
      row,
      start: {
        kind: 'start',
        id: `story:${story.storyId}`,
        storyId: story.storyId,
        title: story.title,
        done: story.done,
        total: story.total,
        buckets: story.buckets,
        ...(story.undecomposed === true ? { undecomposed: true } : {}),
      },
      cells,
      ...(ghost ? { undecomposed: true } : {}),
    })
  })

  // Edges between the visible nodes, de-duplicated; a group stands for all of its members.
  const edges = []
  const seen = new Set()
  const add = (from, to, crossStory, kind) => {
    const key = `${from}>${to}`
    if (seen.has(key)) return
    seen.add(key)
    edges.push({ from, to, crossStory, kind })
  }
  for (const t of m.tasks) {
    const to = visibleOf.get(t.id)
    let inEpic = 0
    for (const d of t.dependsOn) {
      const dep = ctask.get(d)
      if (dep) { inEpic++; add(visibleOf.get(d), to, dep.storyId !== t.storyId, 'dependency') }
      else add(d, to, true, 'boundary')
    }
    if (inEpic === 0) add(`story:${t.storyId}`, to, false, 'start')
    if (t.unlocks.length === 0) add(to, GOAL_NODE_ID, false, 'goal')
  }
  // E92_S12_T02: a ghost band has no task to reach the goal through, so its start node gets its own (dashed) edge to it
  for (const band of bands) if (band.undecomposed) add(band.start.id, GOAL_NODE_ID, false, 'ghost')

  return {
    empty: m.empty,
    goal: m.goal,
    stories: m.stories,
    tasks: m.tasks,
    boundary: m.boundary,
    ready: m.ready,
    unlocked: m.unlocked,
    nodes,
    headers,
    bands,
    edges,
    foldable: [...new Set(foldable)].sort(),
    expanded: [...expanded].filter(id => foldable.includes(id)).sort(),
    columns: maxCol + 1,
  }
}
