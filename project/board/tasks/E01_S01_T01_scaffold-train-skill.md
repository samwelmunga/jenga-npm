---
id: E01_S01_T01
story_id: E01_S01
epic_id: E01
title: Scaffold /train skill structure
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Scaffold /train skill structure

## Description
Create the `skills/train/` directory and `SKILL.md` file following the existing skill conventions in the project. The skill must be invocable as `/train` within a Claude Code session. Set up the entry point structure — argument parsing for `new <type> <job-name>` and any supported CLI flags (`--model`, `--epochs`, etc.).

## Prerequisites
None.

## Acceptance Criteria
- [ ] `skills/train/SKILL.md` exists and follows the same structure as existing skills
- [ ] Skill is invocable as `/train` in a Claude Code session
- [ ] Argument signature `new <type> <job-name>` is parsed correctly
- [ ] Unrecognised subcommands print a usage/help message
