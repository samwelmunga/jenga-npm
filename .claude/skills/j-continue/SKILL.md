---
name: j:j-continue
description: Polyfill alias of the continue skill under a collision-safe directory name. Identical behavior to /continue — Check project status across PROJECT_SUMMARY.md, epics, and stories to determine what should be done next. Reports "All done!" if everything is complete. Use when the bare /continue form is shadowed by another tool's own built-in command of the same name.
keywords:
  - continue
  - next
  - proceed
  - what's next
  - status
  - j-continue
  - polyfill
examples:
  - "what should I do next?"
  - "continue with the project"
  - "j-continue"
---

# Continue — Pick Up the Next Work Item

This skill is a literal-directory-name duplicate of `skills/continue/`. It exists so that `/j-continue` (and `j:j-continue`) give a guaranteed-unshadowed way to reach the same flow as `/continue`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/continue` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh continue` from `skills/continue/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## Instructions

1. **Check `project/PROJECT_SUMMARY.md`** — Determine if there is outstanding work at the project level.

2. **Check `project/epics/`** — If the project summary is done, check if any epics have remaining work.

3. **Check `project/stories/`** — If epics are done, check if any stories have remaining work.

   **Important:** Always check story status within an epic even if the epic itself is marked as done.

4. **If everything is complete** — Respond with: "All done! 🎉"

5. **Otherwise** — Begin work on the next incomplete item.
