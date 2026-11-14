/**
 * pipelineModel — E92_S04_T04.
 *
 * Pure (React-free, DOM-free) view model for the pipeline diagram. Input is the body of `GET /v1/pipeline`, which is
 * the output of `scripts/pipeline-stage.sh` (E92_S04_T01):
 *   { schema_version, stages: [{ id, label, count, active }], active: [id...], idle, skipped }
 *
 * Rules this module owns:
 *   - The diagram always has exactly four stages, in the fixed order todo, do, test, rollup (CLAUDE.md "Workflow
 *     Lifecycle"), whatever order or subset the payload arrives in.
 *   - A stage the payload does not carry, or carries malformed, is drawn inactive with count 0.
 *   - It decides nothing about which stage has work: a stage is active when the script said so (`active: true`), or,
 *     for a stage without that flag, when its count is above 0. Several stages can be active at once.
 *   - `idle` is true exactly when no stage is active.
 */

/** Stage order and default labels, fixed. */
export const STAGES = [
  { id: 'todo', label: 'To do' },
  { id: 'do', label: 'Do' },
  { id: 'test', label: 'Test' },
  { id: 'rollup', label: 'Rollup' },
]

export const IDLE_CAPTION = 'Idle: nothing queued, running, awaiting test or waiting to roll up'
export const SNAPSHOT_CAPTION = 'Point-in-time snapshot: reflects the board when it was captured'
export const ACTIVE_MARKER = '● active' // "● active"

/** A non-negative whole number, or 0. */
function num(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0
}

/** One payload stage -> `{ id, label, count, active }`; a missing or malformed stage is inactive with count 0. */
function nodeFor(def, raw) {
  if (!raw || typeof raw !== 'object') return { id: def.id, label: def.label, count: 0, active: false }
  const count = num(raw.count)
  const active = typeof raw.active === 'boolean' ? raw.active : count > 0
  const label = typeof raw.label === 'string' && raw.label.trim() ? raw.label : def.label
  return { id: def.id, label, count, active }
}

/**
 * Payload -> `{ stages, active, idle }`, `stages` being the four node descriptors in order and `active` the ids of the
 * active ones, in order.
 */
export function buildPipelineModel(payload) {
  const list = payload && Array.isArray(payload.stages) ? payload.stages : []
  const stages = STAGES.map(def => nodeFor(def, list.find(s => s && typeof s === 'object' && s.id === def.id)))
  const active = stages.filter(s => s.active).map(s => s.id)
  return { stages, active, idle: active.length === 0 }
}

/** "Jenga pipeline: Do (3) and Test (1) active." / "Jenga pipeline: no stage active (idle)." */
export function pipelineAriaLabel(model) {
  const on = model.stages.filter(s => s.active).map(s => `${s.label} (${s.count})`)
  if (on.length === 0) return 'Jenga pipeline: no stage active (idle).'
  const names = on.length === 1 ? on[0] : `${on.slice(0, -1).join(', ')} and ${on[on.length - 1]}`
  return `Jenga pipeline: ${names} active.`
}
