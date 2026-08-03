# Plan: E16_S03_T01 — Document hook parity matrix

## Objective
Create `docs/hook-parity.md` — a professional reference mapping Claude Code hook events to GitHub Copilot CLI equivalents and documenting the `JENGA_*` environment variable abstraction layer.

## Approach

1. **Create `docs/` directory** if absent (only `docs/` already contains architecture docs).
2. **Write `docs/hook-parity.md`** covering:
   - Full parity table: `UserPromptSubmit`, `WorktreeCreate`, `WorktreeRemove`, `SessionEnd`
   - `JENGA_PROJECT_DIR` environment variable abstraction section
   - `lib/resolve-project-dir.sh` sourcing pattern
   - Manual invocation guidance for Copilot users
3. **Also implement T02 in the same pass**:
   - Create `hooks/copilot_session_end.sh` as a thin wrapper over `hooks/on_session_end.sh`
   - Update `templates/copilot-instructions.md.tpl` with session-end guidance

## Files
- `docs/hook-parity.md` (new)
- `hooks/copilot_session_end.sh` (new, executable)
- `templates/copilot-instructions.md.tpl` (update)

## Acceptance Criteria
- All four hook events documented with Copilot equivalents or workarounds
- `JENGA_*` vars referenced throughout (no raw `CLAUDE_*` vars)
- `copilot_session_end.sh` is executable and delegates to `on_session_end.sh`
- Template updated with session-end reference
