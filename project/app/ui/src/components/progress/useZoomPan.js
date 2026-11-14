import { useState, useEffect, useRef } from 'react'
import {
  BUTTON_STEP,
  actualSize,
  fitPlan,
  fitView,
  isDrag,
  panBy,
  percentOf,
  pinchStart,
  pinchView,
  stepZoom,
  wheelZoom,
} from './zoomPanModel'
import { keepCentre } from './fullscreenModel'

/**
 * useZoomPan — E92_S06_T21. State and event wiring of the zoom and pan of the overlay dependency tree; every rule of
 * the maths lives in zoomPanModel.js (pure, unit tested). The hook only turns browser events into those functions.
 *
 *   const zoom = useZoomPan({ box, fitKey })
 *   <div ref={zoom.stageRef} {...zoom.handlers}> ... drawing in <g transform={transformOf(zoom.view)}> ... </div>
 *
 * `box` is the drawing's rectangle `{ x, y, w, h }` (null when there is nothing to draw), `fitKey` identifies what is
 * drawn (the epic id). The view is null until the viewport has been measured and fitted; the caller then lets the SVG
 * fit the drawing itself with a viewBox, so nothing is blank.
 *
 *   - Fit runs on the first measured render, when `fitKey` changes, and on a resize of a view the user has not touched
 *     (fitPlan). A refresh of the same epic's data changes `box` but neither `fitKey` nor the size, so it never refits
 *     and a zoomed view stays where the user put it.
 *   - `keepCentreOnResize` (default false, the hook then behaves exactly as before; E92_S07_T05): when on and the viewport
 *     size changes while the user has touched the view, the view is replaced by keepCentre(view, oldSize, newSize), the
 *     same scale with the drawing point at the old centre at the new centre. That adjustment is not a user touch. An
 *     untouched view is still refitted by fitPlan, unchanged; Fit is never newly triggered by it.
 *   - The wheel listener is a native, non-passive one: React's own wheel handler is passive and could not stop the
 *     overlay from scrolling.
 *   - A pointer capture is taken only once a drag has begun, never on pointer down, so a plain click is still delivered
 *     to the card under the pointer (a group expands). A click that ends a drag is swallowed in the capture phase.
 */

const NO_BOX = null

export default function useZoomPan({ box = NO_BOX, fitKey = null, keepCentreOnResize = false } = {}) {
  const stageRef = useRef(null)
  const [size, setSize] = useState(null)
  const [view, setView] = useState(null)
  const [dragging, setDragging] = useState(false)
  const holder = useRef(null)
  if (!holder.current) {
    holder.current = {
      view: null, size: null, box: null, fitKey: null, lastFitKey: null, touched: false,
      pointers: new Map(), pinch: null, dragged: false,
    }
  }
  const L = holder.current
  L.box = box
  L.fitKey = fitKey
  L.keepCentreOnResize = keepCentreOnResize === true

  const commit = (next, touch = true) => {
    if (!next || next === L.view) return
    L.view = next
    if (touch) L.touched = true
    setView(next)
  }
  const hasStage = box !== NO_BOX

  // Measure the viewport, follow its size, and listen for the wheel on it.
  useEffect(() => {
    const el = stageRef.current
    if (!el || !hasStage) return undefined
    const measure = () => {
      const r = el.getBoundingClientRect()
      if (!(r.width > 0 && r.height > 0)) return
      if (L.size && L.size.w === r.width && L.size.h === r.height) return
      const previous = L.size
      L.size = { w: r.width, h: r.height }
      // Opt-in: a touched view keeps the same part of the drawing centred in the new size; not a user touch.
      if (L.keepCentreOnResize && previous && L.touched && L.view) commit(keepCentre(L.view, previous, L.size), false)
      setSize(L.size)
    }
    const onWheel = e => {
      if (!L.view || !L.size) return
      if (e.preventDefault) e.preventDefault()
      const r = el.getBoundingClientRect()
      commit(wheelZoom(L.view, e, e.clientX - r.left, e.clientY - r.top))
    }
    measure()
    let observer = null
    if (typeof ResizeObserver !== 'undefined') {
      observer = new ResizeObserver(measure)
      observer.observe(el)
    } else if (typeof window !== 'undefined') {
      window.addEventListener('resize', measure)
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => {
      el.removeEventListener('wheel', onWheel)
      if (observer) observer.disconnect()
      else if (typeof window !== 'undefined') window.removeEventListener('resize', measure)
    }
  }, [hasStage])

  // Fit: first measured render, a different epic, or a resize of a view nobody touched. Not a data refresh.
  useEffect(() => {
    if (!size || !L.box) return
    if (!fitPlan(L.lastFitKey, L.fitKey, L.touched)) return
    if (L.lastFitKey !== L.fitKey) L.touched = false
    L.lastFitKey = L.fitKey
    commit(fitView(L.box, size), false)
  }, [size, fitKey])

  const local = e => {
    const r = e.currentTarget.getBoundingClientRect()
    return { x: e.clientX - r.left, y: e.clientY - r.top }
  }
  const capture = e => {
    try {
      if (e.currentTarget.setPointerCapture) e.currentTarget.setPointerCapture(e.pointerId)
    } catch {
      // A pointer that is already gone cannot be captured; the drag simply continues without it.
    }
  }
  const release = e => {
    try {
      if (e.currentTarget.releasePointerCapture) e.currentTarget.releasePointerCapture(e.pointerId)
    } catch {
      // Nothing was captured.
    }
  }

  const handlers = {
    onPointerDown(e) {
      if (!L.view) return
      if (e.pointerType === 'mouse' && e.button !== 0) return
      L.dragged = false
      L.pointers.set(e.pointerId, { x0: e.clientX, y0: e.clientY, p: local(e), dragged: false })
      if (L.pointers.size === 2) {
        const [a, b] = [...L.pointers.values()]
        L.pinch = pinchStart(L.view, a.p, b.p)
        for (const rec of L.pointers.values()) rec.dragged = true
        L.dragged = true
        setDragging(true)
      }
    },
    onPointerMove(e) {
      const rec = L.pointers.get(e.pointerId)
      if (!rec || !L.view) return
      const p = local(e)
      if (L.pinch && L.pointers.size >= 2) {
        rec.p = p
        const [a, b] = [...L.pointers.values()]
        commit(pinchView(L.pinch, a.p, b.p))
        return
      }
      if (!rec.dragged) {
        if (!isDrag(rec.x0, rec.y0, e.clientX, e.clientY)) return
        rec.dragged = true
        L.dragged = true
        capture(e)
        setDragging(true)
      }
      commit(panBy(L.view, p.x - rec.p.x, p.y - rec.p.y))
      rec.p = p
    },
    onPointerUp(e) {
      if (!L.pointers.delete(e.pointerId)) return
      release(e)
      if (L.pointers.size < 2) L.pinch = null
      if (L.pointers.size === 0) setDragging(false)
    },
    // Focusing a card that is out of view makes the browser scroll the clipping viewport, which would put the drawing out
    // of step with its transform; the view is the only thing that moves the drawing, so the scroll is undone.
    onScroll(e) {
      const el = e.currentTarget
      if (el && (el.scrollLeft || el.scrollTop)) {
        el.scrollLeft = 0
        el.scrollTop = 0
      }
    },
    onClickCapture(e) {
      if (!L.dragged) return
      L.dragged = false
      if (e.stopPropagation) e.stopPropagation()
      if (e.preventDefault) e.preventDefault()
    },
  }
  handlers.onPointerCancel = handlers.onPointerUp

  const step = factor => {
    if (L.view && L.size) commit(stepZoom(L.view, factor, L.size))
  }

  return {
    stageRef,
    view,
    size,
    dragging,
    percent: view ? percentOf(view) : null,
    handlers,
    zoomIn: () => step(BUTTON_STEP),
    zoomOut: () => step(1 / BUTTON_STEP),
    actual: () => {
      if (L.view && L.size) commit(actualSize(L.view, L.size))
    },
    fit: () => {
      if (!L.box || !L.size) return
      L.touched = false
      commit(fitView(L.box, L.size), false)
    },
  }
}
