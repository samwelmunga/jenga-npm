// E47_S09 - single place the dashboard title string is formed, so the browser tab title and the
// header text can never drift apart. `name` is the `/v1/health` `projectName` (resolved server-side
// by api/lib/resolve-project-title.js, and baked into the snapshot at export time).
export const STATIC_TITLE = 'Jenga AI Dashboard'

export function dashboardTitle(name) {
  return typeof name === 'string' && name.trim().length > 0 ? `${name.trim()}'s Dashboard` : STATIC_TITLE
}
