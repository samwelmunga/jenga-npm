import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { join, resolve, dirname } from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";

const HOOK_TYPE = "command";
// This file lives at <package>/lib/inject-settings.js — one level up is the
// installed jenga-agent package root, which is where hooks/prompt_router.sh
// ships. Consumers never need a local copy of the hook script.
const __dirname   = dirname(fileURLToPath(import.meta.url));
const PACKAGE_ROOT = join(__dirname, "..");

/**
 * Injects the Jenga UserPromptSubmit hook into settings.json.
 * Idempotent — running twice does not duplicate the entry.
 *
 * @param {string} projectRoot - project root directory (default: cwd)
 * @param {boolean} global - if true, target ~/.claude/settings.json instead
 */
export async function injectSettings(projectRoot = process.cwd(), global = false) {
  const settingsDir = global
    ? join(homedir(), ".claude")
    : join(projectRoot, ".claude");
  const settingsPath = join(settingsDir, "settings.json");

  const hookCommand = resolve(PACKAGE_ROOT, "hooks", "prompt_router.sh");

  // Load or create settings
  let settings = {};
  if (existsSync(settingsPath)) {
    try {
      settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    } catch (e) {
      throw new Error(`Failed to parse ${settingsPath}: ${e.message}`);
    }
  }

  // Ensure hooks.UserPromptSubmit exists
  if (!settings.hooks) settings.hooks = {};
  if (!settings.hooks.UserPromptSubmit) settings.hooks.UserPromptSubmit = [];

  const hooks = settings.hooks.UserPromptSubmit;

  // Check for existing Jenga entry (idempotency)
  const alreadyRegistered = hooks.some(
    (entry) =>
      Array.isArray(entry.hooks) &&
      entry.hooks.some((h) => h.type === HOOK_TYPE && h.command === hookCommand)
  );

  if (!alreadyRegistered) {
    hooks.push({
      matcher: "",
      hooks: [{ type: HOOK_TYPE, command: hookCommand }],
    });
  }

  mkdirSync(settingsDir, { recursive: true });
  writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n", "utf8");
  console.log(`✓ Hook registered in ${settingsPath}`);
}
