---
name: j.jenga-permission-level
description: Report or switch the current session's 5-tier permission level (Locked/Guarded/Standard/Elevated/Unrestricted) without hand-editing settings.json.
keywords:
  - "permission level"
  - "permission"
  - "session level"
  - "jenga permission level"
examples:
  - "what permission level am I at?"
  - "switch to permission level 4"
  - "set permission level to elevated"
  - "lock down permissions"
  - "unlock full permissions for this session"
---

# jenga-permission-level — Report or Switch Session Permission Level

## Purpose

`/jenga-permission-level [1-5]` reports or switches the current session's permission level:

| Level | Name | Notes |
|-------|------|-------|
| 1 | Locked | |
| 2 | Guarded | Conceptual default — always reported as `Default: 2`, no matter the current session level. |
| 3 | Standard | |
| 4 | Elevated | |
| 5 | Unrestricted | |

`defaultMode` stays `acceptEdits` at every level; only the `permissions` block changes. Levels are backed by template files at `$([ -f templates/permission-levels/level-<n>-<name>.json ] && echo templates/permission-levels/level-<n>-<name>.json || echo node_modules/@jenga-ai/agent/templates/permission-levels/level-<n>-<name>.json)`, e.g. `$([ -f templates/permission-levels/level-4-elevated.json ] && echo templates/permission-levels/level-4-elevated.json || echo node_modules/@jenga-ai/agent/templates/permission-levels/level-4-elevated.json)` (naming convention: `<name>` is the lowercase level name from the table above — Locked/Guarded/Standard/Elevated/Unrestricted). Those templates are owned by story E33_S01 and are the input the switch script (see below) copies from.

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
bash "$([ -f scripts/jenga-permission-level-switch.sh ] && echo scripts/jenga-permission-level-switch.sh || echo node_modules/@jenga-ai/agent/scripts/jenga-permission-level-switch.sh)" <n>
```

This script (created by a separate task, E33_S02_T02) is responsible for:
- Merging the matching template `$([ -f templates/permission-levels/level-<n>-<name>.json ] && echo templates/permission-levels/level-<n>-<name>.json || echo node_modules/@jenga-ai/agent/templates/permission-levels/level-<n>-<name>.json)` into both `.claude/settings.json` and `.agents/settings.json` as a **key-level merge**, not a copy of the whole file. The switch owns only the level policy keys: `defaultMode`, `permissions.deny`, `permissions.ask`, `autoMode`. For each owned key the destination takes the template's value (or loses the key when the template does not set it); every other key (`hooks`, `permissions.allow`, `env`, `statusLine`, ...) is left exactly as it was. The templates carry only those keys; `hooks`, `permissions.allow` and `env` come from the root `settings.json` and the settings merge from `E100_S03`. Two fields vary by level: `permissions.deny` and `autoMode.allow`. A switch therefore cannot drop the pre-flight `PreToolUse` backstop or any other hook registration.
- Creating or updating `.jenga-permission-level.json` at the repo root to `{"session_level": <n>}`.

Relay the script's stdout to the user and honor its exit code:
- Exit code `0` — report success, e.g. `Switched to level <n> (<name>).`. If the script also prints a `Note:` line on stderr saying a settings file has no `PreToolUse` entry for `hooks/on_preflight_check.sh`, so the pre-flight backstop is not registered, relay it verbatim. It is printed only in that case (the switch itself never removes the entry), and it names the command that registers it. Do not add a sync hint of your own when the line is absent.
- Non-zero exit code — report the script's error output verbatim and treat the switch as failed; do not claim success.

If neither `scripts/jenga-permission-level-switch.sh` nor `node_modules/@jenga-ai/agent/scripts/jenga-permission-level-switch.sh` exists yet (e.g. E33_S02_T02 has not landed), report that clearly as a missing dependency rather than attempting to reimplement its logic inline.

### Session End

When this skill's session concludes, emit the following signal on its own line so the Jenga Router clears the active session:

```
[JENGA:SESSION_END:jenga-permission-level]
```
