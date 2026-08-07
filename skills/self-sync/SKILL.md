---
name: self-sync
description: Mirror this repo's root-level framework directories into its own `.claude/` and `.agents/` sub-trees so edits to `/skills/*`, `/agents/*`, `/hooks/*`, `/scripts/*`, `/templates/*`, and `settings.json` take effect in the current Claude Code (and non-Claude) agent session — the in-repo replacement for the retired `/distribute` self-sync loop.
keywords:
  - "self sync"
  - "mirror skills"
  - "sync .claude"
  - "sync .agents"
  - "in-repo distribute"
examples:
  - "self-sync the mirrors"
  - "/self-sync --dry-run"
  - "refresh .claude/skills from root"
---

# Self-Sync

Copies the framework's root-level entries into this repo's own `.claude/` and `.agents/` mirrors so agent tooling (Claude Code, Copilot, custom) picks up local edits without reinstalling or running `/distribute`.

Delegates the actual filesystem work to `lib/mirror.js`, the same helper used by `scripts/postinstall.js` on consumer installs. Two-directory mirror + delete reconciliation are the only differences from that consumer path.

## Instructions

1. If the user passed `--dry-run` (or asked for a preview), invoke:
   ```
   node skills/self-sync/scripts/run.js --dry-run
   ```
   Report the printed plan (added / overwritten / deleted) verbatim.

2. Otherwise, invoke:
   ```
   node skills/self-sync/scripts/run.js
   ```
   Report the printed summary. Do not run any inline `cp`, `rsync`, or `fs` commands — all mirroring goes through the script.

3. If the summary shows `+0 ~0 -0` on a second consecutive real run, the mirrors are already in sync — surface that as confirmation of idempotency.

## Copy Set

The script mirrors exactly these root-level entries:

```
bin/  lib/  scripts/  agents/  hooks/  mcp/  skills/  templates/  settings.json
```

This is an **explicit constant** in `scripts/run.js`, deliberately not derived at runtime from `package.json` `files`. Two reasons:

- `package.json` `files` includes `README.md` and `LICENSE`, which should not appear in the agent mirrors.
- `settings.json` is required in the mirrors but is intentionally not shipped in the npm tarball, so it does not appear in `files`.

The list is kept aligned with `package.json` `files` by convention. If a new top-level framework directory is added, update both.

## Invocation Model

**Manual invocation only.** The user runs `/self-sync` (or `node skills/self-sync/scripts/run.js`) after making framework edits and before expecting them to be visible to the current agent session.

Rationale: an on-`/commit` or file-watch trigger would fire on every edit — including drafts that shouldn't leak into the mirrors — and would obscure the write footprint (delete reconciliation prunes orphans, so accidental deletes on the source side propagate). Making the sync explicit keeps the human in the loop for a destructive-by-default operation, which matches the framework's boundary-checked, dry-runnable posture.

## Dry-Run Behavior

`--dry-run` computes the full plan (added / overwritten / deleted / unchanged) via `lib/mirror.js` without touching the filesystem. Use it before every real run when the mirror state is uncertain, or when running in a repo where uncommitted mirror edits might exist.

## Safety Guarantees

- **Never writes outside the repo root.** `lib/mirror.js` boundary-checks every destination path with `assertInside(destRoot, target)`; the helper throws if a resolved child escapes its destination root.
- **Additive helper + explicit reconciliation.** The mirror helper is additive by default; delete reconciliation is enabled only because this skill passes `reconcileDeletes: true`.
- **No shell out.** Pure Node built-ins (`node:fs`, `node:path`) — no `cp`, `rsync`, or subprocess calls.
- **Idempotent.** A second consecutive run reports `+0 ~0 -0` because the byte-comparison in `filesEqual` classifies unchanged files as `skipped`.

## Guard Rails

- Do not inline mirroring logic in this skill body — all filesystem work goes through `scripts/run.js` → `lib/mirror.js`.
- Do not run this skill from a directory other than a checkout of the framework repo itself. `scripts/postinstall.js` handles consumer installs; this skill handles the framework's own repo.
