import { createInterface } from "readline";
import { readFileSync, writeFileSync, existsSync, appendFileSync, mkdirSync, readdirSync } from "fs";
import { join } from "path";
import { validateConfig } from "../config-schema.js";
import { injectSettings } from "../inject-settings.js";

const CONFIG_FILE = "jenga.cli.json";

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

    // 2. Skills path
    const skillsDefault = existing.skillsPath ?? "skills/";
    const skillsPath = await prompt(rl, "Skills directory path", skillsDefault);

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

    // Generate .github/copilot-instructions.md from template
    try {
      const tplPath = join(projectRoot, "templates", "copilot-instructions.md.tpl");
      if (existsSync(tplPath)) {
        const tpl = readFileSync(tplPath, "utf8");

        // Build skill list from skillsPath
        const skillsDir = join(projectRoot, config.skillsPath);
        let skillLines = [];
        if (existsSync(skillsDir)) {
          for (const entry of readdirSync(skillsDir, { withFileTypes: true })) {
            if (!entry.isDirectory()) continue;
            const skillMdPath = join(skillsDir, entry.name, "SKILL.md");
            let description = "";
            if (existsSync(skillMdPath)) {
              const content = readFileSync(skillMdPath, "utf8");
              const match = content.match(/^description:\s*(.+)$/m);
              if (match) description = match[1].trim();
            }
            skillLines.push(`- **${entry.name}**${description ? `: ${description}` : ""}`);
          }
        }
        const skillList = skillLines.length > 0 ? skillLines.join("\n") : "_No skills found._";
        const rendered = tpl.replace("{{SKILL_LIST}}", skillList);

        const githubDir = join(projectRoot, ".github");
        const copilotInstructionsPath = join(githubDir, "copilot-instructions.md");

        if (!existsSync(githubDir)) mkdirSync(githubDir, { recursive: true });

        if (!existsSync(copilotInstructionsPath)) {
          writeFileSync(copilotInstructionsPath, rendered, "utf8");
        } else {
          // Replace only the JENGA block; preserve content outside the markers
          const existing = readFileSync(copilotInstructionsPath, "utf8");
          const startMarker = "<!-- JENGA:START -->";
          const endMarker = "<!-- JENGA:END -->";
          const startIdx = existing.indexOf(startMarker);
          const endIdx = existing.indexOf(endMarker);

          // Extract the new JENGA block from rendered template
          const renderedStart = rendered.indexOf(startMarker);
          const renderedEnd = rendered.indexOf(endMarker);
          const newBlock = rendered.slice(renderedStart, renderedEnd + endMarker.length);

          let updated;
          if (startIdx !== -1 && endIdx !== -1 && startIdx < endIdx) {
            updated =
              existing.slice(0, startIdx) +
              newBlock +
              existing.slice(endIdx + endMarker.length);
          } else {
            // No existing markers — append the block
            updated = existing + (existing.endsWith("\n") ? "" : "\n") + newBlock + "\n";
          }
          writeFileSync(copilotInstructionsPath, updated, "utf8");
        }
        console.log("✓ .github/copilot-instructions.md written");
      }
    } catch (e) {
      console.warn(`Warning: Could not write .github/copilot-instructions.md — ${e.message}`);
    }

    console.log('\nRun `jenga start` to start the router.');

    return config;
  } finally {
    rl.close();
  }
}
