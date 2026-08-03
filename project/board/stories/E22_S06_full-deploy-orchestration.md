---
id: E22_S06
epic_id: E22
title: Full deploy orchestration & ownership matrix
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
tasks:
  - E22_S06_T01
  - E22_S06_T02
  - E22_S06_T03
---

# Story: Full deploy orchestration & ownership matrix

## Goal
Wire S01–S05 into the full end-to-end `/publish deploy` flow. Define the agent
ownership matrix (which of Scrum Master, Developer, Tester approves/executes/validates
a publish action). Validate the complete flow on the iOS target from a clean project
with only `publish.json` configured.

## Acceptance Criteria
- [ ] `/publish deploy` full flow implemented end-to-end:
  1. Prompt target selection (suggestions from publish.json; wizard if config incomplete)
  2. Validate all env vars for selected target
  3. Show board summary — closed tasks/stories since last tag (informational)
  4. Run pre-deploy mandatory + configured gates (from S03); halt on failure
  5. Generate release note draft (from S05); user reviews/edits
  6. Semver bump suggestion + confirmation prompt
  7. Final confirmation: "Deploy v<x.y.z> to <target>? [y/N]"
  8. Execute adapter pipeline (from S04 for iOS)
  9. Run post-deploy gates
  10. On success: write ledger entry + create git tag (from S05)
  11. Surface manual steps
- [ ] Non-interactive path: all prompts skipped when `--yes` flag and `--target` are provided; semver bump defaults to `patch` unless `--minor` or `--major` is passed
- [ ] Agent ownership matrix documented in `skills/publish/assets/ownership-matrix.md`:
  - Developer: initiates `/publish deploy`, resolves gate failures, executes adapter
  - Tester: may invoke `/publish deploy` to staging as part of a test cycle
  - Scrum Master: never directly deploys; reviews deploy context in `/status`
- [ ] Dry-run: `--dry-run` flag runs all steps except actual adapter execution and git tag creation
- [ ] Integration validated: a single iOS staging deploy from a configured project completes successfully or surfaces clear error at each failure point

## Notes
- This story depends on S01–S05 being complete
- Focus on correctness and failure clarity over speed — a deploy that fails silently is worse than a slow one that fails loudly

## Definition of Done
- [x] `skills/publish/scripts/publish_deploy.sh` exists and is executable
- [x] Full 11-step deploy flow implemented and sequenced correctly
- [x] Non-interactive path (`--yes --target`): all prompts suppressed; semver defaults to `patch`
- [x] `--dry-run`: adapter uses dry-run, tag skipped, dry-run ledger entry written
- [x] Exit codes 1–4 propagated correctly in all failure paths
- [x] `skills/publish/assets/ownership-matrix.md` exists with full agent role table and trust boundary note
- [x] SKILL.md `deploy` section shows 11-step flow and references `publish_deploy.sh`
- [x] SKILL.md `metadata.scope` updated to `ios-v1-complete`
