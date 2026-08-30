# jenga.config.json — Schema Reference

This document is the canonical reference for the `jenga.config.json` file written into **consuming projects** during framework distribution. The file is created and maintained by `distribute-changes.sh`, with the `project_files_visibility` field written by `skills/init/scripts/apply-project-visibility.sh` during `/init`; it should not be edited by hand.

---

## Purpose

`jenga.config.json` lives at the root of a consuming project and tracks which version of the Jenga AI framework is currently installed there, where the framework files were placed, and when the last distribution occurred. It is read by the distribution script on subsequent runs to determine the target directory and detect whether an upgrade is needed.

---

## File location

```
<project-root>/jenga.config.json
```

---

## Example

```json
{
  "project_name": "my-project",
  "target_dir": ".agents",
  "version": "2.3.1",
  "updated_at": "2026-08-11",
  "last_distributed": "2026-08-11T10:00:00Z",
  "source": "private",
  "project_files_visibility": "visible"
}
```

---

## Field reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `project_name` | string | yes | — | Human-readable identifier for the consuming project. Must match the `name` field of the corresponding entry in the monorepo's `distribute.config.json`. |
| `target_dir` | string | yes | `.agents` | The directory under the project root where framework files are copied. `distribute-changes.sh` reads this field to resolve the destination path on every run. Change this only if the consuming project uses a non-standard layout. |
| `version` | string | yes | — | The Jenga AI semantic version currently installed in this project (e.g. `"2.3.1"`). Compared against the `version` field in the monorepo's `package.json` to determine whether an upgrade is required. |
| `updated_at` | string (ISO 8601 date) | yes | — | Date of the last successful distribution, in `YYYY-MM-DD` format. Does **not** include a time component. |
| `last_distributed` | string (ISO 8601 datetime) | yes | — | Full UTC timestamp of the last successful distribution, in `YYYY-MM-DDTHH:MM:SSZ` format. Provides more precision than `updated_at` and is useful for audit and ordering purposes. |
| `source` | string | yes | `"private"` | Distribution channel. Always `"private"` for projects that receive updates via the filesystem distribution mechanism. Distinguishes these projects from any future npm-installed consumers. Do not change this value manually. |
| `project_files_visibility` | string (enum) | no | `"visible"` | How Jenga AI's own working files appear in the consuming project. Exactly one of `visible` or `ignored` — no other value is accepted. Written by `/init`, not by distribution. See [Project files visibility](#project-files-visibility) below. |

---

## Project files visibility

`project_files_visibility` controls how Jenga AI's own working files — the `project/` tree containing the scrum board, `todo.md`, `queue/`, `rapports/`, and `logs/` — appear in a consuming project.

This is distinct from `target_dir`. `target_dir` governs where the **distributed framework files** (skill and agent definitions) land; `project_files_visibility` governs the **working tree** that accumulates as the framework is used.

### Allowed values

Exactly two values are accepted. Any other value is rejected with a non-zero exit code.

| Value | On-disk effect |
|---|---|
| `visible` | Working files stay at `project/`, tracked and visible in directory listings. Nothing on disk is changed. |
| `ignored` | Working files stay at `project/`, but `project/` is appended to the project's `.gitignore`, so they exist on disk and are never committed. |

#### Withdrawn: `hidden`

A third value, `hidden` (dot-prefixing `project/` to `.project/`, following the
same convention already used for `.agents/` and `.claude/`), was implemented
and tester-verified to produce the correct on-disk layout, but was withdrawn
before release because it is functionally broken at runtime:

- `scripts/board_resolver.sh` hardcodes `project/configs/workflow.json` as its
  config path. It never locates the rewritten `.project/configs/workflow.json`,
  silently falls back to a default that no longer exists, and exits `0` —
  a silent wrong answer rather than a hard failure.
- `hooks/on_session_end.sh` hardcodes and unconditionally creates
  `project/rapports/problems`, `project/queue`, and `project/logs`. Under
  `hidden` mode this recreates a shadow `project/` tree on the very next
  session end, splitting runtime state across `project/` and `.project/` —
  the clutter the mode was meant to remove reappears, and some agent output
  (e.g. queue triggers) is written to the tree the board no longer lives in.

Full findings: `project/rapports/problems/E31_S05_T01-hidden-mode-path-resolution-gaps.md`.

`hidden` is not offered by the `/init` prompt and is not accepted by
`apply-project-visibility.sh`. Reintroducing it requires fixing both hardcoded
paths above (routing them through `workflow.json` instead) — tracked as a
follow-up `/todo` item rather than built as part of this field.

### Default

The default is **`visible`**, used whenever `/init` runs non-interactively or the user is not prompted.

`visible` is the only value that is a genuine no-op on disk, so an unattended run can never silently relocate a user's directories or mutate their `.gitignore`. It also matches the behaviour of every project scaffolded before this field existed, making it backward-compatible for any consuming project whose `jenga.config.json` predates the field — an absent field is read as `visible`.

### Who writes it

The field is written during `/init` by `skills/init/scripts/apply-project-visibility.sh`, which also performs the corresponding on-disk change. The script merges the field into any existing `jenga.config.json` rather than overwriting the file, since `/init` normally runs before the first `/distribute` has created it.

Changing the value after the initial `/init` is not currently supported — there is no toggle or migration path. Re-running the applier with a different mode is not a supported upgrade route.

---

## First distribution

When `distribute-changes.sh` runs against a project for the first time and no `jenga.config.json` exists in the project root, the script creates the file from scratch. All six fields are populated using:

- `project_name` — taken from the matching entry in `distribute.config.json`
- `target_dir` — taken from the matching entry in `distribute.config.json` (falls back to `.agents` if absent)
- `version` — read from `package.json` in the monorepo at the time of distribution
- `updated_at` — today's date (`YYYY-MM-DD`)
- `last_distributed` — current UTC datetime (`YYYY-MM-DDTHH:MM:SSZ`)
- `source` — hardcoded to `"private"`

The directory referenced by `target_dir` is created if it does not already exist.

> **Known gap:** `distribute-changes.sh` rebuilds `jenga.config.json` from scratch on every run and emits only the six fields above, so a `project_files_visibility` value written by `/init` is dropped by the next `/distribute`. Making the rebuild preserve fields it does not own is tracked as follow-up work; until then, treat the on-disk layout (not the config field) as the source of truth for which mode a project is in.

---

## Atomic write mechanism

To prevent a consuming project from reading a partially-written `jenga.config.json` if distribution is interrupted (e.g. by a signal or disk error), the script uses an atomic write pattern:

1. The updated JSON is written to a temporary file in the same directory as the target (e.g. `jenga.config.json.tmp`).
2. The temporary file is renamed over the target with a single `mv` call.

Because rename is atomic on POSIX filesystems, a reader will always see either the previous complete file or the new complete file — never a half-written intermediate state.

---

## The `active` flag in `distribute.config.json`

`distribute.config.json` (in the monorepo, not in consuming projects) may include an `active` field on each target entry:

```json
{
  "targets": [
    { "name": "my-project", "path": "../my-project", "active": false }
  ]
}
```

- When `active` is `true` (or absent, which defaults to active), the target is distributed normally.
- When `active` is `false`, distribution is **skipped** for that target and a warning is printed to stdout. The distribution run continues to process remaining targets — an inactive entry is not treated as an error.

Use `active: false` to temporarily pause distribution to a project without removing its entry from the config.
