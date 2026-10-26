import { useState, useEffect, useCallback, useRef } from 'react'

// E47_S08_T02 — confirm before the dashboard is left with the browser Back button.
//
// How it works
//  - On mount a sentinel history entry is pushed on top of the entry the user arrived on:
//        [ ...earlier, arrival, sentinel* ]      (* = current)
//  - Back pops the sentinel and fires `popstate` with the arrival entry current. We re-push the sentinel
//    straight away (so the page never actually moved and the stack depth is constant, however many times
//    Back is pressed) and raise `confirming`, which the app renders as an in-app modal.
//  - Stay just closes the modal; tab, filters and expanded state live in React state and were never touched.
//  - Leave disables the guard and calls history.go(-2): back over the sentinel AND the arrival entry,
//    i.e. to whatever the user came from.
//  - `beforeunload` is the backstop for tab close and reload. Browsers show their own generic text there
//    (custom text is ignored) and only do so once the page has had a user interaction.
//
// Never trapping the user
//  - If there is no earlier entry (dashboard opened in a fresh tab, or a snapshot file opened directly),
//    go(-2) is a no-op. After a short timeout the hook then gives up: it tries window.close() (works for
//    script-opened windows only), closes the modal and leaves the guard OFF, so Back and tab close behave
//    natively from then on.
//  - If history.pushState is unavailable or throws (some sandboxed/opaque-origin documents), the Back guard
//    is simply not installed; only the beforeunload backstop remains.
//  - The sentinel is detected through history.state, so React StrictMode's double effect run, or a hot
//    reload, never stacks a second sentinel.
const SENTINEL = { jengaLeaveGuard: true }
const LEAVE_FALLBACK_MS = 400

function isSentinel(state) {
  return !!(state && state.jengaLeaveGuard)
}

function pushSentinel() {
  try {
    if (!isSentinel(window.history.state)) window.history.pushState(SENTINEL, '')
    return true
  } catch {
    return false
  }
}

export default function useLeaveGuard() {
  const [confirming, setConfirming] = useState(false)
  const disabled = useRef(false)

  useEffect(() => {
    disabled.current = false
    const hasSentinel = pushSentinel()

    function onPopState(e) {
      if (disabled.current) return
      // Forward navigation onto the sentinel (or any state we pushed ourselves): nothing to guard.
      if (isSentinel(e.state)) return
      // Back popped the sentinel: put it back and ask.
      pushSentinel()
      setConfirming(true)
    }
    function onBeforeUnload(e) {
      if (disabled.current) return undefined
      e.preventDefault()
      e.returnValue = ''
      return ''
    }

    if (hasSentinel) window.addEventListener('popstate', onPopState)
    window.addEventListener('beforeunload', onBeforeUnload)
    return () => {
      window.removeEventListener('popstate', onPopState)
      window.removeEventListener('beforeunload', onBeforeUnload)
    }
  }, [])

  const stay = useCallback(() => setConfirming(false), [])

  const leave = useCallback(() => {
    disabled.current = true
    setConfirming(false)
    const here = window.location.href
    try {
      window.history.go(-2)
    } catch {
      // fall through to the fallback below
    }
    // Still on the same document after the browser had time to navigate: there was nowhere to go back to.
    setTimeout(() => {
      if (window.location.href === here && document.visibilityState !== 'hidden') {
        try { window.close() } catch { /* not script-opened; leave the guard off */ }
      }
    }, LEAVE_FALLBACK_MS)
  }, [])

  return { confirming, stay, leave }
}
