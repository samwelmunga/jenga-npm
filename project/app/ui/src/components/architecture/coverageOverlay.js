// coverageOverlay.js
// E83_S03_T03: pure helpers for the read-only test-coverage overlay on the SAD map. Kept out of
// SADMap.jsx so the badge / tooltip rules can be unit tested without rendering the component.
//
// Payload shape (E83_S03_T02, project/app/api/parsers/knowledge-graph.js): every rendered node carries
// `tests: Array<{name, type, file, line}>`; a ghost stub (`verified: false`) always carries `tests: []`.

export const MAX_TEST_TITLE_LINES = 8

/** The node's test links as an array (a missing or non-array `tests` reads as none). */
export function nodeTests(node) {
  return node && Array.isArray(node.tests) ? node.tests : []
}

/**
 * True when the node gets a covered badge and test lines: a real (non-cluster), verified (non-ghost)
 * node with at least one test. Cluster nodes and ghost stubs are never presented as covered.
 */
export function isCoveredNode(node) {
  if (!node || node.isCluster || node.verified === false) return false
  return nodeTests(node).length > 0
}

/** One tooltip line per test, `<type> · <name> · <file>:<line>`. */
export function formatTestLine(test) {
  return `${test.type} · ${test.name} · ${test.file}:${test.line}`
}

/** Tooltip lines for a list of tests, capped at `cap` with a trailing `+N more` line. */
export function testTitleLines(tests, cap = MAX_TEST_TITLE_LINES) {
  const list = Array.isArray(tests) ? tests : []
  const lines = list.slice(0, cap).map(formatTestLine)
  if (list.length > cap) lines.push(`+${list.length - cap} more`)
  return lines
}

/** The node title with its test lines appended (one per line); unchanged for a non-covered node. */
export function titleWithTests(baseTitle, node) {
  if (!isCoveredNode(node)) return baseTitle
  return [baseTitle, ...testTitleLines(node.tests)].join('\n')
}

// E83_S03_T04: helpers for the "Test coverage" table below the map. Same payload, same read-only rules.

// Plain code-point comparison, so the order does not depend on the viewer's locale.
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0)

/**
 * One row per (covered node, test), sorted by node label then test name. Id, file and line break ties so the
 * order is stable. Rows come from `isCoveredNode`, so a ghost stub never yields one.
 */
export function coverageRows(nodes) {
  const rows = []
  for (const node of Array.isArray(nodes) ? nodes : []) {
    if (!isCoveredNode(node)) continue
    for (const test of nodeTests(node)) {
      rows.push({
        nodeId: String(node.id ?? ''),
        nodeLabel: String(node.label ?? node.id ?? ''),
        type: String(test.type ?? ''),
        name: String(test.name ?? ''),
        file: String(test.file ?? ''),
        line: test.line,
      })
    }
  }
  return rows.sort(
    (a, b) =>
      cmp(a.nodeLabel, b.nodeLabel) ||
      cmp(a.name, b.name) ||
      cmp(a.nodeId, b.nodeId) ||
      cmp(a.file, b.file) ||
      cmp(Number(a.line), Number(b.line))
  )
}

const count = (value) => (Number.isFinite(value) && value > 0 ? value : 0)

/** `N of M rendered nodes covered by tests`, or '' when no node is rendered (it would read "0 of 0"). */
export function coverageSummaryText(coverage) {
  const shown = count(coverage && coverage.shown)
  if (shown === 0) return ''
  return `${count(coverage.testCovered)} of ${shown} rendered nodes covered by tests`
}

/**
 * The empty-state sentence. Names `testLinksUnrendered` when it is above 0 (spike D4/D6): links that exist but
 * point at nodes the map does not show (board-sourced, unverified, or absent from the graph).
 */
export function coverageEmptyText(coverage) {
  const base = 'No test links recorded for the nodes on this map.'
  const unrendered = count(coverage && coverage.testLinksUnrendered)
  if (unrendered === 0) return base
  const noun = unrendered === 1 ? 'test link exists' : 'test links exist'
  return `${base} ${unrendered} ${noun} for nodes that are not shown on this map (board-sourced or unverified).`
}
