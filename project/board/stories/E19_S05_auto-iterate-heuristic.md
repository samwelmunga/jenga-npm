---
id: E19_S05
epic: E19
title: Recommendation-Only auto_iterate (Heuristic Phase)
status: Backlog
date_created: 2026-07-10
date_started:
date_completed:
priority: P4
depends_on: E19_S04
---

# Story: Recommendation-Only auto_iterate (Heuristic Phase)

## Goal
Implement the first phase of `auto_iterate`: after a completed full run, analyze the history of comparable runs and suggest concrete config changes — but require explicit user or agent approval before mutating anything or launching a new run.

## Background
See deep-dive: `project/documentation/plans/train-roadmap.md` (Layer 4)
See solution assessment: Problem 6 (recommendation-only is the RECOMMENDED path over autonomous execution).

## Acceptance Criteria
- [ ] **Gate conditions** — `auto_iterate` recommendations are only generated when: (a) template declares `supports_iteration: true` in manifest, (b) at least 1 prior comparable run exists (same dataset ref, same template version), (c) primary metric direction is declared
- [ ] **Heuristic engine** — after a successful full run, compares primary metric against prior runs; if metric is within `improvement_threshold` (configurable, default 2%), suggests candidate hyperparameter adjustments based on template-declared tunable params
- [ ] Suggestions are presented as a numbered list with rationale and estimated delta (e.g., "Increase `n_estimators` from 100 → 200: typically improves accuracy by ~1–3% at 2× training time")
- [ ] **No autonomous mutation** — user or agent must explicitly approve via prompt (`/train iterate approve`) or `--auto-approve` flag; config is never mutated without explicit confirmation
- [ ] Approved suggestion is applied as a config patch, saved to `jobs/<job>/input/config.yaml`, previous config backed up as `config.yaml.<run-id>.bak`
- [ ] Iteration history tracked in registry: each suggestion, approval/rejection, and resulting metric delta
- [ ] `auto_iterate: false` in config completely disables all suggestion logic

## Definition of Done
After two comparable runs, suggestions are generated with evidence. Approval flow mutates config and triggers a new run. Rejection is a no-op. History shows the iteration chain.
