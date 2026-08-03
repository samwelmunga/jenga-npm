---
id: E22_S04_T03
story_id: E22_S04
epic_id: E22
title: Upload step, state machine history, and post-deploy manual steps
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Upload step, state machine history, and post-deploy manual steps

## Description
Complete the iOS adapter pipeline by implementing the upload step, the full state machine history logging, and post-deploy manual step surfacing.

**Upload step**:
- Use `xcrun altool` or `xcrun notarytool` depending on what is available and the App Store Connect API key format
- Prefer `xcrun notarytool` for newer macOS toolchains; fall back to `xcrun altool` with a warning
- Upload command uses `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, and `APP_STORE_CONNECT_PRIVATE_KEY_PATH` env vars
- On success: write state `uploaded` to history entry; adapter returns control to orchestrator
- On failure: write state `failed` to history entry; exit 3 with full upload output

**State machine history logging** (`project/logs/publish-history.json`):
- On adapter start, append a new entry:
  ```json
  {
    "id": "<uuid>",
    "target": "<target_name>",
    "adapter": "mobile-ios",
    "state": "building",
    "started_at": "<ISO 8601>",
    "completed_at": null,
    "export_method": "<ad-hoc|app-store>",
    "steps": []
  }
  ```
- Each step (build, sign, export, upload) appends to `"steps"` with `{ "step": "<name>", "status": "passed|failed", "timestamp": "..." }`
- On success: update `state` to `uploaded` and set `completed_at`
- On failure: update `state` to `failed` and set `completed_at`
- History file initialised to `[]` if absent
- Use file locking (`.lock` file) before writing

**Post-deploy manual steps**:
- After successful upload, print a clearly formatted block:
  ```
  ✅ Upload complete. Next manual steps:
  1. Go to App Store Connect → Apps → [Your App] → TestFlight (or App Store)
  2. Find the new build and submit for review / release
  3. Set release notes if required
  ```
- If `--non-interactive` flag is set, print the same block to stdout so CI logs capture it

## Prerequisites
T02 (build, sign, export) should be complete.

## Acceptance Criteria
- [ ] Upload step uses `xcrun notarytool` (or `altool` fallback) with API key env vars
- [ ] Successful upload writes `uploaded` state and `completed_at` to history entry
- [ ] Failed upload writes `failed` state and exits 3
- [ ] Full publish state machine tracked in `project/logs/publish-history.json`
- [ ] History file initialised to `[]` if absent, written with file locking
- [ ] Post-deploy manual steps printed clearly after successful upload
- [ ] `--dry-run`: upload command printed with `[DRY RUN]` prefix, state written as `uploaded` so dry runs look like successes
