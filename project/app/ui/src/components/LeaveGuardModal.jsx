import { useEffect, useRef } from 'react'
import './leave-guard-modal.css'

// E47_S08_T02 — in-app "leave the dashboard?" confirmation. Esc = Stay; Tab cycles between the two buttons;
// focus starts on Stay (the safe choice) and returns to the previously focused element when closed.
export default function LeaveGuardModal({ onStay, onLeave }) {
  const stayRef = useRef(null)
  const leaveRef = useRef(null)

  useEffect(() => {
    const previous = document.activeElement
    stayRef.current?.focus()
    function onKeyDown(e) {
      if (e.key === 'Escape') {
        e.preventDefault()
        onStay()
      } else if (e.key === 'Tab') {
        const order = [stayRef.current, leaveRef.current]
        const i = order.indexOf(document.activeElement)
        e.preventDefault()
        order[(i + (e.shiftKey ? order.length - 1 : 1)) % order.length]?.focus()
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      if (previous && typeof previous.focus === 'function') previous.focus()
    }
  }, [onStay])

  return (
    <div className="leave-guard-backdrop" onClick={onStay}>
      <div
        className="leave-guard-modal"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="leave-guard-title"
        onClick={e => e.stopPropagation()}
      >
        <p id="leave-guard-title" className="leave-guard-title">
          Are you sure you want to close down the dashboard?
        </p>
        <div className="leave-guard-actions">
          <button ref={stayRef} type="button" className="leave-guard-btn leave-guard-stay" onClick={onStay}>
            Stay
          </button>
          <button ref={leaveRef} type="button" className="leave-guard-btn leave-guard-leave" onClick={onLeave}>
            Leave
          </button>
        </div>
      </div>
    </div>
  )
}
