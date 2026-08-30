# Board Hierarchy

> **Concept:** Why work is structured as Epics → Stories → Tasks, and how to use that hierarchy well.

---

## The Three Levels

| Level | What it represents | Example |
|---|---|---|
| **Epic** | A large body of work with a clear goal | "User Authentication System" |
| **Story** | A complete user-facing or system-level outcome | "As a user, I want to log in with email/password" |
| **Task** | A concrete technical unit of work | "Add JWT validation middleware" |

The hierarchy isn't bureaucracy — it's a **scope contract**. Each level answers a different question:

- **Epic** → *What are we building and why?*
- **Story** → *Who benefits and what's the complete outcome?*
- **Task** → *What's the smallest independently-implementable unit?*

---

## Why the Hierarchy Exists

Without structure, AI-assisted development tends toward:
- **Scope creep** — a "small feature" quietly expands
- **Missing context** — the Developer picks up a task without knowing the broader goal
- **Incomplete verification** — the Tester doesn't know what "done" looks like

The board hierarchy solves all three:

1. **Stories have Acceptance Criteria** — written so a Tester can verify them without asking
2. **Tasks reference their parent story** — the Developer always knows the broader context
3. **Epics and Stories have a Definition of Done** — rollup only happens when all criteria are met

---

## How Rollup Works

Jenga AI automatically promotes status up the hierarchy when all children pass:

```
Task T01 → Passed ✅
Task T02 → Passed ✅
Task T03 → Passed ✅
           ↓
Story S01 → Passed ✅ (Tester triggers story_rollup)
           ↓
(When all stories under E01 pass)
Epic E01 → Passed ✅ (Scrum Master processes trigger)
```

This means you don't manually mark a story complete — the Tester writes the trigger, and the Scrum Master processes it at the start of the next session.

---

## Practical Guidelines

**When to create an Epic vs. a Story:**
- If the work naturally decomposes into 3+ complete user outcomes → Epic
- If it's a single complete outcome → Story directly under an existing Epic
- When in doubt, use `/brainstorm` — the Scrum Master will help you decide

**When to create a Task vs. a Story:**
- Tasks are technical sub-steps *within* a story, not standalone features
- If someone outside the project would say "I want X" about it → Story
- If only a Developer would say "I need to do X to implement Y" → Task

**The Maintenance Epic pattern:**
Jenga AI reserves a "Maintenance" epic as the default home for chores, refactors, and housekeeping tasks that don't belong under a feature epic. Use it rather than forcing technical debt into unrelated stories.

---

## Naming Conventions

Board files follow strict naming so they sort naturally and can be referenced unambiguously:

| Type | File name pattern | Example |
|---|---|---|
| Epic | `E##_<slug>.md` | `E01_auth-system.md` |
| Story | `E##_S##_<slug>.md` | `E01_S02_email-login.md` |
| Task | `E##_S##_T##_<slug>.md` | `E01_S02_T01_jwt-middleware.md` |

Numbers are zero-padded. Always. `E01`, `S03`, `T07` — never `E1`, `S3`, `T7`.

---

→ Back to [Intro Guide](../intro-guide.md) | Next concept: [Session Continuity](./session-continuity.md)
