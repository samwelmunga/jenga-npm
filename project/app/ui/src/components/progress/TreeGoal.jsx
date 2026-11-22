import './seasons-tree.css'
import { towerCaption } from './castleCaption'
import { DaySky, DayNightEffects } from './DayNightScene'
import { GROWTH_STAGES, curvePoint, curveTangent, girthAt, hsh, treeAnchors } from './treeLayout'

/**
 * TreeGoal - E92_S13_T07. The "seasons tree" goal design of the epic progress map: a storybook tree on a floating moss island above
 * a pool in a misty forest, drawn in pure SVG (story decision 9, prototype project/documentation/prototypes/E92_S13/seasons-tree.html).
 * It draws what treeLayout.js (geometry) made of castleModel.js (the per-story data, the tree parent and lean rule, the wall
 * share): the very same castle model object the citadel and the facade draw. No status, percent, count or position is worked
 * out here.
 *
 *   - The root story is the trunk and the heart of the crown, every other story a branch growing out of its parent's branch,
 *     leaning toward its other dependencies. Each counted task is one clump or twig round the branch tip, in census order (a status
 *     picture, not a dependency structure), told apart by shape as well as colour (E92_S11): done a full shaded outlined clump
 *     (summer), in progress a smaller pink clump in blossom with flowers (spring), to do a bare twig with snow (winter) and snow
 *     along a branch where nothing has started, failed a withered brown clump shedding dead leaves on a drooping branch. An
 *     undecomposed story is a dashed bare stub under snow, marked "?". A finished story nothing depends on hangs a vine with a
 *     lantern. A ribbon in the E92 colours is tied round each branch base. A detailed crown body (scalloped rim, leaves poking
 *     out, inner sub-clumps with contour lines, light edges, shade) sits behind the clumps, one for the crown and one per section.
 *   - The surroundings (the island, the grass, flowers, mushrooms, the stones of the pool, the light rays and the motes) read the
 *     epic percent and the goal-reached state only. At goal reached each crown section takes its own season tone, light rays
 *     fall, motes (day) or fireflies (night) drift, petals fall, birds fly by day, stars twinkle by night, a swing hangs from a
 *     low branch and two small forest spirits stand on the island. A rejected task is not counted and not drawn.
 *   - Day and night follow the dashboard's light and dark theme through CSS alone, exactly as in the castle designs and through
 *     the same shared DayNightScene.jsx (the sky, the sun or the moon, the birds, the twinkling stars); the tree adds its own
 *     palette, the `--color-tree-*` tokens of tokens.css mapped in seasons-tree.css. No colour literal and no movement here: every
 *     movement (sway, swing, falling petals and leaves, motes, drips, bobbing stones) is CSS, which reduced motion stops.
 *   - The text under the node (name, title, count, decomposed) is drawn by DependencyTree.jsx and not repeated here; only the
 *     stage track of the six growth stages is taken over from the prototype's HUD.
 *
 * Renderer contract (see StarGoal.jsx and CitadelGoal.jsx):
 *   goalArea     'tree'             the room the goal takes in the layout (dependencyTreeModel.js): the tree's own box
 *   role         'group'            the goal group's ARIA role: a group, because its branches are images of their own
 *   edgeInset    0                  unused: the edges end at edgeAnchors
 *   edgeAnchors  (goal, n, castle)  the n points where the edges to the goal end, down the left rim of the island
 *   textTop      (castle)           y of the goal name line under the tree (in the goal's coordinates)
 *   Defs         null (the gradients are part of the drawing, so the palette hook colours them)
 *   Drawing      the tree, props { goal, gid, castle, label, fill }; `castle` is the model's castle, which holds `tree`
 */

const f = n => Math.round(n * 100) / 100
const pts = a => a.map(p => `${f(p[0])},${f(p[1])}`).join(' ')
const D = Math.PI / 180
/** A clump whose radius is below this is drawn flat (an outline and a fill): at that size the detail is not visible, and a 94-task epic stays light. */
const FLAT_BELOW = 9
/** The layout's radius is the footprint; the bumps of a drawn clump reach about 1.15 of the radius they are given. */
const DRAW = 0.87

const FRAME_REF = 680 // the prototype's width: the far forest and the rays are laid out in these units, then spread over the frame

/** A tapered limb along a quadratic curve as one closed path. */
function taperPath(b, w0, w1) {
  const N = 16
  const A = []
  const B = []
  for (let i = 0; i <= N; i++) {
    const t = i / N
    const p = curvePoint(b, t)
    const d = curveTangent(b, t)
    const w = (w0 + (w1 - w0) * Math.pow(t, 0.7)) / 2
    A.push([p[0] - d[1] * w, p[1] + d[0] * w])
    B.push([p[0] + d[1] * w, p[1] - d[0] * w])
  }
  return `M${A.map(p => `${f(p[0])} ${f(p[1])}`).join(' L')} L${B.reverse().map(p => `${f(p[0])} ${f(p[1])}`).join(' L')}Z`
}

/** A stylised foliage clump: an outlined union of bumps, a mid layer, contour lines and highlights, leaf tips below. Its tones are the --tr-a/b/c of the group it sits in. */
function Clump({ x, y, r, seed, flat }) {
  const nb = 11
  const b = []
  for (let i = 0; i < nb; i++) {
    const a = (i / nb) * 2 * Math.PI + seed
    b.push([x + Math.cos(a) * r * 0.7, y + Math.sin(a) * r * 0.52, r * (0.34 + 0.1 * hsh(seed * 10 + i))])
  }
  b.push([x, y, r * 0.72])
  const els = []
  b.forEach(([bx, by, br], i) => els.push(<circle key={`o${i}`} className="tr-ink" cx={f(bx)} cy={f(by)} r={f(Math.max(0.1, br + 1.8))} />))
  if (!flat) {
    ;[-0.62, -0.2, 0.25, 0.66].forEach((q, i) => {
      const lx = x + q * r
      const ly = y + r * (0.42 - 0.06 * Math.abs(q))
      const rot = q * 40 + (i % 2 ? 8 : -8)
      els.push(<path key={`l${i}`} className="tr-leaf" transform={`translate(${f(lx)} ${f(ly)}) rotate(${f(rot)}) scale(${f(r / 24)})`} d="M0 -6 Q-4.5 2 0 10 Q4.5 2 0 -6Z" strokeWidth={f((1.8 * 24) / r)} />)
    })
  }
  b.forEach(([bx, by, br], i) => els.push(<circle key={`a${i}`} className="tr-a" cx={f(bx)} cy={f(by)} r={f(Math.max(0.1, br))} />))
  if (!flat) {
    b.filter(q => q[1] < y + r * 0.25).forEach(([bx, by, br], i) => els.push(<circle key={`b${i}`} className="tr-b" cx={f(bx + r * 0.05)} cy={f(by - r * 0.09)} r={f(Math.max(0.1, br * 0.84))} />))
    els.push(<circle key="bc" className="tr-b" cx={f(x + r * 0.04)} cy={f(y - r * 0.06)} r={f(r * 0.6)} />)
    ;[[-0.4, 0.1], [0.1, 0.25], [-0.05, -0.2], [0.4, 0]].forEach(([dx, dy], i) => {
      const vx = x + dx * r
      const vy = y + dy * r
      els.push(<path key={`c${i}`} className="tr-line-a" d={`M${f(vx - r * 0.14)} ${f(vy)} q${f(r * 0.14)} ${f(r * 0.12)} ${f(r * 0.28)} 0`} strokeWidth={f(Math.max(0.8, r * 0.05))} />)
    })
    b.filter(q => q[1] < y - r * 0.1).forEach(([bx, by, br], i) => els.push(<circle key={`h${i}`} className="tr-c" cx={f(bx + r * 0.1)} cy={f(by - r * 0.14)} r={f(Math.max(0.1, br * 0.44))} />))
    els.push(<circle key="hc" className="tr-c" cx={f(x + r * 0.2)} cy={f(y - r * 0.3)} r={f(r * 0.2)} />)
  }
  return <g className="tr-clump">{els}</g>
}

/** A crown body: a scalloped rim with leaves poking out, inner sub-clumps with contour lines, light edges and shade. */
function Mass({ x, y, r, seed }) {
  const nb = 13
  const b = []
  for (let i = 0; i < nb; i++) {
    const a = (i / nb) * 2 * Math.PI + seed
    b.push([x + Math.cos(a) * r * 0.72, y + Math.sin(a) * r * 0.54, r * (0.3 + 0.09 * hsh(seed * 10 + i))])
  }
  b.push([x, y, r * 0.74])
  const els = []
  b.forEach(([bx, by, br], i) => els.push(<circle key={`o${i}`} className="tr-ink" cx={f(bx)} cy={f(by)} r={f(br + 1.8)} />))
  for (let i = 0; i < 11; i++) {
    const a = seed * 3 + (i * 2 * Math.PI) / 11 + 0.2
    const lx = x + Math.cos(a) * r * 0.9
    const ly = y + Math.sin(a) * r * 0.68
    const rot = Math.atan2(Math.sin(a) * 0.68, Math.cos(a)) / D + 90
    const sc = (r / 60) * (0.8 + 0.4 * hsh(seed + i))
    els.push(<path key={`p${i}`} className="tr-leaf" transform={`translate(${f(lx)} ${f(ly)}) rotate(${f(rot)}) scale(${f(sc)})`} d="M0 4 Q-5 -4 0 -14 Q5 -4 0 4Z" strokeWidth={f(1.6 / sc)} />)
  }
  b.forEach(([bx, by, br], i) => els.push(<circle key={`a${i}`} className="tr-a" cx={f(bx)} cy={f(by)} r={f(br)} />))
  els.push(<ellipse key="sh" className="tr-ink tr-shade" cx={f(x)} cy={f(y + r * 0.32)} rx={f(r * 0.66)} ry={f(r * 0.22)} />)
  for (let i = 0; i < 8; i++) {
    const a = seed + (i * 2 * Math.PI) / 8 + 0.3
    const ring = i % 2 ? 0.52 : 0.3
    const cx = x + Math.cos(a) * r * ring
    const cy = y + Math.sin(a) * r * ring * 0.72 - r * 0.06
    const rr = r * (0.24 + 0.07 * hsh(seed * 7 + i))
    ;[[-0.5, 0.12, 0.6], [0, -0.14, 0.72], [0.5, 0.1, 0.58]].forEach(([dx, dy, q], j) => els.push(<circle key={`s${i}-${j}`} className="tr-b tr-soft" cx={f(cx + dx * rr)} cy={f(cy + dy * rr)} r={f(rr * q)} />))
    els.push(<path key={`k${i}`} className="tr-contour" d={`M${f(cx - rr)} ${f(cy + rr * 0.28)} q${f(rr * 0.33)} ${f(rr * 0.44)} ${f(rr * 0.66)} ${f(rr * 0.12)} q${f(rr * 0.33)} ${f(rr * 0.42)} ${f(rr * 0.66)} ${f(-rr * 0.04)} q${f(rr * 0.3)} ${f(rr * 0.34)} ${f(rr * 0.62)} ${f(-rr * 0.18)}`} />)
    els.push(<path key={`e${i}`} className="tr-line-c tr-edge" d={`M${f(cx - rr * 0.15)} ${f(cy - rr * 0.5)} q${f(rr * 0.3)} ${f(-rr * 0.16)} ${f(rr * 0.55)} ${f(rr * 0.08)}`} strokeWidth={f(Math.max(1, rr * 0.12))} />)
    if (hsh(seed * 3 + i) < 0.5) els.push(<path key={`v${i}`} className="tr-leaf tr-b tr-soft2" transform={`translate(${f(cx + rr * 0.35)} ${f(cy + rr * 0.05)}) rotate(${f(-30 + 60 * hsh(i + seed))}) scale(${f(rr / 30)})`} d="M0 0 Q-4 -6 0 -13 Q4 -6 0 0Z M0 0 L0 -11" strokeWidth={f(30 / rr)} />)
  }
  b.filter(q => q[1] < y - r * 0.2 && q[0] > x - r * 0.3).forEach(([bx, by, br], i) => els.push(<path key={`r${i}`} className="tr-line-c tr-edge" d={`M${f(bx - br * 0.55)} ${f(by - br * 0.35)} q${f(br * 0.5)} ${f(-br * 0.55)} ${f(br * 1.05)} ${f(-br * 0.05)}`} strokeWidth={f(Math.max(1.2, br * 0.14))} />))
  return <g className="tr-mass">{els}</g>
}

function Flower({ x, y, s, tone }) {
  const petals = []
  for (let i = 0; i < 5; i++) {
    const a = (i * 72 - 90) * D
    petals.push(<circle key={i} className={`tr-flower-${tone}`} cx={f(x + Math.cos(a) * s * 0.42)} cy={f(y + Math.sin(a) * s * 0.42)} r={f(s * 0.36)} />)
  }
  return <g className="tr-flower">{petals}<circle className="tr-flower-core" cx={f(x)} cy={f(y)} r={f(s * 0.2)} /></g>
}

const LeafShape = ({ x, y, s, rot, cls }) => <path className={`tr-fallen ${cls}`} transform={`translate(${f(x)} ${f(y)}) rotate(${f(rot)}) scale(${f(s)})`} d="M0 0 Q-3 -4 0 -9 Q3 -4 0 0Z" />

/** A bare twig with snow: the to-do state. `u` scales it with the clump slot it stands in. */
function Twig({ x, y, u }) {
  const p = (dx, dy) => `${f(x + dx * u)} ${f(y + dy * u)}`
  return (
    <g className="tr-twig">
      <path className="tr-wood-line" d={`M${p(0, 8)} L${p(0, -2)} M${p(0, 2)} L${p(-6, -6)} M${p(0, 0)} L${p(5, -7)}`} strokeWidth={f(1.6 * u)} />
      <ellipse className="tr-snow" cx={f(x - 6 * u)} cy={f(y - 7.5 * u)} rx={f(3 * u)} ry={f(1.7 * u)} />
      <ellipse className="tr-snow" cx={f(x + 5 * u)} cy={f(y - 8.5 * u)} rx={f(2.6 * u)} ry={f(1.5 * u)} />
      <path className="tr-bud" d={`M${p(0, -2)} C${p(-2.4, -4)} ${p(-1, -7)} ${p(0, -8)} C${p(1, -7)} ${p(2.4, -4)} ${p(0, -2)}Z`} strokeWidth={f(u)} />
    </g>
  )
}

const stateOf = b => (b.undecomposed ? 'todo' : b.status === 'done' ? 'done' : b.status === 'failed' ? 'fail' : b.status === 'in_progress' ? 'wip' : 'todo')
const labelState = s => (s === 'done' ? 'done' : s === 'failed' ? 'fail' : s === 'in_progress' ? 'wip' : 'todo')

/** The sky's backdrop, the forest, the light, the pool, the stones and the island: everything that grows with the percent only. */
function Backdrop({ L, gid }) {
  const { frame, surroundings: sur } = L
  const fw = frame.w
  const fx = x => frame.x + (x / FRAME_REF) * fw
  const iy = sur.islandY
  const iw = sur.islandHalfW
  const els = []
  // far forest trunks and canopies in haze
  ;[[30, 26, 0], [110, 18, 1], [600, 30, 0], [660, 20, 1], [520, 14, 1], [180, 12, 1]].forEach(([x, w, lay], i) => {
    const cx = fx(x)
    els.push(<path key={`ft${i}`} className={`tr-far tr-far-${lay}`} d={`M${f(cx - w / 2)} ${f(frame.y + frame.h)} L${f(cx - w * 0.35)} ${f(frame.y)} L${f(cx + w * 0.35)} ${f(frame.y)} L${f(cx + w / 2)} ${f(frame.y + frame.h)}Z`} />)
    ;[[0, 90], [-30, 140], [34, 170]].forEach(([dx, y], j) => els.push(<circle key={`fc${i}-${j}`} className={`tr-far tr-far-${lay}`} cx={f(cx + dx)} cy={f(frame.y + y - lay * 30)} r={30 + j * 6} />))
  })
  // light rays, stronger with the percent (day and night have their own strength; both are in the markup, the theme shows one)
  ;[['day', sur.rays.day], ['night', sur.rays.night]].forEach(([half, a]) => {
    els.push(
      <g key={`rays-${half}`} className={`tr-rays dn-${half}`}>
        {[[470, -40, 90], [540, -40, 60], [400, -40, 50]].map(([x, y, w], i) => (
          <polygon key={i} className="tr-ray" points={pts([[fx(x), frame.y + y + 40], [fx(x + w), frame.y + y + 40], [fx(x + w - 260), frame.y + frame.h], [fx(x - 300), frame.y + frame.h]])} fill={`url(#tr-ray-${gid})`} opacity={f(a * (1 - i * 0.25))} />
        ))}
      </g>,
    )
  })
  els.push(<ellipse key="fog1" className="tr-fog" cx={f(fx(80))} cy={f(frame.y + frame.h - 150 - 0)} rx="140" ry="26" opacity=".45" />)
  els.push(<ellipse key="fog2" className="tr-fog" cx={f(fx(620))} cy={f(frame.y + frame.h - 170)} rx="150" ry="24" opacity=".4" />)
  // the pool, with ripples and the island's reflection
  els.push(<rect key="pool" className="tr-pool" x={f(frame.x)} y={44} width={f(fw)} height={f(frame.y + frame.h - 44)} fill={`url(#tr-water-${gid})`} />)
  els.push(<ellipse key="refl" className="tr-ink tr-reflect" cx="0" cy="112" rx={f(90 + 70 * (iw - 95) / 75)} ry={f(16 + 6 * (iw - 95) / 75)} />)
  sur.poolRipples.forEach((s, i) => els.push(<ellipse key={`rp${i}`} className="tr-ripple" cx="0" cy="96" rx={f(70 * s)} ry={f(12 * s)} opacity={f(0.55 - i * 0.12)} />))
  // the stones lift out of the pool one by one (at 25, 45, 65 and 85 percent)
  sur.stones.filter(s => s.lifted).forEach((s, i) => {
    const { x, y, r } = s
    els.push(
      <g key={`st${i}`} className="tr-stone" data-at={s.at} style={{ '--tr-delay': `${s.delay}s` }}>
        <path className="tr-rock-a" d={`M${x - r} ${y} Q${x - r} ${f(y - r * 1.3)} ${x} ${f(y - r * 1.4)} Q${x + r} ${f(y - r * 1.3)} ${f(x + r * 0.9)} ${y} Q${f(x + r * 0.6)} ${f(y + r * 1.2)} ${x} ${f(y + r * 1.3)} Q${f(x - r * 0.8)} ${f(y + r * 1.1)} ${x - r} ${y}Z`} strokeWidth="1.2" />
        <path className="tr-moss-a" d={`M${f(x - r * 0.9)} ${f(y - r * 0.5)} Q${x} ${f(y - r * 1.6)} ${f(x + r * 0.85)} ${f(y - r * 0.6)} Q${f(x + r * 0.3)} ${f(y - r * 0.9)} ${f(x - r * 0.9)} ${f(y - r * 0.5)}Z`} />
        <path className="tr-snow" d={`M${f(x - r * 0.5)} ${f(y - r * 1.15)} Q${x} ${f(y - r * 1.55)} ${f(x + r * 0.5)} ${f(y - r * 1.15)} Q${x} ${f(y - r * 1.3)} ${f(x - r * 0.5)} ${f(y - r * 1.15)}Z`} />
      </g>,
    )
  })
  // the floating moss island, wider and mossier with the percent
  els.push(<path key="isl" className="tr-rock-b tr-outline" d={`M${f(-iw)} ${iy} L${f(-iw * 0.85)} ${iy + 38} L${f(-iw * 0.45)} ${iy + 64} L${f(-iw * 0.1)} ${iy + 92} L${f(iw * 0.25)} ${iy + 78} L${f(iw * 0.6)} ${iy + 60} L${f(iw * 0.92)} ${iy + 30} L${f(iw)} ${iy}Z`} strokeWidth="1.4" />)
  els.push(<path key="isl2" className="tr-line-ink" d={`M${f(-iw * 0.85)} ${iy + 38} L${f(-iw * 0.4)} ${iy + 20} L${f(-iw * 0.1)} ${iy + 92} M${f(iw * 0.25)} ${iy + 78} L${f(iw * 0.2)} ${iy + 24} L${f(iw * 0.92)} ${iy + 30}`} strokeWidth="1" opacity=".55" />)
  els.push(<path key="isl3" className="tr-rock-c" d={`M${f(-iw * 0.85)} ${iy + 38} L${f(-iw * 0.4)} ${iy + 20} L${f(-iw * 0.1)} ${iy + 92} L${f(-iw * 0.45)} ${iy + 64}Z`} opacity=".45" />)
  els.push(<ellipse key="moss1" className="tr-moss-b tr-outline" cx="0" cy={iy} rx={f(iw + 4)} ry={f(18 + (6 * (iw - 95)) / 75)} strokeWidth="1.4" />)
  els.push(<ellipse key="moss0" className="tr-moss-a" cx="-6" cy={iy - 3} rx={f(iw - 8)} ry={f(13 + (5 * (iw - 95)) / 75)} />)
  els.push(<ellipse key="glow" className="tr-glow dn-day" cx={f(iw * 0.3)} cy={iy - 2} rx={f(iw * 0.4)} ry="7" opacity={sur.glow} />)
  sur.tufts.forEach((t, i) => els.push(<path key={`tf${i}`} className="tr-moss-b" d={`M${f(t.x - 4)} ${f(t.y)} Q${f(t.x)} ${f(t.y + t.len)} ${f(t.x + 4)} ${f(t.y)}Z`} />))
  els.push(<ellipse key="moss2" className="tr-moss-c" cx={f(iw * 0.45)} cy={iy + 2} rx={f(iw * 0.25)} ry="5" opacity=".7" />)
  sur.roots.forEach((r, i) => els.push(<path key={`hr${i}`} className="tr-wood-line" d={`M${f(r.x)} ${f(r.y)} q${f(r.sway)} ${f(r.len * 0.5)} -1 ${f(r.len)}`} strokeWidth="1.1" />))
  sur.drips.forEach((d, i) => els.push(<g key={`dr${i}`} transform={`translate(${f(d.x)} ${f(d.y)})`}><path className="tr-drip" style={{ '--tr-delay': `${-d.delay}s` }} d="M0 0 C-1.6 3 -1.6 5 0 5.6 C1.6 5 1.6 3 0 0Z" /></g>))
  return <g className="tr-backdrop">{els}</g>
}

/** The tree itself: the crown bodies, the island roots, the wood, the snow, the ribbons, the twigs, the clumps, the stubs, the vines and the swing. */
function Tree({ L, label, fill }) {
  const g = L.growth
  const byId = new Map(L.branches.map(b => [b.storyId, b]))
  const trunk = L.branches.find(b => b.isTrunk)
  const reached = g.effects
  const toneClass = n => `tr-tone-${n}`
  const out = []

  if (L.crown) out.push(<g key="crown" className={reached ? 'tr-tone-crown' : 'tr-tone-canopy'}><Mass x={L.crown.x} y={L.crown.y} r={L.crown.r} seed={1.1} /></g>)
  L.sections.forEach(s => out.push(<g key={`sec-${s.storyId}`} className={toneClass(reached ? byId.get(s.storyId).tone : 0)} data-section={s.storyId}><Mass x={s.x} y={s.y} r={s.r} seed={s.si * 2.3} /></g>))

  // the roots flare over the island
  if (trunk) {
    const w0 = trunk.w0
    ;[[-1, 0.9], [-1, 0.45], [1, 0.5], [1, 1], [-0.1, 0.2]].forEach(([dir, kk], i) => {
      const st = [dir * w0 * 0.25, -w0 * 0.45]
      const en = [dir * (w0 * 0.75 + 30 * g.S * kk), 8 + kk * 4]
      const c = [st[0] + dir * w0 * 0.4, en[1] - 4]
      const rb = { p0: st, c, p1: en }
      out.push(
        <g key={`root${i}`} className="tr-root">
          <path className="tr-bark tr-outline" d={taperPath(rb, w0 * 0.42, 2)} strokeWidth="1.2" />
          <path className="tr-line-hi" d={`M${f(st[0] + (en[0] - st[0]) * 0.15)} ${f(st[1] + (en[1] - st[1]) * 0.15 - w0 * 0.1)} Q${f(c[0])} ${f(c[1] - w0 * 0.12)} ${f(st[0] + (en[0] - st[0]) * 0.8)} ${f(st[1] + (en[1] - st[1]) * 0.8 - 2)}`} strokeWidth={f(Math.max(0.8, w0 * 0.06))} />
        </g>,
      )
    })
  }

  // the wood of every branch: its own group is the branch for the screen reader and the tooltip
  L.branches.forEach(b => {
    const caption = towerCaption({ storyId: b.storyId, title: b.title, undecomposed: b.undecomposed, facts: b.facts }, label, fill)
    const els = []
    if (b.undecomposed) {
      els.push(<path key="stub" className="tr-stub-wood" d={taperPath(b, b.w0, b.w1)} />)
    } else {
      els.push(<path key="wood" className="tr-bark tr-outline" d={taperPath(b, b.w0, b.w1)} strokeWidth="1.3" />)
      if (b.isTrunk) {
        const c2 = [b.c[0] - b.w0 * 0.5, b.c[1]]
        els.push(<path key="shade" className="tr-bark-dark" d={taperPath({ p0: [b.p0[0] + b.w0 * 0.08, b.p0[1]], c: c2, p1: b.p1 }, b.w0 * 0.5, b.w1 * 0.6)} opacity=".55" />)
        ;[-0.3, -0.05, 0.22].forEach((off, j) => {
          const line = []
          for (let q = 0.04; q <= 0.82; q += 0.06) {
            const p = curvePoint(b, q)
            const d = curveTangent(b, q)
            const w = girthAt(b, q) / 2
            const tw = off + 0.12 * Math.sin(q * 9 + j * 2)
            line.push([p[0] - d[1] * w * tw * 2, p[1] + d[0] * w * tw * 2])
          }
          els.push(<polyline key={`tw${j}`} className="tr-line-ink" points={pts(line)} strokeWidth={f(Math.max(0.8, b.w0 * 0.035))} opacity=".55" />)
        })
        if (b.w0 > 18) {
          const p = curvePoint(b, 0.42)
          els.push(<ellipse key="knot" className="tr-knot" cx={f(p[0] + b.w0 * 0.12)} cy={f(p[1])} rx={f(b.w0 * 0.09)} ry={f(b.w0 * 0.15)} />)
        }
        ;[[-0.42, 0.06, 0.3], [0.3, 0.03, 0.24], [-0.1, 0.14, 0.2]].forEach(([dx, q, r], j) => {
          const p = curvePoint(b, q)
          els.push(<ellipse key={`mo${j}`} className="tr-moss-a" cx={f(p[0] + dx * b.w0)} cy={f(p[1])} rx={f(b.w0 * r)} ry={f(b.w0 * r * 0.45)} opacity=".9" />)
        })
      }
      const hl = [0.12, 0.5, 0.85].map(q => {
        const p = curvePoint(b, q)
        const d = curveTangent(b, q)
        const w = girthAt(b, q) / 2
        return [p[0] + d[1] * w * 0.45, p[1] - d[0] * w * 0.45]
      })
      els.push(<path key="hi" className="tr-line-hi" d={`M${f(hl[0][0])} ${f(hl[0][1])} Q${f(hl[1][0])} ${f(hl[1][1])} ${f(hl[2][0])} ${f(hl[2][1])}`} strokeWidth={f(Math.max(1, b.w0 * 0.13))} />)
      if (b.w0 > 14) [0.25, 0.55].forEach(q => { const p = curvePoint(b, q); els.push(<path key={`bk${q}`} className="tr-line-ink" d={`M${f(p[0] - b.w0 * 0.2)} ${f(p[1] + 6)} q${f(b.w0 * 0.1)} -8 0 -16`} strokeWidth="1" opacity=".6" />) })
    }
    out.push(
      <g key={`wood-${b.storyId}`} className={`tr-branch${b.droops ? ' tr-droop' : ''}${b.undecomposed ? ' tr-undecomposed' : ''}`} data-branch={b.storyId} data-status={b.status} data-undecomposed={b.undecomposed ? 'true' : undefined} role="img" aria-label={caption}>
        <title>{caption}</title>
        {els}
      </g>,
    )
  })

  // winter: snow along a branch where nothing has started
  L.branches.filter(b => b.snow).forEach(b => {
    const line = []
    for (let q = 0.15; q <= 0.95; q += 0.1) {
      const p = curvePoint(b, q)
      const d = curveTangent(b, q)
      const w = girthAt(b, q) / 2
      const nx = d[1]
      const ny = -d[0]
      const sg = ny < 0 ? 1 : -1
      line.push([p[0] + nx * w * sg, p[1] + ny * w * sg - 1])
    }
    out.push(<polyline key={`snow-${b.storyId}`} className="tr-snow-line" data-snow={b.storyId} points={pts(line)} strokeWidth={f(2.2 + 2 * g.S)} />)
  })

  // the status ribbons tied round each branch base, in the E92 colours
  L.branches.forEach(b => out.push(
    <g key={`rib-${b.storyId}`} transform={`translate(${f(b.ribbon.x)} ${f(b.ribbon.y)}) rotate(${f(b.ribbon.angle)})`}>
      <rect className={`tr-ribbon tr-st-${stateOf(b)}`} data-ribbon={b.storyId} x={f(-b.ribbon.w / 2 - 1)} y="-2.2" width={f(b.ribbon.w + 2)} height="4.4" rx="2" />
    </g>,
  ))

  // twigs join each clump to its branch
  L.clumps.forEach(c => {
    const b = byId.get(c.storyId)
    out.push(<line key={`tg-${c.taskId}`} className="tr-wood-line" x1={f(b.p1[0])} y1={f(b.p1[1])} x2={f(c.x)} y2={f(c.y + c.r * 0.3)} strokeWidth={f(1 + 1.6 * g.S)} />)
  })

  // the clumps, one group per story: done, in progress (blossom), to do (a bare twig with snow), failed (withered)
  L.branches.forEach(b => {
    const cs = L.clumps.filter(c => c.storyId === b.storyId)
    if (!cs.length) return
    const caption = towerCaption({ storyId: b.storyId, title: b.title, undecomposed: b.undecomposed, facts: b.facts }, label, fill)
    const tone = reached ? b.tone : 0
    out.push(
      <g key={`cl-${b.storyId}`} className="tr-crown" data-crown={b.storyId} aria-hidden="true">
        <title>{caption}</title>
        {cs.map(c => {
          const r = c.r * DRAW
          const flat = c.r < FLAT_BELOW
          if (c.state === 'done') return <g key={c.taskId} className={`tr-done ${toneClass(tone)}`} data-state="done"><Clump x={c.x} y={c.y} r={r} seed={c.si * 1.7 + c.i} flat={flat} /></g>
          if (c.state === 'failed') {
            return (
              <g key={c.taskId} className="tr-failed tr-tone-dead" data-state="failed">
                <Clump x={c.x} y={c.y + r * 0.25} r={r} seed={c.i + 3} flat={flat} />
                <path className="tr-crack" d={`M${f(c.x - r * 0.4)} ${f(c.y - r * 0.1)} l${f(r * 0.25)} ${f(r * 0.3)} l${f(-r * 0.12)} ${f(r * 0.25)} l${f(r * 0.35)} ${f(r * 0.3)}`} />
                <g transform={`translate(${f(c.x + r * 0.5)} ${f(c.y + r * 1.6)})`}><g className="tr-fall" style={{ '--tr-delay': '0s' }}><LeafShape x={0} y={0} s={f(Math.max(0.8, r / 14))} rot={140} cls="tr-b" /></g></g>
                <g transform={`translate(${f(c.x - r * 0.6)} ${f(c.y + r * 2.4)})`}><g className="tr-fall" style={{ '--tr-delay': '-2.2s' }}><LeafShape x={0} y={0} s={f(Math.max(0.7, r / 18))} rot={40} cls="tr-c" /></g></g>
              </g>
            )
          }
          if (c.state === 'in_progress') {
            return (
              <g key={c.taskId} className="tr-wip tr-tone-bloom" data-state="in_progress">
                <Clump x={c.x} y={c.y} r={r} seed={c.i + 5} flat={flat} />
                {flat ? null : [[-0.35, -0.15], [0.3, -0.25], [0, 0.15], [0.45, 0.15], [-0.5, 0.2]].map(([dx, dy], j) => <Flower key={j} x={c.x + dx * r} y={c.y + dy * r} s={r * 0.24} tone="c" />)}
                {flat ? <circle className="tr-flower-core" cx={f(c.x)} cy={f(c.y)} r={f(r * 0.2)} /> : null}
                {flat ? null : [[0.9, 0.9, 0], [-0.8, 1.4, 2.2]].map(([dx, dy, dl], j) => <g key={`p${j}`} transform={`translate(${f(c.x + dx * r)} ${f(c.y + dy * r)})`}><g className="tr-fall" style={{ '--tr-delay': `${-dl}s` }}><ellipse className="tr-petal" rx="2.4" ry="1.4" /></g></g>)}
              </g>
            )
          }
          return <g key={c.taskId} data-state="pending"><Twig x={c.x} y={c.y} u={Math.max(0.4, c.slotR / 22)} /></g>
        })}
      </g>,
    )
  })

  // a dormant stub for a story that is not decomposed: a dashed ring under snow, marked "?"
  L.stubs.forEach(s => out.push(
    <g key={`stub-${s.storyId}`} className="tr-stub" data-stub={s.storyId}>
      <circle className="tr-stub-ring" cx={f(s.x)} cy={f(s.y)} r={f(s.r)} />
      <ellipse className="tr-snow" cx={f(s.x)} cy={f(s.y - s.r * 0.85)} rx={f(s.r * 0.72)} ry={f(s.r * 0.34)} />
    </g>,
  ))

  // vines with lanterns on finished stories that nothing grows from; the lantern is lit at night
  L.vines.forEach(v => out.push(
    <g key={`vine-${v.storyId}`} className="tr-vine" data-vine={v.storyId} style={{ '--tr-delay': `${v.delay}s` }}>
      <path className="tr-vine-line" d={`M${f(v.x)} ${f(v.y0)} Q${f(v.x + 4)} ${f((v.y0 + v.y1) / 2)} ${f(v.x)} ${f(v.y1)}`} />
      <g className="tr-tone-0"><LeafShape x={v.x + 2} y={v.y0 + 8} s={1} rot={60} cls="tr-b" /><LeafShape x={v.x - 1} y={v.y0 + 15} s={0.9} rot={-60} cls="tr-c" /></g>
      <circle className="tr-lantern-glow dn-night" cx={f(v.x)} cy={f(v.y1 + 5)} r="11" />
      <rect className="tr-lantern" x={f(v.x - 3.6)} y={f(v.y1)} width="7.2" height="9.5" rx="2" />
      <line className="tr-lantern-bar" x1={f(v.x - 3.6)} y1={f(v.y1 + 4.7)} x2={f(v.x + 3.6)} y2={f(v.y1 + 4.7)} />
    </g>,
  ))

  // goal: a swing under a low limb
  if (L.effects.swing) {
    const { a, b, y } = L.effects.swing
    out.push(
      <g key="swing" className="tr-swing" data-effect="swing">
        <line className="tr-line-ink" x1={f(a[0])} y1={f(a[1])} x2={f(a[0])} y2={y} strokeWidth="1" />
        <line className="tr-line-ink" x1={f(b[0])} y1={f(b[1])} x2={f(b[0])} y2={y} strokeWidth="1" />
        <rect className="tr-seat" x={f(Math.min(a[0], b[0]) - 3)} y={y} width={f(Math.abs(b[0] - a[0]) + 6)} height="4" rx="1.5" />
      </g>,
    )
  }
  return <g className={`tr-tree${reached ? ' tr-sway' : ''}`}>{out}</g>
}

/** The island's life: grass, flowers, mushrooms and, at the goal, two forest spirits. */
function IslandLife({ L }) {
  const sur = L.surroundings
  const iy = sur.islandY
  const els = []
  sur.grass.forEach((g, i) => els.push(<path key={`g${i}`} className="tr-grass" d={`M${f(g.x)} ${f(iy + g.y)} q-2 -6 -4 -8 M${f(g.x)} ${f(iy + g.y)} q0 -7 1 -10 M${f(g.x)} ${f(iy + g.y)} q3 -5 5 -7`} />))
  sur.flowers.forEach((fl, i) => els.push(<Flower key={`f${i}`} x={fl.x} y={iy + fl.y} s={3.2} tone={'abcd'[fl.tone]} />))
  sur.mushrooms.forEach((m, i) => els.push(
    <g key={`m${i}`} className="tr-mushroom" data-mushroom="">
      <rect className="tr-stem" x={f(m.x - 1.4 * m.s)} y={f(iy - 8 * m.s)} width={f(2.8 * m.s)} height={f(7 * m.s)} />
      <path className="tr-cap" d={`M${f(m.x - 6 * m.s)} ${f(iy - 7 * m.s)} Q${f(m.x)} ${f(iy - 16 * m.s)} ${f(m.x + 6 * m.s)} ${f(iy - 7 * m.s)}Z`} strokeWidth=".8" />
    </g>,
  ))
  L.effects.spirits.forEach((s, i) => els.push(
    <g key={`sp${i}`} className={`tr-spirit tr-spirit-${'ab'[s.tone]}`} data-effect="spirit" transform={`translate(${f(s.x)} ${f(iy - 2)}) scale(${s.dir} 1)`}>
      <path className="tr-spirit-body" d="M-5 0 Q-6 -12 0 -13 Q6 -12 5 0Z" strokeWidth="1" />
      <circle className="tr-spirit-body" cx="0" cy="-16" r="6" strokeWidth="1" />
      <path className="tr-spirit-body" d="M-4 -20 L-6 -27 L-1 -21 M4 -20 L6 -27 L1 -21" strokeWidth="1" />
      <circle className="tr-ink" cx="-2" cy="-16" r=".9" />
      <circle className="tr-ink" cx="2" cy="-16" r=".9" />
    </g>,
  ))
  return <g className="tr-life">{els}</g>
}

/** The goal effects over the tree: falling petals and leaves, and the motes (day) or fireflies (night) that grow with the percent. */
function Floaters({ L }) {
  const { frame } = L
  return (
    <>
      <g className="tr-motes" aria-hidden="true">
        {L.surroundings.motes.map((m, i) => <g key={i} transform={`translate(${f(m.x)} ${f(m.y)})`}><circle className="tr-mote" r={m.r} style={{ '--tr-delay': `${m.delay}s` }} /></g>)}
      </g>
      {L.effects.active ? (
        <g className="tr-petals" data-effect="petals" aria-hidden="true">
          {L.effects.petals.map((p, i) => (
            <g key={i} transform={`translate(${f(p.x)} ${f(p.y)})`}>
              <g className="tr-fall tr-fall-long" style={{ '--tr-delay': `${-p.delay}s` }}>
                {p.leaf ? <g className={`tr-tone-${p.tone % 7}`}><LeafShape x={0} y={0} s={1.2} rot={i * 50} cls="tr-b" /></g> : <g className="tr-tone-bloom"><Flower x={0} y={0} s={3} tone="b" /></g>}
              </g>
            </g>
          ))}
        </g>
      ) : null}
      <g className="tr-foreground" aria-hidden="true">
        {[[frame.x, frame.y + frame.h, 1], [frame.x + frame.w, frame.y + frame.h, -1]].map(([x, y, dir], i) => (
          <g key={i}>
            {[[30, -60, 40, 0], [70, -30, 52, 1], [18, -110, 30, 1], [96, -70, 26, 0]].map(([dx, dy, s, ci], j) => (
              <path key={j} className={`tr-plant tr-plant-${ci}`} transform={`translate(${f(x + dir * dx)} ${f(y + dy)}) rotate(${f(dir * (30 - dx / 3))}) scale(${f((dir * s) / 10)} ${f(s / 10)})`} d="M0 0 Q-6 -8 0 -18 Q6 -8 0 0Z" />
            ))}
          </g>
        ))}
      </g>
    </>
  )
}

/** The pill of every branch: a status dot, the story id and its done count ("?" for a story not broken down), linked to its branch by a short leader line when it was pushed away. */
function Labels({ L }) {
  return (
    <g className="tr-labels" aria-hidden="true">
      {L.labels.map(l => (
        <g key={l.storyId} className="tr-label" data-label={l.storyId} data-moved={l.moved > 8 ? 'true' : undefined}>
          {l.moved > 8 ? <line className="tr-leader" x1={f(l.ax)} y1={f(l.ay)} x2={f(l.x)} y2={f(l.y)} /> : null}
          <rect className="tr-pill" x={f(l.x - l.w / 2)} y={f(l.y - l.h / 2)} width={f(l.w)} height={f(l.h)} rx={f(l.h / 2)} />
          <circle className={`tr-dot tr-st-${labelState(l.state)}`} cx={f(l.x - l.w / 2 + l.h / 2)} cy={f(l.y)} r={f(l.h * 0.2)} />
          <text className="tr-pill-text" x={f(l.x + l.h * 0.25)} y={f(l.y + l.font * 0.35)} textAnchor="middle" fontSize={l.font}>{l.text}</text>
        </g>
      ))}
    </g>
  )
}

/** The stage track (the prototype's HUD, without the HUD box): six dots, the current stage named under them. */
function StageTrack({ L, label, fill }) {
  const { track, growth } = L
  const u = track.u
  const stage = GROWTH_STAGES[growth.stage]
  const name = label(stage.labelKey)
  const n = GROWTH_STAGES.length
  const x = i => track.x0 + ((track.x1 - track.x0) * i) / (n - 1)
  const aria = fill(label('tree_stage_track'), name)
  return (
    <g className="tr-track" data-stage={stage.id} role="img" aria-label={aria}>
      <title>{aria}</title>
      <rect className="tr-pill" x={f(track.x0 - 14 * u)} y={f(track.y - 14 * u)} width={f(track.x1 - track.x0 + 28 * u)} height={f(46 * u)} rx={f(10 * u)} />
      <line className="tr-track-line" x1={f(track.x0)} y1={f(track.y)} x2={f(track.x1)} y2={f(track.y)} />
      {GROWTH_STAGES.map((s, i) => <circle key={s.id} className={`tr-stage-dot${i <= growth.stage ? ' tr-reached' : ''}${i === growth.stage ? ' tr-current' : ''}`} cx={f(x(i))} cy={f(track.y)} r={f((i === growth.stage ? 5 : 3) * u)} />)}
      <text className="tr-stage-name" x={f(x(growth.stage))} y={f(track.y + 20 * u)} textAnchor={growth.stage === 0 ? 'start' : growth.stage === n - 1 ? 'end' : 'middle'} fontSize={f(11 * u)}>{name}</text>
    </g>
  )
}

/** The tree in the goal's own coordinates (centre 0,0): the sky, the surroundings, the tree, the island's life, the floaters, the labels and the stage track. */
function TreeDrawing({ goal, gid, castle, label, fill }) {
  const L = castle && castle.tree
  if (!L || L.empty) return null
  const clip = `tr-clip-${gid}`
  return (
    <g className="dt-tree dn-scene" data-castle="tree" data-stage={GROWTH_STAGES[L.growth.stage].id} data-growth={L.growth.percent} data-wall-share={L.growth.k.toFixed(2)} transform={`translate(${f(L.shiftX)} ${f(L.shiftY)}) scale(${f(L.scale)})`}>
      <defs>
        <clipPath id={clip}><rect x={f(L.frame.x)} y={f(L.frame.y)} width={f(L.frame.w)} height={f(L.frame.h)} rx="10" /></clipPath>
        <linearGradient id={`tr-water-${gid}`} x1="0" y1="0" x2="0" y2="1"><stop className="tr-water-top" offset="0" /><stop className="tr-water-bottom" offset="1" /></linearGradient>
        <linearGradient id={`tr-ray-${gid}`} x1="0" y1="0" x2="0" y2="1"><stop className="tr-ray-stop" offset="0" stopOpacity=".9" /><stop className="tr-ray-stop" offset="1" stopOpacity="0" /></linearGradient>
      </defs>
      <g clipPath={`url(#${clip})`}>
        <DaySky frame={L.sky} gid={gid} percent={L.growth.percent} backdrop />
        <Backdrop L={L} gid={gid} />
        <Tree L={L} label={label} fill={fill} />
        <IslandLife L={L} />
        <Floaters L={L} />
        <g className="cc-effects tr-effects" data-castle-effects="goal-reached" aria-hidden="true">{L.effects.active ? <DayNightEffects frame={L.sky} /> : null}</g>
        <Labels L={L} />
        <StageTrack L={L} label={label} fill={fill} />
      </g>
    </g>
  )
}

/** The edges to the goal end along the left rim of the island, spread, instead of at one inset from the centre. */
function edgeAnchors(goal, count, castle) {
  return treeAnchors(castle && castle.tree, count).map(p => ({ x: goal.x + p.x, y: goal.y + p.y }))
}

/** The goal name line sits under the tree box. */
const textTop = castle => (castle && castle.tree && castle.tree.text ? castle.tree.text.top : 80)

const TreeGoal = { goalArea: 'tree', role: 'group', edgeInset: 0, edgeAnchors, textTop, Defs: null, Drawing: TreeDrawing, rootStyle: undefined }

export default TreeGoal
