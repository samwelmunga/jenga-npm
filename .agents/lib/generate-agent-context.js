#!/usr/bin/env node
/**
 * lib/generate-agent-context.js — CLAUDE.md / AGENTS.md generation
 *
 * Single source of truth for scaffolding the two root-level agent-context
 * files from templates/agent-context.md.tpl (E41_S04_T02). Used by:
 *   - lib/commands/init.js         (published `jenga init` CLI)
 *   - skills/init/scripts/init.sh  (this repo's own board-scaffolding flow,
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
function buildSkillList(projectRoot) {
  const candidates = [".claude/skills", ".agents/skills"].map((p) => join(projectRoot, p));
  const skillsDir = candidates.find(existsSync);
  if (!skillsDir) return "_No skills found._";

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
 */
function writeManagedFile(path, rendered) {
  if (!existsSync(path)) {
    writeFileSync(path, rendered, "utf8");
    return;
  }
  const existing = readFileSync(path, "utf8");
  const renderedStart = rendered.indexOf(CONTENT_START);
  const renderedEnd = rendered.indexOf(CONTENT_END);
  const newBlock = rendered.slice(renderedStart, renderedEnd + CONTENT_END.length);
  const updated = replaceManagedBlock(existing, newBlock);
  if (updated !== existing) writeFileSync(path, updated, "utf8");
}

/**
 * Insert (or, on repeat runs, update in place) a short Jenga-marked
 * reference block near the very top of a pre-existing user file, pointing
 * at the J-<NAME>.md copy. Idempotent via its own REF marker pair, kept
 * distinct from CONTENT_START/CONTENT_END so the two replace passes never
 * interfere with each other in the same file.
 */
function insertOrUpdateReference(path, jFilename) {
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
  if (updated !== existing) writeFileSync(path, updated, "utf8");
}

/**
 * Generate CLAUDE.md and AGENTS.md at projectRoot from the shared template,
 * applying the J- collision rule and idempotent managed-block updates.
 *
 * @param {string} projectRoot - project root directory (default: cwd)
 * @param {string} packageRoot - installed jenga-agent package root (default:
 *   derived from this file's own location)
 * @returns {{written: Array<{filename: string, mode: string}>, skipped?: boolean}}
 */
export function generateAgentContext(projectRoot = process.cwd(), packageRoot = DEFAULT_PACKAGE_ROOT) {
  const tplPath = resolveTemplatePath(projectRoot, packageRoot);
  if (!tplPath) {
    return { written: [], skipped: true };
  }

  const tpl = readFileSync(tplPath, "utf8");
  const skillList = buildSkillList(projectRoot);
  const written = [];

  for (const target of TARGETS) {
    const rendered = tpl
      .split("{{TARGET_FILENAME}}").join(target.filename)
      .split("{{SKILL_DISCOVERY_PATH}}").join(target.skillDiscoveryPath)
      .split("{{SKILL_LIST}}").join(skillList);

    const targetPath = join(projectRoot, target.filename);
    const jFilename = `J-${target.filename}`;
    const jPath = join(projectRoot, jFilename);

    if (existsSync(jPath)) {
      // A J- file can only ever have been created by Jenga — this is a
      // repeat run after a prior collision. Update it in place; never
      // re-derive collision handling from it (no J-J-CLAUDE.md).
      writeManagedFile(jPath, rendered);
      if (existsSync(targetPath)) {
        insertOrUpdateReference(targetPath, jFilename);
      }
      written.push({ filename: target.filename, mode: "updated-j-file" });
      continue;
    }

    if (existsSync(targetPath)) {
      const existingContent = readFileSync(targetPath, "utf8");
      if (existingContent.includes(CONTENT_START)) {
        // Jenga's own file from a prior *non-collision* run — update in
        // place rather than treating it as a fresh collision.
        writeManagedFile(targetPath, rendered);
        written.push({ filename: target.filename, mode: "direct-update" });
      } else {
        // Genuine pre-existing user file — collision. Write Jenga's copy
        // as J-<NAME>.md and insert a reference into the user's file.
        writeFileSync(jPath, rendered, "utf8");
        insertOrUpdateReference(targetPath, jFilename);
        written.push({ filename: target.filename, mode: "collision-created-j-file" });
      }
      continue;
    }

    // Neither the target nor its J- copy exists — first-run, no collision.
    writeManagedFile(targetPath, rendered);
    written.push({ filename: target.filename, mode: "direct-write" });
  }

  return { written };
}

// CLI guard — allows `node lib/generate-agent-context.js [projectRoot]`,
// used by skills/init/scripts/init.sh (this repo's own board-scaffolding
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
