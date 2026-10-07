---
layout: page
title: Pre-Flight Checklists
permalink: /preflight-checklists.html
---

A pre-flight checklist is a standing list of checks that must hold before a gated action goes ahead. This page
is the authoring reference: how to write your own `project/configs/checklists.json`, what each field accepts,
and how to call the checker directly.

For the overview, see the [README](https://github.com/samwelmunga/jenga-npm#pre-flight-checklists). The full
design notes, including the parts that matter only to people changing Jenga itself, are in
[preflight-checklists.md](https://github.com/samwelmunga/jenga-npm/blob/main/project/documentation/preflight-checklists.md).

## Where the checklist lives

| File | Location | Role |
|---|---|---|
| Shipped default | `templates/checklists.json` (`node_modules/@jenga-ai/agent/templates/checklists.json` in a consumer install) | A small generic default (staged `.env` files, conflict markers, a clean tree and passing tests before a release). |
| Your checklist | `project/configs/checklists.json` (the `configs` directory of your project) | Your own items. |

The checker reads **exactly one** of the two files. If `project/configs/checklists.json` exists it is the whole
registry and the shipped default is not read. Only when it does not exist does the shipped default apply.
There is no merging, no override by `id`, and no inheritance: to keep a shipped item, copy it into your file.
Your file with `"items": []` means "nothing applies here" and does not fall back to the default.

When there is no registry at all, when it has no items, or when no item names the phase being checked, the checker
prints nothing (or `[]`) and exits `0`. The gate is a silent no-op: no warning, no prompt.

## File format

```json
{
  "checklist_version": 1,
  "situations": [],
  "items": []
}
```

| Field | Required | Meaning |
|---|---|---|
| `checklist_version` | yes | Must be the integer `1`. |
| `situations` | no (default `[]`) | Extra phase names this file declares, see [Phases](#phases). |
| `items` | yes (may be empty) | The checklist items. |

Each file is validated on its own. Validate yours with:

```bash
bash "$([ -f scripts/validate-checklists.sh ] && echo scripts/validate-checklists.sh || echo node_modules/@jenga-ai/agent/scripts/validate-checklists.sh)" project/configs/checklists.json
```

It prints `PASS <file>` or `FAIL <file>` and exits `0` when every file is valid.

## Item fields

Every field below is required, except `verify`, which depends on `kind`. Values are case-sensitive.

| Field | Accepted values |
|---|---|
| `id` | Kebab-case string matching `^[a-z0-9]+(-[a-z0-9]+)*$`, unique in the file. Never reuse an `id` for a different item. |
| `text` | Non-empty string. The statement as it is shown to you or an agent. |
| `situations` | Non-empty array of phase names, no duplicates. Each must be a base phase or one this file declares. |
| `kind` | `"machine"` or `"judgment"`. |
| `verify` | `machine`: required, a non-empty shell command line. `judgment`: must be absent. |
| `enforcement` | `"block"`, `"confirm"` or `"advisory"`. |
| `tick_scope` | `"run"` or `"persistent"`. |

An item may also carry an optional `provenance` object. It records where an item came from when an agent
suggested it and you accepted it. You do not need to write one for items you author.

### `machine` and `judgment`

- **`machine`** items are satisfied when their `verify` command exits `0`. The checker runs it.
- **`judgment`** items are satisfied when a person confirms them. The checker cannot confirm one, so it always
  reports a judgment item as `requires_confirmation`, never as passed.

A `machine` item **requires** `verify`. A `judgment` item **forbids** it, even as an empty string or `null`.

`verify` runs as `bash -c <verify>` from the project root, with no stdin and a 60-second time limit. Exit `0`
passes, anything else fails. A command that is missing, not executable or times out is a failure, never a
pass. Keep it non-interactive and read-only: it may run every time a gate fires. A `verify` that hides its own
failure (`cmd || true`) always passes, because exit status is all the checker scores.

```json
{
  "id": "no-untracked-env-files",
  "text": "No untracked .env files are present in the working tree.",
  "situations": ["pre-commit", "pre-release"],
  "kind": "machine",
  "verify": "! git ls-files --others --exclude-standard | grep -q '\\.env$'",
  "enforcement": "block",
  "tick_scope": "run"
}
```

Backslashes and double quotes inside `verify` must be JSON-escaped: the `\\.` above reaches the shell as `\.`.

```json
{
  "id": "contributing-guide-read",
  "text": "I have read the project's contributing guide and will follow its conventions.",
  "situations": ["pre-task"],
  "kind": "judgment",
  "enforcement": "confirm",
  "tick_scope": "persistent"
}
```

### Enforcement

`enforcement` only matters for an item that is not satisfied. A satisfied item never prompts and never halts.

| Level | When the item is not satisfied | Use it for |
|---|---|---|
| `block` | The gated action halts before any work is done. There is no "proceed anyway": fix the cause and re-run, confirm the item (judgment items), or stop. | Things that must never ship: secrets, conflict markers, a broken build. |
| `confirm` | You are asked before the action proceeds, and must choose explicitly: satisfy it, proceed anyway, or stop. Silence is not consent. | Things that are usually right but have legitimate exceptions. |
| `advisory` | The `text` (and the failure, for a `machine` item) is shown as a reminder. The action is never halted and no answer is needed. | Habits and nudges. |

Proceeding past a `confirm` or `advisory` item does not tick it. Only a satisfied item is ever ticked.

### Tick scope

A **tick** records that an item was satisfied. A **run** is one execution of a gated phase from start to finish.

| `tick_scope` | Behaviour | Use it for |
|---|---|---|
| `run` | The tick is discarded when the run ends. The next run verifies or asks again. | Anything whose truth can change between runs: most `machine` items, and confirmations that must be renewed. |
| `persistent` | The tick survives the end of the run and across sessions, until you remove it. | One-time facts and acknowledgements. A persistent `machine` item is not re-verified after its first pass, so reserve it for conditions that cannot regress. |

A tick is bound to a hash of the item's `kind`, `text` and `verify`. Editing any of those makes an old tick count
as absent, so tightening a rule cannot be satisfied by an older acknowledgement. Editing `enforcement`,
`situations` or `tick_scope` does not.

## Phases

A phase is a lifecycle moment, not a skill name. The base phases are a closed list:

| Phase | Applies when | Fired by |
|---|---|---|
| `pre-commit` | Work is about to be committed. | `/j-commit` |
| `pre-task` | A board task is about to start executing. | `/j-do` |
| `pre-release` | A release is about to be published or mirrored. | `/j-publish`, `/j-mirror-public` |
| `pre-reconcile` | The board is about to be reconciled against the implementation. | `/j-reconcile` |

You can declare more phases in your file's top-level `situations` array (names match `^[a-z][a-z0-9-]*$` and may
not repeat a base name):

```json
{ "checklist_version": 1, "situations": ["pre-deploy"], "items": [] }
```

Declaring a phase only makes the name valid in that file. Something still has to fire it. The two release
skills fire a second, skill-specific phase after `pre-release` (`pre-publish` for `/j-publish`, `pre-mirror` for
`/j-mirror-public`); a registry only needs to declare them if it has items for them.

## Calling the checker

`scripts/checklist.sh` is the one implementation. Gating skills call it for you; these are the entry points if
you want to call it yourself. Use the dual-path form so it works in a consumer install:

```bash
CHK="$([ -f scripts/checklist.sh ] && echo scripts/checklist.sh || echo node_modules/@jenga-ai/agent/scripts/checklist.sh)"
```

### `list`

```bash
bash "$CHK" list <phase> [--run <run-id>]
```

Prints each item that names the phase, one per line, as `id`, `text`, `kind`, `enforcement` and tick state,
separated by tabs. It never runs a `verify` command and never writes anything. Nothing to list is not an error.

### `check`

```bash
bash "$CHK" check <phase> [--run <run-id>]
```

Runs the applicable items and prints one JSON array on stdout (`[]` when nothing applies). Each element has
`id`, `text`, `kind`, `enforcement`, `tick_scope`, `tick_state`, `result`, `action`, `reason`, `cause` and
`exit_status`. Diagnostics go to stderr.

| `result` | `action` for `block` / `confirm` / `advisory` |
|---|---|
| `passed` | `proceed` |
| `failed` | `halt` / `prompt` / `remind` |
| `requires_confirmation` (a judgment item) | `halt` / `prompt` / `remind` |
| `already_ticked` (not re-verified or re-asked) | `proceed` |

### `tick`

```bash
bash "$CHK" tick <id> [--run <run-id>] [--note <text>] [--by <actor>]
bash "$CHK" tick --clear <id> [--run <run-id>]
```

Records that item `<id>` was satisfied. It does **not** verify anything: tick a `machine` item only after
`check` reported it passed, and a `judgment` item only after you confirmed it. `--by` names who took that
responsibility (for example `user:me` or `agent:developer`). A `run`-scoped item needs `--run`. `--clear`
removes a tick and is the only way a persistent tick ends. Ticking an already-ticked item refreshes it.

A run id is chosen by the caller, once per execution, and a new one is used for the next execution. It is 1 to
128 characters of letters, digits, `.`, `:`, `_` and `-`, starting with a letter or digit. With no `--run` (and
no `JENGA_CHECKLIST_RUN_ID`), `list` and `check` see run-scoped items as unticked, which costs a re-check and
never skips one.

### Exit codes

A caller that only tells zero from non-zero is always on the safe side.

| Exit | Meaning for the caller |
|---|---|
| `0` | Success. For `check`: no applicable `block` item is unsatisfied and no `confirm` item needs a decision. Also returned when nothing applies. |
| `10` | `check`: at least one `block` item is unsatisfied. The gated action must not proceed. Takes precedence over `11`. |
| `11` | `check`: no `block` item is unsatisfied, but a `confirm` item is. The script cannot prompt, so the caller must ask the user and proceed only on an explicit choice. |
| `1` | The selected registry is invalid or unreadable, or the configs directory could not be resolved. Stdout is empty. |
| `2` | Usage error: unknown subcommand, wrong arguments, or a bad run id, actor, item id or note. |
| `3` | Unknown phase for `list` or `check`: neither a base phase nor declared in the selected file. The message names the phase and the known ones. |
| `4` | `python3` is not installed. |
| `5` | Internal error in the check runner. Stdout is empty. |
| `6`, `7`, `8` | `tick` only: `6` the id is not an item of the registry, `7` the item is `run`-scoped and no run id was given, `8` the tick was not recorded (state directory, lock or write failure). |

Setup errors (`1`, `2`, `3`) leave stdout empty.

## How the layers enforce it

1. **Skills call the checker.** `/j-commit`, `/j-do`, `/j-publish`, `/j-mirror-public` and `/j-reconcile` each
   run `check` for their phase and branch on the exit code. This layer is instructions in each skill, honoured
   by whoever runs it. A `judgment` item is never certified by the agent: it is put to you and ticked only
   after you confirm.
2. **A situation marker.** `scripts/checklist-marker.sh` records which phase is active in the current
   session. `write` always pushes a new frame and prints a fresh token. `refresh --token <t>` extends exactly
   that one frame and exits `3` if the token names no live frame. A frame is cleared by its token. Frames
   expire after 60 minutes, so a dead session cannot keep gating forever.
3. **A `PreToolUse` hook.** `hooks/on_preflight_check.sh`, when registered in `settings.json` (it is in this
   repository's `settings.json` and in all five permission-level templates), reads the marker, runs `check`
   for the active phase and refuses the phase's own irreversible command while a `block` item fails. A
   failing `confirm` item makes it ask. It gates only these commands, so you can always run the failing
   `verify`, tick the item or clear the marker:

   | Active phase | Commands the hook gates |
   |---|---|
   | `pre-commit` | `git commit` |
   | `pre-task` | subagent dispatch, `git worktree add` |
   | `pre-reconcile` | `git merge`, `git worktree remove` |
   | `pre-release`, `pre-publish` | `npm publish`, `gh release`, `git push`, `git tag` |
   | `pre-mirror` | `git push`, `mirror.sh` |
   | any other declared phase | all of the above, plus `git reset --hard` |

   With no marker the hook does nothing. If the registry or tooling is broken (checker exit `1`, `2`, `4` or
   `5`) it lets the command through with a warning on stderr rather than trapping you out of every commit.
   It does not cover file edits made through the editor tools: those are covered only by the skill layer.

What the hook's tests demonstrate is its behaviour in a sandbox. In a live session, a refusal rests on Claude
Code honouring the hook's exit code `2`.

## Suggesting items

Agents can propose a new item when they spot a risk or hit an issue a standing check would have caught. A
suggestion is only a rapport. The Scrum Master reviews it, and nothing is written to
`project/configs/checklists.json` unless you confirm. Agents never edit that file themselves.

## Trust model

`verify` strings are executed as shell by whoever runs the checker. Treat the registry as trusted policy, like a
`Makefile` or a `package.json` script: anyone who can edit it can run commands as you. Never run `check`
against a registry from an untrusted source, such as an unreviewed pull request, until you have read it.
