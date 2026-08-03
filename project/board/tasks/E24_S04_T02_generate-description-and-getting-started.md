---
id: E24_S04_T02
story_id: E24_S04
epic_id: E24
title: Generate project-overview docs with Description and Getting Started
status: Passed
date_created: 2026-07-23
date_started:
date_completed: 2026-07-23
assigned_to: developer
---

# Task: Generate project-overview docs with Description and Getting Started sections

## Description
Implement the generation template for project-overview documents (i.e. `README.md`). The generated file must include at minimum:

1. **Description** — what the project is, what problem it solves, who it's for. Max 1000 words. Source from synthesis context (`project_description`, `features`).
2. **Getting Started** — minimal steps to install, configure, and run. Source from synthesis context (`getting_started`, codebase manifests).

The content must be accurate (sourced from evidence) and concise. No filler text or placeholder sections.

## Prerequisites
- E24_S04_T01

## Acceptance Criteria
- [ ] Generated README.md includes a Description section (≤1000 words)
- [ ] Generated README.md includes a Getting Started section
- [ ] Content is sourced from the synthesis context (not hallucinated)
- [ ] Output is valid Markdown
