# Summary: E01_S03_T03 — Subprocess execution with stdout streaming

## What was done
`runStartSh(jobDir)` in `mcp/training_runner/index.js`:
- Spawns `bash start.sh` in the job directory via `child_process.spawn`
- Collects both `stdout` and `stderr` into a `lines[]` array line-by-line
- Resolves with `{ lines, exitCode }` when process closes
- Handles `error` events (e.g. missing bash) gracefully

The MCP tool response includes the full output as text and the exit code in the structured result.

## Note on "streaming"
MCP tool responses are single-shot (not streamed); output is accumulated and returned as one response.
Line-by-line collection ensures the output appears in execution order.

## Acceptance criteria
- [x] `bash start.sh` is executed from the job directory
- [x] stdout and stderr are collected line by line into the response
- [x] Exit code is included in the final response
