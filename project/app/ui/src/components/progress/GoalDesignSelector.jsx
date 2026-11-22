import { selectorVisible } from './goalDesignModel'

/**
 * GoalDesignSelector — E92_S13_T05. The control that chooses the design of the epic Goal (star, citadel, facade, seasons
 * tree, and whatever is registered after them). Presentational, like ZoomControls.jsx and FullscreenToggle.jsx: it takes
 * the registered designs with their words already resolved from the labels payload by the caller (keys goal_design_*,
 * scripts/lib/progress-labels.sh), the current id and one handler. The list, the default and the stored choice live in
 * goalDesignModel.js and DependencyTree.jsx; this file decides nothing but the markup.
 *
 *   items       [{ id, text }]  the REGISTERED designs in list order (registeredDesigns); one entry per button, however many
 *   value       the id of the chosen design
 *   groupText   the accessible name of the group ('' leaves the group unnamed until the labels arrive)
 *   onSelect    (id) => void
 *
 * Hidden (returns null) with fewer than two items: there is nothing to choose between (selectorVisible).
 *
 * A real control: one <button> per design, so it is reached with Tab and operated with Enter or Space with no code of ours,
 * and `aria-pressed` says which one is chosen. The chosen button is also marked without colour: a check mark in front of its
 * name and a heavier border (dependency-tree.css, .dt-gd-btn[aria-pressed="true"]). The buttons wrap onto further lines
 * at a narrow overlay instead of overflowing. No word is written here.
 */
export default function GoalDesignSelector({ items, value, groupText, onSelect }) {
  if (!selectorVisible(items)) return null
  const name = groupText ? groupText : undefined
  return (
    <div className="dt-gd" role="group" aria-label={name} data-testid="dt-goal-design">
      {items.map(item => {
        const chosen = item.id === value
        return (
          <button
            key={item.id}
            type="button"
            className="dt-gd-btn"
            data-goal-design={item.id}
            aria-pressed={chosen ? 'true' : 'false'}
            onClick={() => onSelect(item.id)}
          >
            {chosen ? <span className="dt-gd-check" aria-hidden="true">✓</span> : null}
            {item.text}
          </button>
        )
      })}
    </div>
  )
}
