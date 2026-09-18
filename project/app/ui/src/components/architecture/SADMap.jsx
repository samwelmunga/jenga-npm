// SADMap.jsx
// Renders a Software Architecture Diagram using inline SVG.
// Props: nodes [{ id, label, type }], edges [{ from, to, label? }]
//
// Rendering approach (E08_S06_T01 decision, path (a) — incremental SVG
// improvement, see project/documentation/plans/architecture-graph-viz.md):
//   - dagre computes a real hierarchical layout instead of fixed type rows.
//   - d3-shape renders curved edges through dagre's own control points.
//   - d3-zoom adds pan/zoom, attached imperatively to the <svg> with a
//     disciplined mount/cleanup pair (safe under React 18 Strict Mode's
//     dev-time double-invoke).
//   - Type-based collapse/expand groups same-type nodes into a single
//     synthetic cluster node, using only the existing node `type` field
//     (no backend/schema changes).

import { useEffect, useMemo, useRef, useState } from 'react'
import dagre from 'dagre'
import { select } from 'd3-selection'
import { zoom as d3zoom, zoomIdentity } from 'd3-zoom'
import { line as d3line, curveBasis } from 'd3-shape'

const TYPE_COLORS = {
  epic: '#3b82f6',       // blue
  story: '#22c55e',      // green
  service: '#a855f7',    // purple
  dependency: '#6b7280', // grey
}

// Fallback fill for any node type not present in TYPE_COLORS (e.g. free-text
// types sourced from knowledge-graph/graph.json such as 'module' or 'function').
const DEFAULT_TYPE_COLOR = '#94a3b8' // slate
const CLUSTER_PREFIX = '__cluster__'

const NODE_W = 140
const NODE_H = 40
const PAD = 20
const ZOOM_MIN = 0.1
const ZOOM_MAX = 4

// Fixed maximum on-screen viewport height. Content taller than this is
// scaled down to fit vertically (see computeFitTransform); content wider
// than the container is NOT scaled down to fit — the user pans horizontally
// instead. This asymmetry is deliberate: dagre lays real board-derived data
// out as a broad, shallow tree (dozens-to-hundreds of siblings in one or two
// ranks), so fitting to *both* dimensions (as a naive `viewBox` auto-scale
// would) squeezes nodes down to sub-pixel illegibility on exactly the
// largest real dataset. Fitting to height only keeps every node at a
// legible, close-to-native pixel size regardless of how wide the graph is.
const VIEWPORT_H = 600

const edgePathGenerator = d3line()
  .x(d => d.x)
  .y(d => d.y)
  .curve(curveBasis)

/**
 * Compute the initial/reset d3-zoom transform for a given content height:
 * scale down (never up) just enough that the content's full height fits
 * within VIEWPORT_H, with a small top/left padding. Width is deliberately
 * left unconstrained — see the VIEWPORT_H comment above for why.
 */
function computeFitTransform(contentHeight) {
  const scale = contentHeight > 0 ? Math.min(1, VIEWPORT_H / contentHeight) : 1
  return zoomIdentity.translate(PAD, PAD).scale(scale)
}

/**
 * Collapse every node of a given type into one synthetic cluster node, and
 * remap edges that touched a collapsed node onto its cluster id.
 * Returns { nodes, edges, clusterMembers } where clusterMembers maps a
 * cluster id back to the list of original node ids it stands in for (used
 * only for the toolbar counts / expand-on-click affordance).
 */
function collapseByType(nodes, edges, collapsedTypes) {
  if (collapsedTypes.size === 0) {
    return { nodes, edges, clusterMembers: {} }
  }

  const idToDisplayId = {}
  const clusterMembers = {}
  const outNodes = []

  for (const n of nodes) {
    if (collapsedTypes.has(n.type)) {
      const clusterId = `${CLUSTER_PREFIX}${n.type}`
      idToDisplayId[n.id] = clusterId
      if (!clusterMembers[clusterId]) clusterMembers[clusterId] = []
      clusterMembers[clusterId].push(n.id)
    } else {
      idToDisplayId[n.id] = n.id
      outNodes.push(n)
    }
  }

  for (const [clusterId, members] of Object.entries(clusterMembers)) {
    const type = clusterId.slice(CLUSTER_PREFIX.length)
    outNodes.push({
      id: clusterId,
      label: `${type} (${members.length})`,
      type,
      isCluster: true,
    })
  }

  const seenEdges = new Set()
  const outEdges = []
  for (const e of edges) {
    const from = idToDisplayId[e.from]
    const to = idToDisplayId[e.to]
    if (!from || !to) continue
    if (from === to) continue // both endpoints collapsed into the same cluster — meaningless self-loop
    const key = `${from} ${to}`
    if (seenEdges.has(key)) continue
    seenEdges.add(key)
    outEdges.push({ ...e, from, to })
  }

  return { nodes: outNodes, edges: outEdges, clusterMembers }
}

/** Filter to a node's 1-hop neighborhood (click-to-isolate), unchanged behavior. */
function isolate(nodes, edges, selectedId) {
  if (selectedId === null) return { nodes, edges }
  const connectedIds = new Set([selectedId])
  for (const e of edges) {
    if (e.from === selectedId) connectedIds.add(e.to)
    if (e.to === selectedId) connectedIds.add(e.from)
  }
  return {
    nodes: nodes.filter(n => connectedIds.has(n.id)),
    edges: edges.filter(e => connectedIds.has(e.from) && connectedIds.has(e.to)),
  }
}

/** Run dagre layout over the given nodes/edges. Returns { svgW, svgH, positions, edgePoints }. */
function layoutWithDagre(nodes, edges) {
  const g = new dagre.graphlib.Graph()
  g.setGraph({ rankdir: 'TB', nodesep: 40, ranksep: 70, marginx: PAD, marginy: PAD })
  g.setDefaultEdgeLabel(() => ({}))

  for (const n of nodes) {
    g.setNode(n.id, { width: NODE_W, height: NODE_H })
  }
  for (const e of edges) {
    if (g.hasNode(e.from) && g.hasNode(e.to)) {
      g.setEdge(e.from, e.to)
    }
  }

  dagre.layout(g)

  const positions = {}
  let maxX = 0
  let maxY = 0
  g.nodes().forEach(id => {
    const n = g.node(id)
    // dagre positions are center-based; convert to top-left for our <rect>/<text> rendering.
    positions[id] = { x: n.x - NODE_W / 2, y: n.y - NODE_H / 2 }
    maxX = Math.max(maxX, n.x + NODE_W / 2)
    maxY = Math.max(maxY, n.y + NODE_H / 2)
  })

  const edgePoints = {}
  edges.forEach(e => {
    const dagreEdge = g.hasEdge(e.from, e.to) ? g.edge(e.from, e.to) : null
    if (dagreEdge && dagreEdge.points) {
      edgePoints[`${e.from} ${e.to}`] = dagreEdge.points
    }
  })

  return {
    svgW: Math.max(maxX + PAD, NODE_W + PAD * 2),
    svgH: Math.max(maxY + PAD, NODE_H + PAD * 2),
    positions,
    edgePoints,
  }
}

export default function SADMap({ nodes, edges }) {
  const [selectedId, setSelectedId] = useState(null)
  const [collapsedTypes, setCollapsedTypes] = useState(() => new Set())

  const svgRef = useRef(null)
  const zoomBehaviorRef = useRef(null)

  const allEdges = edges || []

  // All types present in the *unfiltered* node set, so the collapse toolbar
  // stays stable regardless of the current click-to-isolate selection.
  const allTypes = useMemo(() => {
    const types = new Set()
    for (const n of nodes || []) types.add(n.type)
    return [...types].sort()
  }, [nodes])

  const { nodes: collapsedNodes, edges: collapsedEdges, clusterMembers } = useMemo(
    () => collapseByType(nodes || [], allEdges, collapsedTypes),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [nodes, allEdges, collapsedTypes]
  )

  const { nodes: visibleNodes, edges: visibleEdges } = useMemo(
    () => isolate(collapsedNodes, collapsedEdges, selectedId),
    [collapsedNodes, collapsedEdges, selectedId]
  )

  const layout = useMemo(
    () => layoutWithDagre(visibleNodes, visibleEdges),
    [visibleNodes, visibleEdges]
  )

  // Initial transform fits the content's height into VIEWPORT_H (see
  // computeFitTransform) so the very first paint is already legible instead
  // of flashing an unfit identity transform before the effect below runs.
  const [transform, setTransform] = useState(() => computeFitTransform(layout.svgH))

  // Attach d3-zoom imperatively. Mount/cleanup pair is intentionally
  // symmetric so React 18 Strict Mode's dev double-invoke never leaves two
  // listeners attached. Declared before the fit-transform effect below so
  // zoomBehaviorRef is already populated by the time that effect runs on
  // the same initial commit.
  useEffect(() => {
    if (!svgRef.current) return undefined
    const selection = select(svgRef.current)
    const behavior = d3zoom()
      .scaleExtent([ZOOM_MIN, ZOOM_MAX])
      .on('zoom', event => setTransform(event.transform))
    selection.call(behavior)
    zoomBehaviorRef.current = behavior

    return () => {
      selection.on('.zoom', null)
      zoomBehaviorRef.current = null
    }
  }, [])

  // Re-fit pan/zoom whenever the rendered graph changes shape materially
  // (selection or collapse state change, which both flow into layout.svgH)
  // so the user doesn't end up panned/zoomed into empty space, or staring
  // at an illegibly tiny graph, after the layout shifts underneath them.
  // Goes through the zoom behavior's own `.transform` setter (not a bare
  // setTransform state call) so d3-zoom's internally tracked transform
  // stays in sync — otherwise the next real user gesture would jump,
  // computing its delta from a stale transform the behavior still thinks
  // is current.
  useEffect(() => {
    if (!zoomBehaviorRef.current || !svgRef.current) return
    const fit = computeFitTransform(layout.svgH)
    select(svgRef.current).call(zoomBehaviorRef.current.transform, fit)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [layout.svgH, selectedId, collapsedTypes])

  if (!nodes || nodes.length === 0) {
    return <p className="sad-empty">No architecture map data available.</p>
  }

  const toggleTypeCollapse = type => {
    setCollapsedTypes(prev => {
      const next = new Set(prev)
      if (next.has(type)) next.delete(type)
      else next.add(type)
      return next
    })
  }

  const resetView = () => {
    const fit = computeFitTransform(layout.svgH)
    if (zoomBehaviorRef.current && svgRef.current) {
      select(svgRef.current).call(zoomBehaviorRef.current.transform, fit)
    } else {
      setTransform(fit)
    }
  }

  const { svgH, positions, edgePoints } = layout
  const displayHeight = Math.min(Math.max(svgH, NODE_H + PAD * 2), VIEWPORT_H)

  return (
    <div>
      <div className="sad-map-toolbar" role="toolbar" aria-label="Architecture map controls">
        {allTypes.map(type => {
          const isCollapsed = collapsedTypes.has(type)
          const color = TYPE_COLORS[type] || DEFAULT_TYPE_COLOR
          return (
            <button
              key={type}
              type="button"
              className={`sad-type-chip${isCollapsed ? ' is-collapsed' : ''}`}
              style={{ '--chip-color': color }}
              onClick={() => toggleTypeCollapse(type)}
              aria-pressed={isCollapsed}
              title={isCollapsed ? `Expand ${type} nodes` : `Collapse ${type} nodes`}
            >
              <span className="sad-type-chip-dot" />
              {type} {isCollapsed ? '(collapsed)' : ''}
            </button>
          )
        })}
        <button type="button" className="sad-reset-view-btn" onClick={resetView}>
          Reset view
        </button>
      </div>

      <div className="sad-map-scroll">
        <svg
          ref={svgRef}
          className="sad-map-svg"
          width="100%"
          height={displayHeight}
        >
          <defs>
            <marker id="arrow" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
              <path d="M0,0 L0,6 L8,3 z" fill="#94a3b8" />
            </marker>
          </defs>

          <g transform={transform.toString()}>
            {/* Edges */}
            {visibleEdges.map((e, i) => {
              const key = `${e.from} ${e.to}`
              const points = edgePoints[key]
              if (!points || points.length < 2) return null
              const d = edgePathGenerator(points)
              if (!d) return null
              return (
                <path
                  key={i}
                  d={d}
                  fill="none"
                  stroke="#94a3b8"
                  strokeWidth={1.5}
                  markerEnd="url(#arrow)"
                />
              )
            })}

            {/* Nodes */}
            {visibleNodes.map(n => {
              const pos = positions[n.id]
              if (!pos) return null
              const fill = TYPE_COLORS[n.type] || DEFAULT_TYPE_COLOR
              const label = n.label.length > 18 ? n.label.slice(0, 17) + '…' : n.label
              const opacity = selectedId === null ? 0.85 : 1.0
              const isCluster = Boolean(n.isCluster)
              return (
                <g
                  key={n.id}
                  transform={`translate(${pos.x},${pos.y})`}
                  style={{ cursor: 'pointer' }}
                  onClick={() =>
                    isCluster
                      ? toggleTypeCollapse(n.type)
                      : setSelectedId(selectedId === n.id ? null : n.id)
                  }
                >
                  <title>
                    {isCluster
                      ? `${n.label} — click to expand (${(clusterMembers[n.id] || []).length} nodes)`
                      : n.label}
                  </title>
                  <rect
                    width={NODE_W}
                    height={NODE_H}
                    rx={6}
                    fill={fill}
                    opacity={opacity}
                    stroke={isCluster ? '#1f2937' : 'none'}
                    strokeWidth={isCluster ? 1.5 : 0}
                    strokeDasharray={isCluster ? '4 2' : undefined}
                  />
                  <text
                    x={NODE_W / 2}
                    y={NODE_H / 2}
                    dominantBaseline="middle"
                    textAnchor="middle"
                    fill="#fff"
                    fontSize={11}
                    fontFamily="inherit"
                  >
                    {label}
                  </text>
                </g>
              )
            })}
          </g>
        </svg>
      </div>
    </div>
  )
}
