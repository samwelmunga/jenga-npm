const API_BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:3001'

// E47_S04_T03 — embedded snapshot data support.
//
// `j.dashboard --snapshot` (skills/j-dashboard/scripts/snapshot.sh) bundles the UI into a single
// self-contained HTML file with the JSON artifact captured by E47_S04_T02's capture-snapshot.js
// embedded inline as <script id="jenga-dashboard-data" type="application/json">, via
// vite.config.js's snapshot-mode-only plugin. When that element is present (the offline/file://
// snapshot case), get() reads from it directly instead of calling fetch() — no server is running
// to fetch from in the first place. When it is absent (the normal, live-dashboard case, served by
// `npm run dashboard:start`/`dashboard:open`), get() falls through to the existing fetch()-based
// request() completely unchanged.
//
// Maps a request path (e.g. '/v1/board') to the snapshot artifact's routes.<key> field. Mirrors
// project/app/api/scripts/capture-snapshot.js's own ROUTE_KEYS mapping exactly — keep these two in
// sync if a route is ever added or renamed.
const SNAPSHOT_ROUTE_KEYS = {
  '/v1/board': 'board',
  '/v1/history': 'history',
  '/v1/architecture': 'architecture',
}

let embeddedSnapshotLoaded = false
let embeddedSnapshot = null

// Looks up and parses the embedded snapshot element exactly once per page load (memoized), so the
// live-fetch path never pays a repeated DOM-query cost and the presence/absence check is stable
// for the lifetime of the page.
function loadEmbeddedSnapshot() {
  if (embeddedSnapshotLoaded) return embeddedSnapshot
  embeddedSnapshotLoaded = true

  if (typeof document === 'undefined') return null

  const el = document.getElementById('jenga-dashboard-data')
  if (!el) return null

  try {
    embeddedSnapshot = JSON.parse(el.textContent)
  } catch (err) {
    // A corrupt embedded snapshot should not silently fall back to a live fetch that has no
    // server behind it in the file:// case — surface the parse failure loudly instead.
    console.error('jenga-dashboard: failed to parse embedded snapshot data', err)
    embeddedSnapshot = null
  }

  return embeddedSnapshot
}

async function request(path, options = {}) {
  const url = `${API_BASE_URL}${path}`
  const res = await fetch(url, options)
  const json = await res.json()
  if (!res.ok || json.error) {
    throw new Error(json.error ?? `HTTP ${res.status}`)
  }
  return json.data
}

// Resolves a single route's snapshot envelope the same way request() resolves a live one: throw
// on a truthy `error`, otherwise return `.data`.
function getFromSnapshot(snapshot, path) {
  const key = SNAPSHOT_ROUTE_KEYS[path]
  const envelope = key ? snapshot.routes?.[key] : undefined

  if (!envelope) {
    throw new Error(`jenga-dashboard: no embedded snapshot data for path '${path}'`)
  }
  if (envelope.error) {
    throw new Error(envelope.error.message ?? `Snapshot error for '${path}'`)
  }
  return envelope.data
}

export function get(path) {
  const snapshot = loadEmbeddedSnapshot()
  if (snapshot) {
    try {
      return Promise.resolve(getFromSnapshot(snapshot, path))
    } catch (err) {
      return Promise.reject(err)
    }
  }
  return request(path)
}

export default { get, request }
