---
id: E22_S06_T03
story_id: E22_S06
epic_id: E22
title: Agent ownership matrix and final SKILL.md integration
status: Passed
date_created: 2026-07-11
date_started:
date_completed: 2026-07-11
assigned_to: developer
---

# Task: Agent ownership matrix and final SKILL.md integration

## Description
Write the agent ownership matrix document and ensure SKILL.md accurately reflects the complete, wired deploy flow.

**Agent ownership matrix** (`skills/publish/assets/ownership-matrix.md`):
A reference document defining who initiates, executes, and validates each publish action:

| Action | Developer | Tester | Scrum Master |
|---|---|---|---|
| `/publish setup` | Initiates and owns | May run to configure test targets | Never |
| `/publish deploy --target staging` | Initiates | May run as part of test cycle | Never directly |
| `/publish deploy --target production` | Initiates with explicit confirmation | Reviews ledger entry post-deploy | Reviews `/status` only |
| `/publish history` | Reads for context | Reads for test baseline | Reads in `/status` review |
| `/publish release-notes` | Generates and reviews draft | May read draft for test context | Reviews content for sprint summary |
| Gate failure resolution | Owns rework | Validates rework | Escalates if blocked |
| Ledger entry disputes | Never modifies | Never modifies | Flags as rapport; human resolves |

Include a note on the trust boundary: the adapter may only call `xcodebuild` and `xcrun`; arbitrary shell commands are not permitted.

**SKILL.md final wiring**:
- Update the `/publish deploy` section to show the full 11-step flow (brief numbered list)
- Reference `publish_deploy.sh` as the implementation script
- Reference `ownership-matrix.md` in a new `## Agent Roles` section
- Update `metadata.scope` to `ios-v1-complete`
- Confirm all sub-command sections reference their implementation scripts

## Prerequisites
T02 (full deploy script) must be complete.

## Acceptance Criteria
- [ ] `skills/publish/assets/ownership-matrix.md` exists with full agent role table
- [ ] Trust boundary note included
- [ ] SKILL.md `/publish deploy` section shows the 11-step flow and references `publish_deploy.sh`
- [ ] SKILL.md has `## Agent Roles` section referencing `ownership-matrix.md`
- [ ] `metadata.scope` updated to `ios-v1-complete`
- [ ] All four sub-command sections reference their implementation scripts
