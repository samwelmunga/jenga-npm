#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { resolve } from "path";
import { resolveSkillsDir, candidateSkillsDirs, listSkillFolders } from "./scan.js";

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
    // E50_S12_T06: the actual scan logic lives in ./scan.js (resolveSkillsDir /
    // listSkillFolders) so it is importable and unit-testable without starting this
    // MCP server. See that module's header for why. No behavior change here.
    const skillsDir = resolveSkillsDir(root);

    if (!skillsDir) {
      const candidates = candidateSkillsDirs(root);
      return {
        content: [
          {
            type: "text",
            text: `No skills found. Looked in:\n${candidates.map(p => `  - ${p}`).join("\n")}`,
          },
        ],
      };
    }

    const folders = listSkillFolders(skillsDir);

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
