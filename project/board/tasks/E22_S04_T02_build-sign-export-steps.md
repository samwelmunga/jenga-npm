---
id: E22_S04_T02
story_id: E22_S04
epic_id: E22
title: Build, sign, and export steps — xcodebuild pipeline
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Build, sign, and export steps — xcodebuild pipeline

## Description
Implement the build, sign, and export phases of the iOS adapter pipeline. All commands are implemented as a shell script `skills/publish/scripts/ios_pipeline.sh` that is invoked by the adapter.

**Build phase**:
- Run: `xcodebuild archive -scheme <scheme> -configuration <config> -archivePath <archive_path>`
- `scheme`, `config`, and `archive_path` read from `publish.json` target config
- On failure: write state `failed` to history entry, exit 3 with full xcodebuild output

**Sign phase**:
- Applied during `xcodebuild -exportArchive` via ExportOptions.plist (generated from template)
- ExportOptions.plist is generated at runtime from `publish.json` values:
  - `method`: `ad-hoc` (staging) or `app-store` (production)
  - `teamID`: from `publish.json`
  - `provisioningProfiles`: `{ "<bundle_id>": "<PROVISIONING_PROFILE_UUID env var>" }`
  - `signingIdentity`: from `CODE_SIGN_IDENTITY` env var
- Template for ExportOptions.plist stored at `skills/publish/assets/ExportOptions.plist.template`
- Generated file written to a temp directory, cleaned up after use

**Export phase**:
- Run: `xcodebuild -exportArchive -archivePath <archive_path> -exportPath <export_path> -exportOptionsPlist <generated_plist>`
- On failure: write state `failed`, exit 3 with full output
- On success: write state `exporting` → (next phase handles upload)

## Prerequisites
T01 (adapter scaffold and env validation) should be complete.

## Acceptance Criteria
- [ ] `skills/publish/scripts/ios_pipeline.sh` exists and is executable
- [ ] Build step runs `xcodebuild archive` with correct flags from `publish.json`
- [ ] ExportOptions.plist generated from template using config + env var values
- [ ] Export step runs `xcodebuild -exportArchive` with generated plist
- [ ] Both steps write state transitions to the history entry on success and failure
- [ ] Failures exit 3 with full xcodebuild output
- [ ] `--dry-run` flag: all xcodebuild commands printed with `[DRY RUN]` prefix, not executed
