import { arc as d3Arc, pie as d3Pie } from 'd3-shape'
import './progress.css'

/**
 * PieChart — E92_S03_T05.
 *
 * Renders one pie from a model built by `buildPieModel` (progressModel.js): `{ title, total, empty, slices }`
 * with `slices: [{ key, label, count, percent, colorVar, detail }]`. It decides nothing about buckets or
 * counts; it only draws what the model says.
 *
 *   - Slice fills are `var(<slice.colorVar>)`, so the --color-progress-* tokens carry both themes. No colour
 *     literal exists here or in progress.css.
 *   - The SVG is role="img" with an aria-label that spells out title, total and every slice's label, count and
 *     percent, and the legend repeats the same figures as text: colour is never the only carrier of meaning.
 *   - A zero bucket never reaches this component (the model omits it), so there is no zero-width slice or row.
 *   - A pie with a single slice sweeps a full 2*PI. d3's arc collapses that to a degenerate path (nothing is
 *     drawn), so the single-slice case is drawn as two half arcs, which is a full circle.
 *   - An empty model shows the chart title and the text "Nothing to show", never a blank or broken SVG.
 */

export const EMPTY_TEXT = 'Nothing to show'

const RADIUS = 90
const VIEW = RADIUS + 4 // the viewBox is centred on the pie, with a small margin for the slice outline

const arcGen = d3Arc().innerRadius(0).outerRadius(RADIUS)
const pieGen = d3Pie().sort(null).value(s => s.count)

/** A full circle as two half arcs (d3's own arc cannot draw a 2*PI sweep). */
export const FULL_CIRCLE_PATH =
  `M0,${-RADIUS}A${RADIUS},${RADIUS},0,1,1,0,${RADIUS}A${RADIUS},${RADIUS},0,1,1,0,${-RADIUS}Z`

/** Path data for each slice, in order. */
export function slicePaths(slices) {
  if (slices.length === 1) return [FULL_CIRCLE_PATH]
  return pieGen(slices).map(a => arcGen(a))
}

/** "Tasks: 13 items. Done: 5 (39%), In progress: 1 (8%)." */
export function ariaLabelFor(model) {
  const parts = model.slices.map(s => `${s.label}: ${s.count} (${s.percent}%)`)
  return `${model.title}: ${model.total} ${model.total === 1 ? 'item' : 'items'}. ${parts.join(', ')}.`
}

export default function PieChart({ model, headline }) {
  const { title, empty, slices } = model
  if (empty) {
    return (
      <section className="progress-chart progress-chart-empty" data-testid="progress-chart" data-chart={title} aria-label={title}>
        <h3 className="progress-chart-title">{title}</h3>
        <p className="progress-empty">{EMPTY_TEXT}</p>
      </section>
    )
  }
  const paths = slicePaths(slices)
  return (
    <section className="progress-chart" data-testid="progress-chart" data-chart={title}>
      <h3 className="progress-chart-title">{title}</h3>
      {headline ? <p className="progress-headline">{headline}</p> : null}
      <svg
        className="progress-pie"
        viewBox={`${-VIEW} ${-VIEW} ${VIEW * 2} ${VIEW * 2}`}
        role="img"
        aria-label={ariaLabelFor(model)}
      >
        {slices.map((s, i) => (
          <path
            key={s.key}
            className="progress-slice"
            data-slice={s.key}
            d={paths[i]}
            style={{ fill: `var(${s.colorVar})` }}
          >
            <title>{s.detail ? `${s.label} (${s.detail})` : s.label}</title>
          </path>
        ))}
      </svg>
      <ul className="progress-legend">
        {slices.map(s => (
          <li key={s.key} className="progress-legend-row" data-legend={s.key} title={s.detail || undefined}>
            <span className="progress-swatch" aria-hidden="true" style={{ background: `var(${s.colorVar})` }} />
            <span className="progress-legend-label">{s.label}</span>
            <span className="progress-legend-count">{s.count}</span>
            <span className="progress-legend-percent">{s.percent}%</span>
          </li>
        ))}
      </ul>
    </section>
  )
}
