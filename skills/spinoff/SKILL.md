---
name: spinoff
description: Capture a diverging topic mid-conversation. Collects context and a mandatory origin, optionally runs /brainstorm for prerequisites, saves an /idea entry, and returns focus to the primary thread.
keywords:
  - spinoff
  - diverge
  - side topic
  - capture topic
  - new thread
examples:
  - "let's spinoff this idea"
  - "capture this as a separate thread"
metadata:
  prefered_agent: scrum-master
---

# Spinoff — Capture a Diverging Topic

## Instructions

1. **Identify the diverging topic** — Ask the user to confirm or briefly describe the diverging topic.
   - Pre-fill the prompt with a one-sentence summary of what the agent detected as the diverging subject (if known).
   - Example: *"It looks like we started discussing [detected topic]. Is that the diverging thread you'd like to capture, or would you like to describe it differently?"*

2. **Collect context** — Summarise the relevant context gathered so far in the current conversation that relates to the diverging topic. This summary will pre-fill the `/idea` description so no context is lost.

   **Capture the Origin (mandatory)** — Record:
   - The EST id (task, story, or epic) that was in progress when the divergence happened, if any is currently being worked. If none is in progress (e.g. the divergence happened during a `/brainstorm`-only session with no active EST item), use `None` — this is a valid, expected case, not a gap to fill in later.
   - A one-line summary of what the user was doing at the time of the divergence.

3. **Check prerequisites** — Ask the user:
   > "Are the requirements for **[diverging topic]** clear enough to act on, or would you like to run `/brainstorm` first to flesh them out?"

   Offer these choices:
   - **"Requirements are clear — save now"** → go to step 5
   - **"Run /brainstorm first"** → go to step 4

4. **Run /brainstorm (if chosen)** — Invoke the `/brainstorm` skill, passing the diverging topic and collected context as the opening prompt. After `/brainstorm` completes, use the refined output as the idea description.

5. **Save via `/idea`** — Populate `skills/idea/assets/idea_handoff_template.md` with the context collected so far:
   - **Mission title**: the diverging topic name (as confirmed in step 1)
   - **Goal / objective**: what the diverging topic aims to achieve
   - **Affected files or scope**: any files or modules identified during the conversation
   - **Intended approach**: the context/approach collected in step 2 (or the refined output from step 4)
   - **Epic/Story linkage**: include a reference if a relevant Epic or Story was identified, otherwise `None`
   - **Origin**: the EST id (or `None`) and one-line context summary captured in step 2

   Then invoke the `/idea` skill with the populated template. Since the template fields are pre-filled, `/idea` will skip any questions already answered. The entry lands in `project/ideas.md`, not `project/todo.md` — `/spinoff` no longer writes to the todo list directly.

6. **Return focus** — Inform the user:
   > "✅ Diverging topic saved as an idea. Returning focus to **[primary topic]**."

   Then resume the primary conversation thread exactly where it was paused.
