/**
 * scripts/dashboard-port-state.cjs - where a running dashboard recorded its port (E47_S08_T03)
 *
 * The dashboard now binds a verified-free port instead of a fixed 3001, so `dashboard open`,
 * `j.dashboard` and the dev server need a way to find the one that is actually running. The server writes
 * { port, pid, url, startedAt } to <projectRoot>/project/queue/dashboard-port.json once it is listening and
 * removes it on shutdown. One file per project, so two projects' dashboards never share or overwrite it.
 * The file is a hint, never an authority: readers confirm the recorded pid is alive (and, where they care,
 * answer a health check) before trusting it, and every write/remove failure is swallowed - losing the hint
 * only means falling back to the default port, never a failed start.
 *
 * Dependency-free; the project root is passed in so this module stays generic.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const DEFAULT_PORT = 3001;

function stateFile(projectRoot) {
  return path.join(projectRoot, 'project', 'queue', 'dashboard-port.json');
}

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid < 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === 'EPERM'; // exists but owned by someone else
  }
}

function writeState(projectRoot, { port, pid = process.pid }) {
  try {
    const file = stateFile(projectRoot);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = `${file}.${process.pid}.tmp`;
    const body = { port, pid, url: `http://localhost:${port}`, startedAt: new Date().toISOString() };
    fs.writeFileSync(tmp, JSON.stringify(body) + '\n');
    fs.renameSync(tmp, file);
    return true;
  } catch {
    return false;
  }
}

// Returns the recorded state when its process is still alive, else null (a stale file is removed).
function readState(projectRoot) {
  const file = stateFile(projectRoot);
  let state;
  try {
    state = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
  const portOk = state && Number.isInteger(state.port) && state.port >= 1 && state.port <= 65535;
  if (portOk && pidAlive(state.pid)) return state;
  try { fs.unlinkSync(file); } catch { /* already gone */ }
  return null;
}

// Removes the file only if it still belongs to `pid`, so a dashboard that lost its port to a newer one
// never deletes the newer one's record.
function clearState(projectRoot, pid = process.pid) {
  try {
    const file = stateFile(projectRoot);
    const state = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (state && state.pid === pid) fs.unlinkSync(file);
  } catch { /* nothing to clear */ }
}

module.exports = { DEFAULT_PORT, stateFile, writeState, readState, clearState };
