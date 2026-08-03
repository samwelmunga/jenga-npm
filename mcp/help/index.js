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
  "List all available agent skills by scanning the .agents/skills directory in the given path.",
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
    const skillsDir = join(root, ".agents", "skills");

    if (!existsSync(skillsDir)) {
      return {
        content: [
          {
            type: "text",
            text: `No skills found. The path \`${skillsDir}\` does not exist.`,
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
