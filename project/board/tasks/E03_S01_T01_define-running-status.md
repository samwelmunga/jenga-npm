---
id: E03_S01_T01
story_id: E03_S01
epic_id: E03
title: Define running status in AGENT.md or workflow.json
status: Done
date_created: 2026-05-08
date_started: 2026-05-08
date_completed: 2026-05-08
assigned_to: developer
---

# Task: Define running status in AGENT.md or workflow.json

## Description
Add the `running` status value to the project's status conventions. This status indicates a task or story that has been handed off to a background sub-agent and is currently being implemented. Update `AGENT.md` and/or `project/configs/workflow.json` (whichever is the canonical location for status conventions) to include `running` with a clear description.

## Prerequisites
None

## Acceptance Criteria
- [ ] `running` status is defined in AGENT.md and/or workflow.json
- [ ] Description clearly states it means "handed off to a background sub-agent, currently in-flight"
- [ ] Existing status values are unchanged
