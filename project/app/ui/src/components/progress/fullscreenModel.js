/**
 * fullscreenModel — E92_S07_T01. The state, the Esc rule, the view centring and the focus trap of the large view of the
 * epic progress map, as pure functions with no React, no DOM access and no timers, so every rule is unit tested in
 * project/app/ui/scripts/fullscreen-model.test.cjs (technique of zoomPanModel.js).
 *
 * The element that becomes large is the tree's own root (section.dep-tree). It is never re-parented, so zoom, pan and
 * the hover chain survive the change. While the large view is open the root carries data-fullscreen="native" (the real
 * Fullscreen API) or data-fullscreen="fallback" (a fixed full-viewport layer); the attribute is absent when closed.
 *
 * This module does not read or change the Fit rules of zoomPanModel.js and imports nothing from it.
 */

/** The three modes of the large view; `rootMode` of an open state is the value of data-fullscreen. */
export const MODES = Object.freeze(['closed', 'native', 'fallback'])

const finite = n => typeof n === 'number' && Number.isFinite(n)
const usableSize = s => !!s && finite(s.w) && finite(s.h) && s.w > 0 && s.h > 0

/** Read `obj[key]` and say whether it is there; a getter that throws, or a missing object, counts as unavailable. */
function read(obj, key) {
  try {
    return obj ? obj[key] : undefined
  } catch (e) {
    return undefined
  }
}

/**
 * 'native' when the Fullscreen API can be used for `el` in `doc` (`doc.fullscreenEnabled` truthy, and `el.requestFullscreen`
 * or the webkit prefixed pair present), otherwise 'fallback'. Every property access is guarded; it never throws.
 */
export function fullscreenSupport(doc, el) {
  const unprefixed = !!read(doc, 'fullscreenEnabled') && typeof read(el, 'requestFullscreen') === 'function'
  const prefixed = !!read(doc, 'webkitFullscreenEnabled') && typeof read(el, 'webkitRequestFullscreen') === 'function'
  return unprefixed || prefixed ? 'native' : 'fallback'
}

export function initialState() {
  return { mode: 'closed' }
}

const modeState = mode => ({ mode })

/**
 * The next state for an event. An event that changes nothing returns the same state object, so a caller can compare.
 *   { type: 'enter', support }   the toggle was pressed; `support` is the result of fullscreenSupport
 *   { type: 'enterRefused' }     requestFullscreen was rejected: the fallback layer takes over, never closed, never stuck
 *   { type: 'syncNative', active }  a fullscreenchange result; only a `native` state follows it, and only out of it
 *   { type: 'exit' }             the toggle or the close control was pressed
 *   { type: 'escape' }           Esc reached the app (the browser keeps Esc in native mode)
 */
export function reduce(state, event) {
  const cur = state && MODES.includes(state.mode) ? state : initialState()
  const type = event && event.type
  switch (type) {
    case 'enter': {
      if (cur.mode !== 'closed') return cur
      return modeState(event.support === 'native' ? 'native' : 'fallback')
    }
    case 'enterRefused':
      return cur.mode === 'fallback' ? cur : modeState('fallback')
    case 'syncNative':
      // active=false while native: the browser left fullscreen. active=true never opens a closed model: only `enter` does.
      return cur.mode === 'native' && !event.active ? modeState('closed') : cur
    case 'exit':
      return cur.mode === 'closed' ? cur : modeState('closed')
    case 'escape':
      return cur.mode === 'fallback' ? modeState('closed') : cur
    default:
      return cur
  }
}

export function isOpen(state) {
  return !!state && (state.mode === 'native' || state.mode === 'fallback')
}

/** The value of data-fullscreen on the tree root, or null when the large view is closed (no attribute). */
export function rootMode(state) {
  return isOpen(state) ? state.mode : null
}

/** Label key of the toggle: the exit label while open, the enter label otherwise. */
export function toggleLabelKey(state) {
  return isOpen(state) ? 'fullscreen_exit' : 'fullscreen_enter'
}

/** What the app does on Esc: close the fallback layer; native Esc is consumed by the browser and arrives as fullscreenchange. */
export function escapeAction(state) {
  return state && state.mode === 'fallback' ? 'close' : 'none'
}

/**
 * The view `{ k, x, y }` after the viewport went from `oldSize` to `newSize` (`{ w, h }`): the same scale, and the drawing
 * point that was at the old viewport centre is at the new viewport centre. No clamp, no refit. An unusable size (missing,
 * zero, negative or not finite) or an unusable view returns the input unchanged.
 */
export function keepCentre(view, oldSize, newSize) {
  if (!view || !finite(view.k) || !finite(view.x) || !finite(view.y)) return view
  if (!usableSize(oldSize) || !usableSize(newSize)) return view
  return {
    k: view.k,
    x: view.x + (newSize.w - oldSize.w) / 2,
    y: view.y + (newSize.h - oldSize.h) / 2,
  }
}

/**
 * The index to focus after Tab (or Shift+Tab when `shift`) inside `count` focusable elements, wrapping both ways. No
 * element gives -1; an `index` outside the list (for example -1 when focus is elsewhere) gives the first element, or the
 * last one with `shift`.
 */
export function nextTabTarget(count, index, shift) {
  if (!Number.isInteger(count) || count <= 0) return -1
  if (!Number.isInteger(index) || index < 0 || index >= count) return shift ? count - 1 : 0
  if (shift) return index === 0 ? count - 1 : index - 1
  return index === count - 1 ? 0 : index + 1
}
