import { existsSync, readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..", "..");

function formatDuration(ms) {
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

function readSessionFile() {
  const sessionFile = join(process.cwd(), ".jenga", "session.json");
  try {
    if (!existsSync(sessionFile)) return { skill: null, startedAt: null };
    return JSON.parse(readFileSync(sessionFile, "utf8"));
  } catch {
    return { skill: null, startedAt: null };
  }
}

export async function runStatus(args, root = projectRoot) {
  const pidFile = join(process.cwd(), ".jenga", "router.pid");

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
  const session = readSessionFile();

  if (session.skill && session.startedAt) {
    const elapsed = formatDuration(Date.now() - new Date(session.startedAt).getTime());
    console.log(`✓ Router running (PID: ${pid}) | Active session: ${session.skill} (${elapsed})`);
  } else {
    console.log(`✓ Router running (PID: ${pid}) | No active session`);
  }
}
