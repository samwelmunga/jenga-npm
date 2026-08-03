---
id: E24_S03_T03
story_id: E24_S03
epic_id: E24
title: Normalize evidence into synthesis context object
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Normalize evidence into synthesis context object

## Description
Define and populate a reusable synthesis context object that aggregates all evidence and is passed to the downstream document generation step. This object should be well-structured so that subsequent steps (E24_S04 synthesis, E24_S05 provenance) can consume it without re-reading sources.

The context object should include at minimum:
- `target_path`: the document target
- `objective`: the resolved generation objective (from rule table or user)
- `project_name`: from the highest-precedence source that mentions it
- `project_description`: brief description
- `features`: list of notable features/capabilities
- `getting_started`: any relevant setup/install/usage steps gathered
- `board_items`: list of relevant board items (id, title, status) with `docs` annotations matching the target
- `conflicts_resolved`: list of conflict resolution notes
- `sources_used`: which sources contributed evidence

## Prerequisites
- E24_S03_T01
- E24_S03_T02

## Acceptance Criteria
- [ ] Synthesis context object is defined and documented in the skill
- [ ] All fields above are populated (or explicitly null/empty when unavailable)
- [ ] The object is passed to downstream generation steps
