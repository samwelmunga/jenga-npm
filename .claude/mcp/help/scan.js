/**
 * mcp/help/scan.js — pure directory-scan logic behind the `help` MCP tool (E50_S12_T06).
 *
 * Split out of index.js so it is importable and unit-testable without starting an MCP
 * server. index.js instantiates an `McpServer` and ends with a top-level
 * `await server.connect(transport)` that blocks on stdin — importing that file as a
 * whole would hang any test that tried it, the exact untestability
 * mcp/router/allow-list-guard.js's header describes for mcp/router/index.js, and the
 * same reason mcp/router's Stage 1 decision was extracted into its own module by
 * E50_S07_T02. This file mirrors that precedent: plain Node built-ins only, no MCP SDK
 * import, no side effects at module load time.
 *
 * Confirmed by direct reading (E50_S12_T06): this is a pure `readdirSync`/`statSync`
 * scan. It never parses a SKILL.md's frontmatter, never strips a `j.`/`j:` prefix, and
 * never compares against the allow-list — it returns whatever directory names exist
 * under `.claude/skills`/`.agents/skills` verbatim. A `j-<name>` twin directory and a
 * bare `<name>` directory are both just directory names to this code; neither is
 * treated differently in any way, so nothing here needs to change for a twin-only tree.
 */

import { existsSync, readdirSync, statSync } from "fs";
import { join } from "path";

/**
 * Resolves which of the two generated skill mirrors exists under `root`. The
 * jenga-agent postinstall mirrors skills/ into both .claude/ (Claude Code) and
 * .agents/ (Copilot / custom agents); this prefers .claude/, falling back to .agents/.
 *
 * @param {string} root - project root to scan (already resolved to an absolute path)
 * @returns {string|null} the first candidate skills directory that exists, or null
 */
export function resolveSkillsDir(root) {
  const candidates = [
    join(root, ".claude", "skills"),
    join(root, ".agents", "skills"),
  ];
  return candidates.find(existsSync) ?? null;
}

/**
 * The two candidate mirror paths under `root`, in preference order — exposed
 * separately from resolveSkillsDir() so a caller can report "looked in: ..." even when
 * neither candidate exists (mirrors index.js's `help` tool's own "No skills found"
 * message).
 *
 * @param {string} root
 * @returns {string[]}
 */
export function candidateSkillsDirs(root) {
  return [
    join(root, ".claude", "skills"),
    join(root, ".agents", "skills"),
  ];
}

/**
 * Lists the immediate subdirectory names of `skillsDir` — the exact set the `help` tool
 * reports. See this module's header for why this is safe to call against a twin-only
 * tree with no code change: it is a verbatim directory listing, format-agnostic.
 *
 * @param {string} skillsDir - an existing directory (typically resolveSkillsDir()'s result)
 * @returns {string[]} immediate subdirectory names, in readdirSync's natural order
 */
export function listSkillFolders(skillsDir) {
  const entries = readdirSync(skillsDir);
  return entries.filter((entry) => {
    try {
      return statSync(join(skillsDir, entry)).isDirectory();
    } catch {
      return false;
    }
  });
}
