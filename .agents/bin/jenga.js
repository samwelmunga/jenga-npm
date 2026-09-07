#!/usr/bin/env node
/**
 * jenga — Jenga Agent CLI
 * Usage: jenga <command> [options]
 */
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(join(__dirname, "..", "package.json"), "utf8"));

const [,, cmd, ...args] = process.argv;

const USAGE = `
jenga — Jenga Agent CLI v${pkg.version}

Usage:
  jenga init      Run the setup wizard (creates jenga.cli.json, registers hook)
  jenga attach    Write MCP config for this project so new sessions route through Jenga
  jenga status    Show router status and active session
  jenga doctor    Scan .agents/ and .claude/ for orphaned package files and clean up
                  interactively (alias: jenga clean). Add --dry-run to preview only.

Options:
  --version, -v   Print version
  --help, -h      Print this help message
`.trim();

async function main() {
  if (!cmd || cmd === "--help" || cmd === "-h") {
    console.log(USAGE);
    process.exit(0);
  }

  if (cmd === "--version" || cmd === "-v") {
    console.log(pkg.version);
    process.exit(0);
  }

  switch (cmd) {
    case "init": {
      const { runInit } = await import("../lib/commands/init.js");
      await runInit(args);
      break;
    }
    case "start": {
      const { runStart } = await import("../lib/commands/start.js");
      await runStart(args);
      break;
    }
    case "attach": {
      const { runAttach } = await import("../lib/commands/attach.js");
      await runAttach(args);
      break;
    }
    case "status": {
      const { runStatus } = await import("../lib/commands/status.js");
      await runStatus(args);
      break;
    }
    case "doctor":
    case "clean": {
      // Both names are the same code path (E26_S08_T02) — "doctor" and "clean" are
      // intentionally interchangeable, never two implementations.
      const { runDoctor } = await import("../lib/commands/doctor.js");
      await runDoctor(args);
      break;
    }
    default:
      console.error(`Unknown command: ${cmd}\n`);
      console.log(USAGE);
      process.exit(1);
  }
}

main().catch(err => {
  console.error(err.message);
  process.exit(1);
});
