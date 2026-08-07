import { readFileSync, existsSync } from "fs";
import { join } from "path";

export const configSchema = {
  type: "object",
  required: ["skillsPath", "matchThreshold", "sessionTimeout", "agentTarget"],
  properties: {
    // Single path (string) or multiple discovery paths (array of strings).
    // Multi-target installs (e.g. claude + copilot) use an array holding
    // both .claude/skills/ and .agents/skills/.
    skillsPath: {
      oneOf: [
        { type: "string" },
        { type: "array", items: { type: "string" }, minItems: 1 }
      ]
    },
    matchThreshold: { type: "number", minimum: 0, maximum: 1 },
    sessionTimeout: { type: "number", minimum: 0 },
    agentTarget: {
      oneOf: [
        { type: "string", enum: ["claude", "copilot", "custom"] },
        { type: "array", items: { type: "string", enum: ["claude", "copilot", "custom"] }, minItems: 1 }
      ]
    }
  },
  additionalProperties: false
};

export function validateConfig(config) {
  for (const field of configSchema.required) {
    if (config[field] === undefined || config[field] === null) {
      return { valid: false, error: `Missing required field: ${field}` };
    }
  }
  const skillsPathIsString = typeof config.skillsPath === "string";
  const skillsPathIsArray  = Array.isArray(config.skillsPath)
    && config.skillsPath.length > 0
    && config.skillsPath.every(p => typeof p === "string");
  if (!skillsPathIsString && !skillsPathIsArray) {
    return { valid: false, error: "skillsPath must be a string or a non-empty array of strings" };
  }
  if (typeof config.matchThreshold !== "number" || config.matchThreshold < 0 || config.matchThreshold > 1) {
    return { valid: false, error: "matchThreshold must be a number between 0 and 1" };
  }
  if (typeof config.sessionTimeout !== "number" || config.sessionTimeout < 0) {
    return { valid: false, error: "sessionTimeout must be a non-negative number" };
  }
  const validTargets = ["claude", "copilot", "custom"];
  const targets = Array.isArray(config.agentTarget) ? config.agentTarget : [config.agentTarget];
  if (targets.length === 0 || !targets.every(t => validTargets.includes(t))) {
    return { valid: false, error: 'agentTarget must be one of: "claude", "copilot", "custom" (or an array of those values)' };
  }
  return { valid: true };
}

export function loadConfig(projectRoot = process.cwd()) {
  const configPath = join(projectRoot, "jenga.cli.json");
  if (!existsSync(configPath)) {
    throw new Error(`jenga.cli.json not found at ${configPath}. Run 'jenga init' to create it.`);
  }
  let config;
  try {
    config = JSON.parse(readFileSync(configPath, "utf8"));
  } catch (e) {
    throw new Error(`Failed to parse jenga.cli.json: ${e.message}`);
  }
  const result = validateConfig(config);
  if (!result.valid) {
    throw new Error(result.error);
  }
  return config;
}
