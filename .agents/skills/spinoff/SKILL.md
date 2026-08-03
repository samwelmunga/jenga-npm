---
name: spinoff
description: Capture a diverging topic mid-conversation. Collects context, optionally runs /brainstorm for prerequisites, saves a /todo entry, and returns focus to the primary thread.
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

2. **Collect context** — Summarise the relevant context gathered so far in the current conversation that relates to the diverging topic. This summary will pre-fill the `/todo` description so no context is lost.

3. **Check prerequisites** — Ask the user:
   > "Are the requirements for **[diverging topic]** clear enough to act on, or would you like to run `/brainstorm` first to flesh them out?"

   Offer these choices:
   - **"Requirements are clear — save the todo now"** → go to step 5
   - **"Run /brainstorm first"** → go to step 4

4. **Run /brainstorm (if chosen)** — Invoke the `/brainstorm` skill, passing the diverging topic and collected context as the opening prompt. After `/brainstorm` completes, use the refined output as the todo description.

5. **Save the /todo** — Populate `skills/todo/assets/todo_handoff_template.md` with the context collected so far:
   - **Mission title**: the diverging topic name (as confirmed in step 1)
   - **Goal / objective**: what the diverging topic aims to achieve
   - **Affected files or scope**: any files or modules identified during the conversation
   - **Intended approach**: the context/approach collected in step 2 (or the refined output from step 4)
   - **Epic/Story linkage**: include a reference if a relevant Epic or Story was identified, otherwise `None`

   Then invoke the `/todo` skill with the populated template. Since the template fields are pre-filled, `/todo` will skip any questions already answered.

6. **Return focus** — Inform the user:
   > "✅ Diverging topic saved as a todo. Returning focus to **[primary topic]**."

   Then resume the primary conversation thread exactly where it was paused.
