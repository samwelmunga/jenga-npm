import { facadeAnchors } from './facadeLayout'
import { towerCaption } from './castleCaption'
import { DaySky, DayNightEffects, skyFrame } from './DayNightScene'

/**
 * FacadeGoal - E92_S13_T03. The "facade" goal design of the epic progress map: the flat elevation of the Jenga castle drawn
 * in pure SVG (story decisions 1 to 5, prototype C3 in project/documentation/prototypes/E92_S13/jenga-castle.html). It draws
 * what facadeLayout.js (geometry) made of castleModel.js (what stands on what, the layers and their states, the wall share):
 * the very same castle model object the citadel draws. No status, percent, count or position is worked out here.
 *
 *   - One tower per story. A task is one layer, layers alternate like a real Jenga tower: a layer shows its block ENDS (three
 *     blocks side by side, k above the height cap) or ONE LONG block. done = wood with grain, in progress = the middle block
 *     pulled half out of its layer, hatched, with a dashed slot behind it (a long block juts out at its end), pending =
 *     wireframe, failed = a cracked red layer and the tower leans, a rejected task = a block lying beside the tower, an
 *     undecomposed story = a dashed foundation with a "?". Every state has its own shape or pattern (E92_S11).
 *   - A story on one story stands on its tower; a story on two or more stands on a bridge deck between them (piers where a
 *     support is lower). A finished leaf tower has a roof with a flag, a finished tower that carries others has battlements of
 *     upright blocks. Each tower stands on a status base in the E92 colours.
 *   - The curtain wall of lying blocks grows outward from the main building in BOTH directions by the model's wall share
 *     (nearest segments first, alternating left and right, the two bastions last); the gate is a block pulled out of the
 *     ground in front of the main building; the castle stands on a drawing-board ground (a dotted board, a ground line and a
 *     hatched strip).
 *   - Day and night (E92_S13_T04, story decision 2) follow the dashboard's light and dark theme through CSS alone, exactly as in
 *     the citadel and through the same shared DayNightScene.jsx: a sun drawn as an outline on the board whose height is the epic
 *     percent (day) or a crescent moon and dim stars (night), a lit window on the middle block of every finished layer end
 *     (night), a lit gate (the night value of the gate token) and, in the `cc-effects` group (the citadel's group) and only when
 *     the goal is reached, flapping birds (day) or twinkling stars (night). The colours are the one palette hook, the `--cc-*`
 *     custom properties of `.dt-castle`, and the shared `--dn-*` hook of `.dn-scene`, in dependency-tree.css. No colour literal
 *     and no movement here: the birds and the stars move in CSS, which reduced motion stops.
 *
 * Renderer contract (see StarGoal.jsx and CitadelGoal.jsx):
 *   goalArea     'facade'           the room the goal takes in the layout (dependencyTreeModel.js): the facade's own box
 *   role         'group'            the goal group's ARIA role: a group, because its towers are images of their own
 *   edgeInset    0                  unused: the edges end at edgeAnchors
 *   edgeAnchors  (goal, n, castle)  the n points where the edges to the goal end, down the left edge of the facade
 *   textTop      (castle)           y of the goal name line under the facade (in the goal's coordinates)
 *   Defs         null (the hatch pattern is part of the drawing, so the palette hook colours it)
 *   Drawing      the facade, props { goal, gid, castle, label, fill }; `castle` is the model's castle, which holds `facade`
 */

const LEAN_DEG = 4 // a tower with a failed task leans this far (and what stands on it leans with it)
const f = n => Math.round(n * 100) / 100
const STATE_CLASS = { done: 'cc-done', in_progress: 'cc-wip', pending: 'cc-pend', failed: 'cc-fail' }
const stateClass = s => STATE_CLASS[s] || 'cc-pend'

/** A zig-zag crack down a block (the failed layer's cue). */
function Crack({ x, y, w, h }) {
  const pts = [[0.5, 0], [0.6, 0.28], [0.42, 0.5], [0.58, 0.74], [0.5, 1]].map(([a, b]) => `${f(x + w * a)},${f(y + h * b)}`).join(' ')
  return <polyline className="cc-crack" points={pts} />
}

/** One block end, or one long block, in its own state. */
function Blk({ x, y, w, h, state, hatch, long, className }) {
  return <rect className={`cf-blk${long ? ' cf-long' : ''} ${stateClass(state)}${className ? ' ' + className : ''}`} x={f(x + 0.4)} y={f(y + 0.4)} width={f(w - 0.8)} height={f(h - 0.8)} rx="1.2" fill={state === 'in_progress' ? hatch : undefined} />
}

/** Concentric arcs: the end grain of a done block. */
function Grain({ x, y, w, h }) {
  const r = Math.min(w, h) * 0.2
  const cx = x + w / 2
  const cy = y + h * 0.62
  return <path className="cf-grain" d={`M${f(cx - r)} ${f(cy)} a${f(r)} ${f(r)} 0 0 1 ${f(2 * r)} 0 M${f(cx - r * 1.8)} ${f(cy)} a${f(r * 1.8)} ${f(r * 1.8)} 0 0 1 ${f(3.6 * r)} 0`} />
}

/** One layer: block ends side by side (direction x) or one long block (direction z), each block in its own state. */
function Layer({ cx, w, y, h, layer, hatch }) {
  const x0 = cx - w
  const n = layer.blocks
  const ends = layer.direction === 'x'
  const els = []
  if (ends) {
    const bw = (2 * w) / n
    for (let j = 0; j < n; j++) {
      const st = layer.blockStates[j]
      const x = x0 + j * bw
      // a block in progress is pulled half out of its layer (a normal layer pulls the middle one; a wide layer every block in progress)
      const pulled = st === 'in_progress' && (n !== 3 || j === 1)
      if (pulled) {
        els.push(<rect key={`s${j}`} className="cf-slot" x={f(x + 0.4)} y={f(y + 0.4)} width={f(bw - 0.8)} height={f(h - 0.8)} rx="1.2" />)
        els.push(<g key={`p${j}`} className="cf-pull"><Blk x={x - 2} y={y - 2} w={bw} h={h} state="in_progress" hatch={hatch} /></g>)
        continue
      }
      els.push(<Blk key={`b${j}`} x={x} y={y} w={bw} h={h} state={st} hatch={hatch} />)
      if (st === 'done' && bw > 7 && h >= 8) els.push(<Grain key={`g${j}`} x={x} y={y} w={bw} h={h} />)
      if (st === 'done' && j === Math.floor(n / 2) && bw > 7 && h >= 8) els.push(<rect key={`w${j}`} className="cf-win dn-night" x={f(x + bw * 0.3)} y={f(y + h * 0.28)} width={f(bw * 0.4)} height={f(h * 0.5)} rx="1" />)
      if (st === 'failed') els.push(<Crack key={`c${j}`} x={x} y={y} w={bw} h={h} />)
    }
  } else {
    els.push(<Blk key="long" x={x0} y={y} w={2 * w} h={h} state={layer.state} hatch={hatch} long />)
    if (layer.state === 'done') {
      ;[0.36, 0.68].forEach(k => els.push(<line key={`g${k}`} className="cc-grain" x1={f(x0 + 4)} y1={f(y + h * k)} x2={f(x0 + 2 * w - 4)} y2={f(y + h * k)} />))
    }
    if (layer.state === 'failed') els.push(<Crack key="crack" x={x0} y={y} w={2 * w} h={h} />)
    if (layer.state === 'in_progress') {
      // the long block is pulled half out: a hatched stub juts out of its end
      const pull = Math.min(6, Math.max(3, w * 0.4))
      els.push(<rect key="pull" className="cf-pull cf-stub" x={f(x0 + 2 * w - 1)} y={f(y + 2)} width={f(pull + 1)} height={f(h - 4)} rx="1.2" fill={hatch} />)
    }
  }
  return <g className="cf-layer" data-state={layer.state} data-form={ends ? 'ends' : 'long'}>{els}</g>
}

/** A roof with a flag (a finished leaf tower), or the roof of a bastion when the goal is reached. */
function Roof({ cx, y, w, height, reached, big }) {
  const L = [cx - w - 3, y]
  const R = [cx + w + 3, y]
  const A = [cx, y - height]
  const s = big ? 1 : 0.8
  const lerp = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
  return (
    <g className="cc-roof">
      <polygon className="cc-p cc-roof-l" points={[L, R, A].map(p => `${f(p[0])},${f(p[1])}`).join(' ')} />
      {[0.2, 0.4, 0.6, 0.8].map(k => {
        const p = lerp(L, R, k)
        return <line key={k} className="cc-plank" x1={f(p[0])} y1={f(p[1])} x2={f(A[0])} y2={f(A[1])} />
      })}
      <rect className="cc-p cc-wood-l cf-eave" x={f(L[0] - 2)} y={f(y - 1.5)} width={f(R[0] - L[0] + 4)} height="3.5" rx="1" />
      <g className={`cc-flag${reached ? ' cc-flag-reached' : ''}`}>
        <line className="cc-pole" x1={f(A[0])} y1={f(A[1])} x2={f(A[0])} y2={f(A[1] - 14 * s)} />
        <path className="cc-pennant" d="M0 0 L12 0 L8.5 3.5 L12 7 L0 7Z" transform={`translate(${f(A[0])} ${f(A[1] - 14 * s)}) scale(${f(s)})`} />
      </g>
    </g>
  )
}

/** Battlements: upright blocks along the top of a finished tower that carries others. */
function Battlements({ cx, y, w, h }) {
  const n = Math.max(2, Math.floor((2 * w) / 9))
  const mw = (2 * w) / (2 * n - 1)
  return (
    <g className="cc-battlements">
      {Array.from({ length: n }, (_, i) => (
        <rect key={i} className="cc-p cc-wood-l cf-merlon" x={f(cx - w + i * 2 * mw)} y={f(y - h)} width={f(mw)} height={f(h)} rx="0.8" />
      ))}
    </g>
  )
}

/** Rejected tasks: blocks lying on the ground beside the tower (in the gap to its right), half pulled out of the way. */
function Loose({ cx, base, w, count }) {
  return (
    <g className="cc-loose">
      {Array.from({ length: count }, (_, i) => {
        const x = cx + w + 2
        const y = base - 3 - (i + 1) * 3.4
        return (
          <g key={i} className="cc-loose-block" transform={`rotate(${i % 2 ? 5 : -4} ${f(x + 3.5)} ${f(y + 1.6)})`}>
            <rect className="cc-p cc-loose-l" x={f(x)} y={f(y)} width="7" height="3.2" rx="0.8" />
          </g>
        )
      })}
    </g>
  )
}

/** The tower of one story: its status base, its layers (or its dashed foundation) and its top, with its own label. */
function Tower({ t, limits, hatch, text, reached }) {
  const { cx, base, w, layerH } = t
  const baseY = base - limits.slabH
  const els = []
  if (t.undecomposed) {
    els.push(<rect key="slab" className="cf-found cf-slab" x={f(cx - w - limits.slabPad)} y={f(baseY)} width={f(2 * w + 2 * limits.slabPad)} height={limits.slabH} />)
    els.push(
      <g key="fd" className="cc-foundation">
        <rect className="cf-found" x={f(cx - w)} y={f(baseY - limits.foundationH)} width={f(2 * w)} height={limits.foundationH} />
        <text className="cc-q" x={f(cx)} y={f(baseY - limits.foundationH / 2 + 3)} textAnchor="middle">?</text>
      </g>,
    )
  } else {
    els.push(
      <g key="slab" className={`cc-base cc-st-${t.status}`}>
        <rect className="cc-p cf-slab" x={f(cx - w - limits.slabPad)} y={f(baseY)} width={f(2 * w + 2 * limits.slabPad)} height={limits.slabH} />
      </g>,
    )
    t.layers.forEach((layer, i) => {
      els.push(<Layer key={`l${i}`} cx={cx} w={w} y={baseY - (i + 1) * layerH} h={layerH} layer={layer} hatch={hatch} />)
    })
    if (t.top === 'roof') els.push(<Roof key="top" cx={cx} y={t.topY} w={w} height={t.roofH} reached={reached} big />)
    else if (t.top === 'battlements') els.push(<Battlements key="top" cx={cx} y={t.topY} w={w} h={limits.battlementH} />)
  }
  if (t.looseCount > 0) els.push(<Loose key="loose" cx={cx} base={base} w={w} count={t.loose.length} />)
  const caption = text(t)
  return (
    <g className={`cc-tower cf-tower cc-tower-${t.undecomposed ? 'undecomposed' : t.status}${t.lean ? ' cc-lean' : ''}`} data-tower={t.storyId} data-status={t.status} data-stacking={t.stacking} data-top={t.top} data-undecomposed={t.undecomposed ? 'true' : undefined} role="img" aria-label={caption}>
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
        <rect key={p.support} className="cc-p cc-pier-p cf-pier" x={f(p.x - 3)} y={f(p.y1)} width="6" height={f(p.y2 - p.y1 + thick)} />
      ))}
      <rect className="cc-p cc-deck-front" x={f(x1)} y={f(y)} width={f(x2 - x1)} height={thick} />
      {[0.2, 0.4, 0.6, 0.8].map(k => (
        <line key={k} className="cc-plank" x1={f(x1 + (x2 - x1) * k)} y1={f(y)} x2={f(x1 + (x2 - x1) * k)} y2={f(y + thick)} />
      ))}
    </g>
  )
}

/** A story's stack: what supports it (deck and piers), its tower, and the stories standing on it, which lean with it. */
function Stack({ id, byId, castle, hatch, text }) {
  const t = byId.get(id)
  const lean = t.lean ? `translate(${f(t.cx)} ${f(t.base)}) skewX(${-LEAN_DEG}) translate(${f(-t.cx)} ${f(-t.base)})` : undefined
  return (
    <g className="cc-stack cf-stack" data-stack={id} transform={lean}>
      <Bridge t={t} />
      <Tower t={t} limits={castle.limits} hatch={hatch} text={text} reached={castle.wall.reached} />
      {t.kids.map(k => (
        <Stack key={k} id={k} byId={byId} castle={castle} hatch={hatch} text={text} />
      ))}
    </g>
  )
}

/** The drawing-board ground: a dotted board behind the castle, the ground line and a hatched strip under it. */
function Ground({ castle, gid }) {
  const { left, right, top } = castle.natural
  const { strip } = castle.ground
  return (
    <g className="cf-ground" aria-hidden="true">
      <defs>
        <pattern id={`dt-facade-dots-${gid}`} width="14" height="14" patternUnits="userSpaceOnUse">
          <circle className="cf-dot" cx="1" cy="1" r="0.8" />
        </pattern>
        <pattern id={`dt-facade-ground-${gid}`} width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="skewX(-35)">
          <line className="cf-ground-hatch" x1="0" y1="0" x2="0" y2="6" />
        </pattern>
      </defs>
      <rect className="cf-board" x={f(left)} y={f(top)} width={f(right - left)} height={f(-top)} fill={`url(#dt-facade-dots-${gid})`} />
      <rect className="cf-ground-strip" x={f(left)} y="0" width={f(right - left)} height={strip} fill={`url(#dt-facade-ground-${gid})`} />
      <line className="cf-ground-line" x1={f(left)} y1="0" x2={f(right)} y2="0" />
    </g>
  )
}

/** One segment of the curtain wall: three courses of lying blocks and two merlons (built), or a wireframe slot (not yet built). */
function WallSegment({ s, wall }) {
  const w = s.x2 - s.x1
  const rh = wall.height / 3
  const cls = s.built ? 'cc-p cc-wall cf-wall' : 'cc-wall-wire'
  const rect = (x, y, ww, h, key) => <rect key={key} className={cls} x={f(x)} y={f(y)} width={f(ww)} height={f(h)} />
  return (
    <g className="cf-wall-block" data-built={s.built ? 'true' : 'false'} data-side={s.side} data-k={s.k}>
      {rect(s.x1, -rh, w, rh, 'c0')}
      {rect(s.x1, -2 * rh, w / 2, rh, 'c1a')}
      {rect(s.x1 + w / 2, -2 * rh, w / 2, rh, 'c1b')}
      {rect(s.x1, -3 * rh, w, rh, 'c2')}
      {rect(s.x1 + 2.5, -wall.height - wall.merlon, 5, wall.merlon, 'm0')}
      {rect(s.x2 - 7.5, -wall.height - wall.merlon, 5, wall.merlon, 'm1')}
    </g>
  )
}

/** A bastion at an outer end of the wall: a small tower of layers, with a roof and a flag once the goal is reached. */
function Bastion({ b, castle, hatch }) {
  const { bastionLayers: n, bastionLayerH: h, bastionW } = castle.limits
  const w = bastionW / 2
  const cx = (b.x1 + b.x2) / 2
  const state = b.built ? 'done' : 'pending'
  return (
    <g className="cf-bastion" data-bastion={b.side} data-built={b.built ? 'true' : 'false'} aria-hidden="true">
      {Array.from({ length: n }, (_, i) => (
        <Layer key={i} cx={cx} w={w} y={-(i + 1) * h} h={h} layer={{ direction: i % 2 ? 'z' : 'x', blocks: 3, blockStates: [state, state, state], state }} hatch={hatch} />
      ))}
      {b.built && castle.wall.reached ? <Roof cx={cx} y={-n * h} w={w} height={w * 1.6} reached big={false} /> : null}
    </g>
  )
}

/** The gate: a dark block pulled out of the ground in front of the main building (a wireframe slot until the wall has started). */
function Gate({ gate }) {
  const x = gate.x - gate.w / 2
  return (
    <g className="cf-gate" data-gate-built={gate.built ? 'true' : 'false'} aria-hidden="true">
      <rect className="cc-wall-wire" x={f(x)} y="1" width={gate.w} height={gate.h} rx="1" />
      {gate.built ? <rect className="cc-p cf-gate-door" x={f(x + 2)} y="2.5" width={gate.w} height={gate.h} rx="1" /> : null}
    </g>
  )
}

/** The hatch of a layer in progress. It sits inside the castle's own group (not in the SVG's <defs>) so the palette hook colours it. */
function HatchPattern({ gid }) {
  return (
    <pattern id={`dt-facade-hatch-${gid}`} width="3.4" height="3.4" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
      <rect className="cc-hatch-bg" width="3.4" height="3.4" />
      <rect className="cc-hatch-fg" width="1.3" height="3.4" />
    </pattern>
  )
}

/** The facade in the goal's own coordinates (centre 0,0): the board and ground, the wall, the towers, the gate, then the effects group. */
function FacadeDrawing({ gid, castle: model, label, fill }) {
  const castle = model && model.facade
  if (!castle || !castle.wall) return null
  const hatch = `url(#dt-facade-hatch-${gid})`
  const byId = new Map(castle.towers.map(t => [t.storyId, t]))
  const text = t => towerCaption(t, label, fill)
  const { wall } = castle
  const frame = skyFrame(castle)
  return (
    <g className="dt-castle dn-scene" data-castle="facade" data-wall-share={wall.share.toFixed(2)} transform={`translate(0 ${f(castle.shiftY)}) scale(${f(castle.scale)})`}>
      <HatchPattern gid={gid} />
      <DaySky frame={frame} gid={gid} percent={wall.percent} line />
      <Ground castle={castle} gid={gid} />
      <g className="cf-wall" aria-hidden="true">
        {wall.segments.map(s => <WallSegment key={`${s.side}${s.k}`} s={s} wall={wall} />)}
        {wall.bastions.map(b => <Bastion key={b.side} b={b} castle={castle} hatch={hatch} />)}
      </g>
      <g className="cc-towers cf-towers">
        {castle.roots.map(r => (
          <Stack key={r} id={r} byId={byId} castle={castle} hatch={hatch} text={text} />
        ))}
      </g>
      <Gate gate={castle.gate} />
      <g className="cc-effects" data-castle-effects="goal-reached" aria-hidden="true">{wall.reached ? <DayNightEffects frame={frame} /> : null}</g>
    </g>
  )
}

/** The edges to the goal end down the left edge of the facade, spread, instead of at one inset from the centre. */
function edgeAnchors(goal, count, castle) {
  return facadeAnchors(castle && castle.facade, count).map(p => ({ x: goal.x + p.x, y: goal.y + p.y }))
}

/** The goal name line sits under the facade box. */
const textTop = castle => (castle && castle.facade && castle.facade.text ? castle.facade.text.top : 80)

const FacadeGoal = { goalArea: 'facade', role: 'group', edgeInset: 0, edgeAnchors, textTop, Defs: null, Drawing: FacadeDrawing, rootStyle: undefined }

export default FacadeGoal
