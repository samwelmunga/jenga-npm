---
id: E19_S06
epic: E19
title: AI-Guided auto_iterate (Agent Overlay)
status: Backlog
date_created: 2026-07-10
date_started:
date_completed:
priority: P5
depends_on: E19_S05
---

# Story: AI-Guided auto_iterate (Agent Overlay)

## Goal
Layer an AI agent on top of the heuristic iteration engine: feed the run report, history, and current config to an LLM agent that produces config change proposals with detailed reasoning, confidence estimates, and tradeoff analysis. Requires proven heuristic iteration (E19_S05) and real usage data.

## Background
See deep-dive: `project/documentation/plans/train-roadmap.md` (Layer 5)
**Note:** This story should only be started after E19_S05 has been used in production and iteration quality can be assessed. See solution assessment Problem 6.

## Acceptance Criteria
- [ ] **AI agent invocation** — when `auto_iterate: ai` is set in config (distinct from `auto_iterate: true` for heuristic mode), a Jenga agent is invoked with: current `config.yaml`, `summary.md` report, `run.meta.json`, iteration history, and template manifest
- [ ] Agent produces a structured proposal: each suggested change includes field path, current value, proposed value, reasoning, confidence (low/med/high), estimated impact, and tradeoffs
- [ ] **Proposal format** is saved as `jobs/<job>/training-results/<run-id>/iterate-proposal.md` for human review
- [ ] Approval flow identical to heuristic phase (E19_S05): no autonomous mutation without explicit confirm
- [ ] AI proposals and heuristic proposals are clearly distinguished in iteration history
- [ ] **Guardrails**: agent is prevented from suggesting changes outside the template's declared tunable parameters; hard-coded safety limits (e.g., no suggestion to set `max_iter > 10000`); max 3 AI-suggested iterations per job before requiring human review reset
- [ ] `auto_iterate: false` disables both heuristic and AI layers

## Definition of Done
AI proposal is generated for a classifiers job with ≥2 prior runs. Proposal file is well-structured and cites specific metrics as evidence. Approval + run cycle completes successfully. Guardrails reject out-of-bounds suggestions.
