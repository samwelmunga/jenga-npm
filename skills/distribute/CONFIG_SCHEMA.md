# jenga.config.json — Schema Reference

This document is the canonical reference for the `jenga.config.json` file written into **consuming projects** during framework distribution. The file is created and maintained by `distribute-changes.sh`; it should not be edited by hand.

---

## Purpose

`jenga.config.json` lives at the root of a consuming project and tracks which version of the JengaAgent framework is currently installed there, where the framework files were placed, and when the last distribution occurred. It is read by the distribution script on subsequent runs to determine the target directory and detect whether an upgrade is needed.

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
  "source": "private"
}
```

---

## Field reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `project_name` | string | yes | — | Human-readable identifier for the consuming project. Must match the `name` field of the corresponding entry in the monorepo's `distribute.config.json`. |
| `target_dir` | string | yes | `.agents` | The directory under the project root where framework files are copied. `distribute-changes.sh` reads this field to resolve the destination path on every run. Change this only if the consuming project uses a non-standard layout. |
| `version` | string | yes | — | The JengaAgent semantic version currently installed in this project (e.g. `"2.3.1"`). Compared against the `version` field in the monorepo's `package.json` to determine whether an upgrade is required. |
| `updated_at` | string (ISO 8601 date) | yes | — | Date of the last successful distribution, in `YYYY-MM-DD` format. Does **not** include a time component. |
| `last_distributed` | string (ISO 8601 datetime) | yes | — | Full UTC timestamp of the last successful distribution, in `YYYY-MM-DDTHH:MM:SSZ` format. Provides more precision than `updated_at` and is useful for audit and ordering purposes. |
| `source` | string | yes | `"private"` | Distribution channel. Always `"private"` for projects that receive updates via the filesystem distribution mechanism. Distinguishes these projects from any future npm-installed consumers. Do not change this value manually. |

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
