# Hook Parity: Claude Code ↔ GitHub Copilot CLI

This document maps each **Claude Code hook event** to its **GitHub Copilot CLI equivalent** within the Jenga Agent Framework. Where no native Copilot hook exists, the recommended workaround is provided.

---

## Parity Matrix

| Claude Code Hook | Trigger | Copilot CLI Equivalent | Notes |
|---|---|---|---|
| `UserPromptSubmit` | Every user message before Claude processes it | `copilot-instructions.md` routing guidance | Copilot reads `copilot-instructions.md` at session start; there is no per-prompt interception. Use the routing table in the instructions file to direct Copilot to the correct skill. |
| `WorktreeCreate` | Agent creates a git worktree | Manual / script | Run `hooks/worktree_create.sh` manually or invoke it as a pre-step inside a skill. Copilot has no native worktree lifecycle event. |
| `WorktreeRemove` | Agent removes a git worktree | Manual / script | Run `hooks/worktree_remove.sh` manually or as a skill post-step. |
| `SessionEnd` | Claude session closes | Skill post-execution or manual | Run `hooks/copilot_session_end.sh` after completing a skill (see [Session End](#session-end) below). |

---

## Session End

Claude Code fires `SessionEnd` automatically when a session closes, which triggers `hooks/on_session_end.sh`. Copilot CLI has no equivalent native hook.

**Copilot workaround:** call `hooks/copilot_session_end.sh` explicitly at the end of each Copilot session or skill execution:

```bash
bash hooks/copilot_session_end.sh
```

`copilot_session_end.sh` is a thin wrapper that:

1. Sources `lib/resolve-project-dir.sh` to export `JENGA_PROJECT_DIR`.
2. Delegates to `hooks/on_session_end.sh` for all shared cleanup logic (queue routing, rapport detection, handoff file processing, todo cleanup).

This ensures the same pipeline logic runs under both Claude and Copilot.

---

## `JENGA_PROJECT_DIR` Environment Variable

Jenga introduces a canonical environment variable — `JENGA_PROJECT_DIR` — that abstracts over agent-specific variables:

| Agent | Native Variable | Mapped To |
|---|---|---|
| Claude Code | `CLAUDE_PROJECT_DIR` | `JENGA_PROJECT_DIR` |
| GitHub Copilot CLI | `COPILOT_WORKSPACE_FOLDER` | `JENGA_PROJECT_DIR` |
| Fallback | `git rev-parse --show-toplevel` or `pwd` | `JENGA_PROJECT_DIR` |

**Always use `JENGA_PROJECT_DIR`** in hook scripts and skills. Never reference `CLAUDE_PROJECT_DIR` or `COPILOT_WORKSPACE_FOLDER` directly — the resolver handles the mapping at runtime.

Similarly:

| Concept | Jenga Canonical | Claude Source | Copilot Fallback |
|---|---|---|---|
| Project directory | `JENGA_PROJECT_DIR` | `CLAUDE_PROJECT_DIR` | `COPILOT_WORKSPACE_FOLDER` |
| Agent type | `JENGA_AGENT_TYPE` | `CLAUDE_AGENT_TYPE` | `"generic"` |
| Session ID | `JENGA_SESSION_ID` | `CLAUDE_SESSION_ID` | `uuidgen` / timestamp |

---

## `lib/resolve-project-dir.sh`

All hook scripts and skills source this file at the top of their execution:

```bash
source "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh"
```

The resolver is **idempotent**: if `JENGA_PROJECT_DIR` is already set (e.g. by a parent script that already sourced it), it returns immediately. This makes it safe to source multiple times in a chain of scripts.

After sourcing, the following variables are available for use:

- `$JENGA_PROJECT_DIR` — absolute path to the project root
- `$JENGA_AGENT_TYPE` — the active agent identifier (`scrum-master`, `developer`, `tester`, `generic`)
- `$JENGA_SESSION_ID` — a unique identifier for the current agent session

---

## Manual Invocation Guide for Copilot Users

Because Copilot CLI does not fire lifecycle hooks automatically, the following actions must be performed **manually** or wired into skill pre/post steps:

| When | What to run |
|---|---|
| Creating a worktree | `bash hooks/worktree_create.sh` |
| Removing a worktree | `bash hooks/worktree_remove.sh` |
| Ending a session or completing a skill | `bash hooks/copilot_session_end.sh` |

**Tip:** Add these calls to the bottom of any skill that manages worktrees or completes a significant pipeline step (e.g. the `commit` skill, the `lgtm` skill).

---

## See Also

- [`lib/resolve-project-dir.sh`](../lib/resolve-project-dir.sh) — canonical env var resolver
- [`hooks/on_session_end.sh`](../hooks/on_session_end.sh) — shared session-end cleanup logic
- [`hooks/copilot_session_end.sh`](../hooks/copilot_session_end.sh) — Copilot-side entry point
- [`templates/copilot-instructions.md.tpl`](../templates/copilot-instructions.md.tpl) — Copilot instructions template
