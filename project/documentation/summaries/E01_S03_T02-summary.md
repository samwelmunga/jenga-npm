# Summary: E01_S03_T02 — Job directory and config validation

## What was done
In `mcp/training_runner/index.js`, `run_training_job` performs these checks before execution:

1. **Directory exists** — `existsSync(jobDir)` → returns `❌ Job directory not found: ...`
2. **config.yaml exists** — looks for `<jobDir>/input/config.yaml` → returns `❌ config.yaml not found at: ...`
3. **config.yaml parses** — catches YAML parse errors → returns `❌ Failed to parse config.yaml: ...`
4. **Required fields** — checks `model.type` or `model.name` is present → lists missing fields
5. **start.sh exists** — checks `<jobDir>/start.sh` → returns `❌ start.sh not found ...`

## Acceptance criteria
- [x] Missing directory returns a clear error
- [x] Missing config.yaml returns a clear error
- [x] Missing required config fields returns a clear error with field names
