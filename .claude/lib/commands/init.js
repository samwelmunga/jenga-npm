import { createInterface } from "readline";
import { readFileSync, writeFileSync, existsSync, appendFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { validateConfig } from "../config-schema.js";
import { injectSettings } from "../inject-settings.js";
import { generateAgentContext } from "../generate-agent-context.js";
import { generateCopilotInstructions } from "../generate-copilot-instructions.js";

const CONFIG_FILE = "jenga.cli.json";

// This file lives at <package>/lib/commands/init.js — two levels up is the
// installed jenga-agent package root, which holds templates/ and other
// framework assets sourced directly from node_modules.
const __dirname    = dirname(fileURLToPath(import.meta.url));
const PACKAGE_ROOT = join(__dirname, "..", "..");

async function prompt(rl, question, defaultValue) {
  return new Promise(resolve => {
    const hint = defaultValue !== undefined ? ` (default: ${defaultValue})` : "";
    rl.question(`${question}${hint}: `, answer => {
      resolve(answer.trim() || String(defaultValue ?? ""));
    });
  });
}

export async function runInit(args, projectRoot = process.cwd()) {
  const configPath = join(projectRoot, CONFIG_FILE);
  
  // Load existing config as defaults if re-running
  let existing = {};
  if (existsSync(configPath)) {
    try {
      existing = JSON.parse(readFileSync(configPath, "utf8"));
      console.log(`Found existing ${CONFIG_FILE} — showing current values as defaults.\n`);
    } catch {
      console.warn(`Warning: Could not parse existing ${CONFIG_FILE}. Starting fresh.\n`);
    }
  } else {
    console.log("Welcome to Jenga! Let's set up your configuration.\n");
  }

  const rl = createInterface({ input: process.stdin, output: process.stdout });

  try {
    // 1. Agent target (supports comma-separated for multiple targets)
    const validTargets = ["claude", "copilot", "custom"];
    const existingTargets = existing.agentTarget
      ? (Array.isArray(existing.agentTarget) ? existing.agentTarget.join(", ") : existing.agentTarget)
      : "claude";
    console.log("Agent target options: claude, copilot, custom (comma-separate for multiple, e.g. claude, copilot)");
    let agentTargetRaw;
    let parsedTargets;
    do {
      agentTargetRaw = await prompt(rl, "Agent target", existingTargets);
      parsedTargets = agentTargetRaw.split(",").map(s => s.trim()).filter(Boolean);
      if (!parsedTargets.every(t => validTargets.includes(t))) {
        console.log('  Please enter valid targets: claude, copilot, custom');
        parsedTargets = null;
      }
    } while (!parsedTargets);
    const agentTarget = parsedTargets.length === 1 ? parsedTargets[0] : parsedTargets;

    // 2. Skills path — postinstall mirrors skills/ into .claude/skills/ (Claude)
    // and .agents/skills/ (Copilot / custom). Default reflects the chosen target(s):
    // a single string for one target, an array for multi-target installs.
    const skillPathForTarget = (t) => t === "claude" ? ".claude/skills/" : ".agents/skills/";
    const derivedDefault = (() => {
      const unique = [...new Set(parsedTargets.map(skillPathForTarget))];
      return unique.length === 1 ? unique[0] : unique;
    })();
    const existingSkillsPath = existing.skillsPath ?? derivedDefault;
    const skillsDefaultHint = Array.isArray(existingSkillsPath)
      ? existingSkillsPath.join(", ")
      : existingSkillsPath;
    const skillsRaw = await prompt(rl, "Skills directory path(s) (comma-separate for multiple)", skillsDefaultHint);
    const skillsParsed = skillsRaw.split(",").map(s => s.trim()).filter(Boolean);
    const skillsPath = skillsParsed.length === 1 ? skillsParsed[0] : skillsParsed;

    // 3. Match threshold
    const thresholdDefault = existing.matchThreshold ?? 0.75;
    let matchThreshold;
    do {
      const raw = await prompt(rl, "Match confidence threshold (0–1)", thresholdDefault);
      matchThreshold = parseFloat(raw);
    } while (isNaN(matchThreshold) || matchThreshold < 0 || matchThreshold > 1);

    // 4. Session timeout (minutes in wizard → ms in config)
    const timeoutMinutesDefault = existing.sessionTimeout ? existing.sessionTimeout / 60000 : 5;
    let sessionTimeoutMinutes;
    do {
      const raw = await prompt(rl, "Session timeout (minutes)", timeoutMinutesDefault);
      sessionTimeoutMinutes = parseFloat(raw);
    } while (isNaN(sessionTimeoutMinutes) || sessionTimeoutMinutes <= 0);

    const config = {
      agentTarget,
      skillsPath,
      matchThreshold,
      sessionTimeout: Math.round(sessionTimeoutMinutes * 60000),
    };

    writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n", "utf8");

    // Assert the written config passes schema validation
    const validation = validateConfig(config);
    if (!validation.valid) {
      throw new Error(`Config validation failed: ${validation.error}`);
    }

    console.log(`\n✓ Configuration written to ${CONFIG_FILE}`);

    // Ensure .jenga/ is in .gitignore (idempotent)
    const gitignorePath = join(projectRoot, ".gitignore");
    const gitignoreEntry = ".jenga/";
    let gitignoreContent = existsSync(gitignorePath) ? readFileSync(gitignorePath, "utf8") : "";
    if (!gitignoreContent.split("\n").some(line => line.trim() === gitignoreEntry)) {
      const prefix = gitignoreContent.length > 0 && !gitignoreContent.endsWith("\n") ? "\n" : "";
      appendFileSync(gitignorePath, `${prefix}${gitignoreEntry}\n`, "utf8");
    }

    try {
      await injectSettings(projectRoot);
    } catch (e) {
      console.warn(`Warning: Could not register hook in settings.json — ${e.message}`);
      console.warn("You can register it manually later by running jenga init again.");
    }

    // Generate .github/copilot-instructions.md from template, via the shared generator
    // (lib/generate-copilot-instructions.js) also used unconditionally by scripts/postinstall.js
    // at install time (E46_S03_T01). Templates ship inside the jenga-agent package
    // (node_modules/jenga-agent/templates/), with a bare `templates/` at the project root as a
    // fallback for the dev-repo case — both handled inside the shared generator.
    //
    // skillsPath may be a string or an array (multi-target installs); pick the first existing
    // directory — mirrored copies hold identical content. This pass uses the user's actual
    // chosen skillsPath from the wizard, which may differ from postinstall's `.agents/skills`
    // default and refines whatever postinstall already bootstrapped. The shared generator's
    // idempotent marker-replace logic means running it again here never duplicates the JENGA
    // block or corrupts content outside the markers.
    try {
      const skillsPathList = Array.isArray(config.skillsPath) ? config.skillsPath : [config.skillsPath];
      const skillsDir = skillsPathList
        .map(p => join(projectRoot, p))
        .find(existsSync);

      const result = generateCopilotInstructions(projectRoot, PACKAGE_ROOT, skillsDir);
      if (result.skipped) {
        console.warn("Warning: templates/copilot-instructions.md.tpl not found — skipped .github/copilot-instructions.md generation.");
      } else {
        console.log("✓ .github/copilot-instructions.md written");
      }
    } catch (e) {
      console.warn(`Warning: Could not write .github/copilot-instructions.md — ${e.message}`);
    }

    // Generate CLAUDE.md / AGENTS.md from templates/agent-context.md.tpl.
    // Unconditional — never gated on agentTarget (E41_S04): every agent
    // benefits from these files being cheap to write, and users switch
    // tools mid-project. Applies the J- collision rule and idempotent
    // managed-block updates; see lib/generate-agent-context.js.
    try {
      const result = generateAgentContext(projectRoot, PACKAGE_ROOT);
      if (result.skipped) {
        console.warn("Warning: templates/agent-context.md.tpl not found — skipped CLAUDE.md/AGENTS.md generation.");
      } else {
        for (const { filename, mode } of result.written) {
          console.log(`✓ ${filename} written (${mode})`);
        }
      }
    } catch (e) {
      console.warn(`Warning: Could not write CLAUDE.md/AGENTS.md — ${e.message}`);
    }

    console.log('\nRun `jenga start` to start the router.');

    return config;
  } finally {
    rl.close();
  }
}
