# Pre-Flight Checklists

> **Feature guide:** Standing checks that must hold before a gated action goes ahead, and how to author your own.

Full authoring reference on the [docs site](https://samwelmunga.github.io/jenga-npm/preflight-checklists.html) (source: `docs/preflight-checklists.md`). Maintainer-level design notes: `project/documentation/preflight-checklists.md`.

---

## What it is

A pre-flight checklist is a list of checks, each tied to a lifecycle **phase** and a strictness level. A gating skill runs the checks for its phase before it does anything it cannot take back: no `.env` file staged before a commit, a clean working tree before a release, "I have re-read the acceptance criteria" before a task starts.

The four base phases:

| Phase | Fires when | Fired by |
|---|---|---|
| `pre-commit` | Work is about to be committed | `j.commit` |
| `pre-task` | A board task is about to start executing | `j.do` |
| `pre-release` | A release is about to be published or mirrored | `j.publish`, `j.mirror-public` |
| `pre-reconcile` | The board is about to be reconciled against the implementation | `j.reconcile` |

The two release skills fire a second, skill-specific phase after `pre-release`: `pre-publish` for `j.publish`, `pre-mirror` for `j.mirror-public`. A registry declares these (or any other extra phase) in its own top-level `situations` array.

## The registry, and the no-op guarantee

| File | Location |
|---|---|
| Shipped default | `templates/checklists.json` (`node_modules/@jenga-ai/agent/templates/checklists.json` in a consumer install) |
| Your checklist | `project/configs/checklists.json` |

The checker reads exactly one of them. If `project/configs/checklists.json` exists it **replaces the shipped default wholesale**: the two are never merged, so copy any shipped items you want to keep into your own file. With no project file, the shipped default applies. A project file with `"items": []` is a deliberate "nothing applies here" and does not fall back to the default.

When there is no registry at all, the registry has no items, or no item names the phase being checked, the checker prints nothing (or `[]`) and exits `0`. That is a silent no-op: no warning, no prompt.

## An item

Every field is required except `verify`, which depends on `kind`. Values are case-sensitive.

| Field | Accepted values |
|---|---|
| `id` | Kebab-case string, unique in the file |
| `text` | Non-empty statement, shown verbatim |
| `situations` | Non-empty array of phases, no duplicates |
| `kind` | `machine` or `judgment` |
| `verify` | `machine`: required shell command, exit `0` passes. `judgment`: must be absent |
| `enforcement` | `block`, `confirm` or `advisory` |
| `tick_scope` | `run` or `persistent` |

- `block`: the gated action halts, with no "proceed anyway".
- `confirm`: you are asked and must choose explicitly; silence is not consent.
- `advisory`: reminded only, never halted.
- `run` ticks are discarded when the run ends; `persistent` ticks survive across runs and sessions until cleared.

A `judgment` item is never certified by the agent running the skill: it is put to you and ticked only after you confirm.

## Calling the checker

`scripts/checklist.sh` offers `list <phase>`, `check <phase>` and `tick <id>` (plus `tick --clear <id>`). `check` prints a JSON array and its exit code is the backstop:

| Exit | Meaning |
|---|---|
| `0` | Nothing blocks and no `confirm` item needs a decision (also when nothing applies) |
| `10` | A `block` item is unsatisfied: do not proceed |
| `11` | Only `confirm` items are unsatisfied: ask the user, proceed only on an explicit choice |
| `1` | Invalid or unreadable registry |
| `2` | Usage error |
| `3` | Unknown phase |

Further codes: `4` python3 missing, `5` internal error, and for `tick` only `6` unknown item id, `7` run-scoped item with no run id, `8` tick not recorded.

## Three layers of enforcement

1. **Skills call the checker.** Instructions in each gating skill, honoured by whoever runs it.
2. **A situation marker** (`scripts/checklist-marker.sh`) records which phase is active. `write` always pushes a new frame with a fresh token; `refresh --token` extends exactly that frame and exits `3` if the token names no live frame; frames are cleared by token.
3. **A `PreToolUse` hook** (`hooks/on_preflight_check.sh`) reads the marker and refuses the active phase's own irreversible command (for example `git commit` during `pre-commit`) while a `block` item fails. A failing `confirm` item makes it ask. With no marker it does nothing, and a broken registry or toolchain fails open with a warning on stderr.

What the hook's tests demonstrate is its behaviour in a sandbox; in a live session a refusal rests on Claude Code honouring the hook's exit code `2`.

## Suggested items

Agents can propose a new item when they spot a risk. A suggestion is only a rapport: the Scrum Master reviews it, and nothing reaches `project/configs/checklists.json` without your confirmation.
