import { readdirSync, readFileSync, statSync, existsSync } from "fs";
import { join } from "path";

/**
 * Parses YAML frontmatter from a markdown file.
 * Returns an object with the parsed fields, or {} if no frontmatter found.
 */
function parseFrontmatter(content) {
  const match = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!match) return {};
  try {
    const lines = match[1].split("\n");
    const obj = {};
    let currentKey = null;
    let arrayMode = false;
    for (const line of lines) {
      const arrayItem = line.match(/^\s+-\s+(.*)/);
      if (arrayItem && arrayMode && currentKey) {
        obj[currentKey].push(arrayItem[1].trim().replace(/^["']|["']$/g, ""));
        continue;
      }
      arrayMode = false;
      const kv = line.match(/^(\w+):\s*(.*)/);
      if (!kv) continue;
      const [, key, val] = kv;
      if (val.trim() === "[]") {
        obj[key] = [];
        currentKey = key;
        arrayMode = false;
      } else if (val.trim() === "") {
        obj[key] = [];
        currentKey = key;
        arrayMode = true;
      } else {
        obj[key] = val.trim().replace(/^["']|["']$/g, "");
        currentKey = key;
      }
    }
    return obj;
  } catch {
    return {};
  }
}

/**
 * Recursively finds all SKILL.md files under a directory.
 */
function findSkillFiles(dir) {
  if (!existsSync(dir)) return [];
  const results = [];
  try {
    for (const entry of readdirSync(dir)) {
      const full = join(dir, entry);
      try {
        if (statSync(full).isDirectory()) {
          results.push(...findSkillFiles(full));
        } else if (entry === "SKILL.md") {
          results.push(full);
        }
      } catch {}
    }
  } catch {}
  return results;
}

/**
 * Builds the in-memory skill index from the skills directory.
 * Optionally accepts an embedder ({ embed(text) }) to pre-compute skill embeddings.
 * Returns an array of skill records.
 */
export async function buildSkillIndex(skillsPath, embedder = null) {
  const start = Date.now();
  const files = findSkillFiles(skillsPath);
  const skills = [];

  for (const filePath of files) {
    try {
      const content = readFileSync(filePath, "utf8");
      const fm = parseFrontmatter(content);
      if (!fm.name) {
        process.stderr.write(`Warning: ${filePath} has no 'name' in frontmatter — skipped\n`);
        continue;
      }
      const skill = {
        name: fm.name,
        description: fm.description || "",
        keywords: Array.isArray(fm.keywords) ? fm.keywords : [],
        examples: Array.isArray(fm.examples) ? fm.examples : [],
        path: filePath,
        embedding: null,
      };
      if (embedder) {
        skill.embedding = await embedder.embed(skill.description);
      }
      skills.push(skill);
    } catch (e) {
      process.stderr.write(`Warning: failed to parse ${filePath}: ${e.message}\n`);
    }
  }

  const elapsed = Date.now() - start;
  process.stderr.write(`[jenga-router] Indexed ${skills.length} skills in ${elapsed}ms\n`);
  return skills;
}
