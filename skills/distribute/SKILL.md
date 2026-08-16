---
name: distribute
description: Distribute JengaAgent framework files from this private monorepo to one or more consuming projects via the local filesystem. Manages release type selection, version bumping, dry-run preview, per-target file copy, and a post-distribution git commit.
keywords:
  - distribute
  - private distribution
  - filesystem distribute
  - framework update
  - version bump
  - distribute to projects
examples:
  - "/distribute"
  - "/distribute /path/to/consuming-project"
  - "/distribute --dry-run"
---

# Distribute

Copies JengaAgent framework files from this monorepo to all active consuming projects registered in `distribute.config.json`. Manages the full version lifecycle: release type selection, `package.json` version bump, dry-run preview, per-target file copy, and a final git commit of the version bump.

Distinct from `/self-sync` (which mirrors root → in-repo `.claude/.agents/`) and `/mirror-public` (which syncs to the public GitHub repo). Do not call either of those skills from within this flow.

## Instructions

Follow these steps in order. Do not skip any step.

### Step 1 — Path argument check

If the user passed a path argument (e.g. `/distribute /path/to/project`):

1. Verify the path exists on disk. If it does not, print an error and halt.
2. Read `distribute.config.json` at the repo root.
3. Derive `name` from the directory name of the path (e.g. `my-project` from `/home/user/my-project`).
4. Add a new entry to the `targets` array:
   ```json
   { "name": "<derived-name>", "path": "<absolute-or-relative-path>", "active": true }
   ```
5. Write the updated `distribute.config.json`.
6. Confirm the addition to the user: `Added <name> (<path>) to distribute.config.json.`

If no path argument was passed, skip this step.

### Step 2 — Release type prompt

Ask the user to choose a release type. Present all four options:

| Type | Effect |
|------|--------|
| `major` | Breaking change. Bumps major version in `package.json`. Distributes to ALL active targets. |
| `minor` | New feature. Bumps minor version in `package.json`. Distributes to ALL active targets. |
| `patch` | Bug fix. Bumps patch version in `package.json`. Distributes to ALL active targets. |
| `amend` | No version bump. Distributes only to targets whose `jenga.config.json` version is behind the current `package.json` version, or targets that have no `jenga.config.json`. |

Wait for the user's answer before continuing.

### Step 3 — Config validation

Read `distribute.config.json`.

For each entry in `targets`:
- If `active` is `false`: print `Skipping <name> — inactive.` Do not include it in the distribution run.
- If the `path` does not exist on disk: print `Skipping <name> — path not found: <path>.` Do not include it in the distribution run.
- If release type is `amend`: run `bash skills/distribute/scripts/check-version.sh <path>`.
  - Exit 0 → include the target.
  - Exit 1 → print `Skipping <name> — already up to date.` Do not include it in the distribution run (record it in the final report as "already up to date").
  - Exit 2 → print `Skipping <name> — invalid path or config.` Do not include it.
- Otherwise (major / minor / patch): include all active, path-valid targets.

Print the final list of targets that will receive distribution. If the list is empty, print `No targets eligible for distribution.` and halt.

### Step 4 — Version bump (non-amend only)

Skip this step entirely for `amend`.

For `major`, `minor`, or `patch`:

```bash
npm version <type> --no-git-tag-version
```

Run this at the monorepo root. If the command fails (non-zero exit), print the error, and halt — do not proceed to distribution with an unbumped or failed version.

On success, read the new version from `package.json` and print: `Version bumped to <new-version>.`

### Step 5 — Dry-run preview

For each eligible target (from Step 3), run:

```bash
bash skills/distribute/scripts/distribute-changes.sh <project_path> --dry-run
```

Display the full output for each target. Then ask the user:

`Proceed with distribution to the above targets? [y/N]`

Wait for confirmation. If the user does not confirm, halt without making any changes. If a version bump was already applied in Step 4 and the user aborts here, inform them that `package.json` has been bumped but not committed, and they must either re-run `/distribute` or revert manually.

### Step 6 — Execute distribution

For each eligible target in sequence:

```bash
bash skills/distribute/scripts/distribute-changes.sh <project_path>
```

Record the exit code and any output. If a target fails (non-zero exit), record the failure and continue to the next target. Do not abort the run on partial failure.

### Step 7 — Report results

Print a per-target summary:

**Succeeded:**
- List each target name and the version distributed (read from `package.json`)

**Failed:**
- List each target name and the error output; note that manual retry is required

**Already up to date (amend mode only):**
- List each target skipped due to version match

**Skipped:**
- List inactive or missing-path targets from Step 3

### Step 8 — Commit version bump (non-amend only, only if at least one target succeeded)

Skip this step for `amend`. Skip this step if no targets succeeded in Step 6.

Call:

```bash
bash skills/distribute/scripts/commit-version-bump.sh
```

Report the resulting commit SHA to the user.

If at least one target failed and at least one succeeded, note that the version bump commit reflects the distributed version; failed targets need manual retry and will receive the same version on retry.

### Step 9 — Do not call downstream skills

Do not invoke `/self-sync` or `/mirror-public` at any point in this flow. They are separate skills with separate responsibilities and separate triggers.

## Scripts

| Script | Purpose |
|--------|---------|
| `skills/distribute/scripts/distribute-changes.sh <path> [--dry-run]` | Copy framework files to a single consuming project |
| `skills/distribute/scripts/commit-version-bump.sh` | Commit the `package.json` version bump |
| `skills/distribute/scripts/check-version.sh <path>` | Amend mode: exits 0 if target needs update, 1 if up to date, 2 if invalid |

## Config

`distribute.config.json` at the repo root is the registry of consuming projects.

Schema reference: `skills/distribute/CONFIG_SCHEMA.md`

Each target entry:

```json
{
  "name": "my-project",
  "path": "/absolute/or/relative/path/to/project",
  "active": true
}
```

## Guard Rails

- Never call `/self-sync` or `/mirror-public` from this skill.
- Never inline file copy logic — all filesystem work goes through `distribute-changes.sh`.
- Never commit anything other than `package.json` via `commit-version-bump.sh`.
- Never skip the dry-run confirmation gate — even in non-interactive contexts, print the dry-run output and require explicit `y` from the user.
- Never proceed past Step 4 if `npm version` fails.
