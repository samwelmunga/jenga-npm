#!/usr/bin/env node
/**
 * skills/jenga/scripts/load-nl-catalog.js
 *
 * Node (ESM) helper behind `load-nl-catalog.sh` — the SINGLE REQUIRED SOURCE of skill-catalog
 * data for `/jenga`'s natural-language branch (E53_S01_T03). `skills/jenga/SKILL.md` must never
 * re-implement its own skill directory scan or hand-maintain a skill list; it only ever reads
 * this script's stdout.
 *
 * The catalog's NAME LIST comes exclusively from `lib/generate-skill-allow-list.js`'s generated
 * inventory (`readSkillAllowList()`, which reads the committed `lib/skill-allow-list.json`
 * artifact) — this script does not independently re-scan `skills/` for a name list of its own,
 * per E53_S01_T02's acceptance criteria and the drift lesson E41_S04 already documented for that
 * generator. For each name in that inventory, this script reads exactly one file —
 * `skills/<name>/SKILL.md` — to populate the remaining catalog fields: `description`, `keywords`,
 * `examples`, and `metadata.prefered_agent`. These are the same fields `/route`'s Step 1
 * ("Discover Available Skills") collects.
 *
 * ---------------------------------------------------------------------------
 * USAGE
 * ---------------------------------------------------------------------------
 *   node load-nl-catalog.js <projectRoot> <pkgRoot>
 *
 *   <projectRoot>  the consuming project's root (passed through to
 *                  readSkillAllowList's projectRoot fallback candidate)
 *   <pkgRoot>      the jenga-agent PACKAGE root — where lib/generate-skill-allow-list.js and the
 *                  canonical skills/ tree actually live (monorepo checkout root, or
 *                  node_modules/@jenga-ai/agent for an installed consumer)
 *
 * ---------------------------------------------------------------------------
 * OUTPUT SCHEMA
 * ---------------------------------------------------------------------------
 * stdout is a single JSON array, one object per catalog entry, e.g.:
 *
 *   [
 *     {
 *       "name":           "btw",
 *       "description":    "...",
 *       "keywords":       ["..."],
 *       "examples":       ["..."],
 *       "prefered_agent": "scrum-master"   // or null when absent
 *     },
 *     ...
 *   ]
 *
 * Nothing but this JSON array is ever written to stdout. Warnings (a skill skipped because its
 * SKILL.md is missing/unreadable, or its frontmatter lacks `description`) go to stderr only, and
 * are non-fatal.
 *
 * ---------------------------------------------------------------------------
 * EXIT CODES
 * ---------------------------------------------------------------------------
 *   0   catalog written to stdout (possibly with skip warnings already emitted to stderr)
 *   2   usage error, or a real setup failure (allow-list inventory unreadable/empty, or
 *       lib/generate-skill-allow-list.js failed to load)
 *
 * ---------------------------------------------------------------------------
 */

import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { pathToFileURL } from "url";

/**
 * Parses YAML frontmatter from a SKILL.md's content into a plain object. This is a hand-rolled,
 * intentionally minimal parser scoped to the small set of shapes SKILL.md frontmatter actually
 * uses — it follows the same overall approach as mcp/router/skill-index.js's `parseFrontmatter`
 * (scalar keys, and array keys introduced by an empty `key:` line followed by `  - item` lines),
 * extended here to also recognize ONE level of nested mapping (the `metadata:` block, e.g.
 * `metadata:\n  prefered_agent: developer`) — a shape skill-index.js's parser doesn't need to
 * handle, since it never reads `metadata`.
 *
 * Returns {} if no frontmatter block is found.
 */
function parseFrontmatter(content) {
  const match = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!match) return {};

  const lines = match[1].split("\n");
  const obj = {};
  let i = 0;

  const stripQuotes = (s) => s.trim().replace(/^["']|["']$/g, "");

  while (i < lines.length) {
    const topMatch = lines[i].match(/^(\w+):\s*(.*)$/);
    if (!topMatch) {
      i++;
      continue;
    }
    const [, key, valRaw] = topMatch;
    const val = valRaw.trim();

    if (val === "[]") {
      obj[key] = [];
      i++;
      continue;
    }

    if (val !== "") {
      obj[key] = stripQuotes(val);
      i++;
      continue;
    }

    // Empty value — look ahead at indented child lines to decide whether this key is an array
    // (child lines shaped `  - item`) or a nested map (child lines shaped `  childKey: value`).
    // A block is only ever consistently one or the other in this repo's frontmatter, so the
    // first child line's shape decides it.
    let j = i + 1;
    const arrayItems = [];
    const mapObj = {};
    let sawArray = false;
    let sawMap = false;

    while (j < lines.length && /^\s+\S/.test(lines[j])) {
      const arrItem = lines[j].match(/^\s+-\s+(.*)$/);
      const mapItem = lines[j].match(/^\s+(\w+):\s*(.*)$/);
      if (arrItem && !sawMap) {
        sawArray = true;
        arrayItems.push(stripQuotes(arrItem[1]));
      } else if (mapItem && !sawArray) {
        sawMap = true;
        mapObj[mapItem[1]] = stripQuotes(mapItem[2]);
      }
      j++;
    }

    obj[key] = sawArray ? arrayItems : sawMap ? mapObj : [];
    i = j;
  }

  return obj;
}

async function main() {
  const [projectRoot, pkgRoot] = process.argv.slice(2);
  if (!projectRoot || !pkgRoot) {
    process.stderr.write("Usage: load-nl-catalog.js <projectRoot> <pkgRoot>\n");
    process.exit(2);
  }

  const generatorPath = join(pkgRoot, "lib", "generate-skill-allow-list.js");
  let readSkillAllowList;
  try {
    ({ readSkillAllowList } = await import(pathToFileURL(generatorPath).href));
  } catch (e) {
    process.stderr.write(`Error: failed to load ${generatorPath}: ${e.message}\n`);
    process.exit(2);
    return;
  }

  const names = readSkillAllowList(projectRoot, pkgRoot);
  if (!Array.isArray(names) || names.length === 0) {
    process.stderr.write(
      "Error: skill allow-list inventory is empty or unreadable (lib/skill-allow-list.json) — cannot build NL catalog\n"
    );
    process.exit(2);
    return;
  }

  const catalog = [];
  for (const name of names) {
    const skillMdPath = join(pkgRoot, "skills", name, "SKILL.md");
    if (!existsSync(skillMdPath)) {
      process.stderr.write(
        `Warning: ${skillMdPath} not found for allow-listed skill '${name}' — skipped\n`
      );
      continue;
    }

    let content;
    try {
      content = readFileSync(skillMdPath, "utf8");
    } catch (e) {
      process.stderr.write(`Warning: failed to read ${skillMdPath}: ${e.message} — skipped\n`);
      continue;
    }

    const fm = parseFrontmatter(content);
    if (!fm.description) {
      process.stderr.write(
        `Warning: ${skillMdPath} missing 'description' in frontmatter — skipped\n`
      );
      continue;
    }

    catalog.push({
      name,
      description: fm.description,
      keywords: Array.isArray(fm.keywords) ? fm.keywords : [],
      examples: Array.isArray(fm.examples) ? fm.examples : [],
      prefered_agent:
        fm.metadata && typeof fm.metadata === "object" && fm.metadata.prefered_agent
          ? fm.metadata.prefered_agent
          : null,
    });
  }

  process.stdout.write(JSON.stringify(catalog, null, 2) + "\n");
}

main().catch((e) => {
  process.stderr.write(`Error: ${e.message}\n`);
  process.exit(2);
});
