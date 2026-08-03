---
id: E22_S05_T03
story_id: E22_S05
epic_id: E22
title: /publish history command and tag-ledger reconciliation
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: /publish history command and tag-ledger reconciliation

## Description
Implement the `/publish history` sub-command and the tag-ledger reconciliation utility.

**`/publish history`** (`skills/publish/scripts/show_history.sh`):
- Reads `project/logs/publish-history.json`
- If file doesn't exist or is empty `[]`: print `No publish history found.` and exit 0
- Otherwise display a human-readable table:
  ```
  Version   Target          Date                  State      Tag
  v1.2.0    staging-ios     2026-07-11T09:00:00Z  uploaded   v1.2.0
  v1.1.0    production-ios  2026-07-10T14:30:00Z  uploaded   v1.1.0
  ```
- Supports `--limit <n>` flag (show last N entries, default: all)
- Supports `--target <name>` flag (filter by target)
- Supports `--json` flag (raw JSON output of filtered entries)

**Tag-ledger reconciliation** (`skills/publish/scripts/reconcile_tags.sh`):
- Compare all semver git tags (`v*.*.*`) on current branch against `publish-history.json` entries
- For each git tag with no ledger entry:
  - Append a `partial` ledger entry: `"platform_state": "partial"`, `"released_by": "unknown"`, note: `"Manually tagged without /publish"`
  - Print: `⚠️  Tag <v> found without ledger entry — created partial entry`
- For each ledger entry with no matching git tag:
  - Create the missing tag: `git tag -a <version> <commit_sha_from_entry_or_HEAD> -m "Retroactive tag from /publish ledger"`
  - Print: `⚠️  Ledger entry <v> had no git tag — created retroactively`
- Print summary: `Reconciliation complete. X new ledger entries, Y new git tags.`
- `--dry-run` flag: print what would be done without making changes

**SKILL.md update**:
- Update the `/publish history` section to reference `show_history.sh`
- Add a brief `## Ledger & Tagging` section documenting reconciliation and append-only rule

## Prerequisites
T02 (publish ledger) must be complete.

## Acceptance Criteria
- [ ] `skills/publish/scripts/show_history.sh` exists and is executable
- [ ] Displays history table with all columns; handles empty ledger gracefully
- [ ] Supports `--limit`, `--target`, and `--json` flags
- [ ] `skills/publish/scripts/reconcile_tags.sh` exists and is executable
- [ ] Creates partial ledger entries for unmatched git tags
- [ ] Creates retroactive git tags for unmatched ledger entries
- [ ] `--dry-run` prints changes without applying them
- [ ] SKILL.md updated with history command reference and ledger/tagging section
