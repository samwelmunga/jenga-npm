#!/usr/bin/env node
/**
 * scripts/find-free-port.cjs - verified-free TCP port helper (E47_S08_T03)
 *
 * Dependency-free (node:net only) and generic: nothing here knows about the dashboard, so any Jenga
 * tool that needs a port (a dev preview, a service Jenga develops for another project) can require it.
 *
 * A port is "free" only if we can actually bind it right now. Nothing is inferred from a lock file, a
 * hardcoded default or a previous run. Each candidate is probed on every host a real server would use
 * (the wildcard address, which is what express's app.listen(port) binds, and 127.0.0.1), because a
 * wildcard bind alone can succeed while a loopback-only listener already holds the port on some systems.
 *
 *   isPortFree(port)                          -> Promise<boolean>
 *   findFreePort({ start, tries })            -> Promise<number>   first free port from `start`;
 *                                                after `tries` busy ports, an OS-assigned one
 *   listenOnFreePort(target, { explicit, start, tries })
 *                                             -> Promise<{ server, port }>
 *       `target` is anything with .listen(port, cb) returning a net.Server (an http.Server or an express
 *       app). Without `explicit` it takes the first free port from `start` and retries past a port that
 *       was lost between probe and bind. WITH `explicit` it tries exactly that port and rejects with an
 *       error whose code is 'EADDRINUSE' when it is busy: an explicitly requested port is never
 *       substituted.
 *
 * CLI (for shell callers and quick checks):
 *   node scripts/find-free-port.cjs [--start <n>] [--tries <n>]    print one free port
 *   node scripts/find-free-port.cjs --check <n>                    exit 0 if free, 1 if busy
 */

'use strict';

const net = require('net');

const PROBE_HOSTS = [undefined, '127.0.0.1'];
const MAX_PORT = 65535;

function canBind(port, host) {
  return new Promise(resolve => {
    const probe = net.createServer();
    probe.unref();
    probe.once('error', () => resolve(false));
    const onListening = () => probe.close(() => resolve(true));
    if (host === undefined) probe.listen(port, onListening);
    else probe.listen(port, host, onListening);
  });
}

async function isPortFree(port) {
  for (const host of PROBE_HOSTS) {
    if (!(await canBind(port, host))) return false;
  }
  return true;
}

// Asks the OS for an unused port (bind 0, read it back, release it).
function osAssignedPort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.unref();
    probe.once('error', reject);
    probe.listen(0, () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

async function findFreePort({ start = 3001, tries = 100 } = {}) {
  const last = Math.min(start + tries - 1, MAX_PORT);
  for (let port = start; port <= last; port++) {
    if (await isPortFree(port)) return port;
  }
  return osAssignedPort();
}

function listenOnce(target, port) {
  return new Promise((resolve, reject) => {
    let server;
    const onError = err => reject(err);
    try {
      server = target.listen(port, () => {
        server.removeListener('error', onError);
        resolve(server);
      });
    } catch (err) {
      reject(err);
      return;
    }
    server.once('error', onError);
  });
}

async function listenOnFreePort(target, { explicit = null, start = 3001, tries = 100 } = {}) {
  if (explicit !== null && explicit !== undefined) {
    const server = await listenOnce(target, explicit); // EADDRINUSE propagates; never substituted
    return { server, port: server.address().port };
  }
  let next = start;
  for (let attempt = 0; attempt < tries; attempt++) {
    const port = await findFreePort({ start: next, tries: tries - attempt });
    try {
      const server = await listenOnce(target, port);
      return { server, port: server.address().port };
    } catch (err) {
      if (err.code !== 'EADDRINUSE') throw err;
      next = port + 1; // lost the race between probe and bind: move on
    }
  }
  throw new Error(`no free port found after ${tries} attempts starting at ${start}`);
}

module.exports = { isPortFree, findFreePort, listenOnFreePort };

if (require.main === module) {
  const argv = process.argv.slice(2);
  const opt = name => {
    const i = argv.indexOf(name);
    return i >= 0 ? parseInt(argv[i + 1], 10) : undefined;
  };
  (async () => {
    const check = opt('--check');
    if (check !== undefined) {
      if (!Number.isInteger(check) || check < 1 || check > MAX_PORT) {
        console.error('--check needs a port number (1-65535)');
        process.exit(2);
      }
      process.exit((await isPortFree(check)) ? 0 : 1);
    }
    const start = opt('--start');
    const tries = opt('--tries');
    console.log(await findFreePort({ ...(start ? { start } : {}), ...(tries ? { tries } : {}) }));
  })().catch(err => {
    console.error(err.message);
    process.exit(2);
  });
}
