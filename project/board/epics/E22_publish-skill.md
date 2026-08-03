---
id: E22
title: /publish Skill — Deployment Pipeline Orchestrator
status: Passed
date_created: 2026-07-11
date_started:
date_completed:
stories:
  - E22_S01
  - E22_S02
  - E22_S03
  - E22_S04
  - E22_S05
  - E22_S06
---

# Epic: /publish Skill — Deployment Pipeline Orchestrator

## Purpose
Introduce a `/publish` skill that guides and executes deployment pipelines from the
current project to remote environments (staging, production, app stores). The skill
is a single entry point with bounded sub-commands, executes pipelines directly where
automation is possible, always confirms before deploying, and surfaces manual steps
where automation is not possible.

Architecture decisions (from deep-dive):
- Single `/publish` skill with sub-commands (`setup`, `deploy`, `history`, `release-notes`)
- Thin orchestrator in SKILL.md; execution logic lives in adapter scripts
- Non-interactive contract is the primary spec; interactive wizard wraps it
- v1 scope: one platform adapter — iOS App Store
- One canonical publish ledger (`publish-history.json`); git tags mirror it
- Mandatory global quality gates + optional per-target gates

## Sub-commands
| Command | Description |
|---|---|
| `/publish setup [<target>]` | Run setup wizard for a deployment target |
| `/publish deploy` | Interactive deploy with confirmation |
| `/publish history` | Show publish history |
| `/publish release-notes` | Generate release notes without deploying |

## Definition of Done
- [ ] `skills/publish/SKILL.md` exists with correct frontmatter
- [ ] `project/configs/publish.json` schema is defined and validated by the skill
- [ ] Non-interactive contract documented (flags, env vars, exit codes)
- [ ] Setup wizard runs and writes valid `publish.json` config
- [ ] Mandatory global quality gates enforced before any deploy
- [ ] iOS App Store adapter executes build → sign → upload flow
- [ ] Release notes generated from git log + board tasks since last publish tag
- [ ] Canonical publish ledger (`project/logs/publish-history.json`) written on success
- [ ] Git tag created on successful deploy
- [ ] All manual steps surfaced clearly to the user post-deploy
- [ ] Skill listed in `/help` output

## Reference
Design document: `project/documentation/plans/publish-skill-design.md`
Scrutiny assessment: `project/documentation/plans/scrutiny-publish-skill.md`
Solution assessment: `project/documentation/plans/solution-assessment-publish-skill.md`
