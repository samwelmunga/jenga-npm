# Summary: E16_S03_T01 & E16_S03_T02 — Platform-Aware Hook Parity

## Tasks Completed
- **E16_S03_T01** — Document hook parity matrix
- **E16_S03_T02** — Implement Copilot-side session-end equivalent

## What Was Built

### `docs/hook-parity.md`
A professional reference document mapping all four Claude Code hook events (`UserPromptSubmit`, `WorktreeCreate`, `WorktreeRemove`, `SessionEnd`) to their Copilot CLI equivalents or workarounds. Includes:
- Full parity table with trigger descriptions and workaround notes
- Dedicated section on `JENGA_PROJECT_DIR` and how it abstracts `CLAUDE_PROJECT_DIR` / `COPILOT_WORKSPACE_FOLDER`
- Explanation of `lib/resolve-project-dir.sh` and its idempotent sourcing pattern
- Manual invocation guide for Copilot users

### `hooks/copilot_session_end.sh`
A thin, executable wrapper that:
1. Sources `lib/resolve-project-dir.sh` (idempotent)
2. `exec`s `hooks/on_session_end.sh` for all shared cleanup logic

Made executable with `chmod +x`.

### `templates/copilot-instructions.md.tpl`
Added a **Session End** section explaining that Copilot users must call `hooks/copilot_session_end.sh` manually (since Copilot has no native `SessionEnd` hook), with a reference to `docs/hook-parity.md`.

## Outcome
Both Claude Code and GitHub Copilot CLI now have a documented and implemented parity layer for all major Jenga lifecycle events. No hook script references a Claude-only env var without a `JENGA_*` fallback provided by the resolver.
