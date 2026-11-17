#!/usr/bin/env node
/**
 * lib/generate-copilot-instructions.js — .github/copilot-instructions.md generation
 *
 * Single source of truth for scaffolding the Copilot routing-instructions file from
 * templates/copilot-instructions.md.tpl (extracted from lib/commands/init.js per E46_S03_T01).
 * Used by:
 *   - scripts/postinstall.js  (runs unconditionally, non-interactively, on every `npm install`)
 *   - lib/commands/init.js    (the interactive `jenga init` CLI wizard, using the user's chosen
 *                              skillsPath — may differ from postinstall's default)
 *
 * Root-cause context: `.github/copilot-instructions.md` teaches Copilot the `/skill-name` →
 * `.agents/skills/<name>/SKILL.md` routing convention. It was previously written only by the
 * `jenga init` CLI wizard, never by postinstall.js — so a consumer whose very first action was
 * typing `/init` inside Copilot (before ever running `jenga init`) got no routing at all.
 * Extracting this into a shared, parameterized function lets postinstall.js bootstrap a working
 * routing file immediately, with `jenga init` free to refine it later using the user's actual
 * chosen skills path.
 *
 * Collision behaviour (preserved verbatim from the original inline implementation — do not
 * rewrite this algorithm, only relocate it):
 *   - If `.github/copilot-instructions.md` does not exist, write the rendered template in full.
 *   - If it exists, replace only the content between `<!-- JENGA:START -->` and
 *     `<!-- JENGA:END -->`, preserving everything outside the markers.
 *   - If it exists but has no JENGA markers, append the block to the end of the file.
 * This makes repeat runs (postinstall run twice, or postinstall followed by `jenga init`)
 * idempotent: the JENGA block is never duplicated and content outside the markers is never
 * touched.
 *
 * ESM, Node built-ins only — mirrors lib/generate-agent-context.js and lib/mirror.js.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { readSkillAllowList } from "./generate-skill-allow-list.js";

// This file lives at <package>/lib/generate-copilot-instructions.js — one level up is the
// installed jenga-agent package root, which holds templates/.
const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_PACKAGE_ROOT = join(__dirname, "..");

const START_MARKER = "<!-- JENGA:START -->";
const END_MARKER = "<!-- JENGA:END -->";

function resolveTemplatePath(projectRoot, packageRoot) {
  const candidates = [
    join(packageRoot, "templates", "copilot-instructions.md.tpl"),
    join(projectRoot, "templates", "copilot-instructions.md.tpl"),
  ];
  return candidates.find(existsSync);
}

/**
 * Build the {{SKILL_LIST}} markdown block by scanning `skillsDir` for subdirectories
 * containing a SKILL.md, extracting each one's `description:` frontmatter line.
 */
function buildSkillList(skillsDir) {
  if (!skillsDir || !existsSync(skillsDir)) return "_No skills found._";

  const skillLines = [];
  for (const entry of readdirSync(skillsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const skillMdPath = join(skillsDir, entry.name, "SKILL.md");
    let description = "";
    if (existsSync(skillMdPath)) {
      const content = readFileSync(skillMdPath, "utf8");
      const match = content.match(/^description:\s*(.+)$/m);
      if (match) description = match[1].trim();
    }
    skillLines.push(`- **${entry.name}**${description ? `: ${description}` : ""}`);
  }
  return skillLines.length > 0 ? skillLines.join("\n") : "_No skills found._";
}

/**
 * Build the rendered {{ALLOWED_SKILL_IDS}} block: the canonical, committed
 * `lib/skill-allow-list.json` artifact (E50_S02_T01/T02), rendered as a compact comma-joined
 * inline-code list for the "Routing decision table" allow-list check (E50_S02_T04). Reads via
 * the shared readSkillAllowList() helper — never re-derives its own scan of a skills
 * directory, mirroring the sibling buildAllowedSkillIds in lib/generate-agent-context.js so
 * both routing paths share the one committed artifact.
 */
function buildAllowedSkillIds(projectRoot, packageRoot, override) {
  const ids = Array.isArray(override) ? override : readSkillAllowList(projectRoot, packageRoot);
  return ids.length > 0 ? ids.map((id) => `\`${id}\``).join(", ") : "_No skills found._";
}

/**
 * Replace only the JENGA:START..JENGA:END block in an existing copilot-instructions.md with the
 * freshly rendered one, preserving everything outside the markers. If no existing file, write
 * the rendered template in full. If the existing file has no markers, append the block.
 *
 * Returns true when the file's bytes change (or the file is created). With `dryRun` nothing is
 * written; the return value says what a real run would have done (E26_S11_T01).
 */
function writeCopilotInstructions(path, rendered, dryRun = false) {
  if (!existsSync(path)) {
    if (!dryRun) writeFileSync(path, rendered, "utf8");
    return true;
  }

  const existing = readFileSync(path, "utf8");
  const startIdx = existing.indexOf(START_MARKER);
  const endIdx = existing.indexOf(END_MARKER);

  const renderedStart = rendered.indexOf(START_MARKER);
  const renderedEnd = rendered.indexOf(END_MARKER);
  const newBlock = rendered.slice(renderedStart, renderedEnd + END_MARKER.length);

  let updated;
  if (startIdx !== -1 && endIdx !== -1 && startIdx < endIdx) {
    updated = existing.slice(0, startIdx) + newBlock + existing.slice(endIdx + END_MARKER.length);
  } else {
    // No existing markers — append the block.
    updated = existing + (existing.endsWith("\n") ? "" : "\n") + newBlock + "\n";
  }
  if (updated === existing) return false;
  if (!dryRun) writeFileSync(path, updated, "utf8");
  return true;
}

/**
 * Generate (or idempotently refresh) `.github/copilot-instructions.md` at projectRoot from the
 * shared template.
 *
 * @param {string} projectRoot - project root directory (default: cwd)
 * @param {string} packageRoot - installed jenga-agent package root (default: derived from this
 *   file's own location)
 * @param {string} skillsDir - path to the skills directory, resolved relative to projectRoot if
 *   not already absolute (e.g. ".agents/skills" from postinstall, or the user's chosen
 *   skillsPath from the `jenga init` wizard)
 * @param {object} [options]
 * @param {boolean} [options.dryRun=false] - compute what a real run would write and compare it with
 *   the file on disk, but create no directory and write no file (E26_S11_T01).
 * @param {string[]} [options.allowedSkillIds] - render this allow-list instead of reading
 *   `lib/skill-allow-list.json` (lets a dry run reflect an allow-list a real run would regenerate first).
 * @returns {{written: boolean, changed: boolean, path?: string, skipped?: boolean, dryRun?: boolean}}
 *   `changed` is true when a real run alters the file's bytes; with `dryRun` `written` is false.
 */
export function generateCopilotInstructions(
  projectRoot = process.cwd(),
  packageRoot = DEFAULT_PACKAGE_ROOT,
  skillsDir,
  { dryRun = false, allowedSkillIds: allowedOverride } = {}
) {
  const tplPath = resolveTemplatePath(projectRoot, packageRoot);
  if (!tplPath) {
    return { written: false, changed: false, skipped: true };
  }

  const tpl = readFileSync(tplPath, "utf8");

  const resolvedSkillsDir = skillsDir
    ? (skillsDir.startsWith("/") ? skillsDir : join(projectRoot, skillsDir))
    : undefined;
  const skillList = buildSkillList(resolvedSkillsDir);
  const allowedSkillIds = buildAllowedSkillIds(projectRoot, packageRoot, allowedOverride);
  const rendered = tpl
    .replace("{{SKILL_LIST}}", skillList)
    .replace("{{ALLOWED_SKILL_IDS}}", allowedSkillIds);

  const githubDir = join(projectRoot, ".github");
  const copilotInstructionsPath = join(githubDir, "copilot-instructions.md");

  if (dryRun) {
    const changed = writeCopilotInstructions(copilotInstructionsPath, rendered, true);
    return { written: false, changed, path: copilotInstructionsPath, dryRun: true };
  }

  if (!existsSync(githubDir)) mkdirSync(githubDir, { recursive: true });

  const changed = writeCopilotInstructions(copilotInstructionsPath, rendered);

  return { written: true, changed, path: copilotInstructionsPath };
}
