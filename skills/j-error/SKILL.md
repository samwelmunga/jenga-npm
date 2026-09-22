---
name: j.error
description: Guided troubleshooting flow that gathers context about an error — where it occurs, what was attempted, what went wrong, and what was expected.
keywords:
  - error
  - bug
  - fix
  - troubleshoot
  - debug
  - broken
  - j-error
examples:
  - "I'm getting an error"
  - "help me fix this bug"
  - "j-error"
metadata: 
  prefered_agent: tester
---

# Error — Guided Troubleshooting

`skills/j-error/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-error/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/error/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

Ask the following questions to understand the background of the error:

1. Where does the error occur?
2. What are you trying to do?
3. What went wrong?
4. What was the expected outcome?

Then use the answers to investigate and resolve the issue by creating a issue using the /todo skill.
