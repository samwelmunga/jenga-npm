import { existsSync, readFileSync, writeFileSync, mkdirSync } from "fs";
import { join, dirname, resolve } from "path";
import { createRequire } from "module";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const packageRoot = join(__dirname, "..", "..");

export async function runAttach(args) {
  const cwd = process.cwd();
  const configPath = join(cwd, "jenga.cli.json");

  if (!existsSync(configPath)) {
    console.error("No jenga.cli.json found. Run `jenga init` first.");
    process.exit(1);
  }

  // Resolve absolute path to the jenga router script
  const routerPath = resolve(packageRoot, "mcp", "router", "index.js");

  // Read or initialise .claude/settings.json
  const settingsDir = join(cwd, ".claude");
  const settingsPath = join(settingsDir, "settings.json");
  let settings = {};
  if (existsSync(settingsPath)) {
    try {
      settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    } catch (e) {
      console.error(`Failed to parse .claude/settings.json: ${e.message}`);
      process.exit(1);
    }
  }

  // Merge jenga mcpServers entry (overwrite if already present)
  if (!settings.mcpServers) settings.mcpServers = {};
  settings.mcpServers["jenga"] = {
    type: "stdio",
    command: "node",
    args: [routerPath],
  };

  mkdirSync(settingsDir, { recursive: true });
  writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n", "utf8");

  // Mirror the same mcpServers entry into .agents/settings.json
  const agentsSettingsDir = join(cwd, ".agents");
  const agentsSettingsPath = join(agentsSettingsDir, "settings.json");
  let agentsSettings = {};
  if (existsSync(agentsSettingsPath)) {
    try {
      agentsSettings = JSON.parse(readFileSync(agentsSettingsPath, "utf8"));
    } catch (e) {
      console.error(`Failed to parse .agents/settings.json: ${e.message}`);
      process.exit(1);
    }
  }
  if (!agentsSettings.mcpServers) agentsSettings.mcpServers = {};
  agentsSettings.mcpServers["jenga"] = {
    type: "stdio",
    command: "node",
    args: [routerPath],
  };
  mkdirSync(agentsSettingsDir, { recursive: true });
  writeFileSync(agentsSettingsPath, JSON.stringify(agentsSettings, null, 2) + "\n", "utf8");

  console.log("Attached. Open a new session in this project to start routing through Jenga.");
  console.log("  ✓ .claude/settings.json updated");
  console.log("  ✓ .agents/settings.json updated");
}
