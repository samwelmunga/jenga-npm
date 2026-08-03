---
name: continue
description: Check project status across PROJECT_SUMMARY.md, epics, and stories to determine what should be done next. Reports "All done!" if everything is complete.
keywords:
  - continue
  - next
  - proceed
  - what's next
  - status
examples:
  - "what should I do next?"
  - "continue with the project"
---

# Continue — Pick Up the Next Work Item

## Instructions

1. **Check `project/PROJECT_SUMMARY.md`** — Determine if there is outstanding work at the project level.

2. **Check `project/epics/`** — If the project summary is done, check if any epics have remaining work.

3. **Check `project/stories/`** — If epics are done, check if any stories have remaining work.

   **Important:** Always check story status within an epic even if the epic itself is marked as done.

4. **If everything is complete** — Respond with: "All done! 🎉"

5. **Otherwise** — Begin work on the next incomplete item.
