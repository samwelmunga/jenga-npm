#!/usr/bin/env node
// hooks/session_end_helper.js
// Detects and strips [JENGA:SESSION_END:<skill>] from Claude output.

import { readFileSync } from "fs";

const SIGNAL_RE = /\[JENGA:SESSION_END:([a-zA-Z0-9_-]+)\]/;

const input = readFileSync("/dev/stdin", "utf8");
const lines = input.split("\n");
const filteredLines = [];
let detectedSkill = null;

for (const line of lines) {
  const match = line.match(SIGNAL_RE);
  if (match) {
    detectedSkill = match[1];
    // Skip this line (strip it from output)
  } else {
    filteredLines.push(line);
  }
}

if (detectedSkill) {
  process.stderr.write(`[jenga-router] Session ended: ${detectedSkill}\n`);
  // TODO: Call router end_session MCP tool (E11_S04)
}

process.stdout.write(filteredLines.join("\n"));
