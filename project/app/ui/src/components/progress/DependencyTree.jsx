import { useRef, useState } from 'react'
import './dependency-tree.css'
import { GOAL_NODE_ID, goalFailedText, LAYOUT, unfinishedDepText, unfoldGroups } from './dependencyTreeModel'
import { toggleLabelKey } from './fullscreenModel'
import FullscreenToggle from './FullscreenToggle'
import { GOAL_RENDERERS } from './goalDesigns'
import { GOAL_DESIGN_GROUP_LABEL_KEY, GOAL_DESIGNS, readGoalDesign, registeredDesigns, resolveGoalDesign, writeGoalDesign } from './goalDesignModel'
import GoalDesignSelector from './GoalDesignSelector'
import useFocusContain from './useFocusContain'
import useFullscreen from './useFullscreen'
import useZoomPan from './useZoomPan'
import ZoomControls from './ZoomControls'
import { transformOf } from './zoomPanModel'

/**
 * DependencyTree — E92_S06_T10, rendering reworked to dependency-tree v2 by E92_S06_T20.
 *
 * Renders the model of buildDependencyTreeModel (dependencyTreeModel.js) as SVG, geometry and behaviour copied from the
 * approved prototype (project/documentation/prototypes/E92_S06/tree-prototype.html). Takes `{ model, labels }` and
 * fetches nothing. All numbers (columns, bands, node boxes, the goal) come from the model; this file draws them.
 *
 * Paint order, bottom to top: story bands, edges (so no band fill can hide a line), story start nodes, boundary nodes,
 * collapse headers, cards, goal. Edges run from the right edge of the dependency to the left edge of the dependent.
 *
 *   - A state is never conveyed by colour alone: a done tick, in-progress half dot, ready plus or failed cross sits on
 *     the RIGHT of a card; a locked card shows only the closed padlock gate on its LEFT edge (no status mark). The gate
 *     is the dependency: closed = waiting, open = every dependency done, none = the task has no dependency. Since
 *     E92_S09_T02 the gate counts the story's depends_on too, and every `ready` card (dashed border, ring, plus) looks the
 *     same with or without dependencies: the gate badge is the only difference.
 *   - A done card whose dependency is not done (the model's unfinishedDeps, from board-progress.sh's unfinished_deps,
 *     E92_S11_T02, user decision 2026-11-15) shows a "?" in the in-progress yellow at the mark position, in place of its
 *     tick, with a <title> tooltip naming the dependency (dep_unfinished / dep_unfinished_more); the tooltip and the
 *     card's aria-label say it in words, so the "?" is the non-colour cue. It is still a done card (class, padlock, counts).
 *   - Hovering or focusing a card highlights its whole upstream and downstream chain and dims the rest; a tooltip lists
 *     the direct dependencies and what it unlocks. A group of more than FOLD_THRESHOLD same-state tasks is one stacked
 *     card; click or Enter expands it, an expanded group gets a collapse header. Expansion state lives here and uses
 *     unfoldGroups from the model.
 *   - The goal is drawn by the chosen goal design (E92_S13_T05). The designs are one ordered list (goalDesignModel.js:
 *     star, citadel, facade, seasons tree) and a renderer registry (goalDesigns.js); a design without a renderer is absent.
 *     The goal slot below picks the renderer of the chosen design (the stored choice, else the default: the citadel while it
 *     is registered, else the first registered design) and draws its defs and its drawing, and GoalDesignSelector (next to
 *     the zoom controls, hidden with fewer than two registered designs) changes it for the page and stores it per browser.
 *     The star is the Goal node as it was before (StarGoal.jsx): a star in a disc with a progress ring whose halo strength
 *     and radius and fill grow with the completed share; at 100 % it turns done-green, shimmers and twinkles five sparks.
 *     The text under the node (name, title, count, decomposed) is drawn here for every design. `renderers` is the
 *     registry (default GOAL_RENDERERS) and `designs` the ordered list (default GOAL_DESIGNS); a test passes its own to
 *     register designs that are not built yet and to add a further entry.
 *   - Every word comes from `labels` (the progress payload, scripts/lib/progress-labels.sh). Colours are
 *     var(--color-*) tokens only, set in dependency-tree.css. No colour literal here.
 *   - Animation is CSS only and lives in dependency-tree.css, stopped by prefers-reduced-motion: reduce and by
 *     :root[data-motion="off"].
 *   - E92_S06_T21: the drawing sits in a zoom and pan viewport (useZoomPan, zoomPanModel.js): wheel zooms about the cursor
 *     (ctrl faster), a drag pans, two pointers pinch, and ZoomControls offers minus, plus, Fit and 100 % with a percent
 *     readout. Fit runs on the first render and when the epic changes, never on a refresh of the same epic. The viewport
 *     owns the size of the drawing, so it is no longer given a minimum width.
 *   - E92_S12_T03: a story the payload states undecomposed (no task, or no counted task: the model's `undecomposed` flag on
 *     the band and on the start node, E92_S12_T02) is drawn as an empty slot: its band and start node get a dashed outline
 *     (9 4, longer than every other dash on the map: ready card 5 3, rejected card 2 3, boundary 3 3, cross-story edge
 *     2 5, ready edge 6 6), the start node keeps its id, title and 0/0 and shows the short text of the story_undecomposed
 *     label where the mini bar would be (no bar is drawn, so it never reads as 0 % progress), it has an aria label made from
 *     story_undecomposed_aria, and a `ghost` edge (dash-dot) runs from it to the goal. Both labels are read with optLabel:
 *     there is no English fallback, a payload without them keeps the dashed outline and omits the text. Nothing here
 *     assumes a band has a task node.
 *   - E92_S07_T07: the large view. FullscreenToggle (next to the zoom controls) opens the tree's own root section.dep-tree
 *     large through useFullscreen (Fullscreen API, fixed-layer fallback), useFocusContain keeps focus inside it, and the
 *     root carries data-fullscreen while open. The root is never re-parented or remounted, so zoom, pan, hover, expanded
 *     groups and the Animations toggle are kept; Fit is not re-run (useZoomPan keepCentreOnResize only keeps the centre).
 */

const NODE_W = LAYOUT.cardW
const NODE_H = LAYOUT.cardH
const PAD = 12
const GOAL_GAP = 40
const BOUNDARY_ROW = 56
const TITLE_MAX = 25

const clip = (s, n) => (typeof s === 'string' && s.length > n ? s.slice(0, n - 1) + '…' : s || '')
// E92_S10_T02: the failed-story goal line is longer than the goal's room, so it wraps on spaces into lines of at most n
// characters (a longer word stays whole on its own line); the lines are drawn as tspans under the goal.
const wrapWords = (s, n) => {
  const lines = []
  for (const w of String(s || '').split(' ').filter(Boolean)) {
    const last = lines.length - 1
    if (last >= 0 && lines[last].length + 1 + w.length <= n) lines[last] += ' ' + w
    else lines.push(w)
  }
  return lines
}
const GOAL_LINE_H = 15
const safeId = s => String(s).replace(/[^A-Za-z0-9_-]/g, '')

/** Fallbacks for a labels object that lacks a key (the labels come from the progress payload). */
const FALLBACK = {
  goal: 'Goal',
  ready_to_take: 'Ready to take',
  nothing_ready: 'Nothing ready to take',
  tree_empty: 'No tasks to show',
  state_done: 'Done',
  state_ready: 'Ready',
  state_locked: 'Locked',
  state_failed: 'Failed',
  state_rejected: 'Rejected',
  in_progress: 'In progress',
  gate_waiting: 'Waiting for a dependency (locked)',
  gate_open: 'Dependency done (unlocked)',
  group_tasks: '%d tasks',
  show_all: 'Show all %d',
  collapse: 'Collapse',
  goal_reached: 'Goal reached!',
  goal_failed: 'Goal not reached - %s has failed',
  goal_failed_more: 'Goal not reached - %s and %d more have failed',
  dep_unfinished: 'Done although dependency %s is not done - check the dependency',
  dep_unfinished_more: 'Done although dependency %s and %d more are not done - check the dependencies',
  goal_progress: '%d / %d done · %d %%',
  epic_decomposed: '%d/%d stories decomposed',
  tip_depends_on: 'Depends on',
  tip_unlocks: 'Unlocks',
  tip_goal_direct: 'Leads straight to the goal',
  goal_design_group: 'Goal design',
  goal_design_star: 'Star',
  goal_design_citadel: 'Citadel',
  goal_design_facade: 'Facade',
  goal_design_tree: 'Seasons tree',
  castle_tower: '%s: %d of %d done',
  castle_tower_failed: '%s: %d of %d done, %d failed',
  castle_tower_undecomposed: '%s: not broken down yet',
  tree_stage_sprout: 'Sprout',
  tree_stage_seedling: 'Seedling',
  tree_stage_sapling: 'Sapling',
  tree_stage_young: 'Young tree',
  tree_stage_mature: 'Mature tree',
  tree_stage_majestic: 'Majestic tree',
  tree_stage_track: 'Growth stage: %s',
}
// The zoom controls' words are optional: no fallback word is written here (a control without its label shows its symbol
// only). The percent format is a number format, not a word, so it has a fallback.
const ZOOM_PERCENT_FALLBACK = '%d %%'
const STATE_LABEL_KEY = {
  done: 'state_done',
  in_progress: 'in_progress',
  ready: 'state_ready',
  locked: 'state_locked',
  failed: 'state_failed',
  rejected: 'state_rejected',
}

function label(labels, key) {
  const v = labels && labels[key]
  return typeof v === 'string' && v ? v : FALLBACK[key] || key
}

/** A label that has no fallback: the empty string when the payload did not supply it. */
function optLabel(labels, key) {
  const v = labels && labels[key]
  return typeof v === 'string' ? v : ''
}

/** Fill the printf-style placeholders of a label in order: %d and %s take a value, %% is a literal percent sign. */
function fill(template, ...values) {
  let i = 0
  return template.replace(/%([sd%])/g, (m, c) => (c === '%' ? '%' : String(values[i++] ?? '')))
}

const curve = (x1, y1, x2, y2) => {
  const m = (x1 + x2) / 2
  return `M${x1} ${y1} C${m} ${y1} ${m} ${y2} ${x2} ${y2}`
}

/** Colour class of an edge: by the state of the dependent, a locked dependent by whether its dependency is done. */
function edgeState(depState, targetState) {
  if (targetState === 'failed') return 'failed'
  if (targetState === 'rejected') return 'rejected'
  if (targetState === 'done') return 'done'
  if (targetState === 'in_progress') return 'active'
  if (targetState === 'ready') return 'ready'
  return depState === 'done' ? 'done' : 'locked'
}

// The final padlock values, copied from the prototype (the star and spark outlines moved to StarGoal.jsx).
const SHACKLE_CLOSED = 'M-2.8 0 V-2.6 A2.8 2.8 0 0 1 2.8 -2.6 V0'
const SHACKLE_OPEN = 'M-2.8 0 V-3.4 A2.8 2.8 0 0 1 2.8 -3.4 V-2.3'

/** The status mark of a card, drawn around (0,0). A locked or unmarked card has none. */
function Mark({ mark }) {
  switch (mark) {
    case 'done':
      return <path className="dt-mark-line" d="M-6 0 L-2 4.5 L6.5 -5" />
    case 'in_progress':
      return (
        <g>
          <circle className="dt-mark-line" r="7" />
          <path className="dt-mark-fill dt-blink" d="M0 -7 A7 7 0 0 1 0 7 Z" />
        </g>
      )
    case 'ready':
      return <path className="dt-mark-line dt-mark-plus" d="M0 -7 V7 M-7 0 H7" />
    case 'failed':
      return <path className="dt-mark-line" d="M-5.5 -5.5 L5.5 5.5 M5.5 -5.5 L-5.5 5.5" />
    case 'rejected':
      return <path className="dt-mark-line" d="M-6 0 H6" />
    default:
      return null
  }
}

/** The "?" of a done card whose dependency is not done (E92_S11_T02), drawn around (0,0) with its tooltip. */
function UnfinishedMark({ text }) {
  return (
    <g>
      <text className="dt-mark-q" textAnchor="middle" dominantBaseline="central">?</text>
      <title>{text}</title>
    </g>
  )
}

/** The dependency gate badge on the left edge of a card: closed padlock = waiting, open padlock = all dependencies done. */
function Gate({ kind, text }) {
  const open = kind === 'open'
  return (
    <g className={`dt-gate dt-gate-${open ? 'open' : 'closed'}`} data-gate={open ? 'open' : 'closed'} transform={`translate(0 ${NODE_H / 2})`}>
      <circle className="dt-gate-disc" r={LAYOUT.gateR} />
      <g transform="translate(0 -1)">
        <rect className="dt-lock-body" x="-4.5" y="0" width="9" height="6.5" rx="1.5" />
        <path className="dt-lock-shackle" d={open ? SHACKLE_OPEN : SHACKLE_CLOSED} />
      </g>
      <title>{text}</title>
    </g>
  )
}

export default function DependencyTree({ model, labels, renderers = GOAL_RENDERERS, designs = GOAL_DESIGNS }) {
  const [expanded, setExpanded] = useState(() => new Set())
  const [hover, setHover] = useState(null)
  // The goal design (E92_S13_T05): the ordered list filtered to the registered renderers, and the chosen id. The initial
  // value is the stored choice or the default (never throws, also without storage); a later pick is kept in this state, so
  // it switches for the page even when it cannot be stored. resolveGoalDesign guards a choice that is no longer registered.
  const registered = registeredDesigns(renderers, designs)
  const [designChoice, setDesignChoice] = useState(() => readGoalDesign(registered))
  const designId = resolveGoalDesign(designChoice, registered)
  const design = designId ? renderers[designId] : null
  const pickDesign = id => {
    setDesignChoice(id)
    writeGoalDesign(id)
  }
  // The large view (E92_S07): the tree's own root becomes large, never re-parented, so every piece of state here is kept.
  const rootRef = useRef(null)
  const fs = useFullscreen({ rootRef })
  useFocusContain({ rootRef, active: fs.open })
  const empty = !model || model.empty

  const view = empty ? null : unfoldGroups(model, expanded, { goalArea: design && design.goalArea ? design.goalArea : 'disc' })
  const boundary = empty ? [] : model.boundary || []

  // Boundary nodes (outside the epic) sit in a column left of the story start nodes, so their lines point rightwards.
  const boundaryW = boundary.length ? NODE_W + GOAL_GAP : 0
  const vbX = -boundaryW - 10
  const vbY = -10
  const vbW = empty ? 0 : view.layout.width + boundaryW + 20
  const vbH = empty ? 0 : Math.max(view.layout.height, boundary.length * BOUNDARY_ROW + PAD * 2) + 20

  // The viewport (zoom and pan, E92_S06_T21) is keyed on the epic id, so Fit follows the epic and not the data.
  const zoom = useZoomPan({ box: empty ? null : { x: vbX, y: vbY, w: vbW, h: vbH }, fitKey: empty ? null : model.goal.id, keepCentreOnResize: true })

  if (empty) {
    return (
      <section className="dep-tree" data-testid="dependency-tree" data-empty="true">
        <p className="dt-empty">{label(labels, 'tree_empty')}</p>
      </section>
    )
  }

  const { nodes, headers, bands, edges, goal } = view
  const byNode = new Map(nodes.map(n => [n.id, n]))
  const taskById = new Map(model.tasks.map(t => [t.id, t]))
  const visibleOf = new Map()
  for (const n of nodes) {
    if (n.kind === 'group') for (const m of n.members) visibleOf.set(m, n.id)
    else visibleOf.set(n.id, n.id)
  }
  const boundaryAt = new Map(boundary.map((b, i) => [b.id, { x: PAD - boundaryW, y: PAD + i * BOUNDARY_ROW }]))

  const goalName = label(labels, 'goal')
  const goalText = `${goalName}: ${model.goal.id}${model.goal.title ? ' ' + model.goal.title : ''}`
  const stateName = state => label(labels, STATE_LABEL_KEY[state] || 'state_locked')
  const gateText = kind => label(labels, kind === 'open' ? 'gate_open' : 'gate_waiting')
  const groupText = n => `${fill(label(labels, 'group_tasks'), n.count)} · ${stateName(n.state)}`

  const toggle = id => {
    setHover(null)
    const next = new Set(expanded)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    setExpanded(next)
  }
  const toggleKeys = id => e => {
    if (e.key === 'Enter' || e.key === ' ') {
      if (e.preventDefault) e.preventDefault()
      toggle(id)
    }
  }

  // The chain of the hovered or focused card: its upstream and downstream, mapped to the visible nodes (a group stands
  // for all of its members). Boundary ids pass through unchanged.
  const hovered = hover ? byNode.get(hover) : null
  let chain = null
  if (hovered) {
    const seeds = hovered.kind === 'group' ? hovered.members : [hovered.id]
    const rel = new Set(seeds)
    for (const s of seeds) {
      const t = taskById.get(s)
      if (!t) continue
      for (const id of t.upstream) rel.add(id)
      for (const id of t.downstream) rel.add(id)
    }
    chain = new Set([...rel].map(id => visibleOf.get(id) ?? id))
  }
  const dimNode = id => (chain && !chain.has(id) ? ' dt-dim' : '')
  const doneIds = new Set([
    ...model.tasks.filter(t => t.bucket === 'done' || t.state === 'done').map(t => t.id),
    ...boundary.filter(b => b.bucket === 'done').map(b => b.id),
  ])
  const startOf = new Map(bands.map(b => [b.start.id, b.start]))

  // Anchors of an edge end: the right edge of a source, the left edge (gate included) of a target.
  const source = id => {
    const n = byNode.get(id)
    if (n) return { x: n.outX, y: n.midY, state: n.state }
    const s = startOf.get(id)
    if (s) return { x: s.outX, y: s.midY, state: 'done' }
    const b = boundaryAt.get(id)
    if (b) return { x: b.x + NODE_W, y: b.y + NODE_H / 2, state: doneIds.has(id) ? 'done' : 'locked' }
    return null
  }

  // E92_S11_T02: the words of the "?" of a done card whose dependency is not done; '' for every other card.
  const unfinishedLabels = { dep_unfinished: label(labels, 'dep_unfinished'), dep_unfinished_more: label(labels, 'dep_unfinished_more') }
  const unfinishedText = n => unfinishedDepText(unfinishedLabels, n && n.unfinishedDeps)

  // Tooltip: placed at the lower right of the card, so it follows zoom and pan and works for focus too. Once the view is
  // fitted that is a pixel position through the view transform; before the first fit (the SVG then fits the drawing
  // itself) it is a percent of the drawing.
  let tip = null
  if (hovered) {
    const isGroup = hovered.kind === 'group'
    const facts = isGroup ? hovered : taskById.get(hovered.id) || hovered
    const idsText = ids => ids.map(id => id + (doneIds.has(id) ? ' ✓' : '')).join(', ')
    const fitted = zoom.view && zoom.size
    const left = fitted ? zoom.view.x + zoom.view.k * (hovered.x + hovered.w / 2) : ((hovered.x + hovered.w / 2 - vbX) / vbW) * 100
    const top = fitted ? zoom.view.y + zoom.view.k * (hovered.y + hovered.h) : ((hovered.y + hovered.h - vbY) / vbH) * 100
    const flip = fitted ? left > zoom.size.w * 0.6 : left > 60
    tip = (
      <div
        className={`dt-tip${flip ? ' dt-tip-left' : ''}`}
        role="tooltip"
        data-tip-for={hovered.id}
        style={fitted ? { left: `${left.toFixed(1)}px`, top: `${top.toFixed(1)}px` } : { left: `${left.toFixed(2)}%`, top: `${top.toFixed(2)}%` }}
      >
        <b className="dt-tip-head">{isGroup ? groupText(hovered) : `${hovered.id} · ${stateName(hovered.state)}`}</b>
        {isGroup ? <span className="dt-tip-body">{hovered.members.join(', ')}</span> : hovered.title ? <span className="dt-tip-body">{hovered.title}</span> : null}
        {facts.dependsOn.length > 0 ? (
          <span className="dt-tip-row">
            <span className="dt-tip-key">{label(labels, 'tip_depends_on')}</span> {idsText(facts.dependsOn)}
          </span>
        ) : null}
        {unfinishedText(facts) ? <span className="dt-tip-row dt-tip-unfinished">{unfinishedText(facts)}</span> : null}
        {facts.unlocks.length > 0 ? (
          <span className="dt-tip-row">
            <span className="dt-tip-key">{label(labels, 'tip_unlocks')}</span> {facts.unlocks.join(', ')}
          </span>
        ) : (
          <span className="dt-tip-row dt-tip-goal">{label(labels, 'tip_goal_direct')}</span>
        )}
      </div>
    )
  }

  // Goal: the chosen design draws the goal (its own defs and drawing, its own edge inset and custom properties); the text
  // under the node is drawn here for every design. data-progress is the completed share.
  const p = goal.fraction
  const gid = safeId(goal.id)
  const GoalDefs = design ? design.Defs : null
  const GoalDrawing = design ? design.Drawing : null
  const goalStyle = design && design.rootStyle ? design.rootStyle(goal) : undefined
  const edgeInset = design && typeof design.edgeInset === 'number' ? design.edgeInset : 0
  // E92_S13_T02: a design that ends the edges along its own outline (the citadel) gives `edgeAnchors`: one point per goal
  // edge, top to bottom, and the edges are matched to them by the height of their source so none crosses another. A design
  // without it (the star) ends them all at the one inset.
  const goalEdges = edges.filter(e => e.to === GOAL_NODE_ID && source(e.from))
  const anchorOf = new Map()
  if (design && design.edgeAnchors && goalEdges.length) {
    const sorted = goalEdges.map((e, i) => ({ e, i, y: source(e.from).y })).sort((a, b) => a.y - b.y || a.i - b.i)
    const points = design.edgeAnchors(goal, sorted.length, view.castle)
    sorted.forEach(({ e }, k) => anchorOf.set(`${e.from}>${e.to}`, points[k]))
  }
  const goalRole = design && design.role ? design.role : 'img'
  const nameY = design && design.textTop ? design.textTop(view.castle) : 80
  const progressText = fill(label(labels, 'goal_progress'), goal.done, goal.total, goal.percent)
  // E92_S09_T04: the goal shows the epic percent (epic_progress); while some stories have no task yet it also shows
  // decomposed/stories, so the percent reads as the product of the two fractions shown (section 5.1).
  const decomposedText = goal.decomposed < goal.stories ? fill(label(labels, 'epic_decomposed'), goal.decomposed, goal.stories) : ''
  // E92_S10_T02: while a story of the epic has failed (failedStories, stated by board-progress.sh) the goal is not reached
  // and the percent stops at 99; the name line then names the failed story where "Goal reached!" would have been.
  const failedText = goalFailedText({ goal_failed: label(labels, 'goal_failed'), goal_failed_more: label(labels, 'goal_failed_more') }, goal)
  const failedLines = failedText ? wrapWords(failedText, 24) : []
  // the lines under the name move down by the extra lines of a wrapped failed-story line (0 otherwise)
  const below = Math.max(0, failedLines.length - 1) * GOAL_LINE_H

  const edgeEls = edges.map(e => {
    const from = source(e.from)
    if (!from) return null
    let to
    let cls
    if (e.to === GOAL_NODE_ID) {
      to = anchorOf.get(`${e.from}>${e.to}`) || { x: goal.x - edgeInset, y: goal.y }
      // E92_S12_T03: the ghost edge (a not-broken-down story's start node to the goal) is dashed and neutral; a start node
      // counts as done as a source, which would paint it like finished work. Never part of a hover chain (no card in its
      // story), so the chain logic below leaves it to recede like any edge outside the chain.
      cls = e.kind === 'ghost' ? 'dt-edge-goal dt-edge-ghost' : `dt-edge-goal dt-edge-${from.state === 'done' ? 'done' : 'locked'}`
    } else {
      const n = byNode.get(e.to)
      if (!n) return null
      to = { x: n.inX, y: n.midY }
      cls = `dt-edge-${edgeState(from.state, n.state)}`
    }
    const dim = chain && !((chain.has(e.to) && (chain.has(e.from) || e.kind === 'start')) || (e.to === GOAL_NODE_ID && chain.has(e.from)))
    return (
      <path
        key={`${e.from}>${e.to}`}
        className={`dt-edge ${cls}${e.crossStory ? ' dt-edge-cross' : ''}${dim ? ' dt-edge-dim' : ''}`}
        data-from={e.from}
        data-to={e.to}
        data-kind={e.kind}
        d={curve(from.x, from.y, to.x, to.y)}
      />
    )
  })

  // Zoom controls: every word from the labels, a missing one leaves the symbol alone.
  const percentFormat = optLabel(labels, 'zoom_percent') || ZOOM_PERCENT_FALLBACK
  const zoomText = {
    group: optLabel(labels, 'zoom_group'),
    out: optLabel(labels, 'zoom_out'),
    in: optLabel(labels, 'zoom_in'),
    fit: optLabel(labels, 'zoom_fit'),
    actual: optLabel(labels, 'zoom_actual'),
    hint: optLabel(labels, 'zoom_hint'),
  }

  // Large view: every word from the labels; a missing one leaves the symbol (or the attribute) out.
  const toggleText = optLabel(labels, toggleLabelKey(fs))
  const hintText = optLabel(labels, 'fullscreen_hint')
  const layerText = optLabel(labels, 'fullscreen_layer')

  return (
    <section
      className="dep-tree"
      data-testid="dependency-tree"
      ref={rootRef}
      data-fullscreen={fs.open ? fs.mode : undefined}
      role={fs.open && layerText ? 'dialog' : undefined}
      aria-modal={fs.open && layerText ? 'true' : undefined}
      aria-label={fs.open && layerText ? layerText : undefined}
    >
      <div className="dt-zoom" data-testid="dt-zoom">
        {/* First in the DOM, so it is the first focusable control (the exit button useFocusContain focuses); the bar is
            positioned in the top-left corner, next to the zoom controls in the top-right corner. */}
        <FullscreenToggle open={fs.open} label={toggleText} hint={hintText} onToggle={fs.toggle} />
        <div
          className="dt-stage dt-viewport"
          ref={zoom.stageRef}
          data-dragging={zoom.dragging ? 'true' : undefined}
          data-fitted={zoom.view ? 'true' : undefined}
          {...zoom.handlers}
        >
          <svg className="dt-svg" viewBox={zoom.view ? undefined : `${vbX} ${vbY} ${vbW} ${vbH}`} role="group" aria-label={goalText}>
            <defs>{GoalDefs ? <GoalDefs goal={goal} gid={gid} /> : null}</defs>

            <g className="dt-root" transform={zoom.view ? transformOf(zoom.view) : undefined}>
              <g className="dt-bands">
                {bands.map((b, i) => (
                  <rect
                    key={b.storyId}
                    className={`dt-band${i % 2 ? ' dt-band-alt' : ''}${b.start.undecomposed ? ' dt-band-ghost' : ''}`}
                    data-story={b.storyId}
                    data-undecomposed={b.start.undecomposed ? 'true' : undefined}
                    x={LAYOUT.pad / 2}
                    y={b.y}
                    width={goal.x - view.layout.goalOffsetX - LAYOUT.goalGap / 2}
                    height={b.h}
                    rx="12"
                  />
                ))}
              </g>

              <g className="dt-edges" aria-hidden="true">
                {edgeEls}
              </g>

              {bands.map(b => {
                const s = b.start
                const complete = s.total > 0 && s.done >= s.total
                // E92_S12_T03: a story that is not broken down into tasks yet (flag stated by board-progress.sh, never counted here)
                const ghost = s.undecomposed === true
                const ghostText = ghost ? optLabel(labels, 'story_undecomposed') : ''
                const ghostAria = ghost && optLabel(labels, 'story_undecomposed_aria') ? fill(optLabel(labels, 'story_undecomposed_aria'), `${s.storyId}${s.title ? ' ' + s.title : ''}`) : ''
                return (
                  <g
                    key={s.id}
                    className={`dt-start${complete ? ' dt-start-complete' : ''}${ghost ? ' dt-start-ghost' : ''}`}
                    data-start={s.storyId}
                    data-undecomposed={ghost ? 'true' : undefined}
                    transform={`translate(${s.x} ${s.y})`}
                    {...(ghostAria ? { role: 'group', 'aria-label': ghostAria } : {})}
                  >
                    <rect className="dt-start-box" width={s.w} height={s.h} rx="10" />
                    <text className="dt-start-id" x="12" y="20">{s.storyId}</text>
                    <text className="dt-start-count" x={s.w - 12} y="20" textAnchor="end">{`${s.done}/${s.total}`}</text>
                    <text className="dt-start-title" x="12" y="37">{clip(s.title, 28)}</text>
                    {ghost ? null : <rect className="dt-start-bar-bg" x="12" y="50" width={s.w - 24} height="6" rx="3" />}
                    {ghost ? null : <rect className="dt-start-bar" x="12" y="50" width={s.total > 0 ? ((s.w - 24) * Math.min(s.done, s.total)) / s.total : 0} height="6" rx="3" />}
                    {ghostText ? <text className="dt-start-ghost-text" x="12" y="56">{ghostText}</text> : null}
                    <title>{ghostAria || `${s.storyId}${s.title ? ' ' + s.title : ''} · ${s.done}/${s.total}${ghost ? '' : ' ' + label(labels, 'state_done')}`}</title>
                  </g>
                )
              })}

              {boundary.map(b => {
                const at = boundaryAt.get(b.id)
                return (
                  <g key={b.id} className={`dt-node dt-boundary${dimNode(b.id)}`} data-boundary={b.id} transform={`translate(${at.x} ${at.y})`}>
                    <title>{b.id}</title>
                    <rect className="dt-node-box" width={NODE_W} height={NODE_H} rx="9" />
                    <text className="dt-cid" x="12" y="29">{b.id}</text>
                  </g>
                )
              })}

              {headers.map(h => (
                <g
                  key={h.id}
                  className={`dt-collapse${chain ? ' dt-dim' : ''}`}
                  data-toggle={h.id}
                  transform={`translate(${h.x} ${h.y})`}
                  tabIndex={0}
                  role="button"
                  aria-expanded="true"
                  aria-label={`${label(labels, 'collapse')} ${groupText(h)}`}
                  onClick={() => toggle(h.id)}
                  onKeyDown={toggleKeys(h.id)}
                >
                  <rect width={h.w} height={h.h} rx={h.h / 2} />
                  <text x="12" y="15">{`▾ ${label(labels, 'collapse')} · ${fill(label(labels, 'group_tasks'), h.count)}`}</text>
                </g>
              ))}

              {nodes.map(n => {
                const isGroup = n.kind === 'group'
                const gated = n.gate !== 'none'
                const tx = gated ? 18 : 12
                const name = stateName(n.state)
                const gateKind = n.gate === 'open' ? 'open' : 'closed'
                const cls = `dt-node dt-card dt-state-${n.state}${isGroup ? ' dt-group' : ''}${chain && n.id === hover ? ' dt-hl' : ''}${dimNode(n.id)}`
                const handlers = {
                  onPointerEnter: () => setHover(n.id),
                  onPointerLeave: () => setHover(null),
                  onFocus: () => setHover(n.id),
                  onBlur: () => setHover(null),
                }
                const gateNote = gated ? ` (${gateText(gateKind)})` : ''
                const flagText = unfinishedText(n)
                const flagNote = flagText ? ` (${flagText})` : ''
                return (
                  <g
                    key={n.id}
                    className={cls}
                    data-node={n.id}
                    data-state={n.state}
                    data-kind={n.kind}
                    transform={`translate(${n.x} ${n.y})`}
                    tabIndex={0}
                    {...handlers}
                    {...(isGroup
                      ? {
                          role: 'button',
                          'aria-expanded': 'false',
                          'aria-label': `${groupText(n)}, ${fill(label(labels, 'show_all'), n.count)}${flagNote}`,
                          onClick: () => toggle(n.id),
                          onKeyDown: toggleKeys(n.id),
                        }
                      : { role: 'group', 'aria-label': `${name}: ${n.id}${n.title ? ' ' + n.title : ''}${gateNote}${flagNote}` })}
                  >
                    {isGroup ? (
                      <g className="dt-stack" aria-hidden="true">
                        <rect className="dt-box-stack" x="8" y="-8" width={NODE_W} height={NODE_H} rx="9" opacity=".45" />
                        <rect className="dt-box-stack" x="4" y="-4" width={NODE_W} height={NODE_H} rx="9" opacity=".75" />
                      </g>
                    ) : null}
                    {n.state === 'ready' ? <rect className="dt-ring" x="-4" y="-4" width={NODE_W + 8} height={NODE_H + 8} rx="12" /> : null}
                    <rect className="dt-node-box" width={NODE_W} height={NODE_H} rx="9" />
                    {isGroup ? (
                      <g>
                        <text className="dt-cid" x={tx} y="20">{groupText(n)}</text>
                        <text className="dt-clink" x={tx} y="37">{`▸ ${fill(label(labels, 'show_all'), n.count)}`}</text>
                      </g>
                    ) : (
                      <g>
                        <text className="dt-cid" x={tx} y="20">{n.id}</text>
                        <text className="dt-ctitle" x={tx} y="37">{clip(n.title, gated ? TITLE_MAX - 1 : TITLE_MAX)}</text>
                      </g>
                    )}
                    {flagText ? (
                      <g className="dt-mark dt-mark-unfinished" data-mark="unfinished" transform={`translate(${NODE_W - 22} ${NODE_H / 2})`}>
                        <UnfinishedMark text={flagText} />
                      </g>
                    ) : n.mark !== 'none' ? (
                      <g className="dt-mark" data-mark={n.mark} transform={`translate(${NODE_W - 22} ${NODE_H / 2})`}>
                        <Mark mark={n.mark} />
                      </g>
                    ) : null}
                    {gated ? <Gate kind={gateKind} text={gateText(gateKind)} /> : null}
                  </g>
                )
              })}

              <g
                className={`dt-node dt-goal${goal.reached ? ' dt-complete' : ''}`}
                data-goal={model.goal.id}
                data-progress={p.toFixed(3)}
                transform={`translate(${goal.x} ${goal.y})`}
                role={goalRole}
                aria-label={`${goalText} · ${progressText}${decomposedText ? ` · ${decomposedText}` : ''}${failedText ? ` · ${failedText}` : ''}`}
                data-goal-design={designId || undefined}
                style={goalStyle}
              >
                {GoalDrawing ? <GoalDrawing goal={goal} gid={gid} castle={view.castle} label={key => label(labels, key)} fill={fill} /> : null}
                {failedText ? (
                  <text className="dt-goal-name dt-goal-failed" y={nameY} textAnchor="middle">
                    {failedLines.map((l, i) => (
                      <tspan key={i} x="0" dy={i === 0 ? 0 : GOAL_LINE_H}>{l}</tspan>
                    ))}
                  </text>
                ) : (
                  <text className="dt-goal-name" y={nameY} textAnchor="middle">{goal.reached ? label(labels, 'goal_reached') : goalName}</text>
                )}
                <text className="dt-goal-title" y={nameY + 18 + below} textAnchor="middle">{clip(model.goal.title, 34)}</text>
                <text className="dt-goal-count" y={nameY + 36 + below} textAnchor="middle">{progressText}</text>
                {decomposedText ? (
                  <text className="dt-goal-count dt-goal-decomposed" y={nameY + 52 + below} textAnchor="middle">{decomposedText}</text>
                ) : null}
              </g>
            </g>
          </svg>
        </div>
        {tip}
        <ZoomControls
          text={zoomText}
          percent={zoom.percent == null ? '' : fill(percentFormat, zoom.percent)}
          actualText={fill(percentFormat, 100)}
          onZoomOut={zoom.zoomOut}
          onZoomIn={zoom.zoomIn}
          onFit={zoom.fit}
          onActual={zoom.actual}
        />
        <GoalDesignSelector
          items={registered.map(d => ({ id: d.id, text: label(labels, d.labelKey) }))}
          value={designId}
          groupText={label(labels, GOAL_DESIGN_GROUP_LABEL_KEY)}
          onSelect={pickDesign}
        />
        {zoomText.hint ? <p className="dt-zoom-hint">{zoomText.hint}</p> : null}
      </div>

      <div className="dt-ready" data-testid="dt-ready">
        <h4 className="dt-ready-title">{label(labels, 'ready_to_take')}</h4>
        {model.ready.length === 0 ? (
          <p className="dt-nothing-ready">{label(labels, 'nothing_ready')}</p>
        ) : (
          <ul className="dt-ready-list">
            {model.ready.map(r => (
              <li key={r.id} data-ready={r.id}>
                <span className="dt-ready-plus" aria-hidden="true">+</span> {r.id} {r.title}
              </li>
            ))}
          </ul>
        )}
      </div>

      {model.unlocked.length > 0 ? (
        <ul className="dt-unlocked" data-testid="dt-unlocked">
          {model.unlocked.map(u => (
            <li key={u.taskId}>{u.text}</li>
          ))}
        </ul>
      ) : null}
    </section>
  )
}
