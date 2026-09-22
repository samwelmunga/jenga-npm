---
name: j.continue
description: Check project status across PROJECT_SUMMARY.md, epics, and stories to determine what should be done next. Reports "All done!" if everything is complete.
keywords:
  - continue
  - next
  - proceed
  - what's next
  - status
  - j-continue
examples:
  - "what should I do next?"
  - "continue with the project"
  - "j-continue"
---

# Continue — Pick Up the Next Work Item

`skills/j-continue/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-continue/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/continue/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

1. **Check `project/PROJECT_SUMMARY.md`** — Determine if there is outstanding work at the project level.

2. **Check `project/epics/`** — If the project summary is done, check if any epics have remaining work.

3. **Check `project/stories/`** — If epics are done, check if any stories have remaining work.

   **Important:** Always check story status within an epic even if the epic itself is marked as done.

4. **If everything is complete** — Respond with: "All done! 🎉"

5. **Otherwise** — Begin work on the next incomplete item.
