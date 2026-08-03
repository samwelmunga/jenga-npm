#!/usr/bin/env node
/**
 * training_runner — MCP server
 *
 * Exposes a single tool: run_training_job
 *   - Validates the job directory and config.yaml
 *   - Checks confirm_before_run flag
 *   - Executes bash start.sh, collecting stdout/stderr
 *   - Returns a structured result including exit_code, duration, and results.json contents
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { existsSync, readFileSync } from "fs";
import { join, resolve } from "path";
import { spawn } from "child_process";
import { load as yamlLoad } from "js-yaml";

const server = new McpServer({
  name: "training_runner",
  version: "1.0.0",
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Load and parse config.yaml from the job directory.
 * Returns { config, error } — error is a string if loading failed.
 */
function loadConfig(jobDir) {
  const configPath = join(jobDir, "input", "config.yaml");
  if (!existsSync(configPath)) {
    return { config: null, error: `config.yaml not found at: ${configPath}` };
  }
  try {
    const raw = readFileSync(configPath, "utf8");
    const config = yamlLoad(raw) || {};
    return { config, error: null };
  } catch (err) {
    return { config: null, error: `Failed to parse config.yaml: ${err.message}` };
  }
}

/**
 * Validate required config fields.
 * Returns an array of missing field names (empty = all present).
 */
function validateRequiredFields(config) {
  const missing = [];
  const model = config.model || {};

  // Every job type requires at least one of model.type or model.name
  if (!model.type && !model.name) {
    missing.push("model.type (classifiers) or model.name (transformers/nlp)");
  }

  return missing;
}

/**
 * Run `bash start.sh` in jobDir; collect output lines and exit code.
 * Returns a Promise<{ lines: string[], exitCode: number }>.
 */
function runStartSh(jobDir) {
  return new Promise((resolve_) => {
    const lines = [];
    const proc = spawn("bash", ["start.sh"], {
      cwd: jobDir,
      env: process.env,
    });

    const collect = (data) => {
      const text = data.toString();
      text.split("\n").forEach((line) => {
        if (line !== "") lines.push(line);
      });
    };

    proc.stdout.on("data", collect);
    proc.stderr.on("data", collect);

    proc.on("close", (exitCode) => {
      resolve_({ lines, exitCode: exitCode ?? -1 });
    });

    proc.on("error", (err) => {
      lines.push(`[runner error] ${err.message}`);
      resolve_({ lines, exitCode: -1 });
    });
  });
}

/**
 * Read results.json from the job directory, if it exists.
 * Returns the parsed object or null.
 */
function readResultsJson(jobDir) {
  const resultsPath = join(jobDir, "results.json");
  if (!existsSync(resultsPath)) return null;
  try {
    const raw = readFileSync(resultsPath, "utf8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Tool: run_training_job
// ---------------------------------------------------------------------------
server.tool(
  "run_training_job",
  "Validate and run an ML training job by executing bash start.sh in the job directory.",
  {
    job_dir: z
      .string()
      .describe("Absolute or relative path to the job directory (must contain input/config.yaml and start.sh)."),
    confirm: z
      .boolean()
      .optional()
      .default(false)
      .describe(
        "Set to true to confirm execution when confirm_before_run is enabled in config.yaml."
      ),
  },
  async ({ job_dir, confirm }) => {
    const jobDir = resolve(job_dir);

    // --- T02: Directory validation ---
    if (!existsSync(jobDir)) {
      return {
        content: [
          {
            type: "text",
            text: `❌ Job directory not found: ${jobDir}`,
          },
        ],
      };
    }

    // --- T02: config.yaml validation ---
    const { config, error: configError } = loadConfig(jobDir);
    if (configError) {
      return {
        content: [{ type: "text", text: `❌ ${configError}` }],
      };
    }

    // --- T02: Required field validation ---
    const missingFields = validateRequiredFields(config);
    if (missingFields.length > 0) {
      return {
        content: [
          {
            type: "text",
            text: `❌ config.yaml is missing required fields:\n${missingFields.map((f) => `  - ${f}`).join("\n")}`,
          },
        ],
      };
    }

    // --- T02: start.sh must exist ---
    const startSh = join(jobDir, "start.sh");
    if (!existsSync(startSh)) {
      return {
        content: [{ type: "text", text: `❌ start.sh not found in ${jobDir}. Re-scaffold with /train new to generate it.` }],
      };
    }

    // --- T04: confirm_before_run gate ---
    const workflow = config.workflow || {};
    if (workflow.confirm_before_run === true && !confirm) {
      return {
        content: [
          {
            type: "text",
            text: [
              `⚠️  This job has confirm_before_run: true in its config.yaml.`,
              ``,
              `Job directory: ${jobDir}`,
              ``,
              `To proceed, re-invoke this tool with confirm: true.`,
            ].join("\n"),
          },
        ],
      };
    }

    // --- T03: Execute bash start.sh ---
    const startTime = Date.now();
    const { lines, exitCode } = await runStartSh(jobDir);
    const durationSeconds = ((Date.now() - startTime) / 1000).toFixed(2);

    // --- T04 / E01_S04_T02: Read results.json if present ---
    const results = readResultsJson(jobDir);

    // Build response
    const outputText = lines.join("\n");
    const status = exitCode === 0 ? "✅ Completed" : `❌ Failed (exit code ${exitCode})`;

    const summary = [
      `${status}`,
      `Job directory : ${jobDir}`,
      `Duration      : ${durationSeconds}s`,
      `Exit code     : ${exitCode}`,
      ``,
      `--- Output ---`,
      outputText || "(no output)",
    ];

    if (results !== null) {
      summary.push(``, `--- results.json ---`, JSON.stringify(results, null, 2));
    }

    // Structured result as JSON (appended as second content block)
    const structuredResult = {
      exit_code: exitCode,
      job_dir: jobDir,
      duration_seconds: parseFloat(durationSeconds),
      output: lines,
      results: results,
    };

    return {
      content: [
        { type: "text", text: summary.join("\n") },
        { type: "text", text: JSON.stringify(structuredResult, null, 2) },
      ],
    };
  }
);

// ---------------------------------------------------------------------------
// Start server
// ---------------------------------------------------------------------------
const transport = new StdioServerTransport();
await server.connect(transport);
