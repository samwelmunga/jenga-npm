/**
 * ZoomControls — E92_S06_T21. The four buttons and the percent readout of the overlay tree's zoom: minus, the readout,
 * plus, Fit and 100 %. Presentational: it takes the strings, already resolved from the labels payload by the caller
 * (scripts/lib/progress-labels.sh, keys zoom_*), and the four handlers of useZoomPan.
 *
 * No word is written here. A string the labels did not supply is empty, and then the control shows only its symbol and
 * carries no accessible name until the labels arrive (the same graceful fallback as the top bar's Animations toggle).
 * `text`: { group, out, in, fit, actual, hint, percent }; `percent` is the formatted readout ('' before the first fit),
 * `actualText` the formatted caption of the 100 % button.
 */
export default function ZoomControls({ text, percent, actualText, onZoomOut, onZoomIn, onFit, onActual }) {
  const name = s => (s ? s : undefined)
  return (
    <div className="dt-zoom-controls" role="group" aria-label={name(text.group)} data-testid="dt-zoom-controls">
      <button type="button" className="dt-zbtn" data-zoom="out" onClick={onZoomOut} aria-label={name(text.out)} title={name(text.out)}>
        <span aria-hidden="true">−</span>
      </button>
      <span className="dt-zpct" data-zoom="percent">{percent}</span>
      <button type="button" className="dt-zbtn" data-zoom="in" onClick={onZoomIn} aria-label={name(text.in)} title={name(text.in)}>
        <span aria-hidden="true">+</span>
      </button>
      <button type="button" className="dt-zbtn" data-zoom="fit" onClick={onFit} aria-label={name(text.fit)} title={name(text.fit)}>
        {text.fit ? text.fit : <span aria-hidden="true">⤢</span>}
      </button>
      <button type="button" className="dt-zbtn" data-zoom="actual" onClick={onActual} aria-label={name(text.actual)} title={name(text.actual)}>
        {actualText}
      </button>
    </div>
  )
}
