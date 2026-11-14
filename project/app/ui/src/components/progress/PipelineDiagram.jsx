import { ACTIVE_MARKER, IDLE_CAPTION, SNAPSHOT_CAPTION, buildPipelineModel, pipelineAriaLabel } from './pipelineModel.js'
import './pipeline.css'

/**
 * PipelineDiagram — E92_S04_T04.
 *
 * Draws the four Jenga pipeline stages (todo, do, test, rollup) as boxes joined by arrows, left to right, from the
 * `GET /v1/pipeline` payload via `buildPipelineModel` (pipelineModel.js). It decides nothing about which stage has work.
 *
 *   - An active stage is marked three ways, so colour is never the only signal: a fill from
 *     var(--color-progress-in-progress), a thicker outline (the `stroke-width` attribute, ACTIVE_STROKE against
 *     STROKE), and the text "● active" with its count. An inactive stage uses the surface and border tokens.
 *   - The fill is translucent (FILL_OPACITY) so the label and count keep their contrast in both themes.
 *   - The SVG is role="img" with an aria-label that names the active stages.
 *   - When idle, all four stages are in the normal state and a caption says so.
 *   - `pointInTime` is decided by the parent (the snapshot export): when true a caption says the picture reflects the
 *     board when it was captured. This component does not detect a snapshot itself.
 *   - No colour literal here or in pipeline.css; no network access; no dependency beyond React.
 */

const BOX_W = 110
const BOX_H = 78
const GAP = 44
const PAD = 4 // room for the thicker outline
const STROKE = 1
const ACTIVE_STROKE = 4
const FILL_OPACITY = 0.3
const WIDTH = 4 * BOX_W + 3 * GAP + PAD * 2
const HEIGHT = BOX_H + PAD * 2

/** Left edge of the nth box. */
const boxX = n => PAD + n * (BOX_W + GAP)

export default function PipelineDiagram({ data, pointInTime = false }) {
  const model = buildPipelineModel(data)
  const midY = PAD + BOX_H / 2
  return (
    <section className="pipeline" data-testid="pipeline-diagram">
      <h3 className="pipeline-title">Jenga pipeline</h3>
      <svg
        className="pipeline-svg"
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        role="img"
        aria-label={pipelineAriaLabel(model)}
      >
        {model.stages.map((s, i) => {
          const x = boxX(i)
          const cx = x + BOX_W / 2
          return (
            <g key={s.id} className="pipeline-stage" data-stage={s.id} data-active={s.active ? 'true' : 'false'}>
              <rect
                className={s.active ? 'pipeline-box pipeline-box-active' : 'pipeline-box'}
                x={x}
                y={PAD}
                width={BOX_W}
                height={BOX_H}
                rx="6"
                strokeWidth={s.active ? ACTIVE_STROKE : STROKE}
                style={s.active ? { fill: 'var(--color-progress-in-progress)', fillOpacity: FILL_OPACITY } : undefined}
              />
              <text className="pipeline-label" x={cx} y={PAD + 26} textAnchor="middle">{s.label}</text>
              <text className="pipeline-count" x={cx} y={PAD + 50} textAnchor="middle">{s.count}</text>
              {s.active ? (
                <text className="pipeline-marker" x={cx} y={PAD + 68} textAnchor="middle">{ACTIVE_MARKER}</text>
              ) : null}
            </g>
          )
        })}
        {model.stages.slice(0, -1).map((s, i) => {
          const x1 = boxX(i) + BOX_W + 4
          const x2 = boxX(i + 1) - 4
          return (
            <g key={`arrow-${s.id}`} className="pipeline-arrow" aria-hidden="true">
              <line x1={x1} y1={midY} x2={x2 - 7} y2={midY} />
              <polygon points={`${x2},${midY} ${x2 - 9},${midY - 5} ${x2 - 9},${midY + 5}`} />
            </g>
          )
        })}
      </svg>
      {model.idle ? <p className="pipeline-caption" data-caption="idle">{IDLE_CAPTION}</p> : null}
      {pointInTime ? <p className="pipeline-caption" data-caption="snapshot">{SNAPSHOT_CAPTION}</p> : null}
    </section>
  )
}
