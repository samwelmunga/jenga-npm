#!/usr/bin/env node
// hooks/prompt_router_helper.js
// Companion helper for prompt_router.sh. RETIRED STUB (E89_S06_T07): it does nothing and writes
// NOTHING to stdout.
//
// Why: under Claude Code a UserPromptSubmit hook's stdout is injected into model context, so the
// previous behaviour (echo the whole JSON prompt payload back as a "passthrough") put that payload
// into the conversation on every prompt of every scaffolded project. The Router MCP this was a
// client for is slated for retirement and the "call the router" step was never wired up, so there
// is nothing to route: the only observable behaviour was the leak.
//
// Why a silent stub rather than deleting the file: projects scaffolded before this fix already
// have an absolute path to hooks/prompt_router.sh registered in their .claude/settings.json (and
// Copilot projects in .github/hooks/jenga.json). Keeping the script as a silent no-op means those
// registrations stop leaking after a package upgrade, with no per-project remediation. New
// `jenga init` runs no longer register it (lib/commands/init.js).
//
// Contract, guarded by tests/prompt-router-silent.bats: stdout is always empty and exit is always
// 0, whatever arrives on stdin. Do not add a stdout write here; the sibling hook
// on_recording_step.sh guards its stdout the same way (exec 1>/dev/null).

// Drain stdin so the sender never gets a broken pipe, then exit quietly.
process.stdin.on("error", () => process.exit(0));
process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
