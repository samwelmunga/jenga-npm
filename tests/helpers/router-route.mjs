#!/usr/bin/env node
/**
 * tests/helpers/router-route.mjs — thin CLI shim over the router's Stage 1 internals.
 *
 * Exists so tests/router-prefix-guard.bats can exercise the real modules rather than a
 * re-implementation of them. Deliberately contains no logic of its own: it resolves a skills
 * directory, calls the module under test, and prints a single JSON line.
 *
 * `mcp/router/index.js` itself is not importable from a test — it starts an MCP server and loads
 * an embedding model at import time. That untestability is precisely why the E50_S07_T01 fail-open
 * reached main. E50_S07_T02 moved the security-critical Stage 1 decision into
 * mcp/router/allow-list-guard.js, which imports nothing heavier than Node built-ins, so this shim
 * needs no npm install, no network, and no model download.
 *
 * Usage:
 *   router-route.mjs route      <skillsDir> <text>        -> the routeDirectInvocation() result
 *   router-route.mjs allow-list <skillsDir>               -> the normalized allow-list
 *   router-route.mjs index      <skillsDir>               -> [{ name }] from buildSkillIndex()
 *   router-route.mjs emit       <skillsDir> <name> <text> -> the Stage 2 `transformed` string
 */

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const { getAllowedIdentifiers, routeDirectInvocation } = await import(
  join(repoRoot, "mcp", "router", "allow-list-guard.js")
);
const { buildSkillIndex } = await import(join(repoRoot, "mcp", "router", "skill-index.js"));
const { formatInvocation } = await import(join(repoRoot, "mcp", "router", "prefix.js"));

const [mode, skillsDir, ...rest] = process.argv.slice(2);

function out(value) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

switch (mode) {
  case "route":
    out(routeDirectInvocation(rest[0], getAllowedIdentifiers(skillsDir)));
    break;
  case "allow-list":
    out(getAllowedIdentifiers(skillsDir));
    break;
  case "index":
    out((await buildSkillIndex(skillsDir)).map(({ name }) => ({ name })));
    break;
  case "emit": {
    // Mirrors mcp/router/index.js's Stage 2 emission exactly: the bare name off the skill index,
    // run through formatInvocation(). If those two ever drift apart, this test goes red.
    const skill = (await buildSkillIndex(skillsDir)).find((s) => s.name === rest[0]);
    out(skill ? `${formatInvocation(skill.name)} ${rest[1]}` : null);
    break;
  }
  default:
    process.stderr.write(`unknown mode: ${mode}\n`);
    process.exit(2);
}
