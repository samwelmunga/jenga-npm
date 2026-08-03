---
id: E12_S01_T02
story_id: E12_S01
epic_id: E12
title: Implement fallback passthrough when router is unreachable
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Implement fallback passthrough when router is unreachable

## Description
If the Jenga Router is not running or unreachable, the hook must silently fall back to passthrough — outputting the original prompt unchanged. The hook must never block the user or fail loudly. Fallback must complete in < 500ms total (including attempted router connection).

## Prerequisites
- E12_S01_T01

## Acceptance Criteria
- [x] Router down: hook outputs original prompt and exits 0
- [x] No error output visible to the user on fallback
- [x] Hook completes in < 500ms including failed router round-trip
