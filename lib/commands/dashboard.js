/**
 * lib/commands/dashboard.js — `jenga dashboard start` / `jenga dashboard open` (E47_S03_T01)
 *
 * Reuse decision (documented per this task's `needs_docs: true`)
 * ────────────────────────────────────────────────────────────────
 * `project/app/ui/scripts/dashboard-start.cjs` and `dashboard-open.cjs` are standalone CommonJS
 * scripts that parse `process.argv.slice(2)` directly at the top level and act on it immediately
 * (start listening / run a health check then `process.exit`). They are not written as importable,
 * args-parameterized functions.
 *
 * Two reuse strategies were considered:
 *   1. Refactor their bodies into an exported function both the `.cjs` entry points and this
 *      module call.
 *   2. Spawn the existing scripts as a child process, forwarding args and exit code.
 *
 * Chosen: (2), spawning as a child process. Refactoring (1) would require restructuring two
 * scripts that are independently relied on elsewhere (root `package.json`'s `dashboard:start`/
 * `dashboard:open` npm scripts, `skills/j-dashboard`'s launcher, and
 * `scripts/verify-consumer-install.sh`'s Scenario E regression check) for a task whose job is CLI
 * wiring, not a dashboard-scripts refactor. Spawning with `stdio: 'inherit'` reuses the scripts
 * completely verbatim — zero duplicated port-parsing / `--serve-app` / health-check logic — and
 * guarantees byte-identical output and exit-code behavior to running the `.cjs` scripts directly
 * (this is what AC1/AC2's "same behavior" requirement asks for literally). It also avoids the
 * process-global side effects a same-process dynamic `import()` would risk: both scripts call
 * `process.exit()` directly at top level, which would kill the parent `bin/jenga.js` process
 * immediately and unrecoverably if loaded in-process.
 */
import { spawn } from "child_process";
import { existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..", "..");

const SUBCOMMANDS = {
  start: "dashboard-start.cjs",
  open: "dashboard-open.cjs",
};

const DASHBOARD_USAGE = `
Usage:
  jenga dashboard start [--port <n>] [--serve-app]   Start the dashboard API server
                                                      (and optionally serve the built UI)
  jenga dashboard open [--port <n>]                  Health-check the dashboard and open it
                                                      in your browser
`.trim();

export async function runDashboard(args, root = projectRoot) {
  const [sub, ...rest] = args;

  if (!sub || !(sub in SUBCOMMANDS)) {
    if (sub) {
      console.error(`Unknown dashboard subcommand: ${sub}\n`);
    } else {
      console.error("Missing dashboard subcommand.\n");
    }
    console.log(DASHBOARD_USAGE);
    process.exit(1);
    return;
  }

  const scriptPath = join(root, "project", "app", "ui", "scripts", SUBCOMMANDS[sub]);
  if (!existsSync(scriptPath)) {
    console.error(`Error: dashboard script not found at ${scriptPath}`);
    process.exit(1);
    return;
  }

  return new Promise((resolve) => {
    const child = spawn(process.execPath, [scriptPath, ...rest], {
      stdio: "inherit",
      env: process.env,
    });

    child.on("exit", (code, signal) => {
      if (signal) {
        // Re-raise the same signal on ourselves so a Ctrl-C style termination propagates
        // cleanly to any caller inspecting our own exit status, rather than reporting a
        // fabricated exit code for a signal-based termination.
        process.kill(process.pid, signal);
        return;
      }
      process.exit(code === null ? 1 : code);
    });

    child.on("error", (err) => {
      console.error(`Error: failed to launch dashboard ${sub}: ${err.message}`);
      process.exit(1);
    });
  });
}
