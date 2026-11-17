import { existsSync, readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { reportDrift } from "../sync-drift.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..", "..");

function formatDuration(ms) {
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

function readSessionFile(targetRoot = process.cwd()) {
  const sessionFile = join(targetRoot, ".jenga", "session.json");
  try {
    if (!existsSync(sessionFile)) return { skill: null, startedAt: null };
    return JSON.parse(readFileSync(sessionFile, "utf8"));
  } catch {
    return { skill: null, startedAt: null };
  }
}

// `root` is the installed package root; `opts.targetRoot` (test seam, default process.cwd()) is the project.
export async function runStatus(args, root = projectRoot, opts = {}) {
  const targetRoot = opts.targetRoot || process.cwd();
  const pidFile = join(targetRoot, ".jenga", "router.pid");

  // Warn about a project that is out of step with the installed package (E26_S11_T05). Printed before the
  // router check so it also shows on the "Router is not running" paths, which exit early. Read-only; it
  // never changes the exit code.
  reportDrift({ packageRoot: root, consumerRoot: targetRoot });

  // Check if router is running
  if (!existsSync(pidFile)) {
    console.log("Router is not running. Run `jenga start` to start it.");
    process.exit(0);
  }

  let pid;
  try {
    pid = parseInt(readFileSync(pidFile, "utf8").trim(), 10);
    process.kill(pid, 0); // throws if not alive
  } catch {
    console.log("Router is not running. Run `jenga start` to start it.");
    process.exit(0);
  }

  // Read real session state from .jenga/session.json written by the router
  const session = readSessionFile(targetRoot);

  if (session.skill && session.startedAt) {
    const elapsed = formatDuration(Date.now() - new Date(session.startedAt).getTime());
    console.log(`✓ Router running (PID: ${pid}) | Active session: ${session.skill} (${elapsed})`);
  } else {
    console.log(`✓ Router running (PID: ${pid}) | No active session`);
  }
}
