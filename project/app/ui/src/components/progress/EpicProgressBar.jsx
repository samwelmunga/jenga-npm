import { buildEpicBarModel } from './epicBarModel.js'
import './progress.css'

/**
 * EpicProgressBar — E92_S06_T07.
 *
 * Compact, non-animated bar for an epic card: one stop per story (no text in the stops), the percent complete beside
 * the bar. Colours come from the --color-progress-* tokens through progress.css, keyed by the `data-bucket` attribute.
 * The wrapper is role="img" with an aria-label built from the payload's `card_bar_aria` label. All numbers come from
 * the script output via `buildEpicBarModel`; nothing is counted here. No network access, no colour literal.
 */
export default function EpicProgressBar({ epic, stories, labels }) {
  const model = buildEpicBarModel(epic, stories, labels)
  return (
    <div className="epic-bar" role="img" aria-label={model.ariaLabel}>
      <span className="epic-bar-track" aria-hidden="true">
        {model.stops.map(s => (
          <span key={s.id} className="epic-bar-stop" data-bucket={s.bucket} />
        ))}
      </span>
      <span className="epic-bar-percent" aria-hidden="true">{`${model.percent}%`}</span>
    </div>
  )
}
