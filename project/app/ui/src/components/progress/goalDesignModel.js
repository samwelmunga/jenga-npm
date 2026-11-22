/**
 * goalDesignModel — E92_S13_T05.
 *
 * Pure (React-free, DOM-free, import-free) model of the goal design selector of the epic progress map: which designs of
 * the Goal exist and in what order, which one is the default, which are built yet, and which one a browser has chosen.
 * Like motionPreference.js and epicBarModel.js it is plain functions, so the rules are unit tested without a bundler
 * (scripts/goal-design-model.test.cjs). It counts nothing and draws nothing.
 *
 * ONE ORDERED LIST. GOAL_DESIGNS below is the only place the designs, their order and their label keys are declared. The
 * order is the display order of the selector. The selector (GoalDesignSelector.jsx), the stored choice (readGoalDesign)
 * and the goal slot (DependencyTree.jsx) all read it. The renderers live in goalDesigns.js, a map from id to renderer:
 * a design is REGISTERED when that map holds a renderer for its id.
 *
 * ADDING A DESIGN. Add one entry here (an id and a label key), add the five labels (scripts/lib/progress-labels.sh,
 * en and sv) and register its renderer in goalDesigns.js. The selector is not touched: it shows whatever the list and
 * the registry give it.
 *
 * REGISTERED OR ABSENT. A design with no renderer is absent from the selector and can never be chosen or stored (the
 * citadel, facade and tree are registered by E92_S13_T02, T03 and T07). A selector with fewer than two registered
 * designs is hidden: there is nothing to choose between.
 *
 * DEFAULT. DEFAULT_GOAL_DESIGN is a named constant of its own, the citadel; it is never "whatever is first" (the star is
 * first in the list and is not the default). While the default is not registered, the default is the first registered
 * design, so a branch that has only the star still draws it.
 *
 * STORED CHOICE. One localStorage key, GOAL_DESIGN_STORAGE_KEY, holds the id of the chosen design. Every storage read
 * and write is wrapped: unavailable or throwing storage (private mode, blocked site data, the file:// snapshot) gives
 * the default and never throws, and the page still switches design for the session (the choice lives in component
 * state; the write is best effort). A missing value, an id that is not in the list and an id that is in the list but
 * not registered all give the default.
 */

/** The localStorage key of the chosen goal design. The value is one design id of GOAL_DESIGNS. */
export const GOAL_DESIGN_STORAGE_KEY = 'jenga-dashboard-goal-design'

/** The default design, by id. Independent of the list order. */
export const DEFAULT_GOAL_DESIGN = 'citadel'

/** The ordered list of goal designs: display order, and the id each stored value is checked against. */
export const GOAL_DESIGNS = Object.freeze([
  Object.freeze({ id: 'star', labelKey: 'goal_design_star' }),
  Object.freeze({ id: 'citadel', labelKey: 'goal_design_citadel' }),
  Object.freeze({ id: 'facade', labelKey: 'goal_design_facade' }),
  Object.freeze({ id: 'tree', labelKey: 'goal_design_tree' }),
])

/** The labels payload key of the selector's group name. */
export const GOAL_DESIGN_GROUP_LABEL_KEY = 'goal_design_group'

/** True when `registry` holds a renderer for `id` (an own property, so an inherited name such as "constructor" never counts). */
function hasRenderer(registry, id) {
  return !!registry && typeof registry === 'object' && Object.prototype.hasOwnProperty.call(registry, id) && !!registry[id]
}

/** The designs of `designs` (default GOAL_DESIGNS) that have a renderer in `registry`, in list order. */
export function registeredDesigns(registry, designs = GOAL_DESIGNS) {
  return (Array.isArray(designs) ? designs : []).filter(d => d && typeof d.id === 'string' && hasRenderer(registry, d.id))
}

/** The selector is shown only when there is a choice: two or more registered designs. */
export function selectorVisible(registered) {
  return Array.isArray(registered) && registered.length >= 2
}

/** The id of the default design among `registered`: DEFAULT_GOAL_DESIGN when registered, else the first registered, else null. */
export function defaultDesignId(registered, defaultId = DEFAULT_GOAL_DESIGN) {
  const list = Array.isArray(registered) ? registered : []
  if (list.some(d => d.id === defaultId)) return defaultId
  return list.length ? list[0].id : null
}

/** `id` when it names a registered design, otherwise the default. */
export function resolveGoalDesign(id, registered, defaultId = DEFAULT_GOAL_DESIGN) {
  const list = Array.isArray(registered) ? registered : []
  return typeof id === 'string' && list.some(d => d.id === id) ? id : defaultDesignId(list, defaultId)
}

/** localStorage, or null where reaching it throws (blocked storage, some file:// pages) or where there is no window. */
export function goalDesignStorage() {
  try {
    return window.localStorage
  } catch {
    return null
  }
}

/**
 * The chosen design for this browser: the stored id when it names a registered design, otherwise the default. Never
 * throws. `getStorage` is injectable for the tests; it returns a Storage-like object or null.
 */
export function readGoalDesign(registered, getStorage = goalDesignStorage, defaultId = DEFAULT_GOAL_DESIGN) {
  let stored = null
  try {
    const store = getStorage()
    stored = store ? store.getItem(GOAL_DESIGN_STORAGE_KEY) : null
  } catch {
    stored = null
  }
  return resolveGoalDesign(stored, registered, defaultId)
}

/** Store the chosen id (best effort: a storage failure is ignored, the choice then lasts for the page only). */
export function writeGoalDesign(id, getStorage = goalDesignStorage) {
  try {
    const store = getStorage()
    if (store) store.setItem(GOAL_DESIGN_STORAGE_KEY, id)
  } catch {
    // Storage unavailable: session-only.
  }
}
