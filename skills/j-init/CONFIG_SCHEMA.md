# jenga.config.json — Schema Reference

This document is the canonical reference for the `jenga.config.json` file at the root of a Jenga project. It is the **only** copy of this schema: the maintainer-side distribution tooling (private, not shipped) points here for the shared fields instead of keeping its own.

The `project_files_visibility` field is written by `skills/j-init/scripts/apply-project-visibility.sh` during `/init`, and the `scaffold_visibility` field by `skills/j-init/scripts/apply-scaffold-visibility.sh`, also during `/init`. The file should not be edited by hand.

---

## Purpose

`jenga.config.json` lives at the root of a consuming project and records which version of the Jenga AI framework is installed there, where the framework files were placed, and when they were last refreshed. `/init` also uses it to store the two visibility choices described below.

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
  "project_files_visibility": "visible",
  "scaffold_visibility": "visible"
}
```

---

## Field reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `project_name` | string | yes | — | Human-readable identifier for the consuming project. Matches the project's own name. |
| `target_dir` | string | yes | `.agents` | The directory under the project root where framework files are copied. Read on every refresh to resolve the destination path. Change this only if the consuming project uses a non-standard layout. |
| `version` | string | yes | — | The Jenga AI semantic version currently installed in this project (e.g. `"2.3.1"`). Compared against the framework's own `package.json` version to determine whether an upgrade is required. |
| `updated_at` | string (ISO 8601 date) | yes | — | Date of the last successful refresh of the framework files, in `YYYY-MM-DD` format. Does **not** include a time component. |
| `last_distributed` | string (ISO 8601 datetime) | yes | — | Full UTC timestamp of the last successful refresh, in `YYYY-MM-DDTHH:MM:SSZ` format. Provides more precision than `updated_at` and is useful for audit and ordering purposes. |
| `source` | string | yes | `"private"` | Update channel recorded by the maintainer-side tooling. Do not change this value manually. |
| `project_files_visibility` | string (enum) | no | `"visible"` | How Jenga AI's own working files (`project/`) appear in the consuming project. Exactly one of `visible` or `ignored` — no other value is accepted. Written by `/init`, not by an install or sync. See [Project files visibility](#project-files-visibility) below. |
| `scaffold_visibility` | string (enum) | no | `"visible"` | How the `.claude`/`.agents` framework scaffold appears in the consuming project. Exactly one of `visible` or `ignored` — no other value is accepted. A **distinct** flag from `project_files_visibility`, written by `/init`, not by distribution. See [Scaffold visibility](#scaffold-visibility) below. |

---

## Project files visibility

`project_files_visibility` controls how Jenga AI's own working files — the `project/` tree containing the scrum board, `todo.md`, `queue/`, `rapports/`, and `logs/` — appear in a consuming project.

This is distinct from `target_dir`. `target_dir` governs where the **framework files** (skill and agent definitions) land; `project_files_visibility` governs the **working tree** that accumulates as the framework is used.

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

The field is written during `/init` by `skills/j-init/scripts/apply-project-visibility.sh`, which also performs the corresponding on-disk change. The script merges the field into any existing `jenga.config.json` rather than overwriting the file, since `/init` normally runs before the first install or sync has created it.

Changing the value after the initial `/init` is not currently supported — there is no toggle or migration path. Re-running the applier with a different mode is not a supported upgrade route.

---

## Scaffold visibility

`scaffold_visibility` controls how the **framework scaffold** — `.claude/` and
`.agents/`, the mirrored skill and agent definitions that make Jenga AI's own commands
(`/init`, `/do`, `/commit`, etc.) available inside a consuming project — appears in that
project's git history.

### Why this is a separate flag from `project_files_visibility`

This field was filed as new, adjacent scope under `E31_S07`, from a problem rapport
(`project/rapports/problems/E31_S05-consumer-scaffold-committed-despite-ignored-visibility.md`)
reporting that a consumer who selected `project_files_visibility: ignored` still had 342
files under `.claude/`/`.agents/` swept into their `/init` commit — `project_files_visibility`
never covered that tree in the first place.

`E31_S05`'s own Background section explicitly scoped `project_files_visibility` to the
`project/` working tree — the scrum board, `todo.md`, `queue/`, `rapports/`, and `logs/` —
and explicitly said this was **not** about "the skill/agent definitions
themselves." Two ways to close the resulting gap were considered when `E31_S07_T01` made
this decision:

- **(a) Extend** `project_files_visibility`'s `ignored` mode to also gitignore `.claude/`
  and `.agents/`. Rejected: this erases the documented boundary from `E31_S05` — a single
  flag would then silently govern two trees with different lifecycles (`project/`
  accumulates as the user works; `.claude/`/`.agents/` are overwritten wholesale by every
  npm postinstall or `npx jenga sync`), and a consumer reading `ignored` for one tree would
  have no way to tell it also silently applies to the other.
- **(b) Introduce a distinct, separately-named flag** (`scaffold_visibility`), chosen. Costs
  one extra config field and one extra `/init` prompt, but keeps each flag's semantics
  unambiguous and independently selectable — a consumer can, for example, keep `project/`
  visible (to track their own board in git) while still excluding the vendored
  `.claude/`/`.agents/` scaffold, or vice versa.

`scaffold_visibility` reuses `project_files_visibility`'s exact two-value enum and
semantics (same mental model, different target directories) rather than inventing new
vocabulary.

### Allowed values

Exactly two values are accepted. Any other value is rejected with a non-zero exit code.

| Value | On-disk effect |
|---|---|
| `visible` | `.claude/`/`.agents/` are tracked and committed normally — unchanged from `/init`'s behavior before this field existed. |
| `ignored` | `.claude/` and `.agents/` are appended to the project's `.gitignore` (whichever of the two exist, or will later be created by an npm install or `npx jenga sync`), so they exist on disk but are never committed. |

### Default

The default is **`visible`**, used whenever `/init` runs non-interactively or the user is
not prompted — this is an additive capability, not a change to the previously-unconditional
commit behavior. `visible` reproduces exactly what every `/init` run did before this field
existed: the scaffold is committed regardless of `project_files_visibility`'s value. An
absent field (a `jenga.config.json` written before this field existed) is also read as
`visible`.

### Who writes it

The field is written during `/init` by `skills/j-init/scripts/apply-scaffold-visibility.sh`,
which also performs the corresponding `.gitignore` change. Like
`apply-project-visibility.sh`, it merges the field into any existing `jenga.config.json`
rather than overwriting the file, and gitignores `.claude/`/`.agents/` unconditionally
(not only when they already exist on disk), so a scaffold created by a later
npm install or `npx jenga sync` is covered too — not only one already present at `/init`
time.

`init.sh` applies both `project_files_visibility` and `scaffold_visibility` before its
final `git add -A && git commit` step, so any `.gitignore` entries from either flag are
already in place — and therefore respected by `git add -A` — before the first commit is
made.

Changing the value after the initial `/init` is not currently supported, matching
`project_files_visibility`'s own limitation above.
