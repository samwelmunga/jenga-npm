---
id: E08_S03
epic_id: E08
title: SAD Map in Architecture View
status: Done
date_created: 2026-05-05
date_started:
date_completed: 2026-05-05
tasks: [E08_S03_T01, E08_S03_T02, E08_S03_T03, E08_S03_T04]
---

# Story: SAD Map in Architecture View

As a user, I want to see a visual diagram of the project's services and components — and how they connect — in the Architecture tab, so I can quickly understand the system's structure at a glance.

## Acceptance Criteria
- [ ] Architecture tab renders a SAD (Software Architecture Diagram) map section
- [ ] The diagram visualises services/components as nodes and their connections as edges (boxes & arrows)
- [ ] Data is parsed exclusively from local project files (config files, docs, board epics/stories)
- [ ] No external network calls are made to produce the diagram
- [ ] Empty or unresolvable data states are handled gracefully with a meaningful placeholder

## Definition of Done
- [ ] SAD map renders correctly from local file data
- [ ] Diagram is integrated into the existing Architecture view alongside tech stack and dependencies
- [ ] Component connections are accurate relative to what is described in local documentation
