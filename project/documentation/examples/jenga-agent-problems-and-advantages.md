# Jenga AI — Problems It Solves & Advantages

## 1. What It Is

**Jenga AI** is a structured, multi-agent software development workflow built on top of Claude Code. It coordinates three specialised AI agents — **Scrum Master**, **Developer**, and **Tester** — through a shared scrum board, a trigger queue, and a set of slash-command skills to take a project from idea → verified, committed code.

---

## 2. Why It Exists — The Problems It Solves

### Without Jenga AI

| Problem | Reality |
|---|---|
| **AI has no memory of what it was doing** | Each Claude Code session starts from scratch — no awareness of past decisions, open tasks, or what was tested |
| **No role separation** | The AI both writes and "tests" code in the same context, leading to hallucinated test results and self-affirming bugs |
| **No structured planning** | Work happens ad-hoc; there's no Epic → Story → Task hierarchy to organise and track progress |
| **No handoff protocol** | If you switch from implementing to testing, you manually re-explain context every time |
| **No audit trail** | You can't replay *why* something was built, by which agent, based on which task |
| **Changes can't propagate to other projects** | Improvements to your workflow stay siloed in one project |
| **Sessions just... end** | Work-in-progress, unresolved problems, and incomplete stories silently vanish |

### With Jenga AI

| Problem Solved | Mechanism |
|---|---|
| **Persistent project memory** | `PROJECT_SUMMARY.md`, the scrum board (`project/board/`), and `events.json` carry full context across sessions |
| **Clear role separation** | Scrum Master plans, Developer implements, Tester validates — each with exclusive write permissions |
| **Structured planning** | Epics → Stories → Tasks enforced by schema; `/jenga`, `/brainstorm`, `/todo` skills manage this hierarchy |
| **Structured handoffs** | Every inter-agent call requires a typed **sender object** with task ID, commit SHAs, and worktree path |
| **Full audit trail** | Append-only `events.json` logs every event; `rapports/` captures problem analyses with full context |
| **Workflow distribution** | `/distribute` propagates workflow improvements to all registered consumer projects via `jenga.config.json` |
| **Graceful session endings** | `on_session_end.sh` hook detects new rapports and queues triggers for the next Scrum Master session |

---

## 3. How It Works — Core Mechanics

```
/init → /jenga → /todo → /do
                           │
                     Developer agent
                     (isolated worktree, commits)
                           │
                     Tester agent
                     (validates, updates board status)
                           │
                     SessionEnd hook
                     (writes triggers to queue)
                           │
                     Scrum Master (next session)
                     (processes queue, rollups, unblocks)
```

Key structures:
- **Scrum board** — `project/board/epics|stories|tasks/` with structured frontmatter
- **Trigger queue** — `project/queue/scrum_triggers.jsonl` for async Scrum Master handoffs
- **File locking** — `.lock` files prevent concurrent writes to board items
- **Sender objects** — typed JSON contracts passed between every agent call

---

## 4. When to Use It

**Use Jenga AI when:**
- You're building a non-trivial project across multiple sessions
- You want reliable test separation (the Tester *never* trusts the Developer's self-assessment)
- You need traceability — who did what, when, on which task
- You want to reuse and distribute your AI workflow across multiple projects

**You might not need it when:**
- You're doing a quick one-off script or single-session experiment
- Your project has no meaningful test surface
- You're the only agent and don't need role separation

---

## 5. Before / After Example

**Before (without Jenga AI):**
```
You: "Add user authentication"
Claude: [writes auth code, declares it works, session ends]
Next session:
You: "What's the status of auth?"
Claude: "I don't have context from the previous session."
```

**After (with Jenga AI):**
```
/todo → "Add user authentication" → linked to E01_S02
/do   → Developer creates worktree E01_S02_T01-auth
      → commits at milestones
      → hands off to Tester with sender object
Tester → runs tests, updates board status to ✅ Passed
SessionEnd → writes status_review trigger
Next session:
/status → "E01_S02 ✅ complete, E01_S03 pending"
```
