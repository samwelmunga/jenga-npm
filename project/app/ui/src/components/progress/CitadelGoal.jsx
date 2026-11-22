import { goalAnchors } from './castleLayout'
import { towerCaption } from './castleCaption'
import { DaySky, DayNightEffects, skyFrame } from './DayNightScene'

/**
 * CitadelGoal - E92_S13_T02. The "citadel" goal design of the epic progress map: an isometric Jenga castle drawn in pure SVG
 * (story decisions 1 to 5, prototype A in project/documentation/prototypes/E92_S13/jenga-castle.html). It is the default
 * design (DEFAULT_GOAL_DESIGN). It draws what castleLayout.js (geometry) made of castleModel.js (what stands on what, the
 * layers and their states, the wall share): no status, percent, count or position is worked out here.
 *
 *   - One tower per story. A task is one layer of three blocks (k blocks above the height cap), layers alternate direction:
 *     done = wood with grain, in progress = the middle block half pulled out and hatched, pending = wireframe, failed = a
 *     cracked red layer and the tower leans, a rejected task = a block lying beside the tower, an undecomposed story = a
 *     dashed foundation with a "?". Every state has its own shape or pattern, so it reads without colour (E92_S11).
 *   - A story on one story stands on its tower; a story on two or more stands on a bridge deck between them (piers where a
 *     support is lower). A finished leaf tower has a leaning-plank roof with a flag, a finished tower that carries others has
 *     battlements of upright blocks. Each tower stands on a status base in the E92 colours.
 *   - The curtain wall of lying blocks is built from the gate, by the model's wall share, around the towers (it replaces the
 *     progress ring); bastions stand at the four corners; a plank table top is under it all.
 *   - Day and night (E92_S13_T04, story decision 2) follow the dashboard's light and dark theme through CSS alone: no sky
 *     panel is painted behind the castle (hidden 2026-11-18), so the sun, whose height is the epic percent (day), or the moon
 *     and dim stars (night) sit on whatever is behind, a lit window on the middle
 *     block of every finished layer (night), a lit gate (the night value of the gate token) and, in the `cc-effects` group and
 *     only when the goal is reached, flapping birds (day) or twinkling stars (night) in place of the old sparks. The scene is the
 *     shared DayNightScene.jsx; the colours are the `--cc-*` palette hook of `.dt-castle` and the `--dn-*` hook of `.dn-scene`.
 *   - Colours are `var(--cc-*)` / `var(--dn-*)` / `var(--color-*)` tokens in dependency-tree.css and tokens.css, no colour
 *     literal here, and no movement here: the birds and the stars move in CSS, which reduced motion stops.
 *
 * Renderer contract (see StarGoal.jsx; this design adds the optional members used by a design that is not a disc):
 *   goalArea     'castle'           the room the goal takes in the layout (dependencyTreeModel.js)
 *   role         'group'            the goal group's ARIA role: a group, because its towers are images of their own
 *   edgeInset    0                  unused: the edges end at edgeAnchors
 *   edgeAnchors  (goal, n, castle)  the n points (in the tree's coordinates) where the edges to the goal end, top to bottom
 *   textTop      (castle)           y of the goal name line under the castle (in the goal's coordinates)
 *   Defs         null (the hatch pattern is part of the drawing, so the palette hook colours it)
 *   Drawing      the castle, props { goal, gid, castle, label, fill }
 */

const LEAN_DEG = 7 // a tower with a failed task leans this far (and what stands on it leans with it)
const f = n => Math.round(n * 100) / 100
const pts = a => a.map(p => `${f(p[0])},${f(p[1])}`).join(' ')
const lerp = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
const up = (p, h) => [p[0], p[1] - h]
const STATE_CLASS = { done: 'cc-done', in_progress: 'cc-wip', pending: 'cc-pend', failed: 'cc-fail' }
const stateClass = s => STATE_CLASS[s] || 'cc-pend'

/** The footprint diamond of half-width w at (cx, cy) and the faces of a box h tall standing on it. */
function faces(cx, cy, w, h) {
  const F = [cx, cy + w / 2]
  const L = [cx - w, cy]
  const R = [cx + w, cy]
  const B = [cx, cy - w / 2]
  return { F, L, R, B, left: [L, F, up(F, h), up(L, h)], right: [F, R, up(R, h), up(F, h)], top: [up(L, h), up(F, h), up(R, h), up(B, h)] }
}

const Poly = ({ p, cls, fill }) => <polygon className={cls} points={pts(p)} fill={fill} />
const Line = ({ a, b, cls }) => <line className={cls} x1={f(a[0])} y1={f(a[1])} x2={f(b[0])} y2={f(b[1])} />

/** A zig-zag crack up a face from the bottom edge a-b to the top (the failed layer's cue). */
function Crack({ a, b, h }) {
  const at = (t, y) => up(lerp(a, b, t), h * y)
  return <polyline className="cc-crack" points={pts([at(0.5, 0), at(0.58, 0.28), at(0.44, 0.5), at(0.57, 0.74), at(0.5, 1)])} />
}

/** A lit window on a finished block end: the face shrunk toward its centre. It is drawn always and shown by night only (dn-night). */
function Window({ q, side }) {
  const c = [(q[0][0] + q[1][0] + q[2][0] + q[3][0]) / 4, (q[0][1] + q[1][1] + q[2][1] + q[3][1]) / 4]
  return <Poly p={q.map(p => lerp(p, c, 0.42))} cls={`cc-win cc-win-${side} dn-night`} />
}

/** One layer: its long face, its block ends (each block in its own state), its top when it is the tower's top, pulled-out blocks. */
function Layer({ cx, cy, w, h, layer, isTop, hatch }) {
  const fc = faces(cx, cy, w, h)
  const { L, F, R } = fc
  const u = layer.direction === 'x'
  const n = layer.blocks
  const longFace = u ? fc.left : fc.right
  const [la, lb] = u ? [L, F] : [F, R]
  const [ea, eb] = u ? [F, R] : [L, F] // the face that shows the block ends
  const endSide = u ? 'r' : 'l'
  const wip = layer.state === 'in_progress'
  const els = [
    <Poly key="long" p={longFace} cls={`cc-p cc-long cc-f${u ? 'l' : 'r'} ${stateClass(layer.state)}`} fill={wip ? hatch : undefined} />,
  ]
  if (layer.state === 'done' && h >= 6) {
    ;[0.36, 0.7].forEach(k => {
      const p = up(lerp(la, lb, 0.07), h * k)
      const q = up(lerp(la, lb, 0.93), h * k)
      els.push(<Line key={`g${k}`} a={p} b={q} cls="cc-grain" />)
    })
  }
  if (layer.state === 'failed') els.push(<Crack key="crack" a={la} b={lb} h={h} />)
  for (let j = 0; j < n; j++) {
    const a = lerp(ea, eb, j / n)
    const b = lerp(ea, eb, (j + 1) / n)
    const st = layer.blockStates[j]
    els.push(<Poly key={`e${j}`} p={[a, b, up(b, h), up(a, h)]} cls={`cc-p cc-end cc-f${endSide} ${stateClass(st)}`} fill={st === 'in_progress' ? hatch : undefined} />)
    if (st === 'failed' && layer.state !== 'failed') els.push(<Crack key={`c${j}`} a={a} b={b} h={h} />)
    if (st === 'done' && j === Math.floor(n / 2) && h >= 6) els.push(<Window key="win" q={[a, b, up(b, h), up(a, h)]} side={endSide} />)
  }
  if (isTop) {
    const [Lt, Ft, Rt, Bt] = fc.top
    els.push(<Poly key="top" p={fc.top} cls={`cc-p cc-top ${stateClass(layer.state)}`} fill={wip ? hatch : undefined} />)
    for (let j = 1; j < n; j++) {
      const k = j / n
      els.push(<Line key={`d${j}`} a={u ? lerp(Lt, Bt, k) : lerp(Lt, Ft, k)} b={u ? lerp(Ft, Rt, k) : lerp(Bt, Rt, k)} cls="cc-seam-line" />)
    }
  }
  for (let j = 0; j < n; j++) {
    // a block in progress is pulled half out of its layer (a normal layer pulls the middle one; a wide layer every block in progress)
    if (layer.blockStates[j] !== 'in_progress' || (n === 3 && j !== 1)) continue
    const P0 = lerp(ea, eb, j / n)
    const P1 = lerp(ea, eb, (j + 1) / n)
    const s = u ? [(F[0] - L[0]) * 0.34, (F[1] - L[1]) * 0.34] : [(F[0] - R[0]) * 0.34, (F[1] - R[1]) * 0.34]
    const side = u ? P0 : P1
    const M = p => [p[0] + s[0], p[1] + s[1]]
    els.push(
      <g key={`pull${j}`} className="cc-pull">
        <Poly p={[side, M(side), M(up(side, h)), up(side, h)]} cls="cc-p cc-pull-side" fill={hatch} />
        <Poly p={[up(P0, h), up(P1, h), M(up(P1, h)), M(up(P0, h))]} cls="cc-p cc-pull-top" />
        <Poly p={[M(P0), M(P1), M(up(P1, h)), M(up(P0, h))]} cls="cc-p cc-pull-end" fill={hatch} />
      </g>,
    )
  }
  return <g className="cc-layer" data-state={layer.state}>{els}</g>
}

/** A roof of leaning planks with a flag (a finished leaf tower), or the roof of a bastion when the goal is reached. */
function Roof({ cx, y, w, height, flag, reached, big }) {
  const ov = 1.15
  const L2 = [cx - w * ov, y]
  const F2 = [cx, y + (w * ov) / 2]
  const R2 = [cx + w * ov, y]
  const A = [cx, y - height]
  const s = big ? 1 : 0.62
  return (
    <g className="cc-roof">
      <Poly p={[L2, F2, A]} cls="cc-p cc-roof-l" />
      <Poly p={[F2, R2, A]} cls="cc-p cc-roof-r" />
      {[0.25, 0.5, 0.75].map(k => (
        <g key={k}>
          <Line a={lerp(L2, F2, k)} b={A} cls="cc-plank" />
          <Line a={lerp(F2, R2, k)} b={A} cls="cc-plank" />
        </g>
      ))}
      <polyline className="cc-eave" points={pts([L2, F2, R2])} />
      {flag ? (
        <g className={`cc-flag${reached ? ' cc-flag-reached' : ''}`}>
          <line className="cc-pole" x1={f(A[0])} y1={f(A[1])} x2={f(A[0])} y2={f(A[1] - 14 * s)} />
          <path className="cc-pennant" d="M0 0 L12 0 L8.5 3.5 L12 7 L0 7Z" transform={`translate(${f(A[0])} ${f(A[1] - 14 * s)}) scale(${f(s)})`} />
        </g>
      ) : null}
    </g>
  )
}

/** Battlements: upright blocks round the rim of a finished tower that carries others. */
function Battlements({ cx, y, w }) {
  const Lt = [cx - w, y]
  const Ft = [cx, y + w / 2]
  const Rt = [cx + w, y]
  const Bt = [cx, y - w / 2]
  const C = [cx, y]
  const mw = Math.max(1.8, w * 0.1)
  const merlons = []
  ;[[Lt, Bt], [Bt, Rt], [Lt, Ft], [Ft, Rt]].forEach(([a, b], e) => {
    ;[0.2, 0.5, 0.8].forEach(k => {
      const q = lerp(lerp(a, b, k), C, 0.14)
      const fc = faces(q[0], q[1], mw, 5)
      merlons.push(
        <g key={`${e}${k}`} className="cc-merlon">
          <Poly p={fc.left} cls="cc-p cc-wood-l" />
          <Poly p={fc.right} cls="cc-p cc-wood-r" />
          <Poly p={fc.top} cls="cc-p cc-wood-t" />
        </g>,
      )
    })
  })
  return <g className="cc-battlements">{merlons}</g>
}

/** Rejected tasks: blocks lying on the ground in front of the tower, half pulled out of the way. */
function Loose({ cx, base, w, count }) {
  return (
    <g className="cc-loose">
      {Array.from({ length: count }, (_, i) => {
        const x = cx - ((count - 1) * 9) / 2 + i * 9
        const fc = faces(x, base + w / 2 + 5, 3.6, 3)
        return (
          <g key={i} className="cc-loose-block">
            <Poly p={fc.left} cls="cc-p cc-loose-l" />
            <Poly p={fc.right} cls="cc-p cc-loose-r" />
            <Poly p={fc.top} cls="cc-p cc-loose-t" />
          </g>
        )
      })}
    </g>
  )
}

/** The tower of one story: its status base, its layers (or its dashed foundation) and its top, with its own label. */
function Tower({ t, castle, hatch, text }) {
  const { cx, base, w, layerH } = t
  const els = []
  const baseY = base - castle.limits.slabH
  if (t.undecomposed) {
    const slab = faces(cx, base, w + castle.limits.slabPad, castle.limits.slabH)
    els.push(<g key="slab" className="cc-base cc-found"><Poly p={slab.left} cls="cc-p cc-found-p" /><Poly p={slab.right} cls="cc-p cc-found-p" /><Poly p={slab.top} cls="cc-p cc-found-p" /></g>)
    const fd = faces(cx, baseY, w, castle.limits.foundationH)
    els.push(<g key="fd" className="cc-foundation"><Poly p={fd.left} cls="cc-p cc-found-p" /><Poly p={fd.right} cls="cc-p cc-found-p" /><Poly p={fd.top} cls="cc-p cc-found-p" /><text className="cc-q" x={f(cx)} y={f(baseY - castle.limits.foundationH / 2 + 3)} textAnchor="middle">?</text></g>)
  } else {
    const slab = faces(cx, base, w + castle.limits.slabPad, castle.limits.slabH)
    els.push(
      <g key="slab" className={`cc-base cc-st-${t.status}`}>
        <Poly p={slab.left} cls="cc-p cc-base-l" />
        <Poly p={slab.right} cls="cc-p cc-base-r" />
        <Poly p={slab.top} cls="cc-p cc-base-t" />
      </g>,
    )
    t.layers.forEach((layer, i) => {
      els.push(<Layer key={`l${i}`} cx={cx} cy={baseY - i * layerH} w={w} h={layerH} layer={layer} isTop={i === t.layers.length - 1} hatch={hatch} />)
    })
    if (t.top === 'roof') els.push(<Roof key="top" cx={cx} y={t.topY} w={w} height={t.roofH} flag reached={castle.wall.reached} big />)
    else if (t.top === 'battlements') els.push(<Battlements key="top" cx={cx} y={t.topY} w={w} />)
  }
  if (t.looseCount > 0) els.push(<Loose key="loose" cx={cx} base={base} w={w} count={t.loose.length} />)
  const caption = text(t)
  return (
    <g className={`cc-tower cc-tower-${t.undecomposed ? 'undecomposed' : t.status}${t.lean ? ' cc-lean' : ''}`} data-tower={t.storyId} data-status={t.status} data-stacking={t.stacking} data-top={t.top} data-undecomposed={t.undecomposed ? 'true' : undefined} role="img" aria-label={caption}>
      <title>{caption}</title>
      {els}
    </g>
  )
}

/** A bridge deck with its piers, drawn under the story that stands on it. */
function Bridge({ t }) {
  if (!t.deck) return null
  const { x1, x2, y, thick } = t.deck
  return (
    <g className="cc-bridge" data-bridge={t.storyId} aria-hidden="true">
      {t.piers.map(p => (
        <g key={p.support} className="cc-pier">
          <Poly p={[[p.x - 3, p.y1], [p.x + 3, p.y1], [p.x + 3, p.y2 + thick], [p.x - 3, p.y2 + thick]]} cls="cc-p cc-pier-p" />
        </g>
      ))}
      <Poly p={[[x1, y], [x2, y], [x2, y + thick], [x1, y + thick]]} cls="cc-p cc-deck-front" />
      <Poly p={[[x1, y], [x2, y], [x2 + 3, y - 2], [x1 + 3, y - 2]]} cls="cc-p cc-deck-top" />
      {[0.2, 0.4, 0.6, 0.8].map(k => (
        <Line key={k} a={[x1 + (x2 - x1) * k, y]} b={[x1 + (x2 - x1) * k, y + thick]} cls="cc-plank" />
      ))}
    </g>
  )
}

/** A story's stack: what supports it (deck and piers), its tower, and the stories standing on it, which lean with it. */
function Stack({ id, byId, castle, hatch, text }) {
  const t = byId.get(id)
  const lean = t.lean ? `translate(${f(t.cx)} ${f(t.base)}) skewX(${-LEAN_DEG}) translate(${f(-t.cx)} ${f(-t.base)})` : undefined
  return (
    <g className="cc-stack" data-stack={id} transform={lean}>
      <Bridge t={t} />
      <Tower t={t} castle={castle} hatch={hatch} text={text} />
      {t.kids.map(k => (
        <Stack key={k} id={k} byId={byId} castle={castle} hatch={hatch} text={text} />
      ))}
    </g>
  )
}

/** The plank table the castle stands on. */
function Table({ castle }) {
  const { half, thick } = castle.table
  const tb = faces(0, thick, half, thick)
  const [Lt, Ft, Rt, Bt] = tb.top
  return (
    <g className="cc-table" aria-hidden="true">
      <Poly p={tb.left} cls="cc-p cc-table-l" />
      <Poly p={tb.right} cls="cc-p cc-table-r" />
      <Poly p={tb.top} cls="cc-p cc-table-t" />
      {[0.2, 0.4, 0.6, 0.8].map(k => (
        <Line key={k} a={lerp(Lt, Bt, k)} b={lerp(Ft, Rt, k)} cls="cc-seam" />
      ))}
    </g>
  )
}

/** One lying block of the curtain wall (built, or a wireframe slot), and the gate. */
function WallBlock({ b, wall }) {
  const { p0, p1 } = b
  const h = wall.height
  const side = `cc-wall-${b.side.toLowerCase()}`
  const cls = b.built ? `cc-p cc-wall ${side}` : 'cc-p cc-wall-wire'
  const q = (a, c) => [lerp(p0, p1, a), lerp(p0, p1, c)]
  const [q0, q1] = q(0.2, 0.45)
  const [q2, q3] = q(0.6, 0.85)
  const seam = lerp(p0, p1, b.index % 2 ? 0.35 : 0.65)
  return (
    <g className="cc-wall-block" data-built={b.built ? 'true' : 'false'} data-gate={b.gate ? 'true' : undefined}>
      <Poly p={[p0, p1, up(p1, h), up(p0, h)]} cls={cls} />
      {b.built ? <Line a={up(p0, h / 2)} b={up(p1, h / 2)} cls="cc-wall-seam" /> : null}
      {b.built ? <Line a={up(seam, h / 2)} b={up(seam, 0)} cls="cc-wall-seam" /> : null}
      <Poly p={[up(q0, h), up(q1, h), up(q1, h + wall.merlon), up(q0, h + wall.merlon)]} cls={cls} />
      <Poly p={[up(q2, h), up(q3, h), up(q3, h + wall.merlon), up(q2, h + wall.merlon)]} cls={cls} />
      {b.gate ? <Gate b={b} h={h} /> : null}
    </g>
  )
}

/** The gate: a dark block pulled out of the wall, with a lintel when the wall has reached it. */
function Gate({ b, h }) {
  const { p0, p1 } = b
  const b0 = lerp(p0, p1, 0.3)
  const b1 = lerp(p0, p1, 0.7)
  const l0 = lerp(p0, p1, 0.2)
  const l1 = lerp(p0, p1, 0.8)
  return (
    <g className="cc-gate" data-gate-built={b.built ? 'true' : 'false'}>
      <Poly p={[b0, b1, up(b1, h * 0.6), up(b0, h * 0.6)]} cls={b.built ? 'cc-p cc-gate-door' : 'cc-p cc-wall-wire'} />
      {b.built ? <Poly p={[up(l0, h * 0.6), up(l1, h * 0.6), up(l1, h * 0.82), up(l0, h * 0.82)]} cls="cc-p cc-wood-l" /> : null}
    </g>
  )
}

/** A bastion at a corner of the wall: a small tower of lying layers, with a roof once the goal is reached. */
function Bastion({ b, castle, hatch }) {
  const { bastionLayers: n, bastionLayerH: h, bastionHalf: w } = castle.limits
  const layers = Array.from({ length: n }, (_, i) => ({ direction: i % 2 ? 'z' : 'x', blocks: 3, blockStates: Array(3).fill(b.built ? 'done' : 'pending'), state: b.built ? 'done' : 'pending' }))
  return (
    <g className="cc-bastion" data-bastion={b.corner} data-built={b.built ? 'true' : 'false'} aria-hidden="true">
      {layers.map((layer, i) => (
        <Layer key={i} cx={b.x} cy={b.y - i * h} w={w} h={h} layer={layer} isTop={i === n - 1} hatch={hatch} />
      ))}
      {b.built && castle.wall.reached ? <Roof cx={b.x} y={b.y - n * h} w={w} height={w * 2} flag={b.corner !== 'F'} reached big={false} /> : null}
    </g>
  )
}

/** The hatch of a layer in progress. It sits inside the castle's own group (not in the SVG's <defs>) so the palette hook colours it. */
function HatchPattern({ gid }) {
  return (
    <pattern id={`dt-castle-hatch-${gid}`} width="3.4" height="3.4" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
      <rect className="cc-hatch-bg" width="3.4" height="3.4" />
      <rect className="cc-hatch-fg" width="1.3" height="3.4" />
    </pattern>
  )
}

/** The castle in the goal's own coordinates (centre 0,0): back wall, table, towers, front wall, then the effects group. */
function CitadelDrawing({ gid, castle, label, fill }) {
  if (!castle || !castle.wall) return null
  const hatch = `url(#dt-castle-hatch-${gid})`
  const byId = new Map(castle.towers.map(t => [t.storyId, t]))
  const text = t => towerCaption(t, label, fill)
  const { wall } = castle
  const frame = skyFrame(castle)
  const back = wall.blocks.filter(b => b.back)
  const front = wall.blocks.filter(b => !b.back)
  return (
    <g className="dt-castle dn-scene" data-castle="citadel" data-wall-share={wall.share.toFixed(2)} transform={`translate(0 ${f(castle.shiftY)}) scale(${f(castle.scale)})`}>
      <HatchPattern gid={gid} />
      <DaySky frame={frame} gid={gid} percent={wall.percent} />
      <Table castle={castle} />
      <g className="cc-wall-back" aria-hidden="true">
        {back.map(b => <WallBlock key={b.index} b={b} wall={wall} />)}
        {wall.bastions.filter(b => b.back).map(b => <Bastion key={b.corner} b={b} castle={castle} hatch={hatch} />)}
      </g>
      <g className="cc-towers">
        {castle.roots.map(r => (
          <Stack key={r} id={r} byId={byId} castle={castle} hatch={hatch} text={text} />
        ))}
      </g>
      <g className="cc-wall-front" aria-hidden="true">
        {front.map(b => <WallBlock key={b.index} b={b} wall={wall} />)}
        {wall.bastions.filter(b => !b.back).map(b => <Bastion key={b.corner} b={b} castle={castle} hatch={hatch} />)}
      </g>
      <g className="cc-effects" data-castle-effects="goal-reached" aria-hidden="true">{wall.reached ? <DayNightEffects frame={frame} /> : null}</g>
    </g>
  )
}

/** The edges to the goal end along the left of the wall, spread, instead of at one inset from the centre. */
function edgeAnchors(goal, count, castle) {
  return goalAnchors(castle, count).map(p => ({ x: goal.x + p.x, y: goal.y + p.y }))
}

/** The goal name line sits under the castle box. */
const textTop = castle => (castle && castle.text ? castle.text.top : 80)

const CitadelGoal = { goalArea: 'castle', role: 'group', edgeInset: 0, edgeAnchors, textTop, Defs: null, Drawing: CitadelDrawing, rootStyle: undefined }

export default CitadelGoal
