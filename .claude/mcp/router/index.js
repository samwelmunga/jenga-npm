#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { writeFileSync, unlinkSync, existsSync, readFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { buildSkillIndex } from "./skill-index.js";
import { findBestMatch } from "./matcher.js";
import { warmUp, embed } from "./embedder.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..", "..");
const jengaDir = join(process.cwd(), ".jenga");
const pidFile = join(jengaDir, "router.pid");
const sessionFile = join(jengaDir, "session.json");
const startTime = Date.now();

// Load config (optional — defaults used if absent)
let config = {
  skillsPath: "skills/",
  matchThreshold: 0.75,
  sessionTimeout: 300000,
  agentTarget: "claude",
};
const configPath = join(projectRoot, "jenga.cli.json");
if (existsSync(configPath)) {
  try {
    config = { ...config, ...JSON.parse(readFileSync(configPath, "utf8")) };
  } catch (e) {
    process.stderr.write(`Warning: failed to parse jenga.cli.json: ${e.message}\n`);
  }
}

// Build skill index (with semantic embeddings)
let skillIndex = [];
if (config.skillsPath) {
  await warmUp();
  skillIndex = await buildSkillIndex(join(projectRoot, config.skillsPath), { embed });
}

// Write PID file
mkdirSync(jengaDir, { recursive: true });
writeFileSync(pidFile, String(process.pid), "utf8");

// Graceful shutdown
function shutdown() {
  try { unlinkSync(pidFile); } catch {}
  persistSession({ skill: null, startedAt: null });
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

let activeSession = { skill: null, startedAt: null };
let sessionTimer = null;

function persistSession(state) {
  try {
    writeFileSync(sessionFile, JSON.stringify(state), "utf8");
  } catch (e) {
    process.stderr.write(`[jenga-router] Failed to write .session.json: ${e.message}\n`);
  }
}

const server = new McpServer({ name: "jenga-router", version: "1.0.0" });

server.tool("ping", "Health check — returns ok and uptime in seconds.", {}, async () => {
  try {
    return {
      content: [{ type: "text", text: JSON.stringify({ ok: true, uptime: Math.floor((Date.now() - startTime) / 1000), skill_count: skillIndex.length }) }],
    };
  } catch (e) {
    return { content: [{ type: "text", text: JSON.stringify({ error: e.message }) }], isError: true };
  }
});

server.tool(
  "route_prompt",
  "Route a prompt through the skill matching pipeline. Returns { action: 'invoke'|'passthrough', transformed: string, skill: string|null, confidence: number }.",
  { text: z.string().describe("The user prompt to route") },
  async ({ text }) => {
    try {
      // Stage 1: Passthrough rules
      if (text.startsWith("/")) {
        return {
          content: [{
            type: "text",
            text: JSON.stringify({ action: "passthrough", transformed: text, skill: null, confidence: 0 }),
          }],
        };
      }

      // Stage 0: Active session — passthrough all prompts while session is active
      if (activeSession.skill) {
        if (sessionTimer) clearTimeout(sessionTimer);
        sessionTimer = setTimeout(() => {
          activeSession = { skill: null, startedAt: null };
          sessionTimer = null;
          persistSession(activeSession);
          process.stderr.write(`[jenga-router] Session auto-expired after ${config.sessionTimeout}ms\n`);
        }, config.sessionTimeout);
        return {
          content: [{ type: "text", text: JSON.stringify({ action: "passthrough", transformed: text, skill: activeSession.skill, confidence: 0 }) }],
        };
      }

      // Stage 2: Semantic + keyword matching
      const promptEmbedding = await embed(text);
      const match = findBestMatch(text, skillIndex, config.matchThreshold, promptEmbedding);
      if (match) {
        activeSession = { skill: match.skill.name, startedAt: new Date().toISOString() };
        persistSession(activeSession);
        if (sessionTimer) clearTimeout(sessionTimer);
        sessionTimer = setTimeout(() => {
          activeSession = { skill: null, startedAt: null };
          persistSession(activeSession);
          sessionTimer = null;
          process.stderr.write(`[jenga-router] Session auto-expired after ${config.sessionTimeout}ms\n`);
        }, config.sessionTimeout);
        return {
          content: [{
            type: "text",
            text: JSON.stringify({
              action: "invoke",
              transformed: `/${match.skill.name} ${text}`,
              skill: match.skill.name,
              confidence: match.confidence,
            }),
          }],
        };
      }

      // Default: passthrough
      return {
        content: [{
          type: "text",
          text: JSON.stringify({ action: "passthrough", transformed: text, skill: null, confidence: 0 }),
        }],
      };
    } catch (e) {
      return { content: [{ type: "text", text: JSON.stringify({ error: e.message }) }], isError: true };
    }
  }
);

server.tool("active_session", "Returns the currently active skill session, if any.", {}, async () => {
  try {
    return {
      content: [{ type: "text", text: JSON.stringify({ skill: activeSession.skill, startedAt: activeSession.startedAt }) }],
    };
  } catch (e) {
    return { content: [{ type: "text", text: JSON.stringify({ error: e.message }) }], isError: true };
  }
});

server.tool(
  "end_session",
  "Clear the active session for the given skill. No-op if skill is not the active session.",
  { skill: z.string().describe("The skill name to end the session for") },
  async ({ skill }) => {
    try {
      if (activeSession.skill === skill) {
        activeSession = { skill: null, startedAt: null };
        persistSession(activeSession);
        if (sessionTimer) { clearTimeout(sessionTimer); sessionTimer = null; }
      }
      return { content: [{ type: "text", text: JSON.stringify({ ok: true }) }] };
    } catch (e) {
      return { content: [{ type: "text", text: JSON.stringify({ error: e.message }) }], isError: true };
    }
  }
);

server.tool(
  "list_skills",
  "Returns the current skill index — all loaded skills with their name, description, and keywords.",
  {},
  async () => {
    try {
      const skills = skillIndex.map(({ name, description, keywords }) => ({ name, description, keywords }));
      return {
        content: [{ type: "text", text: JSON.stringify({ skills }) }],
      };
    } catch (e) {
      return { content: [{ type: "text", text: JSON.stringify({ error: e.message }) }], isError: true };
    }
  }
);

server.tool("reload_skills", "Re-scan the skills directory and rebuild the in-memory skill index.", {}, async () => {
  try {
    await warmUp();
    skillIndex = await buildSkillIndex(join(projectRoot, config.skillsPath), { embed });
    return {
      content: [{ type: "text", text: JSON.stringify({ ok: true, skill_count: skillIndex.length }) }],
    };
  } catch (e) {
    return { content: [{ type: "text", text: JSON.stringify({ error: e.message }) }], isError: true };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
