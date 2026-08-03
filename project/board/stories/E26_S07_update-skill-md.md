---
id: E26_S07
epic_id: E26
title: Update SKILL.md with npm examples and metadata
status: Passed
date_created: 2026-07-31
date_started: 2026-08-01
date_completed: 2026-08-01
dates_previously_completed:
reopened_on:
reopened_reason:
docs: ["skills/publish/SKILL.md"]
tasks:
  - E26_S07_T01
---

# Story: Update SKILL.md with npm examples and metadata

As a developer reading the `/publish` skill documentation, I want the SKILL.md to include npm target examples and accurate metadata so that I know how to set up and deploy an npm package without reading internal adapter files.

## Acceptance Criteria
- [x] `skills/publish/SKILL.md` includes at least one invocation example for `setup --type npm` and one for `deploy --target npm-registry`
- [x] The sub-command table notes include `npm` as a supported type alongside `mobile-ios`
- [x] The `metadata.scope` field (or equivalent) no longer implies iOS-only scope (e.g. update from `ios-v1-complete` to a broader value)
- [x] `primary_target` (or equivalent metadata) is updated to reflect that multiple target types are now supported
- [x] Any iOS-specific language in the skill overview that would confuse an npm user is neutralised or moved to an iOS-specific section
- [x] The `--dry-run` flag is documented in the deploy sub-command description

## Definition of Done
- [x] `skills/publish/SKILL.md` has npm examples in the `examples` section of its frontmatter or body
- [x] Metadata fields no longer signal iOS-only scope
- [x] The `--dry-run` flag appears in the deploy sub-command description
- [x] The skill reads clearly as a multi-target publish tool, not an iOS-specific one
