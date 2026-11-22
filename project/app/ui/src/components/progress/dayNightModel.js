/**
 * dayNightModel - E92_S13_T04. The geometry of the day and night scene a goal design draws behind and over its subject: where the
 * sun and the moon stand, where the stars and the bird flocks are. Pure functions, no DOM and no colour: the colours are the
 * `--dn-*` custom properties of dependency-tree.css (day and night are the dashboard's light and dark theme, read by CSS only),
 * and the drawing is DayNightScene.jsx. It is SHARED: the citadel and the facade use it, and the seasons tree (E92_S13_T07) is
 * meant to call the same functions with its own box instead of copying them.
 *
 * It states no percent and no "goal reached": the sun's height is the percent the caller hands over (the existing
 * `epic_progress.percent`), and the birds and the twinkling stars are drawn by the caller only when the goal is reached
 * (`epic_progress.goal_reached`, the E92_S10 state). Nothing is counted here (E92 decision 1).
 *
 * A "frame" is the scene's box in the drawing's OWN coordinates (the group the designs scale): the designs lay their castle out
 * in a natural frame that is then scaled by `scale` and shifted by `shiftY` into the goal's frame, and the box is given in the
 * goal's frame. `skyFrame` turns the box back into the natural frame and carries `k`, the factor that keeps a sun, a bird or a star
 * the same size on screen however much the castle was scaled down.
 */

const round2 = v => Math.round(v * 100) / 100
const clampPercent = p => (typeof p === 'number' && isFinite(p) ? Math.min(100, Math.max(0, p)) : 0)

/** On-screen size of the scene's small things (sun, bird, star) as a multiple of the prototype's size at the castle's scale 1. */
export const SCENE_UNIT = 1.2

/** Where the sun stands across the box, and how far up it climbs: a fraction of the box height from its top. */
export const SUN = Object.freeze({ x: 0.86, low: 0.27, high: 0.09, radius: 15, halo: 22, rays: 12, rayIn: 20, rayOut: 30, rayOutShort: 26 })
/** The moon takes the sun's column, at a fixed height. */
export const MOON = Object.freeze({ x: 0.88, y: 0.18 })

/** A small star: four points, in a box of 12 x 12 around 0,0 (the shape of the old spark). */
export const STAR_PATH = 'M0 -6 L1.4 -1.4 L6 0 L1.4 1.4 L0 6 L-1.4 1.4 L-6 0 L-1.4 -1.4Z'
/** A bird in flight seen from the front: two arcs, 14 wide, around 0,0. */
export const BIRD_PATH = 'M-7 0 Q-3.5 -4.5 0 0 Q3.5 -4.5 7 0'
/** The crescent moon, 14 wide around 0,0. */
export const MOON_PATH = 'M0 -14 A14 14 0 0 0 0 14 A18 18 0 0 1 0 -14Z'

/** The dim stars that stand in the night sky whatever the progress: [fx, fy, big], fractions of the box. */
export const NIGHT_STARS = Object.freeze([
  [0.09, 0.08, 0], [0.19, 0.21, 1], [0.31, 0.05, 0], [0.7, 0.07, 1], [0.79, 0.28, 0], [0.13, 0.4, 0],
  [0.94, 0.42, 1], [0.62, 0.02, 0], [0.44, 0.17, 1], [0.25, 0.54, 0], [0.88, 0.56, 1], [0.07, 0.62, 0],
])

/** The stars that twinkle when the goal is reached: [fx, fy], fractions of the box, in the order of their delays. */
export const TWINKLE_STARS = Object.freeze([[0.3, 0.2], [0.7, 0.19], [0.5, 0.06], [0.37, 0.13], [0.63, 0.1], [0.82, 0.37]])

/** The birds that fly when the goal is reached: flocks of [fx, fy, size], fractions of the box. */
export const BIRD_FLOCKS = Object.freeze([
  [[0.28, 0.16, 1.1], [0.315, 0.143, 0.9], [0.347, 0.168, 1]],
  [[0.618, 0.086, 1], [0.656, 0.068, 0.85]],
  [[0.441, 0.06, 0.75], [0.468, 0.045, 0.65]],
])

/**
 * The scene's box in the drawing's own coordinates, from a layout that has `box`, `scale` and `shiftY` (castleLayout.js,
 * facadeLayout.js). Without a usable layout it is a plain 440 x 420 box at the origin, so a caller never has to guard.
 */
export function skyFrame(layout) {
  const b = layout && layout.box
  const s = layout && typeof layout.scale === 'number' && layout.scale > 0 ? layout.scale : 1
  const ty = layout && typeof layout.shiftY === 'number' ? layout.shiftY : 0
  if (!b || typeof b.w !== 'number' || typeof b.h !== 'number') return { x: -220, y: -210, w: 440, h: 420, k: round2(SCENE_UNIT) }
  return { x: round2(b.left / s), y: round2((b.top - ty) / s), w: round2(b.w / s), h: round2(b.h / s), k: round2(SCENE_UNIT / s) }
}

const at = (frame, fx, fy) => [round2(frame.x + frame.w * fx), round2(frame.y + frame.h * fy)]

/** Where the sun stands: its height follows the percent (0 low, 100 high), its place across the box is fixed. */
export function sunPosition(frame, percent) {
  const p = clampPercent(percent) / 100
  const [x, y] = at(frame, SUN.x, SUN.low + (SUN.high - SUN.low) * p)
  return { x, y }
}

/** Where the moon stands. */
export function moonPosition(frame) {
  const [x, y] = at(frame, MOON.x, MOON.y)
  return { x, y }
}

/** The ray segments of the sun around 0,0 (unscaled): alternate rays are a little shorter. */
export function sunRays() {
  return Array.from({ length: SUN.rays }, (_, i) => {
    const a = (i * 360 / SUN.rays) * Math.PI / 180
    const out = i % 2 ? SUN.rayOutShort : SUN.rayOut
    return { x1: round2(Math.cos(a) * SUN.rayIn), y1: round2(Math.sin(a) * SUN.rayIn), x2: round2(Math.cos(a) * out), y2: round2(Math.sin(a) * out) }
  })
}

/** The dim night stars placed in a frame: [{ x, y, r, dim }]. */
export function nightStars(frame) {
  return NIGHT_STARS.map(([fx, fy, big], i) => {
    const [x, y] = at(frame, fx, fy)
    return { x, y, r: round2((big ? 1.2 : 0.8) * frame.k), dim: i % 2 === 1 }
  })
}

/** The twinkling stars placed in a frame: [{ x, y, scale }]. */
export function twinkleStars(frame) {
  return TWINKLE_STARS.map(([fx, fy]) => {
    const [x, y] = at(frame, fx, fy)
    return { x, y, scale: round2(frame.k * 1.1) }
  })
}

/** The bird flocks placed in a frame: [[{ x, y, scale }]]. */
export function birdFlocks(frame) {
  return BIRD_FLOCKS.map(flock => flock.map(([fx, fy, size]) => {
    const [x, y] = at(frame, fx, fy)
    return { x, y, scale: round2(size * frame.k) }
  }))
}
