#!/usr/bin/env node
/**
 * lib/generate-agent-context.js — CLAUDE.md / AGENTS.md generation
 *
 * Single source of truth for scaffolding the two root-level agent-context
 * files from templates/agent-context.md.tpl (E41_S04_T02). Used by:
 *   - lib/commands/init.js         (published `jenga init` CLI)
 *   - skills/j-init/scripts/init.sh  (this repo's own board-scaffolding flow,
 *                                   invoked via `node` — see the CLI guard
 *                                   at the bottom of this file)
 *
 * Design constraints (per E41_S04 story — do not re-litigate):
 *   - CLAUDE.md and AGENTS.md are written unconditionally, never gated on
 *     `agentTarget`.
 *   - Both are written as real files — never a symlink.
 *   - No AGENT.md (singular) is ever scaffolded.
 *   - Collision rule: if the target file doesn't exist, write it directly.
 *     If it already exists, Jenga's copy goes to `J-<NAME>.md` instead, and
 *     a short, clearly-marked reference is inserted near the top of the
 *     existing file. The J- prefix always belongs to the incoming Jenga
 *     file; the user's file keeps its name and content.
 *   - Idempotent across repeat runs: managed blocks update in place, the
 *     reference line is never duplicated, and a J- file is updated in place
 *     rather than re-triggering collision handling (no J-J-CLAUDE.md).
 *
 * ESM, Node built-ins only — mirrors lib/mirror.js and lib/inject-settings.js.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, realpathSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { readSkillAllowList } from "./generate-skill-allow-list.js";

// This file lives at <package>/lib/generate-agent-context.js — one level up
// is the installed jenga-agent package root, which holds templates/.
const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_PACKAGE_ROOT = join(__dirname, "..");

const CONTENT_START = "<!-- JENGA:START -->";
const CONTENT_END = "<!-- JENGA:END -->";
const REF_START = "<!-- JENGA:REF:START -->";
const REF_END = "<!-- JENGA:REF:END -->";

// One entry per generated file. skillDiscoveryPath reflects the reading
// agent's own discovery convention: Claude Code reads .claude/skills/,
// every other agent (Codex, generic AGENTS.md consumers, ...) reads
// .agents/skills/.
const TARGETS = [
  { filename: "CLAUDE.md", skillDiscoveryPath: ".claude/skills/" },
  { filename: "AGENTS.md", skillDiscoveryPath: ".agents/skills/" },
];

/**
 * Build the rendered {{SKILL_LIST}} block by scanning the first existing
 * skills directory among .claude/skills/ and .agents/skills/ — mirrored
 * copies hold identical content, so either is representative. Mirrors the
 * skill-list extraction already used for the Copilot template in
 * lib/commands/init.js.
 */
function buildSkillList(projectRoot, skillsDirOverride) {
  const entries = listSkillEntries(projectRoot, skillsDirOverride);
  if (entries === null) return "_No skills found._";
  const skillLines = entries.map(formatSkillLine);
  return skillLines.length > 0 ? skillLines.join("\n") : "_No skills found._";
}

/** The one place the rendered skill-list line format is defined; `parseSkillNamesFromBlock` is its inverse. */
function formatSkillLine({ name, description }) {
  return `- **${name}**${description ? `: ${description}` : ""}`;
}

/**
 * The skill directories the {{SKILL_LIST}} is built from: `{name, description}` per immediate
 * subdirectory of the first existing skills directory (an explicit `skillsDirOverride`, else
 * `.claude/skills`, else `.agents/skills` under projectRoot). Returns null when there is none.
 * Shared by the generator and by lib/sync-drift.js so a drift check cannot disagree with what a
 * sync would write (E26_S11_T05).
 */
export function listSkillEntries(projectRoot, skillsDirOverride) {
  const candidates = skillsDirOverride
    ? [skillsDirOverride]
    : [".claude/skills", ".agents/skills"].map((p) => join(projectRoot, p));
  const skillsDir = candidates.find(existsSync);
  if (!skillsDir) return null;

  const entries = [];
  for (const entry of readdirSync(skillsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const skillMdPath = join(skillsDir, entry.name, "SKILL.md");
    let description = "";
    if (existsSync(skillMdPath)) {
      const content = readFileSync(skillMdPath, "utf8");
      const match = content.match(/^description:\s*(.+)$/m);
      if (match) description = match[1].trim();
    }
    entries.push({ name: entry.name, description });
  }
  return entries;
}

/** Skill directory names a sync would list (see listSkillEntries); `null` when no skills directory exists. */
export function listSkillNames(projectRoot, skillsDirOverride) {
  const entries = listSkillEntries(projectRoot, skillsDirOverride);
  return entries === null ? null : entries.map((e) => e.name);
}

/**
 * The text between the Jenga START/END markers of an agent-context file's content (markers
 * included), or null when the file carries no complete block.
 */
export function extractJengaBlock(content) {
  const startIdx = content.indexOf(CONTENT_START);
  const endIdx = content.indexOf(CONTENT_END);
  if (startIdx === -1 || endIdx === -1 || startIdx >= endIdx) return null;
  return content.slice(startIdx, endIdx + CONTENT_END.length);
}

/** Skill names listed in a rendered Jenga block, in order (inverse of formatSkillLine). */
export function parseSkillNamesFromBlock(block) {
  const names = [];
  for (const line of block.split("\n")) {
    const m = line.match(/^- \*\*(.+?)\*\*(?::|$)/);
    if (m) names.push(m[1]);
  }
  return names;
}

/**
 * Build the rendered {{ALLOWED_SKILL_IDS}} block: the canonical, committed
 * `lib/skill-allow-list.json` artifact (E50_S02_T01/T02), rendered as a
 * compact comma-joined inline-code list for the "Skill Identifier
 * Allow-List" section of the generated context files (E50_S02_T04). Reads
 * via the shared readSkillAllowList() helper — never re-derives its own
 * scan of skills/, so this list always matches the artifact the MCP router
 * (E50_S02_T03) and postinstall/self-sync regeneration also read from.
 */
function buildAllowedSkillIds(projectRoot, packageRoot, override) {
  const ids = Array.isArray(override) ? override : readSkillAllowList(projectRoot, packageRoot);
  return ids.length > 0 ? ids.map((id) => `\`${id}\``).join(", ") : "_No skills found._";
}

function resolveTemplatePath(projectRoot, packageRoot) {
  const candidates = [
    join(packageRoot, "templates", "agent-context.md.tpl"),
    join(projectRoot, "templates", "agent-context.md.tpl"),
  ];
  return candidates.find(existsSync);
}

/**
 * Replace only the JENGA:START..JENGA:END block in `existingContent` with
 * `newBlock` (which itself includes the marker comments), preserving
 * everything outside the markers. If no markers are present, append the
 * block. Identical technique to the Copilot managed-block replace in
 * lib/commands/init.js.
 */
function replaceManagedBlock(existingContent, newBlock) {
  const startIdx = existingContent.indexOf(CONTENT_START);
  const endIdx = existingContent.indexOf(CONTENT_END);
  if (startIdx !== -1 && endIdx !== -1 && startIdx < endIdx) {
    return existingContent.slice(0, startIdx) + newBlock + existingContent.slice(endIdx + CONTENT_END.length);
  }
  return existingContent + (existingContent.endsWith("\n") ? "" : "\n") + newBlock + "\n";
}

/**
 * Write `rendered` (full file content, including the JENGA:START/END block)
 * to `path`. If the file doesn't exist, write it in full. If it does,
 * replace only the managed block, preserving any content outside it (e.g.
 * a user's own edits to the title line of a Jenga-owned file).
 *
 * Returns true when the file's bytes change (or the file is created). With `dryRun` nothing is
 * written; the return value says what a real run would have done (E26_S11_T01).
 */
function writeManagedFile(path, rendered, dryRun = false) {
  if (!existsSync(path)) {
    if (!dryRun) writeFileSync(path, rendered, "utf8");
    return true;
  }
  const existing = readFileSync(path, "utf8");
  const renderedStart = rendered.indexOf(CONTENT_START);
  const renderedEnd = rendered.indexOf(CONTENT_END);
  const newBlock = rendered.slice(renderedStart, renderedEnd + CONTENT_END.length);
  const updated = replaceManagedBlock(existing, newBlock);
  if (updated === existing) return false;
  if (!dryRun) writeFileSync(path, updated, "utf8");
  return true;
}

/**
 * Insert (or, on repeat runs, update in place) a short Jenga-marked
 * reference block near the very top of a pre-existing user file, pointing
 * at the J-<NAME>.md copy. Idempotent via its own REF marker pair, kept
 * distinct from CONTENT_START/CONTENT_END so the two replace passes never
 * interfere with each other in the same file.
 *
 * Returns true when the file's bytes change. With `dryRun` nothing is written (E26_S11_T01).
 */
function insertOrUpdateReference(path, jFilename, dryRun = false) {
  const refBlock =
    `${REF_START}\n` +
    `> **Jenga framework note:** This project also uses [Jenga](https://github.com/samwelmunga/jenga-npm) — ` +
    `see \`${jFilename}\` for Jenga's framework-specific agent context (skills, board, workflow). ` +
    `This file is unrelated to Jenga and was left untouched.\n` +
    `${REF_END}`;

  const existing = readFileSync(path, "utf8");
  const startIdx = existing.indexOf(REF_START);
  const endIdx = existing.indexOf(REF_END);

  let updated;
  if (startIdx !== -1 && endIdx !== -1 && startIdx < endIdx) {
    updated = existing.slice(0, startIdx) + refBlock + existing.slice(endIdx + REF_END.length);
  } else {
    // No existing reference — insert at the very top, ahead of any content,
    // satisfying "early / before the first major section" regardless of
    // the existing file's structure.
    updated = refBlock + "\n\n" + existing;
  }
  if (updated === existing) return false;
  if (!dryRun) writeFileSync(path, updated, "utf8");
  return true;
}

/**
 * Generate CLAUDE.md and AGENTS.md at projectRoot from the shared template,
 * applying the J- collision rule and idempotent managed-block updates.
 *
 * @param {string} projectRoot - project root directory (default: cwd)
 * @param {string} packageRoot - installed jenga-agent package root (default:
 *   derived from this file's own location)
 * @param {object} [options]
 * @param {boolean} [options.dryRun=false] - compute what a real run would write and compare it with
 *   the files on disk, but write nothing (E26_S11_T01).
 * @param {string} [options.skillsDir] - scan this directory for the {{SKILL_LIST}} instead of
 *   `.claude/skills` / `.agents/skills` under projectRoot (lets a dry run reflect a mirror it has not run).
 * @param {string[]} [options.allowedSkillIds] - render this allow-list instead of reading
 *   `lib/skill-allow-list.json`.
 * @returns {{written: Array<{filename: string, mode: string, file: string, changed: boolean}>,
 *            changed: boolean, skipped?: boolean, dryRun?: boolean}}
 *   Each entry's `file` is the file that carries the Jenga block (`J-<name>` on a collision) and
 *   `changed` is true when a real run alters any byte of the block file or of the reference in the
 *   user's own file. The top-level `changed` is true when any entry changed. With `dryRun` nothing
 *   is written; `written` then lists what a real run would write.
 */
export function generateAgentContext(
  projectRoot = process.cwd(),
  packageRoot = DEFAULT_PACKAGE_ROOT,
  { dryRun = false, skillsDir, allowedSkillIds: allowedOverride } = {}
) {
  const tplPath = resolveTemplatePath(projectRoot, packageRoot);
  if (!tplPath) {
    return { written: [], changed: false, skipped: true };
  }

  const tpl = readFileSync(tplPath, "utf8");
  const skillList = buildSkillList(projectRoot, skillsDir);
  const allowedSkillIds = buildAllowedSkillIds(projectRoot, packageRoot, allowedOverride);
  const written = [];

  for (const target of TARGETS) {
    const rendered = tpl
      .split("{{TARGET_FILENAME}}").join(target.filename)
      .split("{{SKILL_DISCOVERY_PATH}}").join(target.skillDiscoveryPath)
      .split("{{SKILL_LIST}}").join(skillList)
      .split("{{ALLOWED_SKILL_IDS}}").join(allowedSkillIds);

    const targetPath = join(projectRoot, target.filename);
    const jFilename = `J-${target.filename}`;
    const jPath = join(projectRoot, jFilename);

    if (existsSync(jPath)) {
      // A J- file can only ever have been created by Jenga — this is a
      // repeat run after a prior collision. Update it in place; never
      // re-derive collision handling from it (no J-J-CLAUDE.md).
      let changed = writeManagedFile(jPath, rendered, dryRun);
      if (existsSync(targetPath)) {
        changed = insertOrUpdateReference(targetPath, jFilename, dryRun) || changed;
      }
      written.push({ filename: target.filename, mode: "updated-j-file", file: jFilename, changed });
      continue;
    }

    if (existsSync(targetPath)) {
      const existingContent = readFileSync(targetPath, "utf8");
      if (existingContent.includes(CONTENT_START)) {
        // Jenga's own file from a prior *non-collision* run — update in
        // place rather than treating it as a fresh collision.
        const changed = writeManagedFile(targetPath, rendered, dryRun);
        written.push({ filename: target.filename, mode: "direct-update", file: target.filename, changed });
      } else {
        // Genuine pre-existing user file — collision. Write Jenga's copy
        // as J-<NAME>.md and insert a reference into the user's file.
        if (!dryRun) writeFileSync(jPath, rendered, "utf8");
        insertOrUpdateReference(targetPath, jFilename, dryRun);
        written.push({ filename: target.filename, mode: "collision-created-j-file", file: jFilename, changed: true });
      }
      continue;
    }

    // Neither the target nor its J- copy exists — first-run, no collision.
    const changed = writeManagedFile(targetPath, rendered, dryRun);
    written.push({ filename: target.filename, mode: "direct-write", file: target.filename, changed });
  }

  return { written, changed: written.some((w) => w.changed), ...(dryRun ? { dryRun: true } : {}) };
}

// CLI guard — allows `node lib/generate-agent-context.js [projectRoot]`,
// used by skills/j-init/scripts/init.sh (this repo's own board-scaffolding
// flow, where node is guaranteed available). The published npm CLI path
// (lib/commands/init.js) imports generateAgentContext() directly instead.
//
// process.argv[1] is compared via realpath, not as a raw string: Node
// resolves import.meta.url through symlinks when loading an ES module, but
// leaves process.argv[1] exactly as the shell passed it. On macOS, TMPDIR
// and /tmp are themselves symlinks into /private, so any invocation from a
// path under either (a very ordinary occurrence — every consumer install
// under a symlinked, mapped, or `npm link`-ed directory hits this) made the
// two sides disagree and silently skipped generation with no error.
const invokedPath = process.argv[1] ? realpathSync(process.argv[1]) : null;
if (invokedPath === fileURLToPath(import.meta.url)) {
  const projectRoot = process.argv[2] || process.cwd();
  const result = generateAgentContext(projectRoot);
  if (result.skipped) {
    console.warn("Warning: agent-context.md.tpl not found — skipped CLAUDE.md/AGENTS.md generation.");
  } else {
    for (const { filename, mode } of result.written) {
      console.log(`✓ ${filename} (${mode})`);
    }
  }
}
