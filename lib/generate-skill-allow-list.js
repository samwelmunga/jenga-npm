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
 * ## The three-way mapping (E50_S12_T01)
 *
 * This generator's correctness rests on a relationship that used to be left implicit in
 * `extractName`'s regex. Stated explicitly, per `docs/skill-authoring.md`'s "The Canonical Naming
 * Contract" table (settled 2026-09-09, transcribed from E50_S10):
 *
 *   skills/j-<name>/  (directory)  <->  name: j.<name>  (frontmatter)  <->  <name>  (allow-listed
 *   identifier, after extractName's /^j[.:]/i strip)
 *
 * Three permanent exceptions skip the `j-` prefix on all three legs of that mapping and keep their
 * bare form everywhere: `jenga`, `jenga-permission-level` (both deliberately excluded from twin
 * generation, E50_S06), and `index` (not a skill — no SKILL.md, not part of routing). Every other
 * skill under `skills/` is expected to satisfy the mapping above once E50_S15 lands (see that
 * story's frontmatter-rewrite scope) — see the note below on the transitional state this generator
 * currently has to tolerate.
 *
 * Consumers:
 *   - CLI guard at the bottom of this file (`node lib/generate-skill-allow-list.js`) — run once
 *     against this repo's own skills/ to produce the committed lib/skill-allow-list.json, and
 *     intended to be callable from skills/j-self-sync/scripts/run.js and scripts/postinstall.js in
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
 *
 * This is the function that produces one leg of the three-way mapping described in this file's
 * header (`directory <-> frontmatter name: <-> allow-listed identifier`): given a SKILL.md's raw
 * frontmatter `name:` value, it returns the bare identifier that goes into the allow-list. For a
 * normal skill (post-E50_S15) that value is `j.<name>` and this strips to `<name>`, matching the
 * `skills/j-<name>/` directory it was read from with the `j-` prefix removed. For the three
 * permanent exceptions (`jenga`, `jenga-permission-level`, `index`) the frontmatter carries no
 * prefix at all and this is a no-op, matching their bare directory name directly.
 *
 * Transitional note (pre-E50_S15): as of E50_S12, most `skills/j-<name>/SKILL.md` twins still
 * carry the doubled `name: j.j-<name>` form (E50_S15's frontmatter rewrite to `j.<name>` has not
 * landed yet — that rewrite and the bare-directory deletion are scoped together and must land in
 * the same change, per E50_S15's story file). Stripping a single leading `j[.:]` off a doubled
 * value yields `j-<name>`, not `<name>` — a real, known, and separately-owned gap in the
 * three-way mapping above, not a bug in this function's own contract. See
 * `project/documentation/plans/E50_S12-plan.md` for why this task's regression coverage targets a
 * synthetic twin-only tree (where the mapping already holds) rather than asserting a bijection
 * against this repo's own transitional `skills/` tree.
 */
function extractName(content) {
  const fmMatch = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!fmMatch) return null;
  const nameMatch = fmMatch[1].match(/^name:\s*(.+)$/m);
  if (!nameMatch) return null;
  const rawName = nameMatch[1].trim().replace(/^["']|["']$/g, "");
  // Frontmatter may carry the pre-E50_S01 bare form, the E50_S01 "j:<name>" form, or the
  // current "j.<name>" form (E50_S07_T01 swapped the separator because GitHub Copilot CLI
  // rejects ":" in a skill name) — strip whichever prefix is present so the allow-list always
  // holds bare identifiers, matching mcp/router/skill-index.js's `bareName` handling.
  //
  // Both separators must stay accepted: this guard is the E50_S02 anti-masquerading check, and
  // a normalizer that fails to strip silently populates the allow-list with prefixed entries
  // ("j.brainstorm" instead of "brainstorm"), which no longer match what the guard compares
  // against. That is a security-guard failure, not a cosmetic one.
  return rawName.replace(/^j[.:]/i, "");
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
 * regenerated by postinstall.js and skills/j-self-sync/scripts/run.js) and return its `skills`
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
 * `skills/` change produce a byte-identical array.
 *
 * `generated_at` stamps when the allow-list CONTENT was last generated, not when this function
 * last ran: if `skill_count` and `skills` both match what is already on disk at `outputPath`, the
 * existing timestamp is preserved and no write happens at all (`written: false`). Repeat runs over
 * an unchanged `skills/` therefore leave the artifact byte-identical.
 *
 * This is narrower than the original contract, which stamped a fresh timestamp unconditionally and
 * documented that as intentional. It was changed by E42_S07_T01's follow-up because an artifact
 * that changes on every run can never be mirrored to a fixed point: `j.self-sync` copies
 * lib/skill-allow-list.json into .claude/ and .agents/ and then regenerates it, so both mirrors sat
 * one timestamp behind forever and every run reported `~2 overwritten` — contradicting the skill's
 * own documented "+0 ~0 -0 on a second consecutive run" idempotency guarantee. Nothing asserted the
 * every-run churn (tests/helpers/allow-list-scan.mjs compares the `skills` array and explicitly
 * ignores `generated_at`), so no contract anyone depended on is broken.
 *
 * @param {string} skillsDir - directory to scan (default: this repo/package's own skills/)
 * @param {string} outputPath - where to write the JSON artifact (default: lib/skill-allow-list.json)
 * @returns {{written: boolean, path: string, skill_count: number}}
 */
export function generateSkillAllowList(skillsDir = DEFAULT_SKILLS_DIR, outputPath = DEFAULT_OUTPUT_PATH) {
  const skills = getSkillAllowListIdentifiers(skillsDir);

  // Reuse the existing timestamp when the derived content is unchanged, so an unchanged
  // skills/ tree leaves the artifact byte-identical. A malformed or unreadable existing
  // artifact is treated as "no previous content" and simply regenerated.
  let generatedAt = null;
  if (existsSync(outputPath)) {
    try {
      const previous = JSON.parse(readFileSync(outputPath, "utf8"));
      const unchanged =
        previous.skill_count === skills.length &&
        Array.isArray(previous.skills) &&
        previous.skills.length === skills.length &&
        previous.skills.every((s, i) => s === skills[i]);
      if (unchanged && typeof previous.generated_at === "string") {
        generatedAt = previous.generated_at;
      }
    } catch {
      generatedAt = null;
    }
  }

  const artifact = {
    generated_at: generatedAt ?? new Date().toISOString(),
    skill_count: skills.length,
    skills,
  };

  const outDir = dirname(outputPath);
  if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });

  const next = JSON.stringify(artifact, null, 2) + "\n";
  if (generatedAt !== null && existsSync(outputPath) && readFileSync(outputPath, "utf8") === next) {
    return { written: false, path: outputPath, skill_count: skills.length };
  }

  writeFileSync(outputPath, next, "utf8");

  return { written: true, path: outputPath, skill_count: skills.length };
}

// CLI guard — allows `node lib/generate-skill-allow-list.js [skillsDir] [outputPath]`, intended
// to be callable from skills/j-self-sync/scripts/run.js and scripts/postinstall.js in the
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
