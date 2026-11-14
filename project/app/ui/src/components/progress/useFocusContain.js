import { useEffect } from 'react'
import { nextTabTarget } from './fullscreenModel'

/**
 * useFocusContain — E92_S07_T04. Keeps keyboard focus inside the large view of the epic progress map while it is open,
 * so no focus is lost to the epic overlay or the page behind it. Decision logic for the wrap is nextTabTarget in
 * fullscreenModel.js; this file only turns browser events into it.
 *
 *   useFocusContain({ rootRef, active })   // rootRef: the tree's own root (section.dep-tree); active: the view is open
 *
 *   - On activation focus moves to the first focusable control in the root (in practice the exit button), unless focus is
 *     already inside it. On deactivation nothing is done to focus: giving focus back belongs to useFullscreen.
 *   - Tab and Shift+Tab are handled on the root and wrap from the last control to the first and back. The list of controls
 *     is read again on every Tab, since groups expand and collapse. A Tab in the middle of the list is left to the browser.
 *   - A focusin on the document that lands outside the root sends focus back into it. In native fullscreen the browser
 *     already keeps the top layer isolated, so this never fires there and is harmless if it does.
 *   - No attribute is written to any element and no markup outside the root is touched. Only a Tab that wraps is
 *     default-prevented: every other key, the activation keys of the zoom buttons included, reaches its control.
 *   - Listeners exist only while active and are removed on deactivation and on unmount. Every DOM access is guarded.
 */

const FOCUSABLE = 'button, [href], input, select, textarea, [tabindex]'

/** Run `fn` and return its result; any throw gives `fallback` (a detached node or a foreign object must not break focus). */
function guard(fn, fallback) {
  try {
    return fn()
  } catch (e) {
    return fallback
  }
}

function hasAttr(el, name) {
  return guard(() => (typeof el.hasAttribute === 'function' ? !!el.hasAttribute(name) : false), false)
}

function isHidden(el) {
  if (guard(() => !!el.hidden, false) || hasAttr(el, 'hidden')) return true
  if (guard(() => String(el.type).toLowerCase() === 'hidden', false)) return true // input type=hidden
  const ancestor = guard(() => (typeof el.closest === 'function' ? el.closest('[hidden]') : null), null)
  return !!ancestor
}

function isDisabled(el) {
  return guard(() => !!el.disabled, false) || hasAttr(el, 'disabled')
}

function isTabbable(el) {
  const raw = guard(() => (typeof el.getAttribute === 'function' ? el.getAttribute('tabindex') : null), null)
  if (raw !== null && raw !== undefined && raw !== '') {
    const n = Number(raw)
    if (Number.isFinite(n) && n < 0) return false // tabindex="-1": focusable by script, not by Tab
  }
  return true
}

/** The focusable controls of `root` in document order, queried now: not disabled, not hidden, tabindex not negative. */
export function focusableIn(root) {
  const found = guard(() => (root && typeof root.querySelectorAll === 'function' ? root.querySelectorAll(FOCUSABLE) : null), null)
  if (!found) return []
  return Array.from(found).filter(el => !isDisabled(el) && !isHidden(el) && isTabbable(el))
}

function activeOf(doc) {
  return guard(() => (doc ? doc.activeElement : null), null)
}

function contains(root, el) {
  return !!el && guard(() => root.contains(el), false)
}

function focusEl(el) {
  guard(() => {
    if (el && typeof el.focus === 'function') el.focus()
  }, undefined)
}

/**
 * Contain focus in `root` until the returned function is called. Moves focus to the first control unless it is already
 * inside, adds the keydown listener on `root` and the focusin listener on its document, and returns the cleanup that
 * removes both. A root that cannot take listeners gives a no-op cleanup.
 */
export function containFocus(root) {
  const noop = () => {}
  if (!root || typeof root.addEventListener !== 'function') return noop
  const doc = guard(() => root.ownerDocument || (typeof document !== 'undefined' ? document : null), null)

  if (!contains(root, activeOf(doc))) focusEl(focusableIn(root)[0])

  const onKeyDown = e => {
    if (!e || e.key !== 'Tab' || e.ctrlKey || e.altKey || e.metaKey) return
    const list = focusableIn(root)
    const shift = !!e.shiftKey
    const index = list.indexOf(activeOf(doc))
    const target = nextTabTarget(list.length, index, shift)
    if (target < 0) {
      guard(() => e.preventDefault(), undefined) // nothing to Tab to: keep focus where it is
      return
    }
    const atEdge = index < 0 || (shift ? index === 0 : index === list.length - 1)
    if (!atEdge) return // the browser moves focus inside the list by itself
    guard(() => e.preventDefault(), undefined)
    focusEl(list[target])
  }

  const onFocusIn = e => {
    const el = e && e.target
    if (!el || contains(root, el)) return
    focusEl(focusableIn(root)[0])
  }

  guard(() => root.addEventListener('keydown', onKeyDown), undefined)
  guard(() => doc && doc.addEventListener('focusin', onFocusIn), undefined)

  return () => {
    guard(() => root.removeEventListener('keydown', onKeyDown), undefined)
    guard(() => doc && doc.removeEventListener('focusin', onFocusIn), undefined)
  }
}

export default function useFocusContain({ rootRef, active } = {}) {
  useEffect(() => {
    if (!active) return undefined
    const root = rootRef ? rootRef.current : null
    if (!root) return undefined
    return containFocus(root)
  }, [rootRef, active])
}
