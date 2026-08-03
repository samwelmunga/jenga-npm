# Plan: E16_S01_T03 — Update hook scripts and config templates to use JENGA_PROJECT_DIR

## Goal
Replace all `CLAUDE_PROJECT_DIR`, `CLAUDE_AGENT_TYPE`, and `CLAUDE_SESSION_ID` references with `JENGA_*` equivalents across hook scripts and config templates. Source `lib/resolve-project-dir.sh` in each shell script.

## Files to Change

### 1. `hooks/on_session_end.sh`
- Add `source "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"` after the comment block
- Line 24: `CLAUDE_PROJECT_DIR` → `JENGA_PROJECT_DIR`
- Line 33: `CLAUDE_AGENT_TYPE` → `JENGA_AGENT_TYPE`
- Line 34: `CLAUDE_SESSION_ID` → `JENGA_SESSION_ID`

### 2. `.agents/hooks/on_session_end.sh`
- Same changes as above (duplicate file, kept in sync)

### 3. `settings.json`
- Line 32 (WorktreeCreate command): prepend `. "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"` and replace `$CLAUDE_PROJECT_DIR` → `$JENGA_PROJECT_DIR`
- Line 53 (SessionEnd command): prepend resolver inline and replace `$CLAUDE_PROJECT_DIR` → `$JENGA_PROJECT_DIR`

### 4. `agents/developer.md`
- Line 213: `$CLAUDE_PROJECT_DIR` → `$JENGA_PROJECT_DIR` (example snippet)
- Line 225: `"$CLAUDE_PROJECT_DIR"` → `"$JENGA_PROJECT_DIR"` (example snippet)

### 5. `agents/tester.md`
- Line 313: `"$CLAUDE_PROJECT_DIR"` → `"$JENGA_PROJECT_DIR"` (example snippet)

## Verification
Run `grep -rn "CLAUDE_PROJECT_DIR\|CLAUDE_AGENT_TYPE\|CLAUDE_SESSION_ID"` excluding board/summary docs to confirm zero remaining references in operational files.
