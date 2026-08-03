import { readFileSync, writeFileSync, existsSync } from "fs";
import { join, resolve } from "path";
import { homedir } from "os";

const HOOK_TYPE = "command";
const HOOK_SCRIPT = "hooks/prompt_router.sh";

/**
 * Injects the Jenga UserPromptSubmit hook into settings.json.
 * Idempotent — running twice does not duplicate the entry.
 *
 * @param {string} projectRoot - project root directory (default: cwd)
 * @param {boolean} global - if true, target ~/.claude/settings.json instead
 */
export async function injectSettings(projectRoot = process.cwd(), global = false) {
  const settingsPath = global
    ? join(homedir(), ".claude", "settings.json")
    : join(projectRoot, "settings.json");

  const hookCommand = resolve(projectRoot, HOOK_SCRIPT);

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

  writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n", "utf8");
  console.log("✓ Hook registered in settings.json");
}
