---
name: j:j-error
description: Polyfill alias of the error skill under a collision-safe directory name. Identical behavior to /error — Guided troubleshooting flow that gathers context about an error — where it occurs, what was attempted, what went wrong, and what was expected. Use when the bare /error form is shadowed by another tool's own built-in command of the same name.
keywords:
  - error
  - bug
  - fix
  - troubleshoot
  - debug
  - broken
  - j-error
  - polyfill
examples:
  - "I'm getting an error"
  - "help me fix this bug"
  - "j-error"
metadata: 
  prefered_agent: tester
---

# Error — Guided Troubleshooting

This skill is a literal-directory-name duplicate of `skills/error/`. It exists so that `/j-error` (and `j:j-error`) give a guaranteed-unshadowed way to reach the same flow as `/error`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/error` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh error` from `skills/error/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## Instructions

Ask the following questions to understand the background of the error:

1. Where does the error occur?
2. What are you trying to do?
3. What went wrong?
4. What was the expected outcome?

Then use the answers to investigate and resolve the issue by creating a issue using the /todo skill.
