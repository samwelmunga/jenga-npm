---
id: E12_S01_T01
story_id: E12_S01
epic_id: E12
title: Create `hooks/prompt_router.sh` executable hook script
status: Passed
date_created: 2026-05-09
date_started: 2026-05-09
date_completed: 2026-05-09
assigned_to: developer
---

# Task: Create `hooks/prompt_router.sh` executable hook script

## Description
Create `hooks/prompt_router.sh` as an executable shell script that implements the Claude Code `UserPromptSubmit` hook. The script reads the incoming prompt from the environment variable provided by Claude Code's hook system, calls the router's `route_prompt` tool, and outputs the (possibly transformed) prompt.

## Prerequisites
None

## Acceptance Criteria
- [x] `hooks/prompt_router.sh` exists and is executable (`chmod +x`)
- [x] Script reads the prompt from the correct Claude Code hook environment variable
- [x] If `action` is `"invoke"`: outputs `transformed` prompt
- [x] If `action` is `"passthrough"`: outputs original prompt unchanged
