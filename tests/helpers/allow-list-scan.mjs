#!/usr/bin/env node
/**
 * tests/helpers/allow-list-scan.mjs — thin CLI shim over lib/generate-skill-allow-list.js.
 *
 * Exists so tests/skill-allow-list-bijection.bats (E50_S12_T01) can exercise the real generator
 * module against an arbitrary directory (a synthetic fixture tree, or this repo's own skills/ /
 * .agents/skills/) without re-implementing its scan logic. Deliberately contains no logic of its
 * own beyond argument dispatch and JSON printing — mirrors tests/helpers/router-route.mjs's shape
 * for the same reason that file gives: a test helper that re-derives behavior instead of calling
 * the real module under test proves nothing about the real module.
 *
 * Usage:
 *   allow-list-scan.mjs ids <skillsDir>
 *     -> the sorted, de-duplicated identifier array from getSkillAllowListIdentifiers()
 *
 *   allow-list-scan.mjs skills-only <skillsDir> <outputPath>
 *     -> generateSkillAllowList(skillsDir, outputPath)'s `skills` array only (generated_at
 *        omitted deliberately, since it is non-deterministic by design — see that function's own
 *        doc comment — and every caller of this mode wants to compare skills arrays only)
 */

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const { getSkillAllowListIdentifiers, generateSkillAllowList } = await import(
  join(repoRoot, "lib", "generate-skill-allow-list.js")
);

const [mode, ...rest] = process.argv.slice(2);

function out(value) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

switch (mode) {
  case "ids":
    out(getSkillAllowListIdentifiers(rest[0]));
    break;
  case "skills-only": {
    const [skillsDir, outputPath] = rest;
    const result = generateSkillAllowList(skillsDir, outputPath);
    // Re-read the artifact just written rather than trusting generateSkillAllowList's return
    // value alone, so this helper also exercises the on-disk write path a caller like
    // scripts/postinstall.js depends on.
    const { readFileSync } = await import("node:fs");
    const artifact = JSON.parse(readFileSync(result.path, "utf8"));
    out(artifact.skills);
    break;
  }
  default:
    process.stderr.write(`unknown mode: ${mode}\n`);
    process.exit(2);
}
