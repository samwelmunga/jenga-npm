import { existsSync, readFileSync, writeFileSync, renameSync } from "fs";
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

  // Register the router in the project-root .mcp.json (the file Claude Code reads
  // project-scope MCP servers from; see project/documentation/mcp-registration-decision.md). Merge by
  // server name: only the "jenga" entry is touched, everything else is preserved.
  const mcpPath = join(cwd, ".mcp.json");
  let mcpConfig = { mcpServers: {} };
  if (existsSync(mcpPath)) {
    try {
      mcpConfig = JSON.parse(readFileSync(mcpPath, "utf8"));
    } catch (e) {
      console.error(`Failed to parse .mcp.json: ${e.message}`);
      console.error("Fix or remove the file and re-run `jenga attach`; it was left untouched.");
      process.exit(1);
    }
    if (!isPlainObject(mcpConfig) || (mcpConfig.mcpServers !== undefined && !isPlainObject(mcpConfig.mcpServers))) {
      console.error('.mcp.json must be a JSON object whose "mcpServers" (if present) is an object.');
      console.error("The file was left untouched.");
      process.exit(1);
    }
    if (mcpConfig.mcpServers === undefined) mcpConfig.mcpServers = {};
  }

  const desired = { type: "stdio", command: "node", args: [routerPath] };
  const unchanged = JSON.stringify(mcpConfig.mcpServers["jenga"]) === JSON.stringify(desired);
  if (!unchanged) {
    mcpConfig.mcpServers["jenga"] = desired;
    const tmpPath = `${mcpPath}.${process.pid}.tmp`;
    writeFileSync(tmpPath, JSON.stringify(mcpConfig, null, 2) + "\n", "utf8");
    renameSync(tmpPath, mcpPath);
  }

  console.log("Attached. Open a new session in this project to start routing through Jenga.");
  console.log(`  ✓ .mcp.json ${unchanged ? "already up to date" : "updated"}`);
  console.log("  Claude Code shows new .mcp.json servers as \"Pending approval\": run `claude` in this project and approve the `jenga` server.");

  // Migration note: older versions wrote mcpServers.jenga into .claude/settings.json, which Claude
  // Code does not read for MCP servers. Leave that file alone; just tell the user it is inert.
  const legacyPath = join(cwd, ".claude", "settings.json");
  try {
    if (existsSync(legacyPath) && JSON.parse(readFileSync(legacyPath, "utf8"))?.mcpServers?.jenga !== undefined) {
      console.log("  Note: .claude/settings.json still has an older mcpServers.jenga entry from a previous `jenga attach`.");
      console.log("  Claude Code does not read it; it was left untouched and can be removed by hand.");
    }
  } catch {
    // .claude/settings.json is no longer touched by attach; an unreadable file is not our concern.
  }
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}
