import { useState, useEffect } from 'react'
import { MOTION_ICON, NEXT_MOTION, applyMotion, osReducesMotion, readMotionAttr } from './motionPreference'

// E92_S06_T21 — Animations toggle (Auto <-> Off), hosted in App.jsx's header next to ThemeToggle and styled by the same
// `.theme-toggle` rules. Initial state comes from the `data-motion` attribute that index.html's inline script already
// resolved before first paint. The words come from the progress labels payload (scripts/lib/progress-labels.sh, keys
// motion_*) handed in as `labels`; until it arrives (or if it never does) the button shows its icon only and carries no
// name, because no word is written in this file.
function fill(template, value) {
  return template.replace(/%s/, value)
}

export default function MotionToggle({ labels }) {
  const [mode, setMode] = useState(() => readMotionAttr(document.documentElement))
  const [osReduce, setOsReduce] = useState(osReducesMotion)

  useEffect(() => {
    let mq
    try {
      mq = window.matchMedia('(prefers-reduced-motion: reduce)')
    } catch {
      return undefined
    }
    const onChange = e => setOsReduce(e.matches)
    if (mq.addEventListener) mq.addEventListener('change', onChange)
    return () => { if (mq.removeEventListener) mq.removeEventListener('change', onChange) }
  }, [])

  const word = key => (labels && typeof labels[key] === 'string' ? labels[key] : '')
  const stateName = m => word(m === 'off' ? 'motion_off' : 'motion_auto')
  const next = NEXT_MOTION[mode]

  let label = ''
  let long = ''
  if (word('motion_label') && stateName(mode)) {
    const note = mode === 'auto' && osReduce && word('motion_os_reduced') ? ` (${word('motion_os_reduced')})` : ''
    label = `${word('motion_label')}: ${stateName(mode)}${note}`
    long = word('motion_activate') && stateName(next) ? `${label}. ${fill(word('motion_activate'), stateName(next))}` : label
  }

  function apply(to) {
    setMode(applyMotion(to, document.documentElement))
  }

  return (
    <button
      type="button"
      className="theme-toggle motion-toggle"
      data-motion-state={mode}
      onClick={() => apply(next)}
      aria-label={long || undefined}
      title={label || undefined}
    >
      <span aria-hidden="true">{MOTION_ICON[mode]}</span>
      {label ? <span className="theme-toggle-label">{label}</span> : null}
    </button>
  )
}
