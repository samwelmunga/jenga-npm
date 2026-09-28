# Capturing Mid-Flow Ideas

> **How-to:** Handling a new thought, tangent, or feature idea without derailing your current work.

---

## The Problem

You're three tasks into implementing a feature when a better idea surfaces — or a separate concern entirely. If you chase it, you lose the thread of your current work. If you ignore it, you lose the idea.

Jenga AI has two skills designed for exactly this tension: `j.btw` and `j.spinoff`.

---

## `j.btw` — Capture and Continue

Use `j.btw` when you have a new idea that's clearly related to your current epic or story but isn't what you're working on right now.

```
(You're implementing E01_S02 — Refresh Tokens)
j.btw add a "remember me" checkbox to the login form
```

The Scrum Master:
1. Identifies which epic/story this belongs to (`E01_S03 — Login UI`)
2. Proposes: "Add as E01_S03_T04?"
3. You confirm — it's written to the board as Pending
4. Control returns to your current task

The idea is captured. Your current work is uninterrupted. Nothing is lost.

**`j.btw` is for:** Small additions, clarifications, or enhancements that you can classify in 30 seconds and defer cleanly.

---

## `j.spinoff` — Capture a Diverging Thread

Use `j.spinoff` when the new topic is more substantial — it needs its own story or epic, or it requires prerequisite thinking before it can be properly sized.

```
(Mid-session on rate limiting)
You bring up caching strategy
j.spinoff
```

The Scrum Master:
1. Confirms or asks you to describe the diverging topic
2. Summarises all context gathered so far in the conversation
3. Asks: *"Are the requirements clear enough to act on, or would you like to run `j.brainstorm` first?"*
4. Saves a `j.todo` entry with the full context summary
5. Returns focus to the primary thread

**`j.spinoff` is for:** Topics that need their own planning, have prerequisites to flesh out, or would take more than a few minutes to properly size.

---

## The Divergence Detection Pattern

The Scrum Master is trained to detect when a conversation shifts subject. When it notices:

```
It looks like we're moving into a new topic. How would you like to handle it?
1. Capture the new topic as a j.todo (I'll return to what we were working on)
2. Capture the current topic as a j.todo (I'll continue with the new topic)
3. Capture both as j.todo items (you choose which to continue first)
4. Ignore it — tell me which topic to continue with
```

This prompt appears automatically. You don't have to remember to use `j.btw` or `j.spinoff` — the Scrum Master will surface the choice for you.

---

## A Note on Context Preservation

Every `j.todo` created through `j.btw` or `j.spinoff` includes:
- A one-sentence summary of the captured topic
- Key details and decisions already discussed
- Open questions or unknowns raised so far

This isn't just a title. It's everything the Developer and Tester will need when the task is eventually picked up — even if that's three weeks later.

---

## Choosing Between `j.btw` and `j.spinoff`

| Situation | Use |
|---|---|
| Quick addition to a known story | `j.btw` |
| Needs its own story or epic | `j.spinoff` |
| Unclear whether it belongs to current epic | `j.spinoff` (Scrum Master will size it) |
| Already have full context, just need to defer | `j.btw` |
| Needs `j.brainstorm` before it can be sized | `j.spinoff` |

When in doubt, `j.spinoff` — it's the safer choice because it always preserves full context.

---

→ Back to [Intro Guide](../intro-guide.md) | Next: [Parallel Tasks](./parallel-tasks.md)
