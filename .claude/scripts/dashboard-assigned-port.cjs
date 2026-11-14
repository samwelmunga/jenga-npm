#!/usr/bin/env node
/**
 * scripts/dashboard-assigned-port.cjs - prefer the project's assigned dashboard port at start (E47_S11_T03)
 *
 * Dependency-free helper for dashboard-start.cjs. The project's port is stored by scripts/dashboard-port.sh
 * (E47_S11_T01) in project/configs/dashboard-config.json. This module reads it through `dashboard-port.sh get`
 * (so the resolver and validity rules exist once), tries it first, and falls back to the verified-free search
 * with a warning that names the assigned port, why it was not used, and the port used instead.
 *
 * Never throws on bad config: bash/jq absence, a missing file, or an invalid value are all reported as a
 * "missing" or "invalid" reason and lead to the fallback.
 *
 * CLI (for debugging): node dashboard-assigned-port.cjs [project-root]  -> prints JSON {status, port?, detail?}
 */

'use strict';

const path = require('path');
const { execFileSync } = require('child_process');
const { isPortFree, listenOnFreePort } = require('./find-free-port.cjs');

const PORT_SCRIPT = path.join(__dirname, 'dashboard-port.sh');
const ALLOCATOR_HINT = 'scripts/dashboard-port.sh ensure';

/**
 * Read the assigned port. Returns { status: 'ok', port } | { status: 'missing'|'invalid', detail }.
 */
function readAssignedPort({ projectRoot = null, env = process.env } = {}) {
  const childEnv = Object.assign({}, env);
  if (projectRoot) childEnv.JENGA_PROJECT_ROOT = projectRoot;
  let out;
  try {
    out = execFileSync('bash', [PORT_SCRIPT, 'get'], { env: childEnv, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 10000 });
  } catch (err) {
    const stderr = String((err && err.stderr) || '').trim();
    if (err && err.code === 'ENOENT') return { status: 'missing', detail: 'bash is not available' };
    if (/outside/.test(stderr)) return { status: 'invalid', detail: stderr.replace(/^dashboard-port\.sh:\s*/, '') };
    return { status: 'missing', detail: stderr.replace(/^dashboard-port\.sh:\s*/, '') || 'no assigned port could be read (is jq installed?)' };
  }
  const port = Number(String(out).trim());
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return { status: 'invalid', detail: `unexpected value "${String(out).trim()}"` };
  }
  return { status: 'ok', port };
}

/** Build the fallback warning. `reason` is 'busy' | 'missing' | 'invalid'. */
function buildWarning(assigned, reason, usedPort, detail) {
  const label = assigned && assigned.port ? `assigned port ${assigned.port}` : 'assigned port';
  if (reason === 'busy') return `Warning: ${label} is busy; using ${usedPort} instead.`;
  const why = reason === 'missing' ? 'is missing' : 'is invalid';
  let msg = `Warning: no usable ${label} (the project's dashboard port ${why}${detail ? `: ${detail}` : ''}); using ${usedPort} instead.`;
  if (reason === 'missing') msg += ` Run \`${ALLOCATOR_HINT}\` to assign this project a stable port.`;
  return msg;
}

/**
 * Listen with the assigned-port preference.
 *   explicit       a requested port (--port / JENGA_API_PORT): wins, rejects EADDRINUSE when busy.
 *   projectRoot    the invoking project's root (null outside a project).
 *   start          where the fallback search starts.
 *   read           injectable reader (tests); defaults to readAssignedPort.
 * Resolves { server, port, assigned, reason, warning }; reason is null when the assigned port (or the explicit
 * one) was bound. `warning` is a string or null.
 */
async function listenPreferAssigned(target, { explicit = null, projectRoot = null, start = 3001, read = readAssignedPort } = {}) {
  if (explicit !== null && explicit !== undefined) {
    const r = await listenOnFreePort(target, { explicit });
    return { server: r.server, port: r.port, assigned: null, reason: null, warning: null };
  }
  let assigned;
  try { assigned = read({ projectRoot }); } catch (e) { assigned = { status: 'missing', detail: e.message }; }
  let reason;
  if (assigned.status === 'ok') {
    if (await isPortFree(assigned.port)) {
      try {
        const r = await listenOnFreePort(target, { explicit: assigned.port });
        return { server: r.server, port: r.port, assigned: assigned.port, reason: null, warning: null };
      } catch (e) {
        if (e.code !== 'EADDRINUSE') throw e;
      }
    }
    reason = 'busy';
  } else {
    reason = assigned.status;
  }
  const r = await listenOnFreePort(target, { start });
  return { server: r.server, port: r.port, assigned: assigned.port || null, reason, warning: buildWarning(assigned, reason, r.port, assigned.detail) };
}

module.exports = { readAssignedPort, listenPreferAssigned, buildWarning };

if (require.main === module) {
  console.log(JSON.stringify(readAssignedPort({ projectRoot: process.argv[2] || process.env.JENGA_PROJECT_ROOT || null })));
}
