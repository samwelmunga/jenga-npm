#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { existsSync, readdirSync, statSync } from "fs";
import { join, resolve } from "path";

const server = new McpServer({
  name: "help",
  version: "1.0.0",
});

server.tool(
  "help",
  "List all available agent skills by scanning the .claude/skills or .agents/skills directory in the given path.",
  {
    path: z
      .string()
      .optional()
      .describe(
        "Absolute or relative path to the project root to scan. Defaults to the current working directory."
      ),
  },
  async ({ path: inputPath }) => {
    const root = inputPath ? resolve(inputPath) : process.cwd();
    // The jenga-agent postinstall mirrors skills/ into both .claude/ (Claude Code)
    // and .agents/ (Copilot / custom agents). Prefer .claude/; fall back to .agents/.
    const candidates = [
      join(root, ".claude", "skills"),
      join(root, ".agents", "skills"),
    ];
    const skillsDir = candidates.find(existsSync);

    if (!skillsDir) {
      return {
        content: [
          {
            type: "text",
            text: `No skills found. Looked in:\n${candidates.map(p => `  - ${p}`).join("\n")}`,
          },
        ],
      };
    }

    const entries = readdirSync(skillsDir);
    const folders = entries.filter((entry) => {
      try {
        return statSync(join(skillsDir, entry)).isDirectory();
      } catch {
        return false;
      }
    });

    if (folders.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: `The skills directory exists at \`${skillsDir}\` but contains no skill folders.`,
          },
        ],
      };
    }

    const list = folders.map((name) => `- ${name}`).join("\n");

    return {
      content: [
        {
          type: "text",
          text: `Available skills in \`${skillsDir}\`:\n\n${list}`,
        },
      ],
    };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
