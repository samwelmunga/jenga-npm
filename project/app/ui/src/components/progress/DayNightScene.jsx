import { skyFrame, sunPosition, moonPosition, sunRays, nightStars, twinkleStars, birdFlocks, STAR_PATH, BIRD_PATH, MOON_PATH, SUN } from './dayNightModel'

/**
 * DayNightScene - E92_S13_T04. The day and night scene of a goal design, drawn in pure SVG from the geometry of dayNightModel.js.
 * It is SHARED: the citadel and the facade draw it, and the seasons tree (E92_S13_T07) is meant to draw the same components with
 * its own frame instead of copying them. It holds no colour and no motion:
 *
 *   - Day and night are the dashboard's light and dark theme (E47_S07), and only CSS reads the theme. Both halves are always in
 *     the markup: what belongs to the day carries `dn-day`, what belongs to the night carries `dn-night`, and dependency-tree.css
 *     shows one of them through the `--theme-day-display` / `--theme-night-display` tokens of tokens.css, which switch with
 *     `prefers-color-scheme` and `data-theme` like every colour token. That is why it works in the `file://` snapshot (CSS only,
 *     no script) and why there is no separate day and night control.
 *   - The colours are the `--dn-*` custom properties of `.dn-scene` in dependency-tree.css (the shared palette hook, mapped from
 *     the `--color-sky-*` tokens). The classes carry no colour here.
 *   - The movement (the flapping birds, the twinkling stars) is CSS only, declared inside prefers-reduced-motion: no-preference
 *     and for a root without data-motion="off", so reduced motion shows the same drawing, still. Nothing here animates.
 *
 * Components (each takes the `frame` of dayNightModel.skyFrame):
 *   DaySky           the sky behind the subject: an optional gradient backdrop, the sun (day) with the height of the percent, the
 *                    moon and the dim stars (night). `line` draws the sun and moon as outlines, for a flat drawing board.
 *   DayNightEffects  what the goal being reached adds over the subject: flapping birds by day, twinkling stars by night.
 */

const f = n => Math.round(n * 100) / 100

/** The sky behind a goal design. `backdrop` paints a gradient rectangle over the frame; without it the sun and the moon sit on whatever is behind. */
export function DaySky({ frame, gid, percent, backdrop = false, line = false }) {
  const sun = sunPosition(frame, percent)
  const moon = moonPosition(frame)
  const gradient = `dt-sky-${gid}`
  return (
    <g className={`dn-sky${line ? ' dn-line' : ''}`} aria-hidden="true">
      {backdrop ? (
        <>
          <linearGradient id={gradient} x1="0" x2="0" y1="0" y2="1">
            <stop className="dn-sky-top" offset="0" />
            <stop className="dn-sky-bottom" offset="1" />
          </linearGradient>
          <rect className="dn-backdrop" x={f(frame.x)} y={f(frame.y)} width={f(frame.w)} height={f(frame.h)} rx={f(8 * frame.k)} fill={`url(#${gradient})`} />
        </>
      ) : null}
      <g className="dn-day">
        <g className="dn-sun" data-percent={Math.min(100, Math.max(0, Math.floor(percent) || 0))} transform={`translate(${f(sun.x)} ${f(sun.y)}) scale(${f(frame.k)})`}>
          <g className="dn-rays">
            {sunRays().map((r, i) => <line key={i} className="dn-ray" x1={r.x1} y1={r.y1} x2={r.x2} y2={r.y2} />)}
          </g>
          <circle className="dn-sun-halo" r={SUN.halo} />
          <circle className="dn-sun-core" r={SUN.radius} />
        </g>
      </g>
      <g className="dn-night">
        <path className="dn-moon" d={MOON_PATH} transform={`translate(${f(moon.x)} ${f(moon.y)}) scale(${f(frame.k)})`} />
        <g className="dn-dim-stars">
          {nightStars(frame).map((s, i) => <circle key={i} className={`dn-dim-star${s.dim ? ' dn-dim' : ''}`} cx={f(s.x)} cy={f(s.y)} r={f(s.r)} />)}
        </g>
      </g>
    </g>
  )
}

/** What the goal being reached adds: birds by day, twinkling stars by night. The caller draws it only when the goal is reached. */
export function DayNightEffects({ frame }) {
  return (
    <>
      <g className="dn-day dn-birds" data-effect="birds">
        {birdFlocks(frame).map((flock, i) => (
          <g key={i} className="dn-flock">
            {flock.map((b, j) => (
              <g key={j} className="dn-bird-at" transform={`translate(${f(b.x)} ${f(b.y)}) scale(${f(b.scale)})`}>
                <path className="dn-bird" d={BIRD_PATH} />
              </g>
            ))}
          </g>
        ))}
      </g>
      <g className="dn-night dn-stars" data-effect="stars">
        {twinkleStars(frame).map((s, i) => (
          <g key={i} className="dn-star-at" transform={`translate(${f(s.x)} ${f(s.y)}) scale(${f(s.scale)})`}>
            <path className="dn-star" d={STAR_PATH} />
          </g>
        ))}
      </g>
    </>
  )
}

export { skyFrame }
