# Plan: E01_S03_T03 — Subprocess execution with stdout streaming

## Goal
Run `bash start.sh` from the job directory; stream stdout/stderr line-by-line to the MCP client.

## Design
Use Node.js `child_process.spawn`:
- `spawn('bash', ['start.sh'], { cwd: jobDir, env: process.env })`
- Pipe `stdout` and `stderr` through readable stream events
- Accumulate lines in an array
- On `close`, resolve with collected lines + exit code

Since MCP tool responses are returned all at once (not streaming), accumulate all output
and return it in the final response alongside the exit code.
