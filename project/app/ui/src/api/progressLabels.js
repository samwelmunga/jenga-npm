import { get } from './client'

/**
 * E92_S06_T21 — the progress label table (scripts/lib/progress-labels.sh, served as `labels` by the existing
 * `/v1/progress-cards` route and, in a snapshot, read from its embedded copy by `get`), for the parts of the page that
 * are not under the board: the top bar's Animations toggle. Never rejects: a failed fetch gives `{}`, and the toggle then
 * shows its icon only. `fetcher` is injectable for tests.
 */
export function loadProgressLabels(fetcher = get) {
  return Promise.resolve()
    .then(() => fetcher('/v1/progress-cards'))
    .then(
      data => (data && typeof data.labels === 'object' && data.labels !== null ? data.labels : {}),
      () => ({}),
    )
}
