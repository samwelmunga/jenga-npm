#!/usr/bin/env node
// hooks/prompt_router_helper.js
// Companion helper for prompt_router.sh — implements Claude Code UserPromptSubmit logic.
// Reads JSON payload from stdin, checks if the Jenga Router is running,
// and either routes the prompt or passes it through unchanged.

"use strict";
const { readFileSync, existsSync } = require("fs");
const { join } = require("path");

const projectRoot = join(__dirname, "..");

// Read stdin (JSON payload from Claude Code: {"prompt": "..."})
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
