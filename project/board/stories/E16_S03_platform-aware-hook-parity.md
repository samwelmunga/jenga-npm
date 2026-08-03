---
id: E16_S03
epic: E16
title: Platform-Aware Hook Parity
status: Done
date_created: 2026-05-10
date_completed: 2026-05-10
tasks:
  - E16_S03_T01
  - E16_S03_T02
---

# Story: Platform-Aware Hook Parity

## Goal
Claude Code has a rich hook system (`WorktreeCreate`, `WorktreeRemove`, `SessionEnd`, `UserPromptSubmit`). GitHub Copilot CLI does not expose the same hooks natively, but equivalent behaviour can be achieved via Copilot's tool/skill invocation lifecycle. This story documents and implements the parity layer so that the same lifecycle events (worktree management, session end cleanup, prompt routing) work regardless of which agent is active.

## Tasks

### E16_S03_T01 — Document hook parity matrix
Create `docs/hook-parity.md` that maps each Claude Code hook event to its Copilot CLI equivalent (or "manual / not supported" with a workaround). Include: `UserPromptSubmit`, `WorktreeCreate`, `WorktreeRemove`, `SessionEnd`.

### E16_S03_T02 — Implement Copilot-side session-end equivalent
Add a skill post-execution step (or a Copilot-specific mechanism) that fires the same cleanup logic as `on_session_end.sh`. Ensure `JENGA_PROJECT_DIR` is available to the script regardless of platform.

## Acceptance Criteria
- `docs/hook-parity.md` exists and is accurate
- Session-end cleanup fires correctly under both Claude and Copilot
- No hook references a Claude-only env var without a fallback
