/**
 * zoomPanModel — E92_S06_T21. The maths of zoom and pan for the overlay dependency tree, as pure functions with no DOM
 * and no React, so every rule is unit tested in project/app/ui/scripts/tree-zoom-pan.test.cjs.
 *
 * A view is `{ k, x, y }`: a point `(wx, wy)` of the drawing is at `(wx * k + x, wy * k + y)` in pixels, measured from
 * the top-left corner of the viewport. `k` is the scale (1 = 100 %), always inside [MIN_SCALE, MAX_SCALE]. A `box` is the
 * drawing's own rectangle `{ x, y, w, h }`, a `size` is the viewport `{ w, h }` in pixels.
 *
 * The rules, copied from the approved prototype (project/documentation/prototypes/E92_S06/tree-prototype.html):
 *   - wheel zoom keeps the drawing point under the cursor where it is; ctrl (and so a trackpad pinch, which browsers
 *     report as ctrl + wheel) zooms four times faster;
 *   - two pointers pinch: the scale follows the distance, the drawing point under the midpoint follows the midpoint;
 *   - a pointer that moved more than DRAG_THRESHOLD pixels has dragged, so the click it ends is not a click;
 *   - Fit runs on the first render and when the epic changes (fitPlan), never because the data refreshed.
 */

export const MIN_SCALE = 0.25
export const MAX_SCALE = 3
export const DRAG_THRESHOLD = 4 // px
export const WHEEL_RATE = 0.0025 // per wheel delta pixel
export const WHEEL_RATE_CTRL = 0.01
export const BUTTON_STEP = 1.25
export const FIT_PAD = 16 // px of air around the drawing when it is fitted

const finite = n => typeof n === 'number' && Number.isFinite(n)

export function clampScale(k) {
  if (!finite(k) || k <= 0) return 1
  return Math.min(MAX_SCALE, Math.max(MIN_SCALE, k))
}

/** The percent shown in the readout, as a whole number. */
export function percentOf(view) {
  return Math.round(clampScale(view && view.k) * 100)
}

/** The CSS-pixel transform of the drawing group; rounded so tiny float noise does not change the markup. */
export function transformOf(view) {
  const r = n => Math.round(n * 1000) / 1000
  return `translate(${r(view.x)} ${r(view.y)}) scale(${r(view.k)})`
}

/** Factor a wheel event multiplies the scale by. `deltaMode` 1 is lines and 2 is pages, scaled to pixels. */
export function wheelFactor(deltaY, ctrlKey, deltaMode = 0) {
  const px = deltaMode === 1 ? 16 : deltaMode === 2 ? 400 : 1
  return Math.exp(-(finite(deltaY) ? deltaY : 0) * px * (ctrlKey ? WHEEL_RATE_CTRL : WHEEL_RATE))
}

/**
 * Multiply the scale by `factor` (clamped), keeping the drawing point that is at the viewport point `(cx, cy)` at
 * `(cx, cy)`. A clamped factor that changes nothing returns the same view.
 */
export function zoomAbout(view, factor, cx, cy) {
  const k = clampScale(view.k * (finite(factor) && factor > 0 ? factor : 1))
  if (k === view.k) return view
  const r = k / view.k
  return { k, x: cx - (cx - view.x) * r, y: cy - (cy - view.y) * r }
}

/** A wheel event `{ deltaY, deltaMode, ctrlKey }` at the viewport point `(cx, cy)`. */
export function wheelZoom(view, ev, cx, cy) {
  return zoomAbout(view, wheelFactor(ev.deltaY, !!ev.ctrlKey, ev.deltaMode), cx, cy)
}

/** The plus and minus buttons: zoom about the centre of the viewport. */
export function stepZoom(view, factor, size) {
  return zoomAbout(view, factor, size.w / 2, size.h / 2)
}

/** The 100 % button: scale 1 about the centre of the viewport. */
export function actualSize(view, size) {
  return zoomAbout(view, 1 / view.k, size.w / 2, size.h / 2)
}

/** Move the drawing by a pointer drag of `(dx, dy)` pixels. */
export function panBy(view, dx, dy) {
  return { k: view.k, x: view.x + dx, y: view.y + dy }
}

/** Whether a pointer that went from `(x0, y0)` to `(x1, y1)` has dragged rather than clicked. */
export function isDrag(x0, y0, x1, y1, threshold = DRAG_THRESHOLD) {
  return Math.hypot(x1 - x0, y1 - y0) > threshold
}

/**
 * Fit: the whole drawing inside the viewport, centred. The scale never goes below MIN_SCALE; a drawing that is still
 * larger than the viewport at that scale starts at the top-left corner (with `pad` of air), where the story starts and the
 * reader begins, instead of being centred and cut off on both sides.
 */
export function fitView(box, size, pad = FIT_PAD) {
  const w = Math.max(1, size.w - pad * 2)
  const h = Math.max(1, size.h - pad * 2)
  const k = clampScale(Math.min(w / Math.max(1, box.w), h / Math.max(1, box.h)))
  const place = (room, extent, origin) => (extent * k <= room ? (room - extent * k) / 2 : pad) - origin * k
  return { k, x: place(size.w, box.w, box.x), y: place(size.h, box.h, box.y) }
}

const mid = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 })
const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y)

/** What a pinch remembers from the moment the second pointer went down. `a` and `b` are viewport points. */
export function pinchStart(view, a, b) {
  return { view, d0: dist(a, b), mid0: mid(a, b) }
}

/**
 * The view of a pinch now that its pointers are at `a` and `b`: the scale is the starting scale times the ratio of the
 * distances, and the drawing point that was under the starting midpoint is under the current midpoint (so a pinch that
 * also moves pans). A zero starting distance gives the starting view.
 */
export function pinchView(start, a, b) {
  const { view, d0, mid0 } = start
  if (!(d0 > 0)) return view
  const k = clampScale(view.k * (dist(a, b) / d0))
  const m = mid(a, b)
  const wx = (mid0.x - view.x) / view.k
  const wy = (mid0.y - view.y) / view.k
  return { k, x: m.x - wx * k, y: m.y - wy * k }
}

/**
 * Whether to fit now. `lastKey` is the key (the epic id) of the last fit, null before the first; `touched` is whether
 * the user has zoomed or panned since. Fit on the first render, when the key changed, and on a resize of a view the
 * user has not touched; never because the same epic's data refreshed (the caller does not ask then).
 */
export function fitPlan(lastKey, key, touched) {
  if (key == null) return false
  if (lastKey == null || lastKey !== key) return true
  return !touched
}
