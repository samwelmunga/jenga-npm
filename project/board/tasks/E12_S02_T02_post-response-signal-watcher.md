---
id: E12_S02_T02
story_id: E12_S02
epic_id: E12
title: Implement post-response signal detection and stripping
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement post-response signal detection and stripping

## Description
Implement a mechanism (hook or watcher script) that scans Claude's output for the `[JENGA:SESSION_END:<skill_name>]` marker. When found: (1) call `end_session(skill)` on the router, (2) strip the marker from the displayed output. The marker must not appear in Claude's visible output.

## Prerequisites
- E12_S02_T01

## Acceptance Criteria
- [x] Marker detected in output triggers `end_session` call on router
- [x] Marker is stripped from visible output
- [x] Non-matching output is passed through unchanged
