---
name: j:j-self-sync
description: Polyfill alias of the self-sync skill under a collision-safe directory name. Identical behavior to /self-sync — Mirror this repo's root-level framework directories into its own `.claude/` and `.agents/` sub-trees so edits to `/skills/*`, `/agents/*`, `/hooks/*`, `/scripts/*`, `/templates/*`, and `settings.json` take effect in the current Claude Code (and non-Claude) agent session — the in-repo replacement for the retired `/distribute` self-sync loop. Use when the bare /self-sync form is shadowed by another tool's own built-in command of the same name.
keywords:
  - "self sync"
  - "mirror skills"
  - "sync .claude"
  - "sync .agents"
  - "in-repo distribute"
  - j-self-sync
  - polyfill
examples:
  - "self-sync the mirrors"
  - "/self-sync --dry-run"
  - "refresh .claude/skills from root"
  - "j-self-sync"
---

# Self-Sync

This skill is a literal-directory-name duplicate of `skills/self-sync/`. It exists so that `/j-self-sync` (and `j:j-self-sync`) give a guaranteed-unshadowed way to reach the same flow as `/self-sync`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/self-sync` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh self-sync` from `skills/self-sync/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

Copies the framework's root-level entries into this repo's own `.claude/` and `.agents/` mirrors so agent tooling (Claude Code, Copilot, custom) picks up local edits without reinstalling or running `/distribute`.

Delegates the actual filesystem work to `lib/mirror.js`, the same helper used by `scripts/postinstall.js` on consumer installs. Two-directory mirror + delete reconciliation are the only differences from that consumer path.

## Instructions

1. If the user passed `--dry-run` (or asked for a preview), invoke:
   ```
   node skills/j-self-sync/scripts/run.js --dry-run
   ```
   Report the printed plan (added / overwritten / deleted) verbatim.

2. Otherwise, invoke:
   ```
   node skills/j-self-sync/scripts/run.js
   ```
   Report the printed summary. Do not run any inline `cp`, `rsync`, or `fs` commands — all mirroring goes through the script.

   A successful non-dry-run invocation also runs a **Merged-status pass** (`E51_S02`) after the
   mirror step completes: it invokes `skills/j-self-sync/scripts/mark-merged.sh`, which in turn
   computes the scoped sync diff via `skills/j-self-sync/scripts/compute-sync-diff.sh` and flips any
   closed ticket (`Done`/`Passed`/`Passed with remarks`) to `status: Merged` once every file its
   commit history touched has been mirrored. This pass is **non-fatal** — a failure inside it is
   logged as a warning and never causes `/self-sync` itself to report failure or a non-zero exit,
   the same resilience pattern already used for the skill-allow-list regeneration step just before
   it. It never runs on `--dry-run`.

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

**Manual invocation only.** The user runs `/self-sync` (or `node skills/j-self-sync/scripts/run.js`) after making framework edits and before expecting them to be visible to the current agent session.

Rationale: an on-`/commit` or file-watch trigger would fire on every edit — including drafts that shouldn't leak into the mirrors — and would obscure the write footprint (delete reconciliation prunes orphans, so accidental deletes on the source side propagate). Making the sync explicit keeps the human in the loop for a destructive-by-default operation, which matches the framework's boundary-checked, dry-runnable posture.

## Dry-Run Behavior

`--dry-run` computes the full plan (added / overwritten / deleted / unchanged) via `lib/mirror.js` without touching the filesystem. Use it before every real run when the mirror state is uncertain, or when running in a repo where uncommitted mirror edits might exist.

## Safety Guarantees

- **Never writes outside the repo root.** `lib/mirror.js` boundary-checks every destination path with `assertInside(destRoot, target)`; the helper throws if a resolved child escapes its destination root.
- **Additive helper + explicit reconciliation.** The mirror helper is additive by default; delete reconciliation is enabled only because this skill passes `reconcileDeletes: true`.
- **No shell out for the mirror step itself.** Pure Node built-ins (`node:fs`, `node:path`) — no `cp`, `rsync`, or subprocess calls; the mirror always goes through `lib/mirror.js`. (The separate Merged-status pass below does invoke shell scripts — that's the one exception, scoped to that pass only.)
- **Idempotent.** A second consecutive run reports `+0 ~0 -0` because the byte-comparison in `filesEqual` classifies unchanged files as `skipped`.
- **Merged-status pass stays read-only on `--dry-run`.** The `E51_S02` Merged-status pass
  (`compute-sync-diff.sh` + `mark-merged.sh`) is invoked only from the non-dry-run branch of
  `run.js`'s `main()` — a `--dry-run` invocation never touches the `last-self-sync` marker tag or
  any board file, matching every other safety guarantee in this section.

## Guard Rails

- Do not inline mirroring logic in this skill body — all filesystem work goes through `scripts/run.js` → `lib/mirror.js`.
- Do not run this skill from a directory other than a checkout of the framework repo itself. `scripts/postinstall.js` handles consumer installs; this skill handles the framework's own repo.
