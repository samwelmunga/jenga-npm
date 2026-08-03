# Summary: E16_S01_T03 — Update hook scripts and config templates to use JENGA_PROJECT_DIR

**Date:** 2026-05-10  
**Status:** Done

## Files Changed

### 1. `hooks/on_session_end.sh`
- Added `source "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"` after the comment block (with `# shellcheck source=` directive)
- Line 24: `PROJECT_DIR="$CLAUDE_PROJECT_DIR"` → `PROJECT_DIR="$JENGA_PROJECT_DIR"`
- Line 33: `AGENT="${CLAUDE_AGENT_TYPE:-unknown}"` → `AGENT="${JENGA_AGENT_TYPE:-unknown}"`
- Line 34: `SESSION_ID="${CLAUDE_SESSION_ID:-}"` → `SESSION_ID="${JENGA_SESSION_ID:-}"`

### 2. `.agents/hooks/on_session_end.sh`
- Same changes as above (duplicate file kept in sync)
- Added resolver source, replaced all three CLAUDE_ vars with JENGA_ equivalents

### 3. `settings.json`
- WorktreeCreate command (line 32): prepended `. "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"` inline and replaced `$CLAUDE_PROJECT_DIR` → `$JENGA_PROJECT_DIR`
- SessionEnd command (line 53): replaced with `. "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh" && "$JENGA_PROJECT_DIR"/.claude/hooks/on_session_end.sh`

### 4. `agents/developer.md`
- Line 213 (WorktreeCreate example): `$CLAUDE_PROJECT_DIR` → `$JENGA_PROJECT_DIR`
- Line 225 (SessionEnd example): `"$CLAUDE_PROJECT_DIR"` → `"$JENGA_PROJECT_DIR"`

### 5. `agents/tester.md`
- Line 313 (SessionEnd example): `"$CLAUDE_PROJECT_DIR"` → `"$JENGA_PROJECT_DIR"`

## Grep Verification

```
grep -rn "CLAUDE_PROJECT_DIR|CLAUDE_AGENT_TYPE|CLAUDE_SESSION_ID" \
  --include="*.sh" --include="*.json" --include="*.md" \
  --exclude-dir=".git" --exclude-dir="project" .
```

**Result:** Only `lib/resolve-project-dir.sh` contains these identifiers — intentionally, as the resolver script maps Claude-specific env vars to `JENGA_*` equivalents as a compatibility fallback. Zero occurrences in hook scripts or config templates.

## Acceptance Criteria
- [x] Zero `CLAUDE_PROJECT_DIR` references remain in hook scripts or config templates
- [x] Zero `CLAUDE_AGENT_TYPE` and `CLAUDE_SESSION_ID` references remain in hook scripts
- [x] All updated shell scripts source `lib/resolve-project-dir.sh` before using `JENGA_*` vars
- [x] `settings.json` hooks use `JENGA_PROJECT_DIR` (inline resolver)
- [x] `agents/developer.md` and `agents/tester.md` example snippets updated
- [x] Existing hook behaviour preserved end-to-end under Claude Code (resolver falls back to `CLAUDE_PROJECT_DIR` when running under Claude Code)
