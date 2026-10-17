---
layout: page
title: Hooks
permalink: /hooks.html
---


Hooks are configured in `settings.json` and fire automatically at specific points in a Claude Code session.

| Hook | Trigger | Script |
|---|---|---|
| `WorktreeCreate` | Developer creates a worktree | `git worktree add` + echo path |
| `WorktreeRemove` | Developer removes a worktree | `git worktree remove --force` |
| `SessionEnd` | Any session ends | `hooks/on_session_end.sh` (async) |
| `PreToolUse` | Every `Bash`, `Task` or `Agent` tool call | `hooks/on_preflight_check.sh` — pre-flight checklist backstop |

---

### `hooks/on_session_end.sh`

Runs asynchronously at the end of every session:

1. Logs a `session_end` event to `project/logs/events.json`
2. Compares `project/rapports/problems/` against `.rapport_manifest.json` (skipping `*.IGNORE.md` files)
   - If new rapports found: writes a `rapport_review` trigger to `scrum_triggers.jsonl`
3. Always writes a `status_review` trigger for the next Scrum Master session
4. If `.session_handoff.json` exists in the queue: forwards the handoff to the developer trigger queue

This ensures the Scrum Master always has an up-to-date view of the project when it starts the next session.

---

### `hooks/on_preflight_check.sh`

The enforcing layer of the [pre-flight checklist](https://samwelmunga.github.io/jenga-npm/preflight-checklists.html) feature (mirrored at [project/.wiki/preflight-checklists.md](https://github.com/samwelmunga/jenga-npm/blob/main/project/.wiki/preflight-checklists.md)). Fires on `PreToolUse` for `Bash`, `Task` and `Agent` calls, reads the situation marker written by `scripts/checklist-marker.sh` to learn which lifecycle phase is active, runs `scripts/checklist.sh check <phase>`, and **refuses the tool call** when a `block`-enforcement item is unsatisfied (a failing `confirm` item makes it ask instead). It exists so enforcement does not ultimately depend on an agent choosing to call the checker.

- **No marker, no effect.** With no lifecycle phase active it exits `0` with no output and no subprocess.
- **It gates each phase's own irreversible operation, not every tool call** — `pre-commit` → `git commit`, `pre-task` → subagent dispatch and `git worktree add`, `pre-release`/`pre-publish` → `npm publish` / `gh release` / `git push` / `git tag`, `pre-mirror` → `git push` / `mirror.sh`, `pre-reconcile` → `git merge` / `git worktree remove`. Gating everything would wedge the session, because satisfying a failed item is itself a tool call.
- **It holds at every permission level, including level 5 (Unrestricted).** Its decision never consults permission state, and no environment variable disables it.
- **It is registered in six files, not one.** Switching permission level whole-file-overwrites `.claude/settings.json` and `.agents/settings.json` from `templates/permission-levels/level-<n>-<name>.json`, so the `PreToolUse` block is byte-identical across the root `settings.json` and all five templates. Change all six together.

---

