# Plan: E01_S03_T01 — Scaffold training_runner MCP server

## Goal
Create `mcp/training_runner/` with a basic MCP server that exposes a `run_training_job` tool.

## Files
- `mcp/training_runner/package.json`
- `mcp/training_runner/index.js`

## Design
Follow the pattern of `mcp/help/index.js`:
- Use `@modelcontextprotocol/sdk` + `zod`
- ES modules (`"type": "module"`)
- StdioServerTransport
- Tool: `run_training_job` with parameter `job_dir` (string, required)

## Verification
- Directory and files exist
- `run_training_job` tool is declared
