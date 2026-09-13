/**
 * @file kanbanColumns.manual-verify.mjs
 * Manual verification script for E06_S05_T03's 10-day-stale
 * Deployed-to-Prod filter (AC #1, #2, #4) and, appended at the bottom of this
 * file, E06_S05_T04's `project/todo.md` promotion rule (its final AC bullet's
 * four fixture cases, plus the promoted-Backlog, ordering, and
 * no-`todo.md`-equivalence cases). The T03 section is unchanged — both run in
 * one invocation so a T04 change can never silently regress T03. Run directly
 * via:
 *
 *   node project/app/ui/src/components/board/kanbanColumns.manual-verify.mjs
 *
 * No test framework is wired up for project/app/ui (confirmed: no
 * jest/mocha/vitest config, no existing *.test.js* files anywhere under
 * project/app/ui). project/app/ui/package.json sets "type": "module" and
 * kanbanColumns.js uses only standard ESM/JS (no JSX, no bundler-specific
 * syntax), so it can be imported and exercised directly by Node with no
 * build step.
 *
 * This is a constructed-fixture verification, not a live-data one: as of
 * 2026-09-12 no real board ticket carries a `date_deployed_prod` value yet
 * (E51_S05 only just shipped the field) — confirmed via grep across
 * project/board/. The fixture below mirrors the exact shape
 * project/app/api/parsers/board.js's parseBoard() produces (flat
 * frontmatter fields spread onto each task/story/epic object, tagged with
 * _itemType by flattenBoardItems), so it is a faithful stand-in for what
 * GET /v1/board will return once real stale/fresh Deployed to Prod tickets
 * exist.
 *
 * REGRESSION NOTE (post-tester-rework): the first version of this script
 * only ever fed `isStaleDeployedProd()`/`bucketIntoColumns()` plain JS date
 * *strings* built directly in JS. The tester found that real board data
 * never actually takes that shape — `project/app/api/parsers/board.js`'s
 * `parseBoard()` uses gray-matter, whose default YAML schema auto-parses an
 * unquoted `YYYY-MM-DD` scalar (exactly what `scripts/mark-deployed.sh`
 * writes) into a native JS `Date` object, not a string. The original
 * `isStaleDeployedProd()` assumed a string and silently fell into its
 * "unparseable -> not stale" fail-safe for every real `Date` input, making
 * the filter a no-op in production despite this script passing cleanly. See
 * project/rapports/problems/E06_S05_T03-stale-filter-fails-on-real-gray-matter-date-objects.md
 * for the full root-cause writeup. The fix (this revision) makes
 * `isStaleDeployedProd()` accept both a string and a `Date` instance
 * explicitly; the checks below now cover BOTH shapes so this exact class of
 * type-mismatch bug is caught here next time, not only downstream by the
 * tester's own live-data reproduction.
 *
 * A best-effort real-gray-matter round-trip check (mirroring the tester's
 * own reproduction method) runs at the bottom of this script if `gray-matter`
 * is resolvable from this environment; it is skipped with a clear note
 * (not a failure) if it isn't, since git worktrees don't carry `node_modules`
 * and this script must still be runnable standalone.
 */

import assert from 'node:assert/strict'
import { flattenBoardItems, bucketIntoColumns, isStaleDeployedProd } from './kanbanColumns.js'

// Fixed "today" so this script's assertions never depend on wall-clock time.
const TODAY = new Date('2026-09-12T12:00:00Z')

function daysAgoISO(days) {
  const d = new Date(TODAY.getTime() - days * 24 * 60 * 60 * 1000)
  return d.toISOString().slice(0, 10) // YYYY-MM-DD
}

// A UTC-midnight Date instance, exactly the shape gray-matter/js-yaml
// produces for a bare `YYYY-MM-DD` YAML scalar (confirmed by the tester's
// reproduction: `date_deployed_prod: 2026-09-01T00:00:00.000Z` came back as
// a real `Date`, not the string `'2026-09-01'`).
function daysAgoDate(days) {
  return new Date(`${daysAgoISO(days)}T00:00:00Z`)
}

// --- Unit-level checks on isStaleDeployedProd (string input) ---------------

assert.equal(isStaleDeployedProd(daysAgoISO(11), 10, TODAY), true, '11 days ago (string) should be stale')
assert.equal(isStaleDeployedProd(daysAgoISO(10), 10, TODAY), false, 'exactly 10 days ago (string) should NOT be stale (boundary: "more than 10 days")')
assert.equal(isStaleDeployedProd(daysAgoISO(3), 10, TODAY), false, '3 days ago (string) should not be stale')
assert.equal(isStaleDeployedProd(undefined, 10, TODAY), false, 'absent date should not be stale')
assert.equal(isStaleDeployedProd(null, 10, TODAY), false, 'null date should not be stale')
assert.equal(isStaleDeployedProd('', 10, TODAY), false, 'empty-string date should not be stale')

console.log('isStaleDeployedProd unit checks (string input): PASS')

// --- Unit-level checks on isStaleDeployedProd (Date instance input) --------
// This is the production-shaped input (see REGRESSION NOTE above) — these
// are the checks that would have caught the tester's finding before hand-off.

assert.equal(isStaleDeployedProd(daysAgoDate(11), 10, TODAY), true, '11 days ago (Date instance) should be stale')
assert.equal(isStaleDeployedProd(daysAgoDate(10), 10, TODAY), false, 'exactly 10 days ago (Date instance) should NOT be stale')
assert.equal(isStaleDeployedProd(daysAgoDate(3), 10, TODAY), false, '3 days ago (Date instance) should not be stale')

console.log('isStaleDeployedProd unit checks (Date instance input): PASS')

// --- Fixture matching parseBoard()'s actual output shape --------------------
// (epic -> stories[] -> tasks[], each item carries the full frontmatter
// object spread onto it, per project/app/api/parsers/board.js parseBoard())
//
// `date_deployed_prod` values below are Date INSTANCES, not strings — this
// is the production shape (see REGRESSION NOTE at the top of this file). A
// second, string-valued fixture follows to confirm both shapes are handled.

function buildFixtureEpics(dateValues) {
  return [
    {
      id: 'E99',
      title: 'Synthetic verification epic',
      status: 'In Progress',
      stories: [
        {
          id: 'E99_S01',
          epic_id: 'E99',
          title: 'Synthetic verification story',
          status: 'In Progress',
          tasks: [
            {
              id: 'E99_S01_T01',
              story_id: 'E99_S01',
              title: 'Stale Deployed to Prod item (11 days old)',
              status: 'Deployed to Prod',
              date_deployed_prod: dateValues.stale,
            },
            {
              id: 'E99_S01_T02',
              story_id: 'E99_S01',
              title: 'Fresh Deployed to Prod item (3 days old)',
              status: 'Deployed to Prod',
              date_deployed_prod: dateValues.fresh,
            },
            {
              id: 'E99_S01_T03',
              story_id: 'E99_S01',
              title: 'Deployed to Prod item with no date_deployed_prod set',
              status: 'Deployed to Prod',
              // date_deployed_prod intentionally absent
            },
            {
              id: 'E99_S01_T04',
              story_id: 'E99_S01',
              title: 'Pending item (pre-existing filter, should still be excluded)',
              status: 'Pending',
            },
            {
              id: 'E99_S01_T05',
              story_id: 'E99_S01',
              title: 'Deployed to Stage item (unaffected by this filter)',
              status: 'Deployed to Stage',
            },
          ],
        },
      ],
    },
  ]
}

function runFixtureChecks(epics, label) {
  const flat = flattenBoardItems(epics)
  assert.equal(flat.length, 7, `[${label}] expected 1 epic + 1 story + 5 tasks = 7 flattened items`)

  const buckets = bucketIntoColumns(flat)

  // AC #1: stale Deployed to Prod item excluded
  const deployedProdIds = buckets['deployed-prod'].map((i) => i.id)
  assert.ok(!deployedProdIds.includes('E99_S01_T01'), `[${label}] AC#1 FAILED: stale (11-day) item must be excluded from Deployed to Prod column`)

  // AC #2: fresh item and no-date item still render normally
  assert.ok(deployedProdIds.includes('E99_S01_T02'), `[${label}] AC#2 FAILED: fresh (3-day) item must still render in Deployed to Prod column`)
  assert.ok(deployedProdIds.includes('E99_S01_T03'), `[${label}] AC#2 FAILED: item with no date_deployed_prod must render normally (not treated as stale)`)
  assert.equal(deployedProdIds.length, 2, `[${label}] Deployed to Prod column should contain exactly the fresh + no-date items`)

  // Pre-existing Pending filter (E06_S05_T02) must still work alongside the new one
  const allBucketedIds = Object.values(buckets).flat().map((i) => i.id)
  assert.ok(!allBucketedIds.includes('E99_S01_T04'), `[${label}] Pending item must still be excluded (pre-existing E06_S05_T02 filter)`)

  // Deployed to Stage unaffected by this filter
  assert.ok(buckets['deployed-stage'].map((i) => i.id).includes('E99_S01_T05'), `[${label}] Deployed to Stage item must be unaffected`)

  console.log(`bucketIntoColumns fixture checks (AC#1, AC#2) [${label}]: PASS`)
  console.log(`Deployed to Prod column after filtering [${label}]:`, deployedProdIds)
  return deployedProdIds
}

// Production-shaped fixture: Date instances (what gray-matter actually produces)
runFixtureChecks(
  buildFixtureEpics({ stale: daysAgoDate(11), fresh: daysAgoDate(3) }),
  'Date instance (production shape)'
)

// String-shaped fixture: plain ISO strings (also supported, e.g. for any
// future non-gray-matter caller or hand-constructed data)
runFixtureChecks(
  buildFixtureEpics({ stale: daysAgoISO(11), fresh: daysAgoISO(3) }),
  'string (secondary shape)'
)

console.log('\nAll checks passed (both Date-instance and string input shapes). AC#4 (verification against stale + fresh Deployed to Prod items) satisfied via constructed fixture — see file header for why no real live pair exists yet, and for the regression this revision specifically now covers.')

// --- Best-effort real gray-matter round-trip check --------------------------
// Mirrors the tester's own reproduction method: parse genuine YAML
// frontmatter (matching exactly what scripts/mark-deployed.sh writes)
// through the real gray-matter library, then feed the result through the
// real isStaleDeployedProd(). This is best-effort and SKIPPED (not failed)
// if gray-matter isn't resolvable — e.g. inside a git worktree, which does
// not carry node_modules.
try {
  const { createRequire } = await import('node:module')
  const require = createRequire(import.meta.url)
  const matter = require('gray-matter')

  const staleYaml = `---\nstatus: Deployed to Prod\ndate_deployed_prod: ${daysAgoISO(11)}\n---\ncontent`
  const freshYaml = `---\nstatus: Deployed to Prod\ndate_deployed_prod: ${daysAgoISO(3)}\n---\ncontent`

  const staleParsed = matter(staleYaml).data
  const freshParsed = matter(freshYaml).data

  assert.ok(staleParsed.date_deployed_prod instanceof Date, 'gray-matter should parse an unquoted YYYY-MM-DD scalar into a Date instance')
  assert.equal(isStaleDeployedProd(staleParsed.date_deployed_prod, 10, TODAY), true, 'real gray-matter-parsed stale date should be detected as stale')
  assert.equal(isStaleDeployedProd(freshParsed.date_deployed_prod, 10, TODAY), false, 'real gray-matter-parsed fresh date should NOT be detected as stale')

  console.log('\nReal gray-matter round-trip check: PASS (matches the tester\'s own reproduction method)')
} catch (err) {
  if (err && err.code === 'MODULE_NOT_FOUND') {
    console.log('\nReal gray-matter round-trip check: SKIPPED (gray-matter not resolvable in this environment, e.g. a git worktree with no node_modules). This is expected and not a failure — the Date-instance fixture checks above already exercise the exact same production-shaped input.')
  } else {
    throw err
  }
}

// ===========================================================================
// E06_S05_T04 — project/todo.md-queued items promoted into In Progress
// ===========================================================================
//
// Covers the four fixture cases the task's final AC bullet names — a promoted
// Pending item, an unreferenced Pending item, a terminal item still named in
// todo.md, and an unresolvable ref — plus three more the other AC bullets
// imply: a promoted Backlog item, the native-before-promoted ordering, and the
// "no todo.md ⇒ identical to pre-T04 behavior" equivalence case.
//
// The queued flags are derived by running the REAL parser
// (project/app/api/parsers/todo.js) over fixture todo.md content, rather than
// hand-setting `_queued` — so this harness exercises the actual comment
// stripping and ref extraction, not a restatement of them. That parser needs
// no third-party dependency (built-ins only), so unlike the gray-matter block
// above it runs even inside a git worktree with no node_modules.

import { createRequire } from 'node:module'

const requireCjs = createRequire(import.meta.url)
const { parseTodoContent } = requireCjs('../../../../api/parsers/todo.js')

// Mirrors project/app/api/parsers/board.js's queuedFlagFor(): tag an item with
// `_queued: true` iff its id is in the ref set (case-insensitive), and add no
// field at all otherwise.
function applyQueuedFlags(epics, refs) {
  const queued = new Set(refs.map((r) => r.toUpperCase()))
  const flag = (item) => (item.id && queued.has(item.id.toUpperCase()) ? { ...item, _queued: true } : item)
  return epics.map((epic) => ({
    ...flag(epic),
    stories: (epic.stories || []).map((story) => ({
      ...flag(story),
      tasks: (story.tasks || []).map(flag),
    })),
  }))
}

// Fixture todo.md content, covering every line shape the real file contains.
const FIXTURE_TODO_MD = `# Todo

<!-- Format: <mission title>: <E##_S##> (epic/story ref optional) -->

Promote this pending task: E98_S01_T01
Promote this backlog task: E98_S01_T04
Terminal item still named by a stale line: E98_S01_T03
invoke /brainstorm project/rapports/analysis/some-eval.md
A deleted/renamed item that no longer exists on the board: E98_S99_T99
Epic-only ref, deliberately not promoted (see todo.js header): E98
<!-- RECONCILED: Already done, must never be promoted: E98_S01_T02 ✅ -->
Cites a rapport filename mid-line (project/rapports/problems/E98_S01_T05-some-note.md) but queues nothing.
`

const fixtureRefs = parseTodoContent(FIXTURE_TODO_MD).refs

assert.deepEqual(
  fixtureRefs,
  ['E98_S01_T01', 'E98_S01_T04', 'E98_S01_T03', 'E98_S99_T99'],
  'T04 parser: only the four trailing story/task refs on active lines should be extracted — not the commented E98_S01_T02, not the epic-only E98, not the mid-line filename E98_S01_T05'
)

console.log('todo.md ref extraction (comment skipping, no-ref lines, mid-line filename, epic-only ref): PASS')

function buildT04FixtureEpics() {
  return [
    {
      id: 'E98',
      title: 'Synthetic todo.md-promotion epic',
      status: 'In Progress',
      stories: [
        {
          id: 'E98_S01',
          epic_id: 'E98',
          title: 'Synthetic todo.md-promotion story',
          status: 'In Progress',
          tasks: [
            {
              id: 'E98_S01_T01',
              story_id: 'E98_S01',
              title: 'Pending task queued in todo.md (must be promoted)',
              status: 'Pending',
            },
            {
              id: 'E98_S01_T02',
              story_id: 'E98_S01',
              title: 'Pending task NOT queued in todo.md (must stay excluded)',
              status: 'Pending',
            },
            {
              id: 'E98_S01_T03',
              story_id: 'E98_S01',
              title: 'Terminal (Merged) task still named in todo.md (must NOT be promoted)',
              status: 'Merged',
            },
            {
              id: 'E98_S01_T04',
              story_id: 'E98_S01',
              title: 'Backlog task queued in todo.md (must be promoted)',
              status: 'Backlog',
            },
            {
              id: 'E98_S01_T05',
              story_id: 'E98_S01',
              title: 'Natively In Progress task, not queued (must render unmarked)',
              status: 'In Progress',
            },
          ],
        },
      ],
    },
  ]
}

// --- With a todo.md present -------------------------------------------------

const t04Flat = flattenBoardItems(applyQueuedFlags(buildT04FixtureEpics(), fixtureRefs))
const t04Buckets = bucketIntoColumns(t04Flat)
const inProgressIds = t04Buckets['in-progress'].map((i) => i.id)

// AC: a todo.md-referenced item that T02's Pending exclusion would have
// dropped is shown in In Progress — promotion wins over the exclusion.
assert.ok(inProgressIds.includes('E98_S01_T01'), 'AC FAILED: queued Pending task must appear in In Progress (promotion wins over the Pending exclusion)')
assert.ok(inProgressIds.includes('E98_S01_T04'), 'AC FAILED: queued Backlog task must appear in In Progress')

// AC: an unreferenced Pending item stays excluded from the whole view.
const t04AllIds = Object.values(t04Buckets).flat().map((i) => i.id)
assert.ok(!t04AllIds.includes('E98_S01_T02'), 'AC FAILED: unreferenced Pending task must remain excluded from every column')

// AC: an item past Pending/Backlog keeps its own status column even though a
// stale todo.md line still names it.
assert.ok(!inProgressIds.includes('E98_S01_T03'), 'AC FAILED: Merged task named by a stale todo.md line must NOT be pulled into In Progress')
assert.ok(t04Buckets['merged'].map((i) => i.id).includes('E98_S01_T03'), 'AC FAILED: Merged task must stay in the Merged column')
assert.equal(t04Buckets['merged'][0]._promotedFromStatus, undefined, 'a non-promoted item must never carry _promotedFromStatus')

// AC: a ref resolving to nothing on the board (E98_S99_T99) is ignored without
// breaking the render — it matches no item, so no phantom card appears.
assert.ok(fixtureRefs.includes('E98_S99_T99'), 'fixture sanity: the unresolvable ref should have been parsed out of todo.md')
assert.ok(!t04AllIds.includes('E98_S99_T99'), 'AC FAILED: an unresolvable todo.md ref must not produce a phantom card')
// The fixture's own epic and story are themselves natively In Progress, so the
// column holds 5 items: E98, E98_S01, E98_S01_T05 (native) + T01, T04 (promoted).
assert.deepEqual(
  inProgressIds.slice().sort(),
  ['E98', 'E98_S01', 'E98_S01_T01', 'E98_S01_T04', 'E98_S01_T05'],
  'In Progress should contain exactly the three natively-In Progress items plus the two promoted tasks — no extras, no duplicates'
)

// AC: promoted items are distinguishable from natively-In Progress ones.
const byId = Object.fromEntries(t04Buckets['in-progress'].map((i) => [i.id, i]))
assert.equal(byId['E98_S01_T01']._promotedFromStatus, 'Pending', 'promoted card must record the status it was promoted from (render marker depends on it)')
assert.equal(byId['E98_S01_T04']._promotedFromStatus, 'Backlog', 'promoted Backlog card must record Backlog as its origin status')
assert.equal(byId['E98_S01_T05']._promotedFromStatus, undefined, 'natively-In Progress card must carry no promotion marker')
assert.equal(byId['E98_S01_T01'].status, 'Pending', 'promotion must not rewrite the item\'s real status (StatusBadge still shows it)')

// Ordering: native In Progress work reads before merely-queued items.
assert.deepEqual(
  inProgressIds,
  ['E98', 'E98_S01', 'E98_S01_T05', 'E98_S01_T01', 'E98_S01_T04'],
  'natively-In Progress items must sort ahead of promoted ones, with board order preserved inside each group (stable sort)'
)

// The source items must never be mutated by bucketing.
const pristine = flattenBoardItems(applyQueuedFlags(buildT04FixtureEpics(), fixtureRefs))
assert.ok(pristine.every((i) => i._promotedFromStatus === undefined), 'bucketIntoColumns must not mutate its input items')

console.log('todo.md promotion checks (promoted Pending, promoted Backlog, unreferenced Pending, terminal item, unresolvable ref, marker, ordering, no-mutation): PASS')
console.log('In Progress column with a todo.md present:', inProgressIds)

// --- With NO todo.md present (no item carries _queued) ----------------------
// Byte-identical-to-pre-T04 case: the Pending items are excluded again, the
// Backlog item returns to the Backlog column, In Progress holds only native
// work, and nothing is marked as promoted.

const noTodoBuckets = bucketIntoColumns(flattenBoardItems(buildT04FixtureEpics()))
const noTodoIdsByColumn = Object.fromEntries(
  Object.entries(noTodoBuckets).map(([key, items]) => [key, items.map((i) => i.id)])
)

assert.deepEqual(noTodoIdsByColumn['in-progress'], ['E98', 'E98_S01', 'E98_S01_T05'], 'no-todo.md case: In Progress must contain only the natively-In Progress epic, story and task')
assert.deepEqual(noTodoIdsByColumn['backlog'], ['E98_S01_T04'], 'no-todo.md case: the Backlog task must stay in the Backlog column')
assert.deepEqual(noTodoIdsByColumn['merged'], ['E98_S01_T03'], 'no-todo.md case: the Merged task must stay in the Merged column')
assert.deepEqual(noTodoIdsByColumn['pending'], [], 'no-todo.md case: the Pending column stays empty (both Pending tasks excluded from the view)')
assert.ok(
  Object.values(noTodoBuckets).flat().every((i) => i._promotedFromStatus === undefined),
  'no-todo.md case: no card may be marked as promoted'
)

console.log('no-todo.md equivalence checks (Active Sprint renders exactly as pre-T04): PASS')
console.log('\nAll E06_S05_T04 checks passed.')
