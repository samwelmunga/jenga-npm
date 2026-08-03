// SADMap.jsx
// Renders a Software Architecture Diagram using inline SVG.
// Props: nodes [{ id, label, type }], edges [{ from, to, label? }]

import { useState } from 'react'

const TYPE_COLORS = {
  epic: '#3b82f6',       // blue
  story: '#22c55e',      // green
  service: '#a855f7',    // purple
  dependency: '#6b7280', // grey
}

const NODE_W = 140
const NODE_H = 40
const H_GAP = 60
const V_GAP = 80
const PAD = 20

function layoutNodes(nodes) {
  const groups = {}
  for (const n of nodes) {
    if (!groups[n.type]) groups[n.type] = []
    groups[n.type].push(n)
  }
  const typeOrder = ['epic', 'story', 'service', 'dependency']
  const positions = {}
  let y = PAD
  for (const type of typeOrder) {
    const group = groups[type] || []
    group.forEach((n, i) => {
      positions[n.id] = { x: PAD + i * (NODE_W + H_GAP), y }
    })
    if (group.length > 0) y += NODE_H + V_GAP
  }
  return positions
}

export default function SADMap({ nodes, edges }) {
  const [selectedId, setSelectedId] = useState(null)

  if (!nodes || nodes.length === 0) {
    return <p className="sad-empty">No architecture map data available.</p>
  }

  // Compute visible nodes and edges based on selection
  let visibleNodes = nodes
  let visibleEdges = edges || []

  if (selectedId !== null) {
    const connectedIds = new Set([selectedId])
    for (const e of visibleEdges) {
      if (e.from === selectedId) connectedIds.add(e.to)
      if (e.to === selectedId) connectedIds.add(e.from)
    }
    visibleNodes = nodes.filter(n => connectedIds.has(n.id))
    visibleEdges = (edges || []).filter(
      e => connectedIds.has(e.from) && connectedIds.has(e.to)
    )
  }

  const positions = layoutNodes(visibleNodes)

  const allX = Object.values(positions).map(p => p.x)
  const allY = Object.values(positions).map(p => p.y)
  const svgW = Math.max(...allX) + NODE_W + PAD * 2
  const svgH = Math.max(...allY) + NODE_H + PAD * 2

  return (
    <div className="sad-map-scroll">
    <svg
      className="sad-map-svg"
      width={svgW}
      height={svgH}
      viewBox={`0 0 ${svgW} ${svgH}`}
    >
      <defs>
        <marker id="arrow" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
          <path d="M0,0 L0,6 L8,3 z" fill="#94a3b8" />
        </marker>
      </defs>

      {/* Edges */}
      {visibleEdges.map((e, i) => {
        const from = positions[e.from]
        const to = positions[e.to]
        if (!from || !to) return null
        const x1 = from.x + NODE_W / 2
        const y1 = from.y + NODE_H
        const x2 = to.x + NODE_W / 2
        const y2 = to.y
        return (
          <line
            key={i}
            x1={x1} y1={y1} x2={x2} y2={y2}
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
        const fill = TYPE_COLORS[n.type] || '#6b7280'
        const label = n.label.length > 18 ? n.label.slice(0, 17) + '…' : n.label
        const opacity = selectedId === null ? 0.85 : 1.0
        return (
          <g
            key={n.id}
            transform={`translate(${pos.x},${pos.y})`}
            style={{ cursor: 'pointer' }}
            onClick={() => setSelectedId(selectedId === n.id ? null : n.id)}
          >
            <title>{n.label}</title>
            <rect width={NODE_W} height={NODE_H} rx={6} fill={fill} opacity={opacity} />
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
    </svg>
    </div>
  )
}
