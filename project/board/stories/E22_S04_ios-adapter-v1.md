---
id: E22_S04
epic_id: E22
title: iOS App Store adapter v1
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
tasks:
  - E22_S04_T01
  - E22_S04_T02
  - E22_S04_T03
---

# Story: iOS App Store adapter v1

## Goal
Implement the first deployment adapter: iOS App Store. The adapter handles build,
code signing, IPA generation, and upload to App Store Connect via the configured
API key. All commands executed via allowlisted tool calls (no arbitrary shell
expansion). Partial failure handling is explicit — if upload fails after a
successful build, the state is recorded and the user is given a recovery path.

## Acceptance Criteria
- [ ] Adapter defined at `skills/publish/adapters/mobile-ios.md` (prompt template driving execution)
- [ ] Adapter supports two export methods: `AdHoc` (staging) and `AppStore` (production)
- [ ] Build step: runs `xcodebuild archive` with scheme/config from `publish.json`
- [ ] Sign step: applies provisioning profile and signing identity from env var references in config
- [ ] Export step: generates IPA using `xcodebuild -exportArchive`
- [ ] Upload step: uses `xcrun altool` or `xcrun notarytool` / App Store Connect API key to upload
- [ ] Publish state machine: tracks states `building | signing | uploading | uploaded | failed`; state written to `project/logs/publish-history.json` so partial failures can be resumed
- [ ] On upload success: adapter returns control to orchestrator (tagging + history in S05)
- [ ] Manual steps surfaced post-deploy: "Go to App Store Connect → [app] → Submit for Review"
- [ ] All env vars validated present before adapter starts; missing vars = exit code 4 with clear message listing which vars are absent
- [ ] Adapter tested against a dry-run mode (`--dry-run`) that logs all commands without executing them

## Notes
- Trust boundary: adapter may only invoke allowlisted commands (`xcodebuild`, `xcrun`, `fastlane` if configured). No raw shell string expansion.
- The `--dry-run` mode is essential for CI validation without Apple credentials
- Android adapter is out of scope for v1 — to be added in a future story

## Definition of Done
- [x] `skills/publish/adapters/mobile-ios.md` exists with contract, phases, state machine, and env vars documented
- [x] `skills/publish/scripts/validate_ios_env.sh` exists and exits 4 on missing env vars
- [x] `skills/publish/scripts/ios_pipeline.sh` exists and is executable
- [x] Build step runs `xcodebuild archive` with config from `publish.json`
- [x] ExportOptions.plist generated from template at `skills/publish/assets/ExportOptions.plist.template`
- [x] Export step runs `xcodebuild -exportArchive` with generated plist
- [x] Upload step uses `xcrun notarytool` (or `altool` fallback)
- [x] State machine transitions tracked in `project/logs/publish-history.json`
- [x] Post-deploy manual steps printed after successful upload
- [x] `--dry-run` mode prints all commands without executing them
