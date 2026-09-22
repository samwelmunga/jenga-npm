---
name: j.brainstorm
description: Engage the scrum-master agent in a focused planning session to define, refine, or challenge features, improvements, tasks, stories, and epics. The agent asks probing questions, challenges assumptions, and helps shape ideas into actionable backlog items.
keywords:
  - brainstorm
  - plan
  - ideate
  - feature planning
  - requirements
  - j-brainstorm
examples:
  - "let's brainstorm ideas for X"
  - "I need to plan a new feature"
  - "j-brainstorm"
metadata: 
  prefered_agent: scrum-master
---

# Brainstorm — Collaborative Planning with the Scrum Master

`skills/j-brainstorm/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-brainstorm/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/brainstorm/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

1. **Invoke the `scrum-master` agent** — Pass the user's input directly to it as the opening prompt for the brainstorm session.

2. **Session framing** — Tell the `scrum-master` agent:
   - This is a **brainstorm session**, not a direct backlog-write session
   - The goal is to explore, challenge, and refine ideas **before** committing anything to the board
   - The agent should be especially frank, inquisitive, and suggestive during this session
   - No board items should be created until the user explicitly says they are ready to commit

3. **The `scrum-master` agent should:**
   - Ask focused, pointed questions to uncover goals, constraints, edge cases, and unknowns
   - Actively challenge assumptions — if something sounds vague, under-scoped, over-scoped, or contradicts existing work, say so plainly
   - Suggest alternative framings, decompositions, or approaches when the current one seems weak
   - Propose how the idea maps to epics, stories, or tasks — but hold off on writing anything until agreed
   - Keep the dialogue moving: after each exchange, either surface the next open question or propose a next step

4. **End of brainstorm** — Once the user is satisfied with the shape of the work, ask:
   - "Are you ready to commit these items to the board?"
   - If **yes** — proceed to create the relevant board items using `/todo` or the appropriate scrum board commands
   - If **no** — continue refining or close the session

### Session End

When the brainstorming session concludes (whether items were committed or the user chose to close), emit the following signal on its own line so the Jenga Router clears the active session:

```
[JENGA:SESSION_END:brainstorm]
```
