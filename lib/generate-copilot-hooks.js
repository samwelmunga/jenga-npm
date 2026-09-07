#!/usr/bin/env node
/**
 * lib/generate-copilot-hooks.js — .github/hooks/jenga.json generation
 *
 * Single source of truth for scaffolding GitHub Copilot CLI's native hook config, wiring the two
 * Copilot lifecycle events that map directly onto this project's existing Claude Code hooks
 * (E16_S03_T04, following E16_S03_T03's empirical verification against a real installed
 * `copilot` CLI):
 *
 *   sessionEnd          -> hooks/copilot_session_end.sh  (mirrors Claude's SessionEnd hook)
 *   userPromptSubmitted -> hooks/prompt_router.sh         (mirrors Claude's UserPromptSubmit hook)
 *
 * `WorktreeCreate`/`WorktreeRemove` have no direct Copilot-native lifecycle equivalent (they are
 * git-worktree-specific, not generic session events) — T03's finding recommends keeping the
 * existing manual workaround rather than a fragile `preToolUse`/`postToolUse` text-match
 * approximation, so this generator does not wire those two events at all.
 *
 * Used by:
 *   - scripts/postinstall.js  (runs unconditionally, non-interactively, on every `npm install`)
 *   - lib/commands/init.js    (the interactive `jenga init` CLI wizard)
 *
 * Placement rationale (recorded in E16_S03_T03's finding): `.github/hooks/jenga.json` has no
 * pre-existing root-level source directory to mirror from — unlike `.github/agents/*.md`, which
 * mirrors real content already living at `agents/*.md`. The closer precedent is `settings.json`
 * itself (Claude's own hook config): committed directly at this monorepo's own root for its own
 * dev use, and separately generated per-consumer because a consumer's hook commands must resolve
 * absolute `node_modules/@jenga-ai/agent/hooks/*.sh` paths rather than this repo's relative ones.
 * This is why `.github/hooks/jenga.json` is entirely Jenga-owned (unlike
 * `.github/copilot-instructions.md`, which preserves user content around JENGA markers) — there
 * is no legitimate reason for a consumer to hand-edit it, so a full deterministic overwrite on
 * every run is safe and simpler than a marker-merge.
 *
 * No `skills/self-sync/scripts/run.js` wiring is needed either: self-sync mirrors root-level
 * source directories, and this file has none to mirror — it is generated directly, exactly like
 * `.github/copilot-instructions.md` is (also outside self-sync's `COPY_SET`/`GITHUB_COPY_SET`).
 *
 * ESM, Node built-ins only — mirrors lib/generate-copilot-instructions.js and lib/mirror.js.
 */

import { writeFileSync, existsSync, mkdirSync } from "fs";
import { join, resolve, dirname } from "path";
import { fileURLToPath } from "url";

// This file lives at <package>/lib/generate-copilot-hooks.js — one level up is the installed
// jenga-agent package root, which holds hooks/copilot_session_end.sh and hooks/prompt_router.sh.
const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_PACKAGE_ROOT = join(__dirname, "..");

/**
 * Build the `.github/hooks/jenga.json` config object.
 *
 * Two path-resolution modes, chosen by the caller (`generateCopilotHooks`) based on whether
 * `projectRoot` and `packageRoot` are the same directory:
 *
 * - `dynamicRoot: true` (this monorepo generating its own config: `projectRoot === packageRoot`)
 *   — commands resolve `hooks/*.sh` at RUN time via `$(git rev-parse --show-toplevel)`, exactly
 *   like `settings.json`'s own hook commands already do. A baked-in absolute path would be wrong
 *   here — it would hardcode wherever the generator happened to run from (e.g. a throwaway
 *   worktree checkout) instead of resolving to whichever checkout of this repo is actually
 *   running the hook.
 * - `dynamicRoot: false` (a real npm consumer: `projectRoot` is the consumer's project,
 *   `packageRoot` is the installed `node_modules/@jenga-ai/agent`) — commands bake in the
 *   absolute `packageRoot`-relative path, mirroring `lib/inject-settings.js`'s
 *   `resolve(PACKAGE_ROOT, "hooks", "prompt_router.sh")` for Claude's own `UserPromptSubmit`
 *   hook. This is safe because a consumer's installed package path is stable once `npm install`
 *   completes — unlike this monorepo's own dev checkouts/worktrees, which move around.
 *
 * @param {string} packageRoot - where hooks/*.sh actually live
 * @param {boolean} dynamicRoot - see above
 */
function buildHooksConfig(packageRoot, dynamicRoot) {
  const sessionEndCmd = dynamicRoot
    ? 'bash "$(git rev-parse --show-toplevel)/hooks/copilot_session_end.sh"'
    : `bash "${resolve(packageRoot, "hooks", "copilot_session_end.sh")}"`;
  const promptRouterCmd = dynamicRoot
    ? 'bash "$(git rev-parse --show-toplevel)/hooks/prompt_router.sh"'
    : `bash "${resolve(packageRoot, "hooks", "prompt_router.sh")}"`;

  return {
    version: 1,
    hooks: {
      sessionEnd: [
        { type: "command", bash: sessionEndCmd },
      ],
      userPromptSubmitted: [
        { type: "command", bash: promptRouterCmd },
      ],
    },
  };
}

/**
 * Generate (or idempotently overwrite) `.github/hooks/jenga.json` at projectRoot.
 *
 * Idempotent by construction: the output is fully deterministic from `packageRoot` alone, so
 * re-running (e.g. a later `jenga init`, or a repeat postinstall on the same version) always
 * produces byte-identical content. Unlike `.github/copilot-instructions.md`, no marker-merge is
 * needed — this file is entirely Jenga-owned.
 *
 * @param {string} projectRoot - project root directory to write into (default: cwd)
 * @param {string} packageRoot - where hooks/*.sh live (default: derived from this file's own
 *   location, i.e. this monorepo's own root when run in-repo)
 * @returns {{written: boolean, path: string}}
 */
export function generateCopilotHooks(projectRoot = process.cwd(), packageRoot = DEFAULT_PACKAGE_ROOT) {
  const hooksDir = join(projectRoot, ".github", "hooks");
  const targetPath = join(hooksDir, "jenga.json");

  const dynamicRoot = resolve(projectRoot) === resolve(packageRoot);
  const config = buildHooksConfig(packageRoot, dynamicRoot);

  if (!existsSync(hooksDir)) mkdirSync(hooksDir, { recursive: true });
  writeFileSync(targetPath, JSON.stringify(config, null, 2) + "\n", "utf8");

  return { written: true, path: targetPath };
}
