# Permission Level Templates

> **Distribution note:** This directory is mirrored automatically — no additional wiring is needed. `/self-sync` (`skills/self-sync/scripts/run.js`, `COPY_SET`) and `/distribute` (`distribute.config.json`, `distribute.include`) both already list `templates` as a top-level entry, and both copy that directory recursively, so `templates/permission-levels/` (including this README and all five level JSON files) rides along automatically with every sync/distribute run.

This directory holds the five canonical `settings.json` permission templates that back the `/jenga-permission-level` session-switchable permission system: **Locked (1)**, **Guarded (2)**, **Standard (3)**, **Elevated (4)**, and **Unrestricted (5)**.

Each level is a full `settings.json` file — `level-1-locked.json` through `level-5-unrestricted.json`. Two fields vary between them: `permissions.deny` and `autoMode.allow`. This table exists so a maintainer can see, at a glance, what each level allows and denies without diffing all 5 JSON files by hand.

## Level Matrix

| Level | Name | `permissions.deny` | Rationale |
|---|---|---|---|
| 1 | Locked | `rm *`<br>`rmdir *`<br>`dd *`<br>`mkfs *`<br>`shred *`<br>`truncate *`<br>`git push *`<br>`git reset --hard *`<br>`git clean *`<br>`chmod *`<br>`chown *`<br>`sudo *`<br>`su *`<br>`git commit *`<br>`git add *`<br>`git stash *`<br>`npm install *`<br>`npm publish *`<br>`git branch -D *`<br>`git tag *` | Maximum safety. Blocks all destructive file/git ops plus every git *write* op (commit, add, stash, branch delete, tag) and package publish/install — suitable for read-only exploration or highly sensitive sessions. |
| 2 | Guarded (**permanent default**) | `rm *`<br>`rmdir *`<br>`dd *`<br>`mkfs *`<br>`shred *`<br>`truncate *`<br>`git push *`<br>`git reset --hard *`<br>`git clean *`<br>`chmod *`<br>`chown *`<br>`sudo *`<br>`su *` | Safe default for normal agentic work. Blocks destructive file ops, destructive/history-rewriting git ops, and permission/ownership changes, but allows normal git commit/add/stash and package installs. |
| 3 | Standard | `dd *`<br>`mkfs *`<br>`shred *`<br>`truncate *`<br>`git push *`<br>`git reset --hard *`<br>`git clean *`<br>`chmod *`<br>`chown *`<br>`sudo *`<br>`su *` | Adds `rm *` / `rmdir *` back (Guarded minus those two) for normal file cleanup during active development, while still blocking pushes and history-rewriting git ops. |
| 4 | Elevated | `dd *`<br>`mkfs *`<br>`shred *`<br>`truncate *`<br>`chmod *`<br>`chown *`<br>`sudo *`<br>`su *` | Adds `git push *` / `git reset --hard *` / `git clean *` back (Standard minus those three) for active development workflows that need to push and reset branches. |
| 5 | Unrestricted | `dd *`<br>`mkfs *`<br>`shred *`<br>`truncate *`<br>`sudo *`<br>`su *` | Adds `chmod *` / `chown *` back (Elevated minus those two). Only the non-negotiable always-blocked set (see below) remains denied. |

## `autoMode.allow` by Level

`autoMode.allow` lists commands that are auto-approved **without a prompt** when the session is running in auto mode. It is a *friction* dial, not a *capability* dial — `permissions.deny` always wins over it — with one important exception described below.

| Level | `autoMode.allow` |
|---|---|
| 1 · Locked | `$defaults` |
| 2 · Guarded | `$defaults` |
| 3 · Standard | `$defaults` |
| 4 · Elevated | `$defaults`<br>`Bash(bash skills/mirror-public/scripts/mirror.sh*)` |
| 5 · Unrestricted | `$defaults`<br>`Bash(bash skills/mirror-public/scripts/mirror.sh*)` |

### Why mirror.sh is gated to level 4+

`permissions.deny` matches the command string the agent invokes — it does **not** see what that command spawns in a subprocess. `skills/mirror-public/scripts/mirror.sh` internally runs `git reset --hard origin/<branch>` and `git push origin <branch>` against the public repo. Auto-approving the script by name therefore grants an unprompted push of repository content to a **public** repo that the deny list cannot intercept. (The push itself is a plain fast-forward `git push` — the script's `--force` flag only overrides a pre-flight safety abort, it does not force-push. The risk here is disclosure, not history loss.)

Levels 1–3 deny `git push *` and `git reset --hard *`. Auto-approving `mirror.sh` at those levels would silently defeat that intent. Level 4 (Elevated) is the first tier where `git push *` and `git reset --hard *` are permitted directly, so it is the first tier where auto-approving a script that performs them is consistent.

**Rule for adding future entries:** before adding a command to `autoMode.allow` at level *n*, check what it executes internally. If it performs an operation that `permissions.deny` blocks at level *n*, it belongs at a higher level instead.

### Every template must carry an `autoMode` key

Even the levels that only grant `$defaults` declare the block explicitly. A level switch is a **whole-file overwrite** of `.claude/settings.json` and `.agents/settings.json` — any top-level key present in the destination but absent from the template is silently dropped. A template that omitted `autoMode` would wipe the destination's block on every switch.

## Always Blocked

The following commands are **never removed from `permissions.deny` at any level, including level 5 (Unrestricted)**:

- `dd *`
- `mkfs *`
- `shred *`
- `truncate *`
- `sudo *`
- `su *`

These are disk-destructive or privilege-escalation commands with no legitimate use case in an agentic coding session. No permission level — not even Unrestricted — removes them.

## Fields That Never Vary

Across all 5 templates:

- `defaultMode` stays `"acceptEdits"` at every level.
- `permissions.allow` stays `["Bash(*)"]` at every level.
- `env` and `hooks` (`WorktreeCreate`, `WorktreeRemove`, `SessionEnd`) are identical across all 5 files.

**Only `permissions.deny` and `autoMode.allow` vary between levels.** Every template is otherwise byte-identical to root `settings.json`, and root `settings.json` matches `level-2-guarded.json` exactly — Guarded being the permanent default.

> **Superseded (2026-08-23):** epic E33 originally settled on "`autoMode` is never used at any level" and "only `permissions.deny` varies". That decision was revisited after it emerged that auto-approving `mirror.sh` by script name bypasses the `git push *` deny at levels 1–3 (see the section above). `autoMode.allow` is now a second, deliberately tiered axis.

## Guarded (Level 2) Is the Permanent Default

There is no separate "default level" config number. Level 2 (Guarded) is conceptually always the project's permanent default.

- To change the **permanent, project-wide default**, a maintainer edits `templates/permission-levels/level-2-guarded.json` directly.
- Running `/jenga-permission-level <n>` only changes the **current session's** active level (by copying the matching template into `.claude/settings.json` and `.agents/settings.json` and recording the level in `.jenga-permission-level.json`) — it does not modify the permanent default, and the scrum-master resets a session back to Guarded at the start of every session it starts.
