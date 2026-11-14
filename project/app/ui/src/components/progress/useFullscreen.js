import { useState, useEffect, useRef } from 'react'
import { escapeAction, fullscreenSupport, initialState, isOpen, reduce, rootMode } from './fullscreenModel'

/**
 * useFullscreen — E92_S07_T03. Event wiring of the large view of the epic progress map; every rule (the states, the Esc
 * rule) lives in fullscreenModel.js (pure, unit tested). The hook only turns browser events into model events, the way
 * useZoomPan.js wires zoomPanModel.js.
 *
 *   const fs = useFullscreen({ rootRef })     // rootRef: the ref to section.dep-tree
 *   fs.open, fs.mode ('closed' | 'native' | 'fallback'), fs.toggle(openerEl?), fs.exit()
 *
 * The root is never re-parented. While the large view is open it carries data-fullscreen="native" or "fallback"; the
 * fallback layer also sets data-dt-fullscreen="fallback" on <html> (page scroll lock). Both are removed on close.
 *
 *   - Enter: the opener (the passed element, an event's currentTarget, else document.activeElement) is remembered for the
 *     focus return. With native support the root is asked for fullscreen; the model stays closed until the browser reports
 *     the root fullscreen, so the hook never believes it is fullscreen when it is not. A synchronous throw, a rejected
 *     promise, a resolution that is not fullscreen on the root, or fullscreenerror becomes enterRefused: the fallback layer.
 *   - Sync: fullscreenchange (and the webkit name) on document feeds syncNative, so leaving by Esc or the browser UI ends in
 *     the same closed state as the close button.
 *   - Esc: only in the fallback, a window capture-phase keydown that closes the large view and stops the event, so the
 *     epic overlay's own document-level Escape handler does not also close the overlay. In native the browser consumes Esc
 *     and the hook registers nothing. The listener is removed on close and on unmount.
 *   - Exit (button, Esc, fullscreenchange, unmount): document.exitFullscreen() only while the root is the fullscreen
 *     element, both attributes removed, focus back to the opener on the next frame. A re-entrant exit is a no-op.
 *   - Every document, window and Fullscreen API access is guarded, so a file:// snapshot, an iframe without permission or a
 *     missing API never throws.
 */

const FS_ATTR = 'data-fullscreen'
const HTML_ATTR = 'data-dt-fullscreen'
const CHANGE_EVENTS = ['fullscreenchange', 'webkitfullscreenchange']
const ERROR_EVENTS = ['fullscreenerror', 'webkitfullscreenerror']

const getDocument = () => {
  try {
    return typeof document !== 'undefined' ? document : null
  } catch {
    return null // a blocked document (sandboxed frame) is the same as none
  }
}
const getWindow = () => {
  try {
    return typeof window !== 'undefined' ? window : null
  } catch {
    return null
  }
}
/** Read `obj[key]`; a getter that throws, or a missing object, reads as undefined. */
const read = (obj, key) => {
  try {
    return obj ? obj[key] : undefined
  } catch {
    return undefined
  }
}
const isThenable = v => !!v && typeof v.then === 'function'
/** The element that is fullscreen in `doc`, or null. */
const fullscreenElementOf = doc => read(doc, 'fullscreenElement') || read(doc, 'webkitFullscreenElement') || null
const isRootFullscreen = (doc, root) => !!root && fullscreenElementOf(doc) === root

function setAttribute(el, name, value) {
  try {
    if (!el) return
    if (value === null || value === undefined) el.removeAttribute(name)
    else el.setAttribute(name, value)
  } catch {
    // An element that refuses attributes leaves the large view without that hook; nothing else depends on it.
  }
}

/** Ask `root` for fullscreen through the pair that fullscreenSupport recognised; throws like the browser does. */
function requestFullscreen(doc, root) {
  if (read(doc, 'fullscreenEnabled') && typeof read(root, 'requestFullscreen') === 'function') return root.requestFullscreen()
  return root.webkitRequestFullscreen()
}

/** Leave real fullscreen; never throws, and a rejected promise is swallowed. */
function exitFullscreen(doc) {
  try {
    const fn = typeof read(doc, 'exitFullscreen') === 'function' ? 'exitFullscreen' : 'webkitExitFullscreen'
    if (typeof read(doc, fn) !== 'function') return
    const out = doc[fn]()
    if (isThenable(out)) out.then(undefined, () => {})
  } catch {
    // The browser left fullscreen already, or refuses to; the model is closed either way.
  }
}

/** The opener to give focus back to: an element, an event's currentTarget, else the focused element. */
function pickOpener(arg, doc) {
  const focusable = el => !!el && typeof read(el, 'focus') === 'function'
  if (focusable(arg)) return arg
  const target = read(arg, 'currentTarget')
  if (focusable(target)) return target
  const active = read(doc, 'activeElement')
  return focusable(active) ? active : null
}

export default function useFullscreen({ rootRef } = {}) {
  const [state, setState] = useState(initialState)
  const holder = useRef(null)
  if (!holder.current) {
    holder.current = { state, opener: null, root: null, pending: false, token: 0, escOn: false, unmounted: false, onKey: null }
  }
  const L = holder.current

  // The ref is already cleared when an unmounting component's cleanup runs, so the last root seen stands in for it.
  const rootEl = () => (rootRef ? read(rootRef, 'current') : null) || L.root

  // Window capture-phase Esc listener of the fallback layer.
  const addEsc = () => {
    if (L.escOn) return
    const win = getWindow()
    try {
      if (!win) return
      if (!L.onKey) {
        L.onKey = e => {
          if (!e || (e.key !== 'Escape' && e.key !== 'Esc')) return
          if (escapeAction(L.state) !== 'close') return
          if (e.stopPropagation) e.stopPropagation()
          if (e.preventDefault) e.preventDefault()
          commit(reduce(L.state, { type: 'escape' }))
        }
      }
      win.addEventListener('keydown', L.onKey, true)
      L.escOn = true
    } catch {
      // No window to listen on: the close button still closes the layer.
    }
  }
  const removeEsc = () => {
    if (!L.escOn) return
    L.escOn = false
    try {
      const win = getWindow()
      if (win && L.onKey) win.removeEventListener('keydown', L.onKey, true)
    } catch {
      // Nothing to remove from.
    }
  }

  const returnFocus = () => {
    const el = L.opener
    L.opener = null
    if (!el) return
    const go = () => {
      try {
        if (el.isConnected === false) return // the opener left the page
        if (typeof el.focus === 'function') el.focus()
      } catch {
        // An element that cannot take focus any more is skipped.
      }
    }
    let scheduled = false
    try {
      const win = getWindow()
      if (win && typeof win.requestAnimationFrame === 'function') {
        win.requestAnimationFrame(go)
        scheduled = true
      }
    } catch {
      // Fall through to the immediate focus.
    }
    if (!scheduled) go()
  }

  // Apply the side effects of a state change. Runs synchronously from commit, so a close is complete when it returns.
  const apply = (prev, next) => {
    const doc = getDocument()
    const root = rootEl()
    const mode = rootMode(next)
    setAttribute(root, FS_ATTR, mode)
    setAttribute(read(doc, 'documentElement'), HTML_ATTR, mode === 'fallback' ? 'fallback' : null)
    if (mode === 'fallback') addEsc()
    else removeEsc()
    if (isOpen(prev) && !isOpen(next)) {
      if (isRootFullscreen(doc, root)) exitFullscreen(doc)
      returnFocus()
    }
  }

  // The one place the model state changes. An event that changes nothing returns the same state, so it does nothing here.
  function commit(next) {
    if (!next || next === L.state) return false
    const prev = L.state
    L.state = next
    apply(prev, next)
    if (!L.unmounted) setState(next)
    return true
  }

  const settleRequest = token => {
    if (token !== L.token) {
      // The request was cancelled (exit or unmount) before the browser answered: leave a fullscreen it still granted.
      const doc = getDocument()
      if (isRootFullscreen(doc, rootEl())) exitFullscreen(doc)
      return
    }
    if (!L.pending) return // the change event came first and entered already
    if (isRootFullscreen(getDocument(), rootEl())) {
      L.pending = false
      commit(reduce(L.state, { type: 'enter', support: 'native' }))
    } else {
      refuseRequest(token)
    }
  }
  const refuseRequest = token => {
    if (token !== L.token || !L.pending) return
    L.pending = false
    commit(reduce(L.state, { type: 'enterRefused' }))
  }

  const enter = arg => {
    const root = rootEl()
    if (!root) return
    L.root = root
    const doc = getDocument()
    L.opener = pickOpener(arg, doc)
    const support = fullscreenSupport(doc, root)
    if (support !== 'native') {
      commit(reduce(L.state, { type: 'enter', support: 'fallback' }))
      return
    }
    L.pending = true
    const token = ++L.token
    let out
    try {
      out = requestFullscreen(doc, root)
    } catch {
      refuseRequest(token)
      return
    }
    if (isThenable(out)) {
      try {
        out.then(() => settleRequest(token), () => refuseRequest(token))
      } catch {
        refuseRequest(token)
      }
    }
    // No promise (older webkit): the fullscreenchange event decides.
  }

  const exit = () => {
    if (L.pending) {
      L.pending = false
      L.token++
      L.opener = null
    }
    commit(reduce(L.state, { type: 'exit' }))
  }

  // Follow the browser: fullscreenchange feeds syncNative; fullscreenerror refuses a request in flight.
  const onChange = () => {
    const doc = getDocument()
    const root = rootEl()
    const active = isRootFullscreen(doc, root)
    if (L.pending) {
      if (!active) return // a change of some other element
      L.pending = false
      commit(reduce(L.state, { type: 'enter', support: 'native' }))
      return
    }
    if (active && !isOpen(L.state)) {
      exitFullscreen(doc) // fullscreen on the root that the model never asked for (a cancelled request)
      return
    }
    commit(reduce(L.state, { type: 'syncNative', active }))
  }
  const onError = () => refuseRequest(L.token)
  L.onChange = onChange
  L.onError = onError

  useEffect(() => {
    L.unmounted = false
    const doc = getDocument()
    const listen = (events, fn) => {
      try {
        if (doc) for (const name of events) doc.addEventListener(name, fn)
      } catch {
        // No events from this document: the close button and Esc still work.
      }
    }
    const unlisten = (events, fn) => {
      try {
        if (doc) for (const name of events) doc.removeEventListener(name, fn)
      } catch {
        // Nothing to remove from.
      }
    }
    const change = () => L.onChange()
    const error = () => L.onError()
    listen(CHANGE_EVENTS, change)
    listen(ERROR_EVENTS, error)
    return () => {
      unlisten(CHANGE_EVENTS, change)
      unlisten(ERROR_EVENTS, error)
      L.unmounted = true
      if (L.pending) {
        L.pending = false
        L.token++
        L.opener = null
      }
      commit(reduce(L.state, { type: 'exit' }))
      removeEsc()
    }
  }, [])

  return {
    open: isOpen(state),
    mode: state.mode,
    toggle: arg => {
      if (isOpen(L.state)) exit()
      else if (!L.pending) enter(arg)
    },
    exit,
  }
}
