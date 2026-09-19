#!/usr/bin/env node
/**
 * tests/helpers/help-scan.mjs — thin CLI shim over mcp/help/scan.js.
 *
 * Exists so tests/help-twin-only-listing.bats (E50_S12_T06) can exercise the real
 * scanning module rather than a re-implementation of it. Contains no logic of its own
 * beyond argument dispatch and JSON printing — mirrors tests/helpers/router-route.mjs's
 * shape.
 *
 * Usage:
 *   help-scan.mjs resolve <root>      -> resolveSkillsDir(root), or "" if none found
 *   help-scan.mjs list    <skillsDir> -> JSON array from listSkillFolders(skillsDir)
 */

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const { resolveSkillsDir, listSkillFolders } = await import(
  join(repoRoot, "mcp", "help", "scan.js")
);

const [mode, arg] = process.argv.slice(2);

switch (mode) {
  case "resolve":
    process.stdout.write(String(resolveSkillsDir(arg) ?? ""));
    break;
  case "list":
    process.stdout.write(JSON.stringify(listSkillFolders(arg)));
    break;
  default:
    process.stderr.write(`unknown mode: ${mode}\n`);
    process.exit(2);
}
