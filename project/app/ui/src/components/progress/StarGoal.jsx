/**
 * StarGoal — E92_S13_T05. The "star" goal design of the epic progress map: a star in a disc with a progress ring. It is the
 * Goal node as it was drawn in DependencyTree.jsx before the goal designs became selectable (E92_S06_T20, E92_S09,
 * E92_S10), moved here unchanged: the same markup, the same classes (dependency-tree.css still styles them), the same
 * numbers. It computes nothing of its own: the share (`goal.fraction`) and the goal-reached state (`goal.reached`) are
 * the epic_progress values the model already carries.
 *
 *   - Its halo strength and radius and the star's fill grow with the completed share; at the goal it turns done-green,
 *     shimmers and twinkles five sparks. Animation is CSS only and is stopped by prefers-reduced-motion: reduce and by
 *     :root[data-motion="off"] (dependency-tree.css), exactly as before.
 *   - An edge to the goal ends just inside the ring (ring radius 50): `edgeInset` is the former GOAL_EDGE_INSET.
 *
 * The renderer contract (every goal design in goalDesigns.js has this shape; the goal slot in DependencyTree.jsx reads it):
 *   edgeInset  number            how far left of the goal centre an edge to the goal ends
 *   Defs       component | null  rendered inside the SVG's <defs>; props { goal, gid }
 *   Drawing    component         rendered inside the goal group, in the goal's own coordinates (centre 0,0); props { goal, gid }
 *   rootStyle  (goal) => object  | undefined: CSS custom properties set on the goal group
 * The text under the node (name, title, count, decomposed) is drawn by DependencyTree.jsx for every design.
 * `gid` is the goal id reduced to characters that are safe in an SVG id.
 *
 * No word is written here (the star has none); colours are theme tokens in dependency-tree.css, no colour literal.
 */

// Star and spark outlines, copied from the prototype.
const STAR = 'M0 -22 L6.5 -7 L22.5 -6.8 L10 3.5 L14 19 L0 10 L-14 19 L-10 3.5 L-22.5 -6.8 L-6.5 -7Z'
const SPARK = 'M0 -6 L1.4 -1.4 L6 0 L1.4 1.4 L0 6 L-1.4 1.4 L-6 0 L-1.4 -1.4Z'
const SPARK_POSITIONS = [[-50, -46], [54, -38], [60, 28], [-58, 34], [0, -68]]

/** An edge to the goal ends just inside its ring (ring radius 50). */
export const GOAL_EDGE_INSET = 46

/** The gradients and clip paths of the star, for the SVG's <defs>. */
function StarDefs({ goal, gid }) {
  const fillH = 41 * goal.fraction
  return (
    <>
      <radialGradient id={`dt-halo-${gid}`} className={`dt-halo-grad${goal.reached ? ' dt-complete' : ''}`}>
        <stop className="dt-halo-stop-0" offset="0" />
        <stop className="dt-halo-stop-1" offset=".55" />
        <stop className="dt-halo-stop-2" offset="1" />
      </radialGradient>
      <linearGradient id={`dt-shine-${gid}`} x1="0" x2="1" y1="0" y2="0">
        <stop className="dt-shine-stop dt-shine-edge" offset="0" />
        <stop className="dt-shine-stop dt-shine-mid" offset=".5" />
        <stop className="dt-shine-stop dt-shine-edge" offset="1" />
      </linearGradient>
      <clipPath id={`dt-starclip-${gid}`}>
        <path d={STAR} />
      </clipPath>
      <clipPath id={`dt-starfill-${gid}`}>
        <rect className="dt-starfill-rect" x="-25" y={(19 - fillH).toFixed(2)} width="50" height={(fillH + 1).toFixed(2)} />
      </clipPath>
    </>
  )
}

/** Halo, ring, disc, star and, at the goal, the shimmer and the five sparks. */
function StarDrawing({ goal, gid }) {
  const ring = 2 * Math.PI * 50
  return (
    <>
      <g className="dt-halo-wrap">
        <circle className="dt-halo" r="54" fill={`url(#dt-halo-${gid})`} />
      </g>
      <circle className="dt-goal-ring-bg" r="50" />
      <circle className="dt-goal-ring" r="50" strokeDasharray={`${(ring * goal.fraction).toFixed(2)} ${ring.toFixed(2)}`} transform="rotate(-90)" />
      <circle className="dt-goal-disc" r="42" />
      <path className="dt-star-fill" d={STAR} clipPath={`url(#dt-starfill-${gid})`} />
      <path className="dt-star-outline" d={STAR} />
      {goal.reached ? (
        <g>
          <g clipPath={`url(#dt-starclip-${gid})`}>
            <g transform="rotate(20)">
              <rect className="dt-shimmer" x="-9" y="-40" width="18" height="80" fill={`url(#dt-shine-${gid})`} />
            </g>
          </g>
          <g className="dt-twinkles">
            {SPARK_POSITIONS.map(([x, y]) => (
              <g key={`${x},${y}`} transform={`translate(${x} ${y})`}>
                <path className="dt-spark" d={SPARK} />
              </g>
            ))}
          </g>
        </g>
      ) : null}
    </>
  )
}

/** Halo strength and radius grow with the completed share (read by .dt-halo-wrap and .dt-halo in dependency-tree.css). */
function starRootStyle(goal) {
  const p = goal.fraction
  return {
    '--goal-halo-opacity': (0.07 + 0.38 * p).toFixed(3),
    '--goal-halo-scale': ((54 + 26 * p) / 54).toFixed(3),
  }
}

const StarGoal = { edgeInset: GOAL_EDGE_INSET, Defs: StarDefs, Drawing: StarDrawing, rootStyle: starRootStyle }

export default StarGoal
