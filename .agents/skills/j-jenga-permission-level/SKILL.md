---
name: j:j-jenga-permission-level
description: Polyfill alias of the jenga-permission-level skill under a collision-safe directory name. Identical behavior to /jenga-permission-level — Report or switch the current session's 5-tier permission level (Locked/Guarded/Standard/Elevated/Unrestricted) without hand-editing settings.json. Use when the bare /jenga-permission-level form is shadowed by another tool's own built-in command of the same name.
keywords:
  - "permission level"
  - "permission"
  - "session level"
  - "jenga permission level"
  - j-jenga-permission-level
  - polyfill
examples:
  - "what permission level am I at?"
  - "switch to permission level 4"
  - "set permission level to elevated"
  - "lock down permissions"
  - "unlock full permissions for this session"
  - "j-jenga-permission-level"
---

# jenga-permission-level — Report or Switch Session Permission Level

This skill is a literal-directory-name duplicate of `skills/jenga-permission-level/`. It exists so that `/j-jenga-permission-level` (and `j:j-jenga-permission-level`) give a guaranteed-unshadowed way to reach the same flow as `/jenga-permission-level`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/jenga-permission-level` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh jenga-permission-level` from `skills/jenga-permission-level/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## Purpose

`/jenga-permission-level [1-5]` reports or switches the current session's permission level:

| Level | Name | Notes |
|-------|------|-------|
| 1 | Locked | |
| 2 | Guarded | Conceptual default — always reported as `Default: 2`, no matter the current session level. |
| 3 | Standard | |
| 4 | Elevated | |
| 5 | Unrestricted | |

`defaultMode` stays `acceptEdits` at every level; only the `permissions` block changes. Levels are backed by template files at `templates/permission-levels/level-<n>-<name>.json`, e.g. `templates/permission-levels/level-4-elevated.json` (naming convention: `<name>` is the lowercase level name from the table above — Locked/Guarded/Standard/Elevated/Unrestricted). Those templates are owned by story E33_S01 and are the input the switch script (see below) copies from.

---

## Instructions

### 1. No argument — report status

Read `.jenga-permission-level.json` at the repo root. Treat a missing file, or a missing/unparseable `session_level` field, as `session_level: 2`.

Run:

```bash
n=$(jq -r '.session_level // 2' .jenga-permission-level.json 2>/dev/null || echo 2)
echo "Default: 2 / Session: $n"
```

Print exactly `Default: 2 / Session: <n>` (e.g. `Default: 2 / Session: 4`). Do not write any files in this path.

### 2. Argument `<n>` provided — validate

Before doing anything else, validate the argument:

- It must match `^[1-5]$` (a single digit, 1 through 5).
- If it does not match — including non-numeric input, decimals, negative numbers, `0`, or `6` and above — **stop immediately**, print a clear error (e.g. `Error: permission level must be an integer between 1 and 5, got '<input>'`), and make **no file changes**. Do not invoke the switch script.

### 3. Argument `<n>` valid — delegate to the switch script

Do not inline the copy/update logic here — per this repo's scripts-over-inline-logic convention, the switch is owned entirely by a dedicated script:

```bash
bash scripts/jenga-permission-level-switch.sh <n>
```

This script (created by a separate task, E33_S02_T02) is responsible for:
- Copying `templates/permission-levels/level-<n>-<name>.json` over both `.claude/settings.json` and `.agents/settings.json` as a **whole-file overwrite** — not a merge of the `permissions` block alone. Two fields vary by level and are expected to change on a switch: `permissions.deny` and `autoMode.allow`. All 5 templates carry byte-identical `defaultMode`, `env`, `hooks`, and `permissions.allow`; that invariant is what keeps the overwrite safe. Two consequences follow: any top-level key present in a destination file but absent from the templates is **silently dropped** by a switch, and any future per-level difference in `defaultMode`/`env`/`hooks` would take effect without warning. Keep the templates in sync with root `settings.json` for everything except those two varying fields.
- Creating or updating `.jenga-permission-level.json` at the repo root to `{"session_level": <n>}`.

Relay the script's stdout to the user and honor its exit code:
- Exit code `0` — report success, e.g. `Switched to level <n> (<name>).`
- Non-zero exit code — report the script's error output verbatim and treat the switch as failed; do not claim success.

If `scripts/jenga-permission-level-switch.sh` does not exist yet (e.g. E33_S02_T02 has not landed), report that clearly as a missing dependency rather than attempting to reimplement its logic inline.

### Session End

When this skill's session concludes, emit the following signal on its own line so the Jenga Router clears the active session:

```
[JENGA:SESSION_END:jenga-permission-level]
```
