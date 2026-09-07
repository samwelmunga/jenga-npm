# Hook Parity: Claude Code ↔ GitHub Copilot CLI

This document maps each **Claude Code hook event** to its **GitHub Copilot CLI equivalent** within the Jenga Agent Framework. Where no native Copilot hook exists, the recommended workaround is provided.

> **Correction (E16_S03_T03/T04, 2026-09-07):** this document originally asserted (2026-05-10,
> `E16_S03_T01`) that "Copilot CLI does not fire lifecycle hooks automatically" and built a
> manual-invocation-only workaround on that premise. GitHub's own docs
> ([use-hooks](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks))
> now describe a native `.github/hooks/*.json` mechanism, and `E16_S03_T03` empirically confirmed
> it fires as documented against a real installed `copilot` CLI (1.0.83) — see
> [Native Copilot Hooks](#native-copilot-hooks) below. `SessionEnd` and `UserPromptSubmit` now
> have direct, verified native mappings; `WorktreeCreate`/`WorktreeRemove` remain manual (see the
> Parity Matrix's Notes column for why a `preToolUse`/`postToolUse` approximation was considered
> and rejected).

---

## Parity Matrix

| Claude Code Hook | Trigger | Copilot CLI Equivalent | Notes |
|---|---|---|---|
| `UserPromptSubmit` | Every user message before Claude processes it | **Native:** `userPromptSubmitted` (`.github/hooks/*.json`) | Confirmed firing (E16_S03_T03) with a JSON stdin payload (`sessionId`, `timestamp`, `cwd`, `prompt`). Wired to `hooks/prompt_router.sh` via `.github/hooks/jenga.json`, which already reads the `prompt` field from stdin and writes JSON to stdout — no platform branching needed, it works unmodified for both Claude's and Copilot's payload shapes. |
| `WorktreeCreate` | Agent creates a git worktree | Manual / inline commands | Claude Code's own `WorktreeCreate` hook is not a standalone script — it's an inline command block in `settings.json`: `git worktree add "$DIR" -b "$NAME"` followed by `scripts/install-worktree-commit-guard.sh "$DIR" "$NAME"`. A Copilot CLI user runs that same two-step sequence manually (see [Manual Invocation Guide](#manual-invocation-guide-for-copilot-users) below for the literal commands). No direct native Copilot lifecycle event exists for this — `preToolUse` fires generically around every tool call and could technically pattern-match `toolArgs.command` for a `git worktree add` substring (confirmed possible, E16_S03_T03), but this was rejected as too fragile versus Claude Code's structured hook input (an explicit `name` field) — a quoting or flag-order variation, an alias, or a wrapper script would all silently evade a plain-text match. |
| `WorktreeRemove` | Agent removes a git worktree | Manual / script | Claude Code's own `WorktreeRemove` hook invokes `scripts/worktree-remove-guard.sh` (a real, existing script — checks worktree liveness before removing; see that script's own header comment). A Copilot CLI user runs the same script directly in its CLI mode: `scripts/worktree-remove-guard.sh [--force-ignore-liveness] <worktree-path>`. Same reasoning as `WorktreeCreate` above — `postToolUse` fires generically but a text-match approximation was rejected as too fragile. |
| `SessionEnd` | Claude session closes | **Native:** `sessionEnd` (`.github/hooks/*.json`) | Confirmed firing (E16_S03_T03). Wired to `hooks/copilot_session_end.sh` via `.github/hooks/jenga.json` (see [Session End](#session-end) below). |

---

## Native Copilot Hooks

GitHub Copilot CLI has a native hooks mechanism, documented at
[use-hooks](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks)
and empirically confirmed against a real installed `copilot` CLI (1.0.83) under `E16_S03_T03`.

**Location:** repo-level config at `.github/hooks/*.json` (any filename), or user-level
`~/.copilot/hooks/`. `hooks` is a first-class category in the CLI's own environment model —
`copilot help commands`'s `/env` command lists it alongside `instructions`, `skills`, `agents`,
`plugins`, `LSPs`, and `extensions`.

**Schema:**
```json
{
  "version": 1,
  "hooks": {
    "eventName": [
      { "type": "command", "bash": "script for Linux/macOS", "powershell": "script for Windows", "cwd": "working directory", "timeoutSec": 30, "env": {"KEY": "value"} }
    ]
  }
}
```
Six events are supported: `sessionStart`, `sessionEnd`, `userPromptSubmitted`, `preToolUse`,
`postToolUse`, `errorOccurred`, `agentStop`. Hooks receive a JSON payload on stdin (shape varies
by event — e.g. `userPromptSubmitted` delivers `{"sessionId", "timestamp", "cwd", "prompt"}`,
`preToolUse`/`postToolUse` deliver `{"sessionId", "timestamp", "cwd", "toolName", "toolArgs", ...}`)
and may emit JSON on stdout; a default 30-second timeout applies.

**This project's config: `.github/hooks/jenga.json`.** Wires `sessionEnd` →
`hooks/copilot_session_end.sh` and `userPromptSubmitted` → `hooks/prompt_router.sh` — the same
scripts Claude Code's own `SessionEnd`/`UserPromptSubmit` hooks invoke, so the same cleanup and
routing logic runs under both platforms.

**Config placement — hybrid, not a single answer:**
- **This monorepo** commits `.github/hooks/jenga.json` directly at repo root (like `settings.json`,
  Claude's own committed hook config) — its commands resolve `hooks/*.sh` dynamically via
  `$(git rev-parse --show-toplevel)` at run time, so the same committed file works across any
  checkout or worktree of this repo.
- **Downstream npm consumers** get it generated — not committed — at `jenga init` time and as an
  unconditional `scripts/postinstall.js` bootstrap step (parallel to the existing
  `.github/copilot-instructions.md` bootstrap), via the shared generator
  `lib/generate-copilot-hooks.js`. A consumer's version bakes in the absolute
  `node_modules/@jenga-ai/agent/hooks/*.sh` paths instead, since a consumer has no local `hooks/`
  copy at their own project root to resolve dynamically (`postinstall.js`'s mirror copy set is
  `skills/` and `agents/` only — see `docs/distribution.md`).

No `skills/self-sync/scripts/run.js` mirroring is involved: unlike `.github/agents/*.md` (which
mirrors real source content already living at `agents/*.md`), `.github/hooks/jenga.json` has no
root-level source directory to mirror from — it is a generated artifact, exactly like
`.github/copilot-instructions.md`, which self-sync also does not touch.

**Known limitation (flagged, not fixed by this task):** `hooks/copilot_session_end.sh` internally
sources `lib/resolve-project-dir.sh` via `$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh`
— correct for this monorepo (and for `.claude/`/`.agents/` mirrors, since self-sync's full copy set
includes `lib/`), but `lib/` is never copied into a real npm consumer's own project root
(`postinstall.js` only mirrors `skills/` and `agents/`; `lib/` ships solely inside
`node_modules/@jenga-ai/agent/lib/`). This equally affects Claude's own `SessionEnd` hook for real
consumers today, and no consumer-side generator even exists yet for that hook — this is a
pre-existing gap, tracked as a future follow-up rather than fixed here.

---

## Session End

Claude Code fires `SessionEnd` automatically when a session closes, which triggers `hooks/on_session_end.sh`. **Copilot CLI now fires this natively too** (`sessionEnd`, confirmed under `E16_S03_T03`) via `.github/hooks/jenga.json` (see [Native Copilot Hooks](#native-copilot-hooks) above).

**Manual invocation remains a valid fallback** — e.g. for a Copilot install that hasn't run `jenga init`/postinstall yet, or when explicitly calling it as a post-step in a skill:

```bash
bash hooks/copilot_session_end.sh
```

`copilot_session_end.sh` is a thin wrapper that:

1. Sources `lib/resolve-project-dir.sh` to export `JENGA_PROJECT_DIR`.
2. Delegates to `hooks/on_session_end.sh` for all shared cleanup logic (queue routing, rapport detection, handoff file processing, todo cleanup).

This ensures the same pipeline logic runs under both Claude and Copilot, whether triggered natively or manually.

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

`SessionEnd`/`UserPromptSubmit` now fire automatically once `.github/hooks/jenga.json` exists
(committed here; generated for consumers at `jenga init`/postinstall time — see
[Native Copilot Hooks](#native-copilot-hooks) above). `WorktreeCreate`/`WorktreeRemove` still have
no native equivalent and must be performed **manually** or wired into skill pre/post steps:

| When | What to run | Native? |
|---|---|---|
| Creating a worktree | `git worktree add "$DIR" -b "$NAME" && bash scripts/install-worktree-commit-guard.sh "$DIR" "$NAME"` (the same inline sequence `settings.json`'s own `WorktreeCreate` hook runs — there is no standalone `hooks/worktree_create.sh` script) | No — manual only |
| Removing a worktree | `bash scripts/worktree-remove-guard.sh <worktree-path>` (real script; also what `settings.json`'s own `WorktreeRemove` hook invokes) | No — manual only |
| Ending a session or completing a skill | `bash hooks/copilot_session_end.sh` | Yes, via `sessionEnd` — manual call still supported as a fallback |

**Tip:** Add the worktree calls to the bottom of any skill that manages worktrees (e.g. the `commit` skill, the `lgtm` skill) — `SessionEnd`/`UserPromptSubmit` no longer need a manual call once `.github/hooks/jenga.json` is present.

---

## See Also

- [`lib/resolve-project-dir.sh`](../lib/resolve-project-dir.sh) — canonical env var resolver
- [`lib/generate-copilot-hooks.js`](../lib/generate-copilot-hooks.js) — generates `.github/hooks/jenga.json` for `jenga init` / npm postinstall
- [`scripts/install-worktree-commit-guard.sh`](../scripts/install-worktree-commit-guard.sh) — the real `WorktreeCreate` companion script (installs a branch-guard pre-commit hook)
- [`scripts/worktree-remove-guard.sh`](../scripts/worktree-remove-guard.sh) — the real `WorktreeRemove` script (liveness check before `git worktree remove --force`)
- [`.github/hooks/jenga.json`](../.github/hooks/jenga.json) — this repo's own native Copilot hook config
- [`hooks/on_session_end.sh`](../hooks/on_session_end.sh) — shared session-end cleanup logic
- [`hooks/copilot_session_end.sh`](../hooks/copilot_session_end.sh) — Copilot-side entry point
- [`hooks/prompt_router.sh`](../hooks/prompt_router.sh) / [`hooks/prompt_router_helper.js`](../hooks/prompt_router_helper.js) — shared `UserPromptSubmit`/`userPromptSubmitted` routing logic
- [`templates/copilot-instructions.md.tpl`](../templates/copilot-instructions.md.tpl) — Copilot instructions template
