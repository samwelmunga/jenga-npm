---
id: E22_S05_T02
story_id: E22_S05
epic_id: E22
title: Publish ledger — append entry on deploy and git tag creation
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Publish ledger — append entry on deploy and git tag creation

## Description
Implement publish ledger writes and git tagging as part of the post-deploy success flow.

**Semver bump suggestion** (`skills/publish/scripts/suggest_semver_bump.sh`):
- Reads git log since last publish tag
- Returns suggested bump: `major` if any commit message contains `BREAKING CHANGE` or `!:`, `minor` if any `feat:` commits, otherwise `patch`
- Prints: `Suggested version bump: <patch|minor|major> → <new_version>`
- Accepts `--current-version <v1.2.3>` override; if not given, reads from `publish-history.json` latest entry or defaults to `v0.0.0`
- In non-interactive mode (`--yes`): auto-accepts the suggestion without prompting

**Ledger entry format** (appended to `project/logs/publish-history.json`):
```json
{
  "id": "<uuid>",
  "version": "<vX.Y.Z>",
  "target": "<target_name>",
  "adapter": "<adapter_type>",
  "timestamp": "<ISO 8601 UTC>",
  "released_by": "<git user.name or CI>",
  "release_notes_path": "<path to notes file, or null>",
  "platform_state": "<uploaded|failed|partial>",
  "git_tag": "<vX.Y.Z>"
}
```

**Git tagging**:
- After user confirms the version bump (or auto in `--yes` mode): `git tag -a v<version> -m "Release v<version> — deployed to <target>"`
- If tag already exists: warn and skip (do not fail the deploy)

**Ledger write**:
- Read `publish-history.json` (initialise to `[]` if absent, using file locking)
- Append the new entry
- Write back with file locking (`.lock` file adjacent to `publish-history.json`)

**Script**: `skills/publish/scripts/write_ledger_entry.sh <target> <adapter> <platform_state> <notes_path> [--yes]`

## Prerequisites
T01 (release notes generator) should be complete.

## Acceptance Criteria
- [ ] `skills/publish/scripts/suggest_semver_bump.sh` exists and is executable
- [ ] Correctly suggests major/minor/patch from commit messages
- [ ] Accepts user confirmation interactively; auto-accepts with `--yes`
- [ ] `skills/publish/scripts/write_ledger_entry.sh` exists and is executable
- [ ] Appends correct JSON entry to `publish-history.json` with all required fields
- [ ] Creates annotated git tag matching ledger version
- [ ] Skips tagging if tag already exists (warn only)
- [ ] File locking used for all ledger writes
