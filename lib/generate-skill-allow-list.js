#!/usr/bin/env node
/**
 * lib/generate-skill-allow-list.js — canonical skill allow-list generator
 *
 * Single source of truth for the `j:`-prefix anti-masquerading guard (E50_S02). Scans a skills
 * directory for every `<name>/SKILL.md`, extracts each one's canonical `name:` frontmatter
 * identifier, and writes a sorted, de-duplicated JSON artifact to `lib/skill-allow-list.json`.
 *
 * Why this exists: E50_S02's guard checks whether a `j:`-prefixed invocation matches a known
 * list of genuine Jenga skill identifiers before treating it as trusted (see
 * docs/skill-authoring.md's "Threat Model — the j: Allow-List Guard" section, landed by
 * E50_S02_T05, for the guard's exact scope boundary). Every routing path that enforces that
 * guard — the MCP router (E50_S02_T03) and native/prose routing enforcement (E50_S02_T04) — must
 * read from this single artifact rather than re-deriving its own scan of `skills/`, mirroring the
 * drift lesson already documented in E41_S04 (CLAUDE.md and AGENT.md hand-maintained skill lists
 * had already drifted from each other before that epic unified them onto one generator).
 *
 * This module only builds the generator and produces the one-time committed artifact.
 * Auto-regeneration at `/self-sync`/postinstall time is wired up separately by the follow-up
 * task E50_S02_T02 — not in scope here.
 *
 * Consumers:
 *   - CLI guard at the bottom of this file (`node lib/generate-skill-allow-list.js`) — run once
 *     against this repo's own skills/ to produce the committed lib/skill-allow-list.json, and
 *     intended to be callable from skills/self-sync/scripts/run.js and scripts/postinstall.js in
 *     the follow-up task.
 *   - getSkillAllowListIdentifiers() — an in-memory-only helper for callers that want the
 *     identifier list without touching disk, e.g. the MCP router work in E50_S02_T03.
 *
 * ESM, Node built-ins only — mirrors lib/generate-agent-context.js and
 * lib/generate-copilot-instructions.js.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, realpathSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// This file lives at <package>/lib/generate-skill-allow-list.js — one level up is the repo/
// package root, which holds skills/.
const DEFAULT_SKILLS_DIR = join(__dirname, "..", "skills");
const DEFAULT_OUTPUT_PATH = join(__dirname, "skill-allow-list.json");
const DEFAULT_PACKAGE_ROOT = join(__dirname, "..");

/**
 * Extract the `name:` frontmatter field from a SKILL.md's content. Only the scalar `name` field
 * is needed here (unlike mcp/router/skill-index.js's fuller frontmatter parser, which also
 * handles array fields like `keywords`/`examples`) — a direct regex against the frontmatter
 * block is sufficient and avoids re-implementing that broader parser for a single field.
 */
function extractName(content) {
  const fmMatch = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!fmMatch) return null;
  const nameMatch = fmMatch[1].match(/^name:\s*(.+)$/m);
  if (!nameMatch) return null;
  const rawName = nameMatch[1].trim().replace(/^["']|["']$/g, "");
  // Frontmatter may carry either the pre-E50_S01 bare form or the post-rename "j:<name>" form
  // (skills/*/SKILL.md was migrated in E50_S01_T02) — strip the prefix so the allow-list always
  // holds bare identifiers, matching mcp/router/skill-index.js's `bareName` handling.
  return rawName.replace(/^j:/i, "");
}

/**
 * Scan `skillsDir` for every immediate `<name>/SKILL.md` and return a sorted, de-duplicated
 * array of canonical skill identifiers (the frontmatter `name` value, treated as authoritative
 * per docs/skill-authoring.md's "name must match the directory name" authoring rule — this
 * function does not itself verify that match, only that `name` is present).
 *
 * A SKILL.md missing the `name` field is skipped with a warning, not fatal — mirrors
 * mcp/router/skill-index.js's buildSkillIndex warning behavior for consistency across the two
 * scanners.
 *
 * No disk write. Pure in-memory scan, for callers (e.g. the MCP router, E50_S02_T03) that want
 * the identifier list without reading the generated artifact.
 *
 * @param {string} skillsDir - directory to scan (default: this repo/package's own skills/)
 * @returns {string[]} sorted, de-duplicated skill identifiers
 */
export function getSkillAllowListIdentifiers(skillsDir = DEFAULT_SKILLS_DIR) {
  if (!existsSync(skillsDir)) return [];

  const identifiers = new Set();

  for (const entry of readdirSync(skillsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;

    const skillMdPath = join(skillsDir, entry.name, "SKILL.md");
    if (!existsSync(skillMdPath)) continue;

    let content;
    try {
      content = readFileSync(skillMdPath, "utf8");
    } catch (e) {
      process.stderr.write(`Warning: failed to read ${skillMdPath}: ${e.message} — skipped\n`);
      continue;
    }

    const name = extractName(content);
    if (!name) {
      process.stderr.write(`Warning: ${skillMdPath} has no 'name' in frontmatter — skipped\n`);
      continue;
    }

    identifiers.add(name);
  }

  return [...identifiers].sort();
}

/**
 * Read the committed skill-allow-list.json artifact (produced by generateSkillAllowList /
 * regenerated by postinstall.js and skills/self-sync/scripts/run.js) and return its `skills`
 * array. Resolution order mirrors resolveTemplatePath's packageRoot-then-projectRoot candidate
 * order in lib/generate-agent-context.js and lib/generate-copilot-instructions.js: the artifact
 * normally lives at `<packageRoot>/lib/skill-allow-list.json` (the installed jenga-agent
 * package's own committed copy), with `<projectRoot>/lib/skill-allow-list.json` as a fallback
 * for the case where this repo IS the project (e.g. this monorepo's own dogfood run).
 *
 * This is the single read path both E50_S02_T04 generators (native Claude Code context files
 * and Copilot/Codex prose-routing instructions) use to render the "trusted identifiers" list —
 * neither one re-derives its own scan of skills/, per the drift lesson already documented in
 * E41_S04 and referenced in this module's header comment.
 *
 * @param {string} projectRoot - project root directory
 * @param {string} packageRoot - installed jenga-agent package root (default: this module's own
 *   package root)
 * @returns {string[]} the artifact's `skills` array, or [] if the artifact is missing/unparseable
 */
export function readSkillAllowList(projectRoot, packageRoot = DEFAULT_PACKAGE_ROOT) {
  const candidates = [
    join(packageRoot, "lib", "skill-allow-list.json"),
    join(projectRoot, "lib", "skill-allow-list.json"),
  ];
  const path = candidates.find(existsSync);
  if (!path) return [];

  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return Array.isArray(parsed.skills) ? parsed.skills : [];
  } catch (e) {
    process.stderr.write(`Warning: failed to read/parse ${path}: ${e.message} — treating allow-list as empty\n`);
    return [];
  }
}

/**
 * Generate the canonical skill allow-list artifact at `outputPath`.
 *
 * The `skills` array is deterministic — sorted and de-duplicated, so repeat runs with no
 * `skills/` change produce a byte-identical array. `generated_at` is NOT deterministic (it is a
 * fresh timestamp on every run) — that is expected and intentional, not a bug: only the `skills`
 * array itself is contracted to be stable.
 *
 * @param {string} skillsDir - directory to scan (default: this repo/package's own skills/)
 * @param {string} outputPath - where to write the JSON artifact (default: lib/skill-allow-list.json)
 * @returns {{written: boolean, path: string, skill_count: number}}
 */
export function generateSkillAllowList(skillsDir = DEFAULT_SKILLS_DIR, outputPath = DEFAULT_OUTPUT_PATH) {
  const skills = getSkillAllowListIdentifiers(skillsDir);

  const artifact = {
    generated_at: new Date().toISOString(),
    skill_count: skills.length,
    skills,
  };

  const outDir = dirname(outputPath);
  if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });

  writeFileSync(outputPath, JSON.stringify(artifact, null, 2) + "\n", "utf8");

  return { written: true, path: outputPath, skill_count: skills.length };
}

// CLI guard — allows `node lib/generate-skill-allow-list.js [skillsDir] [outputPath]`, intended
// to be callable from skills/self-sync/scripts/run.js and scripts/postinstall.js in the
// follow-up auto-regeneration task (E50_S02_T02).
//
// process.argv[1] is compared via realpath, not as a raw string — see the identical comment
// block in lib/generate-agent-context.js for why: Node resolves import.meta.url through symlinks
// when loading an ES module, but leaves process.argv[1] exactly as the shell passed it, so an
// invocation from a path under a symlinked directory (e.g. macOS's /tmp -> /private/tmp) would
// otherwise silently fail this comparison and skip generation with no error.
const invokedPath = process.argv[1] ? realpathSync(process.argv[1]) : null;
if (invokedPath === fileURLToPath(import.meta.url)) {
  const skillsDirArg = process.argv[2] || DEFAULT_SKILLS_DIR;
  const outputPathArg = process.argv[3] || DEFAULT_OUTPUT_PATH;
  const result = generateSkillAllowList(skillsDirArg, outputPathArg);
  console.log(`✓ ${result.path} (${result.skill_count} skills)`);
}
