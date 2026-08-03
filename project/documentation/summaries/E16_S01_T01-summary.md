# E16_S01_T01 — Audit Summary: Claude-Specific & Copilot-Specific Env Vars

**Task:** E16_S01_T01  
**Date Completed:** 2026-05-10  
**Epic:** E16 — Multi-Platform Agent Config Parity  
**Story:** E16_S01 — Abstract Claude-Specific Env Vars  

---

## Findings: `CLAUDE_PROJECT_DIR`

These are the **actionable source files** that must be updated in T03:

| File | Line | Snippet |
|------|------|---------|
| `settings.json` | 32 | `DIR="$CLAUDE_PROJECT_DIR/.claude/worktrees/$NAME"` (WorktreeCreate hook command) |
| `settings.json` | 53 | `"$CLAUDE_PROJECT_DIR"/.claude/hooks/on_session_end.sh` (SessionEnd hook command) |
| `hooks/on_session_end.sh` | 24 | `PROJECT_DIR="$CLAUDE_PROJECT_DIR"` |
| `.agents/hooks/on_session_end.sh` | 24 | `PROJECT_DIR="$CLAUDE_PROJECT_DIR"` |
| `agents/developer.md` | 213 | `DIR="$CLAUDE_PROJECT_DIR/.claude/worktrees/$NAME"` (embedded config example) |
| `agents/developer.md` | 225 | `"$CLAUDE_PROJECT_DIR"/.claude/hooks/on_session_end.sh` (embedded config example) |
| `agents/tester.md` | 313 | `"$CLAUDE_PROJECT_DIR"/.claude/hooks/on_session_end.sh` (embedded config example) |

> **Note:** `agents/developer.md` and `agents/tester.md` contain embedded YAML/JSON config blocks that are templates for agent settings. These should also be updated to use `JENGA_PROJECT_DIR`.

---

## Findings: All `CLAUDE_*` Variables

| Variable | File | Line | Notes |
|----------|------|------|-------|
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `settings.json` | 4 | Feature flag env var set in `env` block — Claude Code-specific |
| `CLAUDE_PROJECT_DIR` | `settings.json` | 32, 53 | See table above |
| `CLAUDE_PROJECT_DIR` | `hooks/on_session_end.sh` | 24 | See table above |
| `CLAUDE_AGENT_TYPE` | `hooks/on_session_end.sh` | 33 | `AGENT="${CLAUDE_AGENT_TYPE:-unknown}"` |
| `CLAUDE_SESSION_ID` | `hooks/on_session_end.sh` | 34 | `SESSION_ID="${CLAUDE_SESSION_ID:-}"` |
| `CLAUDE_PROJECT_DIR` | `.agents/hooks/on_session_end.sh` | 24 | Duplicate hook — same pattern |
| `CLAUDE_AGENT_TYPE` | `.agents/hooks/on_session_end.sh` | 33 | Same as hooks/ copy |
| `CLAUDE_SESSION_ID` | `.agents/hooks/on_session_end.sh` | 34 | Same as hooks/ copy |
| `CLAUDE_PROJECT_DIR` | `agents/developer.md` | 213, 225 | Embedded config templates |
| `CLAUDE_PROJECT_DIR` | `agents/tester.md` | 313 | Embedded config template |

### Summary of unique `CLAUDE_*` variables found

| Variable | Description |
|----------|-------------|
| `CLAUDE_PROJECT_DIR` | Root project directory — primary target for replacement |
| `CLAUDE_AGENT_TYPE` | Agent type identifier set by Claude Code runtime |
| `CLAUDE_SESSION_ID` | Session identifier set by Claude Code runtime |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | Feature flag — enables agent teams mode in Claude Code |

---

## Findings: `COPILOT_*` Variables

**No `COPILOT_*` variables are currently in use in any source files.**

The only references to `COPILOT_*` appear in board/documentation files describing the intended design:

| File | Line | Context |
|------|------|---------|
| `project/board/tasks/E16_S01_T02_create-resolve-project-dir-sh.md` | 19 | `$COPILOT_WORKSPACE_FOLDER` — listed as the Copilot equivalent to resolve |
| `project/board/stories/E16_S01_abstract-claude-specific-env-vars.md` | 16, 26 | `COPILOT_PROJECT_DIR` / `COPILOT_WORKSPACE_FOLDER` — design intent only |

> **Conclusion:** No Copilot-specific env vars are wired into hook scripts or config templates yet. The resolver script created in T02 will need to probe `COPILOT_WORKSPACE_FOLDER` (or the correct Copilot CLI env var name) as a fallback.

---

## Actionable File List for T03

The following **source files** must be updated in T03 (board/doc references are excluded — they are informational):

1. **`settings.json`** — lines 32, 53: Replace `CLAUDE_PROJECT_DIR` with `JENGA_PROJECT_DIR`
2. **`hooks/on_session_end.sh`** — line 24: Replace `CLAUDE_PROJECT_DIR`; lines 33–34: replace `CLAUDE_AGENT_TYPE` / `CLAUDE_SESSION_ID` with Jenga canonical equivalents or add fallback logic
3. **`.agents/hooks/on_session_end.sh`** — same changes as `hooks/on_session_end.sh` (duplicate file)
4. **`agents/developer.md`** — lines 213, 225: Update embedded config template blocks
5. **`agents/tester.md`** — line 313: Update embedded config template block

### `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` in `settings.json` (line 4)

This is a Claude Code feature flag in the `env` block. It is Claude-specific by nature and cannot be aliased to a Jenga var. It should remain as-is but be noted as Claude-only config that Copilot/other agents will simply ignore.

---

## Hook Script Duplicate Note

`hooks/on_session_end.sh` and `.agents/hooks/on_session_end.sh` appear to be identical copies. T03 should update both, and the team should consider whether to consolidate them.
