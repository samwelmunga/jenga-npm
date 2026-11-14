/**
 * FullscreenToggle — E92_S07_T07. The button that opens and closes the large view of the epic progress map, plus the
 * visible Esc hint while the view is open. Presentational, like ZoomControls.jsx: it takes the strings already resolved
 * from the labels payload (scripts/lib/progress-labels.sh, keys fullscreen_*) and the handler of useFullscreen. The state
 * itself lives in fullscreenModel.js and useFullscreen.js; this file decides nothing.
 *
 * No word is written here. `label` is the string for the current state (fullscreen_enter while closed, fullscreen_exit
 * while open) and `hint` is fullscreen_hint; one the labels did not supply is empty, and then the button shows only its
 * icon and carries no accessible name until the labels arrive (the ZoomControls fallback), and no hint is drawn.
 * While open this button is the first focusable control of the root, so it is the exit button that useFocusContain
 * focuses. `aria-pressed` reflects the open state.
 *
 * The icon is an inline SVG that takes its colour from the button (currentColor), so no colour is picked here. The bar
 * sits in the top-left corner of .dt-zoom, clear of the zoom controls in the top-right corner (the positions are the
 * only inline style: dependency-tree.css, where .dt-fs-btn and .dt-fs-hint are styled, has no rule for the bar).
 */
const BAR_STYLE = { position: 'absolute', top: 8, left: 8, zIndex: 6, display: 'flex', alignItems: 'center', gap: 4 }

/** Four corner arrows pointing outwards (enter) or inwards (exit). */
function Icon({ open }) {
  const d = open
    ? 'M6 2v4H2 M10 2v4h4 M6 14v-4H2 M10 14v-4h4'
    : 'M2 6V2h4 M14 6V2h-4 M2 10v4h4 M14 10v4h-4'
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      <path d={d} />
    </svg>
  )
}

export default function FullscreenToggle({ open, label, hint, onToggle }) {
  const name = label ? label : undefined
  return (
    <div className="dt-fs-bar" style={BAR_STYLE}>
      <button
        type="button"
        className="dt-fs-btn"
        data-testid="dt-fs-toggle"
        onClick={onToggle}
        aria-pressed={open ? 'true' : 'false'}
        aria-label={name}
        title={name}
      >
        <Icon open={open} />
      </button>
      {open && hint ? <span className="dt-fs-hint" data-testid="dt-fs-hint">{hint}</span> : null}
    </div>
  )
}
