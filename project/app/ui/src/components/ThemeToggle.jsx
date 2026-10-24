import { useState, useEffect } from 'react'

// E47_S07_T02 — three-state theme control (system -> light -> dark -> system).
// Initial state comes from the `data-theme` attribute that index.html's inline script already
// resolved before first paint (not from a second, independent localStorage read). Every storage
// access is guarded: under file:// or with storage blocked the toggle still works for the session.
const STORAGE_KEY = 'jenga-dashboard-theme'
const NEXT = { system: 'light', light: 'dark', dark: 'system' }
const ICON = { system: '◐', light: '☀', dark: '☾' }

function readAttr() {
  const t = document.documentElement.dataset.theme
  return t === 'light' || t === 'dark' ? t : 'system'
}

function osPrefersDark() {
  try {
    return window.matchMedia('(prefers-color-scheme: dark)').matches
  } catch {
    return false
  }
}

export default function ThemeToggle() {
  const [mode, setMode] = useState(readAttr)
  const [osDark, setOsDark] = useState(osPrefersDark)

  useEffect(() => {
    let mq
    try {
      mq = window.matchMedia('(prefers-color-scheme: dark)')
    } catch {
      return undefined
    }
    const onChange = e => setOsDark(e.matches)
    if (mq.addEventListener) mq.addEventListener('change', onChange)
    return () => { if (mq.removeEventListener) mq.removeEventListener('change', onChange) }
  }, [])

  function apply(next) {
    const root = document.documentElement
    if (next === 'system') delete root.dataset.theme
    else root.dataset.theme = next
    try {
      if (next === 'system') window.localStorage.removeItem(STORAGE_KEY)
      else window.localStorage.setItem(STORAGE_KEY, next)
    } catch {
      // Storage unavailable (blocked, or file:// in some browsers): session-only.
    }
    setMode(next)
  }

  const label = mode === 'system'
    ? `System (${osDark ? 'dark' : 'light'})`
    : mode === 'light' ? 'Light' : 'Dark'

  return (
    <button
      type="button"
      className="theme-toggle"
      onClick={() => apply(NEXT[mode])}
      aria-label={`Theme: ${label}. Activate to switch to ${NEXT[mode]}.`}
      title={`Theme: ${label}`}
    >
      <span aria-hidden="true">{ICON[mode]}</span>
      <span className="theme-toggle-label">{label}</span>
    </button>
  )
}
