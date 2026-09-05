---
name: j:j-brainstorm
description: Polyfill alias of the brainstorm skill under a collision-safe directory name. Identical behavior to /brainstorm — Engage the scrum-master agent in a focused planning session to define, refine, or challenge features, improvements, tasks, stories, and epics. The agent asks probing questions, challenges assumptions, and helps shape ideas into actionable backlog items. Use when the bare /brainstorm form is shadowed by another tool's own built-in command of the same name.
keywords:
  - brainstorm
  - plan
  - ideate
  - feature planning
  - requirements
  - j-brainstorm
  - polyfill
examples:
  - "let's brainstorm ideas for X"
  - "I need to plan a new feature"
  - "j-brainstorm"
metadata: 
  prefered_agent: scrum-master
---

# Brainstorm — Collaborative Planning with the Scrum Master

This skill is a literal-directory-name duplicate of `skills/brainstorm/`. It exists so that `/j-brainstorm` (and `j:j-brainstorm`) give a guaranteed-unshadowed way to reach the same flow as `/brainstorm`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/brainstorm` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh brainstorm` from `skills/brainstorm/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

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
