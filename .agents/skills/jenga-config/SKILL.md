---
name: j.jenga-config
description: List, read and change Jenga's project settings (project/configs/*.json) through the deterministic `jenga config` command. A thin wrapper - it collects the file, key and value in chat and runs one script; the edit itself is validated and written by code, with no model reasoning.
keywords:
  - "jenga config"
  - "config"
  - "settings"
  - "change setting"
  - "threshold"
examples:
  - "show me the jenga settings"
  - "what is scope-thresholds.inline_max_files set to?"
  - "set scope-thresholds.inline_max_files to 4"
  - "change the commit test prompt default"
---

# jenga-config - Read or Change Jenga Settings

## Purpose

`/jenga-config` is a thin chat front end for `jenga config`, the command that lists and edits the settings in `project/configs/*.json`. The skill only collects the inputs and reports the result. Validation, type and range checks, the version-counter bump and the atomic write all happen inside the CLI, so an edit costs no model reasoning beyond gathering three inputs.

It is a main skill like `/jenga` and `/jenga-permission-level`: its directory keeps the bare name `skills/jenga-config/` (one of the permanent exceptions in the Canonical Naming Contract), and it is invoked as `/jenga-config` or `j.jenga-config`.

## Hard rules

1. **One entry point.** Every action runs `run-config.sh` and nothing else. Never read, parse, edit or write `project/configs/*.json` yourself, and never call `jenga` or `node bin/jenga.js` directly. The script resolves the CLI (a `jenga` on PATH, otherwise a pinned copy installed into a per-user cache), so the CLI does not need a global install.
2. **Writes are committed project values.** A `set` changes the file in `project/configs/`, which is version-controlled and shared with the whole project. There is no local-override layer and no `--shared` flag. Do not offer either.
3. **Report verbatim.** Show the script's stdout and its exit code exactly as returned. Do not paraphrase, summarise, or "fix up" the output.

## The script

```
SCRIPT="$([ -f skills/jenga-config/scripts/run-config.sh ] && echo skills/jenga-config/scripts/run-config.sh || echo node_modules/@jenga-ai/agent/skills/jenga-config/scripts/run-config.sh)"
bash "$SCRIPT" <subcommand> <args>
```

Run it from the project root (the command finds `project/configs/` from the working directory).

## Instructions

### 1. Choose the action

If the user did not already say, ask:

    What would you like to do?
    1. List the settings and edit interactively
    2. Read one setting (get)
    3. Change one setting (set)
    4. Other (describe below)

### 2. Gather only what the action needs

An address is `<file-id>.<key>`, where `<file-id>` is a config file's name without `.json` (for example `scope-thresholds.inline_max_files`). If the user does not know the address, run the list action first and let them pick; do not open the config files to look it up.

| Action | Collect | Run |
|--------|---------|-----|
| List | nothing | `bash "$SCRIPT"` |
| Get | the address | `bash "$SCRIPT" get <file-id>.<key>` |
| Set | the address and the new value | `bash "$SCRIPT" set <file-id>.<key> <value>` |

Quote the value if it contains spaces or shell characters. For a `set`, state the address and value once and run it; the CLI rejects an invalid value without writing anything, so no extra confirmation round is needed beyond the user having just supplied the value.

The list action starts the CLI's interactive picker. If the shell has no terminal and it ends without output, say so and tell the user to run `jenga config` in a terminal, or to use `get` / `set` with an address.

### 3. Report

Print the script's stdout and the exit code verbatim. Exit codes:

| Code | Meaning |
|------|---------|
| `0` | Success (a `set` of the value already in the file reports `(unchanged)`). |
| `2` | Usage error: missing or surplus arguments. |
| `3` | Unknown config file or unknown key. |
| `4` | Invalid value: wrong type, out of range, not an allowed value. |
| `5` | Read-only key: nothing was written. |
| `6` | Config file missing or malformed, or the configs directory could not be resolved. |
| `7` | The jenga CLI could not be installed. The config command was not run. Show the script's stderr. |

For a non-zero code, show the stderr the script printed and stop; do not retry with a different value on the user's behalf.

### 4. After a successful `set`

The file under `project/configs/` has changed on disk. Tell the user it is an uncommitted project change and that `j.commit` records it. Do not commit it yourself.
