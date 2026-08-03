---
id: E03_S02
epic: E03
title: /jenga — Auto-Implementation Orchestrator
status: Passed
date_created: 2026-04-29
date_started: 2026-04-29
date_completed: 2026-04-29
---

# Story: /jenga — Auto-Implementation Orchestrator

## Goal
Provide a hands-free implementation mode as a dedicated `/jenga` skill. When invoked, it automatically picks the next eligible task from the board (Pending, dependencies met, in todo.md or derived from a queued story), starts its implementation via `/do`, and loops until no eligible tasks remain — all without user interaction.

## Acceptance Criteria
- [x] `/jenga` is a standalone skill (not a mode of `/dooo`)
- [x] The skill picks the first eligible task (Pending, dependencies met, in todo.md or story-derived) without presenting a choice list
- [x] The loop continues automatically until no eligible tasks remain
- [x] When no eligible tasks remain, the skill exits and informs the user
- [x] `/dooo` is restored to pure interactive behaviour (numbered list, user picks)
- [x] Both `skills/jenga/SKILL.md` and `.agents/skills/jenga/SKILL.md` are created

## Tasks
- [x] Create `skills/jenga/SKILL.md` with the full auto-implementation loop
- [x] Create `.agents/skills/jenga/SKILL.md` (mirror)
- [x] Revert `skills/dooo/SKILL.md` to interactive-only behaviour
- [x] Revert `.agents/skills/dooo/SKILL.md` to interactive-only behaviour
- [x] Update plan and summary documentation
