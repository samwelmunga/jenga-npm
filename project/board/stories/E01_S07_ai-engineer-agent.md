---
id: E01_S07
epic_id: E01
title: AI Engineer Agent
status: Passed
date_created: 2026-04-29
date_started: 2026-04-29
date_completed: 2026-04-29
tasks: []
---

# Story: AI Engineer Agent

As a user setting up or training an AI model, I want a dedicated `ai_engineer` agent that handles the deep technical work — so that I don't need to understand LLM/ML internals directly. The `scrum-master` acts as a mediator between me and the `ai_engineer`: translating technical questions and proposals into plain language for me, and converting my responses back into precise technical terms for the engineer.

## Agent Contract

### `ai_engineer`
- Specialises in AI/ML model setup, configuration, training, and evaluation (LLMs, classical ML, fine-tuning, etc.)
- Communicates exclusively through the `scrum-master` mediator — never addresses the user directly
- Provides technical decisions, options, and questions to the `scrum-master` for translation

### `scrum-master` (mediator role)
- Receives technical output from `ai_engineer` and rephrases it in plain, user-friendly language
- Receives user responses and converts them back to precise technical terms before forwarding to `ai_engineer`
- Maintains conversation continuity and flags when clarification is needed

## Acceptance Criteria
- [ ] An `agents/ai_engineer.md` file exists defining the agent's persona, specialisations, and communication contract
- [ ] `agents/scrum-master.md` is updated with a "Mediator Mode" section describing how to translate between the user and `ai_engineer`
- [ ] The `/train` skill (E01_S01) is updated to invoke `ai_engineer` for model-specific decisions
- [ ] `ai_engineer` never outputs directly to the user — all user-facing communication goes via `scrum-master`
- [ ] Example interaction is documented in `ai_engineer.md` showing the full translation loop

## Definition of Done
- [ ] `agents/ai_engineer.md` exists and is complete
- [ ] `agents/scrum-master.md` updated with Mediator Mode section
- [ ] `/train` skill wired to `ai_engineer`
- [ ] All acceptance criteria pass

## Note for E01_S01 Implementation

`skills/train/SKILL.md` does not yet exist — the `/train` skill is delivered by **E01_S01** which has not been implemented at the time of writing this story.

When E01_S01 is implemented, the following wiring must be added to `skills/train/SKILL.md`:

- At any decision point involving model architecture, framework selection, or hyperparameter choices, the skill should pause and invoke `ai_engineer` (routed through `scrum-master` as mediator) rather than making opinionated defaults silently.
- Specifically, when `workflow.auto_run` is `false` or when the user is prompted for configuration decisions, forward the relevant context to `scrum-master` with a request for `ai_engineer` to produce a `DECISION / OPTIONS / RECOMMENDATION` block.
- `scrum-master` translates the output into plain language before presenting it to the user.
- The user's choice is then converted back to precise technical config values (e.g. `model_name`, `learning_rate`, `batch_size`) before being written into `config.yaml`.
