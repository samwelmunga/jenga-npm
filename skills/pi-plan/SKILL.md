---
name: pi-plan
description: Define or expand project Epics in PROJECT_SUMMARY.md. Use this at the start of a project to establish its foundation, AND whenever the user wants to add major new features, plan a significant new area of work, or make epic-level changes to an existing project. Trigger whenever you hear things like "new feature area", "big change", "new epic", "expand the project", "add a major capability", or "plan a new phase" — even mid-project.
keywords:
  - epic
  - template
  - expand
  - new feature area
  - project structure
examples:
  - "add a new epic for X"
  - "expand the project with a new feature area"
metadata: 
  prefered_agent: scrum-master
---

# Pi-plan — Define and Expand Project Epics

## When to use this skill

- **New project**: Gather project description and goals, then define the initial set of Epics.
- **Existing project**: Add one or more new Epics to an existing `PROJECT_SUMMARY.md` when the user wants to plan a major new area of work.

Detect which mode you're in by checking whether `project/PROJECT_SUMMARY.md` already exists and has Epics defined.

---

## Mode 1: New Project

1. **Gather project info** — Ask the user for:
   - **Description**: A high-level explanation of what the app or service does (an "elevator pitch").
   - **Goals**: What specific problem(s) the project is intended to solve. Be clear about the desired outcome.

2. **Clarify scope** — If the responses are unclear or lack sufficient detail, ask clarifying questions. The goal is a broad understanding — avoid delving into granular details unless they directly impact the core idea.

3. **Define Epics** — Using the description and goals, define the Epics section of `project/PROJECT_SUMMARY.md`. Each Epic is a JSON object:

   - **title**: Concise title for the Epic.
   - **short_description**: Brief explanation of what this Epic aims to achieve.
   - **date_added**: Today's date (YYYY-MM-DD).
   - **date_started**: Set to `null` initially.
   - **related_stories**: Empty array `[]` initially.

Example: `./assets/epic.json`.

Story files created under `project/board/stories/` should follow `./assets/story_template.md`.
---

## Mode 2: Existing Project — Adding New Epics

1. **Read the existing file** — Load `project/PROJECT_SUMMARY.md` to understand the current project context and existing Epics. This prevents duplication and ensures new Epics are coherent with what's already there.

2. **Understand the new scope** — Ask the user:
   - What is the new capability, feature area, or phase they want to add?
   - What problem does it solve, or what goal does it serve?
   - Are there any dependencies on existing Epics?

3. **Clarify if needed** — Same as Mode 1: ask follow-up questions if the scope is vague, but stay high-level.

4. **Define new Epics** — Draft one or more new Epic objects using the same schema as above, then append them to the existing Epics list in `project/PROJECT_SUMMARY.md`. Do not modify existing Epics unless the user explicitly asks.

5. **Confirm before writing** — Show the user the proposed new Epic(s) and get confirmation before updating the file.