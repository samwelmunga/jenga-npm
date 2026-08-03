---
id: E26_S07_T01
story_id: E26_S07
epic_id: E26
title: Update publish SKILL.md with npm examples and metadata
status: Passed
date_created: 2026-07-31
date_started: 2026-08-01
date_completed: 2026-08-01
dates_previously_completed:
reopened_on:
reopened_reason:
assigned_to: developer
docs: ["skills/publish/SKILL.md"]
---

# Task: Update publish SKILL.md with npm examples and metadata

## Description
Edit `skills/publish/SKILL.md` to reflect that `/publish` now supports multiple target types. Specifically:

1. **Invocation examples** — add at least two npm examples to the `examples` section:
   - `/publish setup --type npm`
   - `/publish deploy --target npm-registry`
   - `/publish deploy --target npm-registry --dry-run`

2. **Sub-command table** — update the `setup` row notes to list `npm` alongside `mobile-ios` as a supported type

3. **Metadata scope** — update `metadata.scope` (currently `ios-v1-complete` or similar) to something like `multi-target-v2` or equivalent that no longer implies iOS-only

4. **`primary_target` field** — if present, update to reflect multi-target support or remove it

5. **Overview language** — replace any iOS-specific framing in the intro paragraphs with neutral multi-target language; move iOS-specific details into an "iOS App Store" section if needed

6. **`--dry-run` flag** — add documentation of the `--dry-run` flag under the `deploy` sub-command description

## Prerequisites

## Acceptance Criteria
- [x] `skills/publish/SKILL.md` has at least two npm invocation examples
- [x] Sub-command table notes reference `npm` as a supported type
- [x] `metadata.scope` (or equivalent) no longer reads as iOS-only
- [x] `--dry-run` flag is documented in the `deploy` sub-command section
- [x] The skill overview reads clearly as a multi-target publish tool
