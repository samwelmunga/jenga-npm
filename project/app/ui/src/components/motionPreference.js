// E92_S06_T21 — the dashboard's Animations preference, as plain functions with no React so the rules are unit tested
// (scripts/motion-toggle.test.cjs). Two states, like the theme's three: 'auto' (follow the system's prefers-reduced-motion)
// and 'off' (all animations disabled). 'off' is exposed as data-motion="off" on <html>; Auto has no attribute. The CSS
// that honours it (dependency-tree.css) gates every animation on `:root:not([data-motion="off"])` inside
// `@media (prefers-reduced-motion: no-preference)`.
//
// The stored value is 'off' under localStorage key `jenga-dashboard-motion`; Auto removes the key. index.html's inline
// script resolves it into the attribute before first paint, and the toggle starts from that attribute (not from a second,
// independent storage read), exactly as ThemeToggle does. Every storage access is guarded: under file:// or with storage
// blocked the toggle still works for the session and nothing throws.

export const MOTION_STORAGE_KEY = 'jenga-dashboard-motion'
export const NEXT_MOTION = { auto: 'off', off: 'auto' }
export const MOTION_ICON = { auto: '✦', off: '⏸' }

/** The state the attribute on `root` stands for. */
export function readMotionAttr(root) {
  return root && root.dataset && root.dataset.motion === 'off' ? 'off' : 'auto'
}

/** localStorage, or null where reaching it throws (blocked storage, some file:// pages). */
function storageOrNull() {
  try {
    return window.localStorage
  } catch {
    return null
  }
}

/** Set (off) or remove (auto) the attribute on `root`, then store the choice; a storage failure is ignored. */
export function applyMotion(mode, root, getStorage = storageOrNull) {
  if (mode === 'off') root.dataset.motion = 'off'
  else delete root.dataset.motion
  try {
    const store = getStorage()
    if (store) {
      if (mode === 'off') store.setItem(MOTION_STORAGE_KEY, 'off')
      else store.removeItem(MOTION_STORAGE_KEY)
    }
  } catch {
    // Storage unavailable: session-only.
  }
  return mode === 'off' ? 'off' : 'auto'
}

/** Whether the system asks for reduced motion; false where matchMedia is missing or throws. */
export function osReducesMotion() {
  try {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches
  } catch {
    return false
  }
}
