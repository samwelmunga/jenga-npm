---
name: j:dev-done
description: Commit the current work and immediately sync it into the .claude/ and .agents/ mirrors. Shortcut that chains /commit followed by /self-sync.
keywords:
  - dev done
  - commit and sync
  - commit and mirror
  - done syncing
examples:
  - "dev-done E42_S04_T01"
  - "commit this and sync the mirrors"
---

# Dev-Done — Commit, then Sync the Mirrors

Chains `/commit <scope-id>` and `/self-sync`, the same "convenience shortcut" pattern `skills/lgtm/SKILL.md`
uses for `/commit` + `/continue` — applied here to the commit -> mirror-sync sequence instead of the
commit -> next-task sequence. Useful right after implementing a root-level framework change
(`skills/`, `agents/`, `hooks/`, `scripts/`, `templates/`, `settings.json`), so the `.claude/` and
`.agents/` mirrors never sit stale waiting on a manual `/self-sync` call.

The deterministic decision of whether `/commit` halted early (nothing to commit) or completed
normally lives in `skills/dev-done/scripts/classify-commit-outcome.sh`, not inline here — see that
script's header for the exact contract.

## Instructions

1. Invoke the `/commit` skill with whatever scope-id argument `/dev-done` itself was given (e.g.
   `/dev-done E42_S04_T01` invokes `/commit E42_S04_T01`) — the same EST scope-id argument contract
   `/commit` already accepts (epic, story, or task id; see `skills/commit/SKILL.md`). Capture its full
   output text.

2. Pass the captured output to the classifier script:
   ```
   skills/dev-done/scripts/classify-commit-outcome.sh <<< "$COMMIT_OUTPUT"
   ```

3. If the script exits `1` (HALT): print its stdout — the exact message `No implementation to
   commit.` — to the user, and stop. Do **not** invoke `/self-sync`.

4. If the script exits `0` (PROCEED): invoke the `/self-sync` skill and wait for it to finish. This
   happens regardless of whether `/commit` reported drift or doc-sync findings along the way — those
   are informational, not blocking (see `skills/commit/SKILL.md`).

5. Report both steps' output to the user in sequence — the commit result first, then the self-sync
   summary.
