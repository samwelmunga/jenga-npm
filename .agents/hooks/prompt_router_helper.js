#!/usr/bin/env node
// hooks/prompt_router_helper.js
// Companion helper for prompt_router.sh — implements the UserPromptSubmit /
// userPromptSubmitted routing logic shared by Claude Code and GitHub Copilot CLI
// (E16_S03_T04 — both platforms deliver a JSON stdin payload with a `prompt` field, so
// no platform branching is needed here).
// Reads JSON payload from stdin, checks if the Jenga Router is running,
// and either routes the prompt or passes it through unchanged.
//
// ESM (root package.json sets "type": "module") — found and fixed under E16_S03_T04 while
// verifying the new Copilot userPromptSubmitted wiring end-to-end: this file previously used
// CommonJS require()/__dirname, which crashes under Node's ESM loader with
// "ReferenceError: require is not defined in ES module scope". That crash predates this task
// (present since the file's original authoring, e09242d) and affected the existing Claude-side
// UserPromptSubmit hook equally — not something newly introduced by the Copilot wiring.

import { readFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..");

// Read stdin (JSON payload from Claude Code: {"prompt": "..."}, or from Copilot CLI's
// userPromptSubmitted event: {"sessionId": "...", "timestamp": ..., "cwd": "...", "prompt": "..."})
let input;
try {
  const raw = readFileSync("/dev/stdin", "utf8").trim();
  input = JSON.parse(raw);
} catch {
  process.stdout.write("{}");
  process.exit(0);
}

const prompt = input.prompt || "";

if (!prompt) {
  process.stdout.write(JSON.stringify(input));
  process.exit(0);
}

// Check if the Jenga Router is running via its PID file
const pidFile = join(projectRoot, "mcp", "router", ".pid");
if (!existsSync(pidFile)) {
  // Router not running — passthrough
  process.stdout.write(JSON.stringify(input));
  process.exit(0);
}

let pid;
try {
  pid = parseInt(readFileSync(pidFile, "utf8").trim(), 10);
  process.kill(pid, 0); // Signal 0 just checks if the process is alive
} catch {
  // Router not responsive — passthrough
  process.stdout.write(JSON.stringify(input));
  process.exit(0);
}

// Router is alive — call it with a ≤ 500ms timeout.
// timeout enforced by calling code (e.g. AbortController / Promise.race in future router client)
// Router client integration TBD; passthrough until wired up.
process.stdout.write(JSON.stringify(input));
process.exit(0);
