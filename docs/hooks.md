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

### `hooks/distribute-changes.sh`

Distributes workflow files to all consumer projects registered in `.jenga_paths`.

```bash
.agents/hooks/distribute-changes.sh --dry-run   # preview without writing
.agents/hooks/distribute-changes.sh             # apply
.agents/hooks/distribute-changes.sh --force     # skip version check
```

---

