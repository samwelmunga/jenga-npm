---
name: j:idea
description: Capture a loosely-defined idea to project/ideas.md — a lightweight, "maybe someday" log with no board or promotion overhead.
keywords:
  - idea
  - capture idea
  - log idea
  - brain dump
  - maybe someday
examples:
  - "capture this as an idea"
  - "log this idea for later"
  - "I have a rough idea I want to jot down"
metadata:
  prefered_agent: scrum-master
---

# Idea — Lightweight Idea Capture

## Instructions

1. **Ensure `project/ideas.md` exists** — If it doesn't exist, it will be auto-created by `idea_manager.sh` from `skills/idea/assets/idea_template.md` — no manual action needed.

2. **Ask the user about the idea:**
   - What's the idea?
   - Any known context worth noting (why it came up, what it might relate to)?

   Keep this light — `/idea` is a low-overhead capture, not a structured mission intake like `/todo`.

3. **Add to `project/ideas.md`** by running:
   ```
   bash scripts/idea_manager.sh add '<idea>'
   ```

4. **Ask the user**: "Capture another idea, or done?"
   - If **another** — go back to step 2.
   - If **done** — exit.

   Unlike `/todo`, `/idea` never offers to execute, refine, or promote the captured idea(s) at the end. There is no `/do`-style follow-up here — `/idea` has no refine or promotion logic of its own.

## For Reference Only — Promotion Convention (not implemented here)

`/idea` does not implement any refine or promotion mechanism. This section documents, for reference, how promotion is expected to work elsewhere so future flows stay consistent:

- **Promoting an idea** means re-running `/brainstorm` on it, which routes onward to `/btw` or `/todo` as normal. That routing behavior already exists and is out of scope for `/idea`.
- **Terminal idea states** are marked directly in `project/ideas.md` using the same HTML-comment tag convention `project/todo.md` uses for `RECONCILED`:
  - `PROMOTED` — the idea was picked up via `/brainstorm` and turned into board work.
  - `DISCARDED` — the idea was reviewed and dropped.

  Example (mirroring `project/todo.md`'s tagging style):
  ```
  Add dark mode toggle to settings page <!-- PROMOTED -->
  Rewrite onboarding copy in a more casual tone <!-- DISCARDED -->
  ```

No agent invoked by `/idea` applies these tags or acts on them — that is reserved for a future promotion step (e.g. within `/brainstorm`).
